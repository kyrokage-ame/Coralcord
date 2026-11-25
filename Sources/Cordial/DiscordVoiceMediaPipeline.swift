import Foundation

/// Bridges audio capture/playback to Discord media transport. Callers must provide real DAVE
/// encrypt/decrypt operations; plaintext fallback is deliberately not offered.
final class DiscordVoiceMediaPipeline {
    typealias FrameTransform = (Data, UInt32) throws -> Data

    enum PipelineError: Error {
        case alreadyStarted
    }

    private let audioIO: DiscordAudioIO
    private let codec: OpusCodec
    private let transport: DiscordVoiceUDPTransport
    private let transportCipher: DiscordVoiceTransportCipher
    private let sequencer: DiscordRTPSequencer
    private let ssrc: UInt32
    private let daveEncrypt: FrameTransform
    private let daveDecrypt: FrameTransform
    private let outboundFrames: AsyncStream<Data>
    private let outboundContinuation: AsyncStream<Data>.Continuation
    private var senderTask: Task<Void, Never>?
    private var receiverTask: Task<Void, Never>?
    private var started = false
    private let lock = NSLock()
    private var lastDiagnosticTime = Date.distantPast
    var onDiagnostic: ((String) -> Void)?

    init(audioIO: DiscordAudioIO, codec: OpusCodec, transport: DiscordVoiceUDPTransport,
         transportCipher: DiscordVoiceTransportCipher, ssrc: UInt32,
         daveEncrypt: @escaping FrameTransform, daveDecrypt: @escaping FrameTransform) {
        self.audioIO = audioIO
        self.codec = codec
        self.transport = transport
        self.transportCipher = transportCipher
        sequencer = DiscordRTPSequencer(ssrc: ssrc)
        self.ssrc = ssrc
        self.daveEncrypt = daveEncrypt
        self.daveDecrypt = daveDecrypt
        var continuation: AsyncStream<Data>.Continuation!
        outboundFrames = AsyncStream<Data> { continuation = $0 }
        outboundContinuation = continuation
    }

    func start() throws {
        lock.lock()
        guard !started else { lock.unlock(); throw PipelineError.alreadyStarted }
        started = true
        lock.unlock()

        audioIO.onCapturedFrame = { [weak self] pcm in
            self?.outboundContinuation.yield(pcm)
        }
        senderTask = Task { [weak self] in await self?.sendLoop() }
        receiverTask = Task { [weak self] in await self?.receiveLoop() }
    }

    func stop() {
        lock.lock()
        started = false
        lock.unlock()
        audioIO.onCapturedFrame = nil
        outboundContinuation.finish()
        senderTask?.cancel()
        receiverTask?.cancel()
        senderTask = nil
        receiverTask = nil
        transport.close()
    }

    private func sendLoop() async {
        for await pcm in outboundFrames {
            guard !Task.isCancelled else { return }
            do {
                let opus = try codec.encodeMonoPCM16LE(pcm)
                let daveFrame = try daveEncrypt(opus, ssrc)
                let clearRTP = sequencer.packet(opusPayload: daveFrame)
                let encryptedRTP = try transportCipher.encryptRTPPacket(clearRTP)
                try await transport.sendDatagram(encryptedRTP)
            } catch {
                report(error, stage: "send")
            }
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            do {
                let datagram = try await transport.receiveDatagram()
                let transportPlaintext = try transportCipher.decryptRTPPacket(datagram)
                let rtp = try DiscordRTPPacket.parse(transportPlaintext)
                let opus = try daveDecrypt(rtp.payload, rtp.ssrc)
                let pcm = try codec.decodeToMonoPCM16LE(opus)
                audioIO.enqueuePlaybackFrame(pcm)
            } catch {
                if Task.isCancelled { return }
                report(error, stage: "receive")
            }
        }
    }

    private func report(_ error: Error, stage: String) {
        lock.lock()
        let now = Date()
        guard now.timeIntervalSince(lastDiagnosticTime) >= 1 else {
            lock.unlock()
            return
        }
        lastDiagnosticTime = now
        let handler = onDiagnostic
        lock.unlock()
        handler?("Voice media \(stage) error: \(error.localizedDescription)")
    }
}
