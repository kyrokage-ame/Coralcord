import Foundation

/// Stateful Opus wrapper for Discord's 48 kHz stereo, 20 ms voice frames.
/// The audio engine currently captures mono PCM, so encoding duplicates each sample to stereo.
/// Decoded stereo is downmixed to the mono PCM format expected by DiscordAudioIO.
final class OpusCodec {
    static let sampleRate = 48_000
    static let channels = 2
    static let frameSamplesPerChannel = 960
    private static let monoPCMBytesPerFrame = frameSamplesPerChannel * MemoryLayout<Int16>.size
    private static let maximumPacketBytes = 4_000

    enum CodecError: Error {
        case encoderCreationFailed(Int32)
        case decoderCreationFailed(Int32)
        case invalidPCMFrame
        case encodeFailed(Int32)
        case decodeFailed(Int32)
    }

    private var encoder: OpaquePointer?
    private var decoder: OpaquePointer?
    private let lock = NSLock()

    init() throws {
        var encoderStatus: Int32 = 0
        encoder = opus_encoder_create(Int32(Self.sampleRate), Int32(Self.channels), 2048, &encoderStatus)
        guard encoderStatus == 0, encoder != nil else {
            throw CodecError.encoderCreationFailed(encoderStatus)
        }
        var decoderStatus: Int32 = 0
        decoder = opus_decoder_create(Int32(Self.sampleRate), Int32(Self.channels), &decoderStatus)
        guard decoderStatus == 0, decoder != nil else {
            if let encoder { opus_encoder_destroy(encoder) }
            encoder = nil
            throw CodecError.decoderCreationFailed(decoderStatus)
        }
    }

    deinit {
        if let encoder { opus_encoder_destroy(encoder) }
        if let decoder { opus_decoder_destroy(decoder) }
    }

    /// Encodes one 20 ms mono signed PCM16 little-endian frame into a stereo Opus packet.
    func encodeMonoPCM16LE(_ pcm: Data) throws -> Data {
        guard pcm.count == Self.monoPCMBytesPerFrame else { throw CodecError.invalidPCMFrame }
        lock.lock()
        defer { lock.unlock() }
        guard let encoder else { throw CodecError.encodeFailed(-3) }

        let bytes = [UInt8](pcm)
        var stereo = [Int16](repeating: 0, count: Self.frameSamplesPerChannel * Self.channels)
        for sample in 0..<Self.frameSamplesPerChannel {
            let bits = UInt16(bytes[sample * 2]) | (UInt16(bytes[sample * 2 + 1]) << 8)
            let value = Int16(bitPattern: bits)
            stereo[sample * 2] = value
            stereo[sample * 2 + 1] = value
        }
        var packet = [UInt8](repeating: 0, count: Self.maximumPacketBytes)
        let encodedLength = stereo.withUnsafeBufferPointer { pcmPointer in
            packet.withUnsafeMutableBufferPointer { packetPointer in
                opus_encode(encoder, pcmPointer.baseAddress, Int32(Self.frameSamplesPerChannel),
                            packetPointer.baseAddress, Int32(packetPointer.count))
            }
        }
        guard encodedLength > 0 else { throw CodecError.encodeFailed(encodedLength) }
        return Data(packet.prefix(Int(encodedLength)))
    }

    /// Decodes a stereo Opus packet and downmixes one 20 ms frame to mono PCM16 little-endian.
    func decodeToMonoPCM16LE(_ packet: Data) throws -> Data {
        guard !packet.isEmpty else { throw CodecError.decodeFailed(-4) }
        lock.lock()
        defer { lock.unlock() }
        guard let decoder else { throw CodecError.decodeFailed(-3) }

        let encoded = [UInt8](packet)
        var stereo = [Int16](repeating: 0, count: Self.frameSamplesPerChannel * Self.channels)
        let decodedSamples = encoded.withUnsafeBufferPointer { packetPointer in
            stereo.withUnsafeMutableBufferPointer { pcmPointer in
                opus_decode(decoder, packetPointer.baseAddress, Int32(packetPointer.count),
                            pcmPointer.baseAddress, Int32(Self.frameSamplesPerChannel), 0)
            }
        }
        guard decodedSamples == Self.frameSamplesPerChannel else {
            throw CodecError.decodeFailed(decodedSamples)
        }
        var mono = Data(capacity: Self.monoPCMBytesPerFrame)
        for sample in 0..<Self.frameSamplesPerChannel {
            let left = Int32(stereo[sample * 2])
            let right = Int32(stereo[sample * 2 + 1])
            let value = Int16(clamping: (left + right) / 2)
            let bits = UInt16(bitPattern: value)
            mono.append(UInt8(bits & 0xff))
            mono.append(UInt8(bits >> 8))
        }
        return mono
    }
}

@_silgen_name("opus_encoder_create")
private func opus_encoder_create(_ sampleRate: Int32, _ channels: Int32, _ application: Int32,
                                 _ error: UnsafeMutablePointer<Int32>?) -> OpaquePointer?
@_silgen_name("opus_encoder_destroy")
private func opus_encoder_destroy(_ encoder: OpaquePointer?)
@_silgen_name("opus_encode")
private func opus_encode(_ encoder: OpaquePointer?, _ pcm: UnsafePointer<Int16>?, _ frameSize: Int32,
                         _ data: UnsafeMutablePointer<UInt8>?, _ maxDataBytes: Int32) -> Int32
@_silgen_name("opus_decoder_create")
private func opus_decoder_create(_ sampleRate: Int32, _ channels: Int32,
                                 _ error: UnsafeMutablePointer<Int32>?) -> OpaquePointer?
@_silgen_name("opus_decoder_destroy")
private func opus_decoder_destroy(_ decoder: OpaquePointer?)
@_silgen_name("opus_decode")
private func opus_decode(_ decoder: OpaquePointer?, _ data: UnsafePointer<UInt8>?, _ length: Int32,
                         _ pcm: UnsafeMutablePointer<Int16>?, _ frameSize: Int32,
                         _ decodeFEC: Int32) -> Int32
