import CryptoKit
import Foundation

/// Transport-layer protection for the required Discord RTP-size XChaCha20-Poly1305 mode.
/// DAVE frame encryption is a separate, mandatory inner layer and is not implemented here.
final class DiscordVoiceTransportCipher {
    static let xchachaMode = "aead_xchacha20_poly1305_rtpsize"

    enum CipherError: LocalizedError {
        case unsupportedMode(String)
        case invalidKey
        case malformedPacket
        case nonceExhausted
        case authenticationFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedMode(let mode): return "Unsupported Discord voice transport mode: \(mode)"
            case .invalidKey: return "Discord voice transport key must contain exactly 32 bytes."
            case .malformedPacket: return "Malformed Discord RTP-size encrypted packet."
            case .nonceExhausted: return "The voice transport nonce counter is exhausted; reconnect before sending more audio."
            case .authenticationFailed: return "Discord voice transport authentication failed."
            }
        }
    }

    private let key: Data
    private var sendCounter: UInt32 = 0
    private let lock = NSLock()

    init(mode: String, secretKey: Data) throws {
        guard mode == Self.xchachaMode else { throw CipherError.unsupportedMode(mode) }
        guard secretKey.count == 32 else { throw CipherError.invalidKey }
        key = secretKey
    }

    /// Input is an RTP header followed by a plaintext Opus/DAVE frame.
    /// Output is the clear RTP header, ciphertext, 16-byte Poly1305 tag, and 4-byte nonce suffix.
    func encryptRTPPacket(_ packet: Data) throws -> Data {
        let parsed: (sequence: UInt16, timestamp: UInt32, ssrc: UInt32, headerLength: Int, payload: Data)
        do { parsed = try DiscordRTPPacket.parse(packet) }
        catch { throw CipherError.malformedPacket }
        guard !parsed.payload.isEmpty else { throw CipherError.malformedPacket }

        lock.lock()
        guard sendCounter != UInt32.max else {
            lock.unlock()
            throw CipherError.nonceExhausted
        }
        sendCounter &+= 1
        let counter = sendCounter
        lock.unlock()

        let nonceBytes = counter.littleEndianBytes
        let nonce = try Self.xchachaNonce(key: key, truncatedNonce: nonceBytes)
        let aad = packet.prefix(parsed.headerLength)
        do {
            let sealed = try ChaChaPoly.seal(parsed.payload, using: nonce.key,
                                             nonce: nonce.nonce,
                                             authenticating: Data(aad))
            var result = Data(aad)
            result.append(sealed.ciphertext)
            result.append(sealed.tag)
            result.append(nonceBytes)
            return result
        } catch {
            throw CipherError.authenticationFailed
        }
    }

    /// Input is an RTP-size packet; output is its authenticated plaintext media frame.
    func decryptRTPPacket(_ packet: Data) throws -> Data {
        let parsed: (sequence: UInt16, timestamp: UInt32, ssrc: UInt32, headerLength: Int, payload: Data)
        do { parsed = try DiscordRTPPacket.parse(packet) }
        catch { throw CipherError.malformedPacket }
        guard parsed.payload.count >= 20 else { throw CipherError.malformedPacket }
        let nonceOffset = packet.count - 4
        guard nonceOffset >= parsed.headerLength + 16 else { throw CipherError.malformedPacket }
        let truncatedNonce = packet.subdata(in: nonceOffset..<packet.count)
        let ciphertextAndTag = parsed.payload.dropLast(4)
        guard ciphertextAndTag.count >= 16 else { throw CipherError.malformedPacket }
        let ciphertext = Data(ciphertextAndTag.dropLast(16))
        let tag = Data(ciphertextAndTag.suffix(16))
        let aad = packet.prefix(parsed.headerLength)
        do {
            let nonce = try Self.xchachaNonce(key: key, truncatedNonce: truncatedNonce)
            let box = try ChaChaPoly.SealedBox(nonce: nonce.nonce, ciphertext: ciphertext, tag: tag)
            return try ChaChaPoly.open(box, using: nonce.key, authenticating: Data(aad))
        } catch {
            throw CipherError.authenticationFailed
        }
    }

    private static func xchachaNonce(key: Data, truncatedNonce: Data) throws -> (key: SymmetricKey, nonce: ChaChaPoly.Nonce) {
        guard key.count == 32, truncatedNonce.count == 4 else { throw CipherError.malformedPacket }
        // Discord's XChaCha transport nonce is the 32-bit incrementing value followed by 20 zero bytes.
        let first16 = truncatedNonce + Data(repeating: 0, count: 12)
        let subkeyBytes = hchacha20(key: key, nonce16: first16)
        let ietfNonce = Data(repeating: 0, count: 12)
        return (SymmetricKey(data: subkeyBytes), try ChaChaPoly.Nonce(data: ietfNonce))
    }

    /// HChaCha20 subkey derivation used by XChaCha20; the actual AEAD is CryptoKit's ChaChaPoly.
    private static func hchacha20(key: Data, nonce16: Data) -> Data {
        let constants: [UInt32] = [0x61707865, 0x3320646e, 0x79622d32, 0x6b206574]
        let keyWords = wordsLE(key)
        let nonceWords = wordsLE(nonce16)
        var state = constants + keyWords + nonceWords
        for _ in 0..<10 {
            quarterRound(&state, 0, 4, 8, 12)
            quarterRound(&state, 1, 5, 9, 13)
            quarterRound(&state, 2, 6, 10, 14)
            quarterRound(&state, 3, 7, 11, 15)
            quarterRound(&state, 0, 5, 10, 15)
            quarterRound(&state, 1, 6, 11, 12)
            quarterRound(&state, 2, 7, 8, 13)
            quarterRound(&state, 3, 4, 9, 14)
        }
        let selected = [state[0], state[1], state[2], state[3], state[12], state[13], state[14], state[15]]
        var output = Data(capacity: 32)
        for word in selected {
            var littleEndian = word.littleEndian
            withUnsafeBytes(of: &littleEndian) { output.append(contentsOf: $0) }
        }
        return output
    }

    private static func wordsLE(_ bytes: Data) -> [UInt32] {
        stride(from: 0, to: bytes.count, by: 4).map { offset in
            UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
        }
    }

    private static func quarterRound(_ state: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        state[a] &+= state[b]; state[d] ^= state[a]; state[d] = rotateLeft(state[d], 16)
        state[c] &+= state[d]; state[b] ^= state[c]; state[b] = rotateLeft(state[b], 12)
        state[a] &+= state[b]; state[d] ^= state[a]; state[d] = rotateLeft(state[d], 8)
        state[c] &+= state[d]; state[b] ^= state[c]; state[b] = rotateLeft(state[b], 7)
    }

    private static func rotateLeft(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value << amount) | (value >> (32 - amount))
    }
}

private extension UInt32 {
    var littleEndianBytes: Data {
        var value = littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
