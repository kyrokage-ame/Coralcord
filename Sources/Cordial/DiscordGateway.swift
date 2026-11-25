import Foundation
import UIKit

/// Legacy service interface retained for source compatibility with the HTTP client.
protocol DiscordService {
    func fetchCurrentUser() async throws -> AccountProfile
    func fetchConversations() async throws -> [RemoteConversation]
    func sendMessage(channelID: String, content: String) async throws
}

struct AccountProfile: Decodable {
    let id: String
    let username: String
}

struct RemoteConversation: Decodable, Identifiable {
    let id: String
    let title: String
}

enum DiscordIntegrationError: Error {
    case notConfigured
}

// MARK: - Gateway event models

struct GatewayReady: Decodable {
    let sessionId: String?
    let resumeGatewayURL: String?
    let user: AccountProfile?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case resumeGatewayURL = "resume_gateway_url"
        case user
    }
}

struct GatewayVoiceStateUpdate: Decodable {
    let guildId: String?
    let channelId: String?
    let userId: String?
    let sessionId: String?
    let selfMute: Bool?
    let selfDeaf: Bool?
    let mute: Bool?
    let deaf: Bool?

    enum CodingKeys: String, CodingKey {
        case guildId = "guild_id"
        case channelId = "channel_id"
        case userId = "user_id"
        case sessionId = "session_id"
        case selfMute = "self_mute"
        case selfDeaf = "self_deaf"
        case mute, deaf
    }
}

struct GatewayVoiceServerUpdate: Decodable {
    let token: String?
    let guildId: String?
    let endpoint: String?

    enum CodingKeys: String, CodingKey {
        case token
        case guildId = "guild_id"
        case endpoint
    }
}

struct GatewayCall: Decodable {
    let channelId: String?
    let messageId: String?
    let region: String?
    let ringing: [String]?

    enum CodingKeys: String, CodingKey {
        case channelId = "channel_id"
        case messageId = "message_id"
        case region, ringing
    }
}

enum DiscordGatewayEvent {
    case ready(GatewayReady)
    case voiceStateUpdate(GatewayVoiceStateUpdate)
    case voiceServerUpdate(GatewayVoiceServerUpdate)
    case callCreate(GatewayCall)
    case callUpdate(GatewayCall)
    case other(name: String, data: Data)
}

/// Discord Gateway v10 event transport only. This class does not implement voice
/// media, RTP/UDP, encryption, audio capture/playback, or a completed voice call.
/// Supply a valid authorized Discord token; it is never written to logs.
final class DiscordGatewayClient {
    typealias EventHandler = (DiscordGatewayEvent) -> Void
    typealias StateHandler = (String) -> Void

    private let token: String
    private let eventHandler: EventHandler
    private let stateHandler: StateHandler?
    private let lock = NSLock()
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var sequence: Int?
    private var heartbeatInterval: TimeInterval = 0
    private var heartbeatAcknowledged = true
    private var manuallyDisconnected = false
    private var resumeOnReconnect = false
    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?

    var sessionId: String? { lock.lock(); defer { lock.unlock() }; return storedSessionId }
    var userId: String? { lock.lock(); defer { lock.unlock() }; return storedUserId }
    private var storedSessionId: String?
    private var storedResumeGatewayURL: String?
    private var storedUserId: String?

    /// Uses the user-session Identify shape observed in public desktop clients.
    /// This is undocumented and can be rejected or changed by Discord at any time.
    init(token: String, eventHandler: @escaping EventHandler,
         stateHandler: StateHandler? = nil) {
        self.token = token
        self.eventHandler = eventHandler
        self.stateHandler = stateHandler
    }

    /// Connect to the v10 Gateway. Calling after disconnect starts a fresh connection.
    func connect() {
        lock.lock()
        if socket != nil {
            lock.unlock()
            return
        }
        manuallyDisconnected = false
        let resuming = resumeOnReconnect
        if !resuming { sequence = nil }
        let gatewayBase = resuming ? (storedResumeGatewayURL ?? "wss://gateway.discord.gg") : "wss://gateway.discord.gg"
        heartbeatAcknowledged = true
        lock.unlock()

        guard var components = URLComponents(string: gatewayBase) else {
            stateHandler?("Invalid Gateway URL")
            return
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "v" || $0.name == "encoding" }
        queryItems.append(URLQueryItem(name: "v", value: "10"))
        queryItems.append(URLQueryItem(name: "encoding", value: "json"))
        components.queryItems = queryItems
        guard let url = components.url else {
            stateHandler?("Invalid Gateway URL")
            return
        }
        let newSession = URLSession(configuration: .default)
        let newSocket = newSession.webSocketTask(with: url)
        lock.lock()
        session = newSession
        socket = newSocket
        lock.unlock()
        newSocket.resume()
        stateHandler?("Connecting")
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
    }

