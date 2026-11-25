import Foundation

struct DiscordVoiceReady {
    let ssrc: UInt32
    let ip: String
    let port: UInt16
    let modes: [String]
}

struct DiscordVoiceSessionDescription {
    let mode: String
    let secretKey: Data
    let daveProtocolVersion: Int?
}

enum DiscordVoiceGatewayEvent {
    case ready(DiscordVoiceReady)
    case sessionDescription(DiscordVoiceSessionDescription)
    case heartbeatAck
    case speaking(userID: String?, ssrc: UInt32?, speaking: Int?)
    case dave(opcode: Int, payload: Data)
    case clientsConnect(userIDs: [String])
    case clientDisconnect(userID: String)
    case other(opcode: Int, payload: Data)
    case disconnected(Error?)
}

/// Voice Gateway v8 signaling transport. It does not itself encrypt or carry RTP media.
final class DiscordVoiceGatewayClient {
    typealias EventHandler = (DiscordVoiceGatewayEvent) -> Void

    private let endpoint: String
    private let serverID: String
    private let channelID: String
    private let userID: String
    private let sessionID: String
    private let token: String
    private let onEvent: EventHandler
    private let lock = NSLock()
    private var urlSession: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatInterval: TimeInterval = 0
    private var sequence: Int?
    private var pendingHeartbeatNonce: Int?
    private var manuallyClosed = false

    init(endpoint: String, serverID: String, channelID: String, userID: String, sessionID: String,
         token: String, onEvent: @escaping EventHandler) {
        self.endpoint = endpoint
        self.serverID = serverID
        self.channelID = channelID
        self.userID = userID
        self.sessionID = sessionID
        self.token = token
        self.onEvent = onEvent
    }

    func connect() throws {
        lock.lock()
        guard socket == nil else { lock.unlock(); return }
        manuallyClosed = false
        sequence = nil
        pendingHeartbeatNonce = nil
        lock.unlock()

        let raw = endpoint.hasPrefix("wss://") ? String(endpoint.dropFirst(6)) : endpoint
        let hostAndPath = raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        let urlString = "wss://\(hostAndPath)/?v=8&encoding=json"
        guard let url = URL(string: urlString) else { throw VoiceGatewayError.invalidEndpoint }
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        lock.lock()
        urlSession = session
        socket = task
        lock.unlock()
        task.resume()
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
    }

