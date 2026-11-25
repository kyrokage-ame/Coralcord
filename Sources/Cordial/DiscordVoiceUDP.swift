import Foundation
import Network

struct DiscordUDPDiscoveryResult {
    let address: String
    let port: UInt16
}

enum DiscordVoiceUDPError: LocalizedError {
    case invalidEndpoint
    case connectionFailed(String)
    case invalidDiscoveryResponse
    case unexpectedSSRC
    case malformedRTP

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Discord returned an invalid UDP endpoint."
        case .connectionFailed(let message): return "Voice UDP connection failed: \(message)"
        case .invalidDiscoveryResponse: return "The Discord UDP discovery response was invalid."
        case .unexpectedSSRC: return "The Discord UDP discovery response had a different SSRC."
        case .malformedRTP: return "The received RTP packet was malformed."
        }
    }
}

/// The RTP layer emits/accepts the 12-byte Discord Opus RTP header; encryption is separate.
enum DiscordRTPPacket {
    static let payloadType: UInt8 = 120
    static let headerSize = 12

    static func makeHeader(sequence: UInt16, timestamp: UInt32, ssrc: UInt32) -> Data {
        var packet = Data(capacity: headerSize)
        packet.append(0x80) // RTP version 2, no padding/extension/CSRCs
        packet.append(payloadType)
        appendBigEndian(sequence, to: &packet)
        appendBigEndian(timestamp, to: &packet)
        appendBigEndian(ssrc, to: &packet)
        return packet
    }

    static func parse(_ packet: Data) throws -> (sequence: UInt16, timestamp: UInt32, ssrc: UInt32, headerLength: Int, payload: Data) {
        guard packet.count >= headerSize,
              packet[packet.startIndex] >> 6 == 2,
              packet[packet.startIndex + 1] & 0x7f == payloadType else {
            throw DiscordVoiceUDPError.malformedRTP
        }
        let first = packet[packet.startIndex]
        let csrcCount = Int(first & 0x0f)
        let hasExtension = (first & 0x10) != 0
        var offset = headerSize + csrcCount * 4
        guard packet.count >= offset else { throw DiscordVoiceUDPError.malformedRTP }
        if hasExtension {
            guard packet.count >= offset + 4 else { throw DiscordVoiceUDPError.malformedRTP }
            let extensionWords = Int(readUInt16(packet, at: offset + 2))
            offset += 4 + extensionWords * 4
            guard packet.count >= offset else { throw DiscordVoiceUDPError.malformedRTP }
        }
        var end = packet.count
        if first & 0x20 != 0 {
            let padding = Int(packet[packet.endIndex - 1])
            guard padding > 0, padding <= end - offset else { throw DiscordVoiceUDPError.malformedRTP }
            end -= padding
        }
        return (readUInt16(packet, at: 2), readUInt32(packet, at: 4), readUInt32(packet, at: 8), offset,
                packet.subdata(in: offset..<end))
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[data.startIndex + offset]) << 8) | UInt16(data[data.startIndex + offset + 1])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[data.startIndex + offset]) << 24)
            | (UInt32(data[data.startIndex + offset + 1]) << 16)
            | (UInt32(data[data.startIndex + offset + 2]) << 8)
            | UInt32(data[data.startIndex + offset + 3])
    }
}

final class DiscordRTPSequencer {
    private var sequence: UInt16
    private var timestamp: UInt32
    private let ssrc: UInt32
    private let lock = NSLock()

    init(ssrc: UInt32, initialSequence: UInt16 = UInt16.random(in: .min ... .max),
         initialTimestamp: UInt32 = UInt32.random(in: .min ... .max)) {
        self.ssrc = ssrc
        sequence = initialSequence
        timestamp = initialTimestamp
    }

    func packet(opusPayload: Data) -> Data {
        lock.lock()
        let header = DiscordRTPPacket.makeHeader(sequence: sequence, timestamp: timestamp, ssrc: ssrc)
        sequence &+= 1
        timestamp &+= 960 // 20 ms at 48 kHz, per RTP timestamp rules.
        lock.unlock()
        var packet = header
        packet.append(opusPayload)
        return packet
    }
}