    func disconnect() {
        lock.lock()
        manuallyDisconnected = true
        let oldSocket = socket
        socket = nil
        let oldSession = session
        session = nil
        let oldReceive = receiveTask
        receiveTask = nil
        let oldHeartbeat = heartbeatTask
        heartbeatTask = nil
        let pendingReconnect = reconnectTask
        reconnectTask = nil
        lock.unlock()
        oldReceive?.cancel()
        oldHeartbeat?.cancel()
        pendingReconnect?.cancel()
        oldSocket?.cancel(with: .normalClosure, reason: nil)
        oldSession?.invalidateAndCancel()
        stateHandler?("Disconnected")
    }

    /// Send Gateway opcode 4 (Update Voice State) to join, change, or leave a voice channel.
    /// Use `channelId: nil` to leave. This negotiates signaling state only, not media.
    func updateVoiceState(guildId: String?, channelId: String?, selfMute: Bool = false,
                          selfDeaf: Bool = false) async throws {
        var data: [String: Any] = [
            "guild_id": guildId as Any? ?? NSNull(),
            "channel_id": channelId as Any? ?? NSNull(),
            "self_mute": selfMute,
            "self_deaf": selfDeaf
        ]
        // Ensure JSONSerialization receives explicit JSON null values.
        if guildId == nil { data["guild_id"] = NSNull() }
        if channelId == nil { data["channel_id"] = NSNull() }
        try await sendAwait(opcode: 4, data: data)
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            lock.lock(); let currentSocket = socket; lock.unlock()
            guard let currentSocket = currentSocket else { return }
            do {
                let message = try await currentSocket.receive()
                let bytes: Data
                switch message {
                case .string(let text): bytes = Data(text.utf8)
                case .data(let data): bytes = data
                @unknown default: continue
                }
                try handleGatewayMessage(bytes)
            } catch {
                lock.lock()
                let shouldReconnect = !manuallyDisconnected
                socket = nil
                session = nil
                let hb = heartbeatTask
                heartbeatTask = nil
                lock.unlock()
                hb?.cancel()
                stateHandler?("Gateway connection ended")
                if shouldReconnect {
                    reconnect(resume: storedSessionId != nil, delay: 1)
                }
                return
            }
        }
    }

    private func handleGatewayMessage(_ bytes: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let opcode = root["op"] as? Int else { return }
        if let seq = root["s"] as? Int {
            lock.lock(); sequence = seq; lock.unlock()
        }
        let data = root["d"]
        switch opcode {
        case 10: // Hello
            guard let hello = data as? [String: Any],
                  let intervalMs = hello["heartbeat_interval"] as? Double else { return }
            lock.lock(); heartbeatInterval = intervalMs / 1000.0; lock.unlock()
            lock.lock()
            let shouldResume = resumeOnReconnect
            resumeOnReconnect = false
            let currentSessionID = storedSessionId
            let lastSequence = sequence
            lock.unlock()
            if shouldResume, let currentSessionID {
                send(opcode: 6, data: [
                    "token": token,
                    "session_id": currentSessionID,
                    "seq": lastSequence ?? -1
                ]) { [weak self] error in
                    if error != nil { self?.stateHandler?("Gateway resume send failed") }
                }
            } else {
                sendIdentify()
            }
            startHeartbeat()
        case 11: // Heartbeat ACK
            lock.lock(); heartbeatAcknowledged = true; lock.unlock()
        case 1: // Server-requested heartbeat
            sendHeartbeat()
        case 7: // Reconnect request
            stateHandler?("Gateway requested a reconnect")
            reconnect(resume: storedSessionId != nil, delay: 1)
        case 9: // Invalid session
            let canResume = (data as? Bool) ?? false
            stateHandler?(canResume ? "Gateway session recovering" : "Gateway rejected the session; retrying Identify")
            if !canResume {
                lock.lock()
                storedSessionId = nil
                storedResumeGatewayURL = nil
                storedUserId = nil
                lock.unlock()
            }
            reconnect(resume: canResume, delay: Double.random(in: 1...5))
        case 0:
            guard let name = root["t"] as? String else { return }
            let payload = (try? JSONSerialization.data(withJSONObject: data ?? NSNull())) ?? Data("null".utf8)
            let decoder = JSONDecoder()
            switch name {
            case "RESUMED":
                lock.lock(); reconnectAttempts = 0; lock.unlock()
                stateHandler?("Gateway session restored")
            case "READY":
                let ready = try decoder.decode(GatewayReady.self, from: payload)
                lock.lock()
                storedSessionId = ready.sessionId
                storedResumeGatewayURL = ready.resumeGatewayURL
                storedUserId = ready.user?.id
                reconnectAttempts = 0
                lock.unlock()
                eventHandler(.ready(ready))
            case "VOICE_STATE_UPDATE":
                eventHandler(.voiceStateUpdate(try decoder.decode(GatewayVoiceStateUpdate.self, from: payload)))
            case "VOICE_SERVER_UPDATE":
                eventHandler(.voiceServerUpdate(try decoder.decode(GatewayVoiceServerUpdate.self, from: payload)))
            case "CALL_CREATE":
                eventHandler(.callCreate(try decoder.decode(GatewayCall.self, from: payload)))
            case "CALL_UPDATE":
                eventHandler(.callUpdate(try decoder.decode(GatewayCall.self, from: payload)))
            default:
                eventHandler(.other(name: name, data: payload))
            }
        default:
            break
        }
    }

    private func sendIdentify() {
        send(opcode: 2, data: [
            "token": token,
            "capabilities": 4605,
            "properties": [
                "os": "iOS", "browser": "Coralcord", "device": "Coralcord",
                "system_locale": Locale.current.identifier, "has_client_mods": false,
                "browser_user_agent": "Coralcord/1.0.0 (iOS)", "browser_version": "1.0.0",
                "os_version": UIDevice.current.systemVersion,
                "referrer": "", "referring_domain": "", "referrer_current": "",
                "referring_domain_current": "", "release_channel": "stable",
                "client_build_number": 0, "client_event_source": NSNull()
            ],
            "presence": ["status": "online", "since": 0, "afk": false],
            "compress": false,
            "client_state": [
                "guild_hashes": [String: String](), "highest_last_message_id": "0",
                "read_state_version": 0, "user_guild_settings_version": -1,
                "user_settings_version": -1
            ]
        ]) { [weak self] error in
            if error != nil { self?.stateHandler?("Identify send failed") }
        }
    }

    private func startHeartbeat() {
        lock.lock()
        heartbeatTask?.cancel()
        let interval = heartbeatInterval
        lock.unlock()
        guard interval > 0 else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                let nanos = UInt64(interval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                guard !Task.isCancelled, let self = self else { return }
                self.lock.lock()
                let acknowledged = self.heartbeatAcknowledged
                self.heartbeatAcknowledged = false
                self.lock.unlock()
                if !acknowledged {
                    self.stateHandler?("Heartbeat ACK missed; reconnect required")
                    self.disconnect()
                    return
                }
                self.sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() {
        lock.lock(); let seq = sequence; lock.unlock()
        send(opcode: 1, data: seq as Any? ?? NSNull()) { [weak self] error in
            if error != nil { self?.stateHandler?("Heartbeat send failed") }
        }
    }

    private func reconnect(resume: Bool, delay: TimeInterval) {
        lock.lock()
        guard !manuallyDisconnected else { lock.unlock(); return }
        guard reconnectAttempts < 3 else {
            lock.unlock()
            stateHandler?("Discord Gateway session could not be restored. Sign in again or try later.")
            return
        }
        reconnectAttempts += 1
        manuallyDisconnected = true
        resumeOnReconnect = resume
        if !resume { sequence = nil }
        let oldSocket = socket
        socket = nil
        let oldSession = session
        session = nil
        let oldReceive = receiveTask
        receiveTask = nil
        let oldHeartbeat = heartbeatTask
        heartbeatTask = nil
        reconnectTask?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.connect()
        }
        reconnectTask = task
        lock.unlock()

        oldReceive?.cancel()
        oldHeartbeat?.cancel()
        oldSocket?.cancel(with: .goingAway, reason: nil)
        oldSession?.invalidateAndCancel()
    }

    private func send(opcode: Int, data: Any, completion: ((Error?) -> Void)? = nil) {
        lock.lock(); let currentSocket = socket; lock.unlock()
        guard let currentSocket = currentSocket else {
            completion?(DiscordIntegrationError.notConfigured)
            return
        }
        do {
            let bytes = try JSONSerialization.data(withJSONObject: ["op": opcode, "d": data], options: [.fragmentsAllowed])
            guard let text = String(data: bytes, encoding: .utf8) else {
                completion?(DiscordIntegrationError.notConfigured)
                return
            }
            currentSocket.send(.string(text)) { error in completion?(error) }
        } catch {
            completion?(error)
        }
    }

    private func sendAwait(opcode: Int, data: Any) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(opcode: opcode, data: data) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