    func disconnect() {
        lock.lock()
        manuallyClosed = true
        let task = socket
        socket = nil
        let session = urlSession
        urlSession = nil
        let receiver = receiveTask
        receiveTask = nil
        let heartbeat = heartbeatTask
        heartbeatTask = nil
        lock.unlock()
        receiver?.cancel()
        heartbeat?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    func selectUDPProtocol(address: String, port: UInt16, mode: String) async throws {
        try await send(opcode: 1, data: [
            "protocol": "udp",
            "data": ["address": address, "port": Int(port), "mode": mode]
        ])
    }

    func sendSpeaking(ssrc: UInt32, speaking: Bool) async throws {
        try await send(opcode: 5, data: [
            "speaking": speaking ? 1 : 0,
            "delay": 0,
            "ssrc": Int(ssrc),
            "user_id": userID
        ])
    }

    /// Client-originated DAVE binary messages do not include a server sequence number.
    func sendDAVEBinary(opcode: UInt8, payload: Data) async throws {
        guard opcode == 26 || opcode == 28 else { throw VoiceGatewayError.invalidBinaryOpcode }
        var bytes = Data([opcode])
        bytes.append(payload)
        lock.lock(); let task = socket; lock.unlock()
        guard let task else { throw VoiceGatewayError.notConnected }
        try await task.send(.data(bytes))
    }

    func sendDAVEJSON(opcode: Int, data: [String: Any]) async throws {
        guard opcode == 23 || opcode == 31 else { throw VoiceGatewayError.invalidJSON }
        try await send(opcode: opcode, data: data)
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            lock.lock(); let task = socket; lock.unlock()
            guard let task else { return }
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text): try handle(Data(text.utf8))
                case .data(let bytes): try handle(bytes)
                @unknown default: continue
                }
            } catch {
                lock.lock()
                let intentional = manuallyClosed
                socket = nil
                urlSession = nil
                let heartbeat = heartbeatTask
                heartbeatTask = nil
                lock.unlock()
                heartbeat?.cancel()
                if !intentional { onEvent(.disconnected(error)) }
                return
            }
        }
    }

    private func handle(_ bytes: Data) throws {
        guard let root = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              let opcode = root["op"] as? Int else {
            handleBinaryDAVEMessage(bytes)
            return
        }
        if let seq = root["seq"] as? Int {
            lock.lock(); sequence = seq; lock.unlock()
        }
        let payload = (try? JSONSerialization.data(withJSONObject: root["d"] ?? NSNull(), options: [.fragmentsAllowed])) ?? Data("null".utf8)
        switch opcode {
        case 8: // Hello
            guard let data = root["d"] as? [String: Any],
                  let intervalMs = data["heartbeat_interval"] as? Double else { return }
            lock.lock(); heartbeatInterval = intervalMs / 1000; lock.unlock()
            Task { try? await send(opcode: 0, data: [
                "server_id": serverID,
                "channel_id": channelID,
                "user_id": userID,
                "session_id": sessionID,
                "token": token,
                "video": false,
                "streams": [],
                "max_dave_protocol_version": 1
            ]) }
            startHeartbeat()
        case 2: // Ready
            guard let data = root["d"] as? [String: Any],
                  let ssrc = (data["ssrc"] as? NSNumber)?.uint32Value,
                  let ip = data["ip"] as? String,
                  let port = (data["port"] as? NSNumber)?.uint16Value,
                  let modes = data["modes"] as? [String] else { return }
            onEvent(.ready(DiscordVoiceReady(ssrc: ssrc, ip: ip, port: port, modes: modes)))
        case 4: // Session Description
            guard let data = root["d"] as? [String: Any],
                  let mode = data["mode"] as? String,
                  let key = data["secret_key"] as? [NSNumber] else { return }
            onEvent(.sessionDescription(DiscordVoiceSessionDescription(
                mode: mode, secretKey: Data(key.map { UInt8(truncating: $0) }),
                daveProtocolVersion: data["dave_protocol_version"] as? Int
            )))
        case 6: // Heartbeat ACK
            let ack = (root["d"] as? [String: Any])?["t"] as? Int
            lock.lock()
            if ack == pendingHeartbeatNonce { pendingHeartbeatNonce = nil }
            lock.unlock()
            onEvent(.heartbeatAck)
        case 5: // Speaking
            let data = root["d"] as? [String: Any] ?? [:]
            onEvent(.speaking(userID: data["user_id"] as? String,
                              ssrc: (data["ssrc"] as? NSNumber)?.uint32Value,
                              speaking: data["speaking"] as? Int))
        case 11: // Clients Connect
            let data = root["d"] as? [String: Any] ?? [:]
            onEvent(.clientsConnect(userIDs: data["user_ids"] as? [String] ?? []))
        case 13: // Client Disconnect
            if let data = root["d"] as? [String: Any], let userID = data["user_id"] as? String {
                onEvent(.clientDisconnect(userID: userID))
            }
        case 21...24, 31: // DAVE JSON control messages.
            onEvent(.dave(opcode: opcode, payload: payload))
        case 9: // Resumed
            onEvent(.other(opcode: opcode, payload: payload))
        default:
            onEvent(.other(opcode: opcode, payload: payload))
        }
    }

    private func handleBinaryDAVEMessage(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        if bytes.count >= 3 {
            let opcode = Int(bytes[2])
            if (25...34).contains(opcode) {
                let sequence = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
                lock.lock(); self.sequence = Int(sequence); lock.unlock()
                onEvent(.dave(opcode: opcode, payload: Data(bytes.dropFirst(3))))
                return
            }
        }
        let first = Int(bytes[0])
        if (25...34).contains(first) {
            onEvent(.dave(opcode: first, payload: Data(bytes.dropFirst())))
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
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.lock.lock()
                let missed = self.pendingHeartbeatNonce != nil
                let sequence = self.sequence
                let nonce = Int(Date().timeIntervalSince1970 * 1_000)
                if !missed { self.pendingHeartbeatNonce = nonce }
                self.lock.unlock()
                if missed {
                    self.onEvent(.disconnected(VoiceGatewayError.heartbeatTimedOut))
                    self.disconnect()
                    return
                }
                do {
                    try await self.send(opcode: 3, data: [
                        "t": nonce,
                        "seq_ack": sequence as Any? ?? NSNull()
                    ])
                }
                catch { return }
            }
        }
    }

    private func send(opcode: Int, data: Any) async throws {
        lock.lock(); let task = socket; lock.unlock()
        guard let task else { throw VoiceGatewayError.notConnected }
        let bytes = try JSONSerialization.data(withJSONObject: ["op": opcode, "d": data], options: [.fragmentsAllowed])
        guard let text = String(data: bytes, encoding: .utf8) else { throw VoiceGatewayError.invalidJSON }
        try await task.send(.string(text))
    }
}

enum VoiceGatewayError: LocalizedError {
    case invalidEndpoint
    case notConnected
    case invalidJSON
    case heartbeatTimedOut
    case invalidBinaryOpcode

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Discord returned an invalid voice endpoint."
        case .notConnected: return "The Discord Voice Gateway is not connected."
        case .invalidJSON: return "Could not encode the Voice Gateway message."
        case .heartbeatTimedOut: return "The Discord Voice Gateway heartbeat was not acknowledged."
        case .invalidBinaryOpcode: return "Invalid DAVE binary Voice Gateway opcode."
        }
    }
}