/// Performs Discord's 74-byte UDP IP discovery request/response exchange.
enum DiscordUDPDiscovery {
    static func discover(serverIP: String, serverPort: UInt16, ssrc: UInt32) async throws -> DiscordUDPDiscoveryResult {
        guard let port = NWEndpoint.Port(rawValue: serverPort) else { throw DiscordVoiceUDPError.invalidEndpoint }
        let connection = NWConnection(host: NWEndpoint.Host(serverIP), port: port, using: .udp)
        let queue = DispatchQueue(label: "coralcord.voice.udp-discovery")
        do {
            try await start(connection, queue: queue)
            try await send(discoveryRequest(ssrc: ssrc), on: connection)
            let response = try await receive(on: connection)
            connection.cancel()
            return try parseDiscoveryResponse(response, expectedSSRC: ssrc)
        } catch {
            connection.cancel()
            throw error
        }
    }

    static func discoveryRequest(ssrc: UInt32) -> Data {
        var packet = Data([0, 1, 0, 70])
        appendBigEndian(ssrc, to: &packet)
        packet.append(Data(repeating: 0, count: 66))
        return packet
    }

    static func parseDiscoveryResponse(_ data: Data, expectedSSRC: UInt32) throws -> DiscordUDPDiscoveryResult {
        guard data.count == 74, data[0] == 0, data[1] == 2, data[2] == 0, data[3] == 70 else {
            throw DiscordVoiceUDPError.invalidDiscoveryResponse
        }
        guard readUInt32(data, at: 4) == expectedSSRC else { throw DiscordVoiceUDPError.unexpectedSSRC }
        let addressBytes = data.subdata(in: 8..<72)
        guard let zero = addressBytes.firstIndex(of: 0), zero > 0,
              let address = String(data: addressBytes[..<zero], encoding: .utf8) else {
            throw DiscordVoiceUDPError.invalidDiscoveryResponse
        }
        let port = readUInt16(data, at: 72)
        guard port != 0 else { throw DiscordVoiceUDPError.invalidDiscoveryResponse }
        return DiscordUDPDiscoveryResult(address: address, port: port)
    }

    private static func start(_ connection: NWConnection, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume()
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: DiscordVoiceUDPError.connectionFailed(String(describing: error)))
                case .cancelled:
                    resumed = true
                    continuation.resume(throwing: DiscordVoiceUDPError.connectionFailed("cancelled"))
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    fileprivate static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: DiscordVoiceUDPError.connectionFailed(String(describing: error))) }
                else { continuation.resume() }
            })
        }
    }

    fileprivate static func receive(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receiveMessage { content, _, _, error in
                if let error {
                    continuation.resume(throwing: DiscordVoiceUDPError.connectionFailed(String(describing: error)))
                } else if let content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(throwing: DiscordVoiceUDPError.invalidDiscoveryResponse)
                }
            }
        }
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }
}

/// Connected UDP media socket. Callers must apply transport encryption and DAVE before sending/using payloads.
final class DiscordVoiceUDPTransport {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "coralcord.voice.udp-media")

    init(address: String, port: UInt16) throws {
        guard let port = NWEndpoint.Port(rawValue: port) else { throw DiscordVoiceUDPError.invalidEndpoint }
        connection = NWConnection(host: NWEndpoint.Host(address), port: port, using: .udp)
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume()
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: DiscordVoiceUDPError.connectionFailed(String(describing: error)))
                case .cancelled:
                    resumed = true
                    continuation.resume(throwing: DiscordVoiceUDPError.connectionFailed("cancelled"))
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    func sendDatagram(_ packet: Data) async throws {
        try await DiscordUDPDiscovery.send(packet, on: connection)
    }

    func receiveDatagram() async throws -> Data {
        try await DiscordUDPDiscovery.receive(on: connection)
    }

    func close() { connection.cancel() }
}
