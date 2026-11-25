import AVFoundation
import Foundation

/// Local audio capture/playback only; intentionally has no network or Gateway dependency.
/// Capture callbacks receive exactly 20 ms of mono, 48 kHz, signed PCM16 little-endian audio.
final class DiscordAudioIO {
    static let sampleRate = 48_000
    static let frameDurationMilliseconds = 20
    static let samplesPerFrame = 960
    static let bytesPerFrame = samplesPerFrame * MemoryLayout<Int16>.size

    enum OutputRoute {
        case speaker
        case receiver
    }

    enum AudioError: Error {
        case microphonePermissionDenied
        case invalidInputFormat
        case converterCreationFailed
        case audioSessionConfigurationFailed(Error)
        case audioEngineStartFailed(Error)
    }

    /// Bounded to 50 incoming render buffers. Overflow drops the oldest buffer.
    private let maximumQueuedInputBuffers = 50
    /// Bounded to 100 playback frames. Overflow drops the oldest queued frame.
    private let maximumQueuedPlaybackFrames = 100

    private let stateLock = NSLock()
    private var running = false
    private var muted = false
    private var queuedInputBuffers: [AVAudioPCMBuffer] = []
    private var queuedPlaybackFrames: [Data] = []
    private var pendingConvertedBytes = Data()

    private let inputQueue = DispatchQueue(label: "cordial.audio.input-conversion", qos: .userInitiated)
    private let playbackQueue = DispatchQueue(label: "cordial.audio.playback", qos: .userInitiated)
    private let inputQueueReady = DispatchSemaphore(value: 0)
    private var inputWorker: DispatchWorkItem?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    /// Called on a private serial queue, never the audio render or main queue.
    var onCapturedFrame: ((Data) -> Void)?

    init() {}

    static func requestRecordPermission(_ completion: @escaping (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission(completion)
    }

    /// Starts capture and playback after record permission has been granted.
    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        stateLock.lock()
        guard !running else {
            stateLock.unlock()
            completion(.success(()))
            return
        }
        running = true
        stateLock.unlock()

        guard AVAudioSession.sharedInstance().recordPermission == .granted else {
            resetRunning()
            completion(.failure(AudioError.microphonePermissionDenied))
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
            try session.setPreferredSampleRate(Double(Self.sampleRate))
            try session.setActive(true)

            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.channelCount > 0,
                  let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                   sampleRate: Double(Self.sampleRate),
                                                   channels: 1, interleaved: true),
                  let audioConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                resetRunning()
                completion(.failure(AudioError.converterCreationFailed))
                return
            }
            converter = audioConverter
            targetFormat = outputFormat

            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
            input.installTap(onBus: 0, bufferSize: 960, format: inputFormat) { [weak self] buffer, _ in
                self?.acceptInputBuffer(buffer)
            }
            engine.prepare()
            try engine.start()
            player.play()
            beginInputWorker()
            completion(.success(()))
        } catch {
            inputCleanup()
            resetRunning()
            completion(.failure(AudioError.audioEngineStartFailed(error)))
        }
    }

    /// Selects built-in loudspeaker or receiver. Bluetooth routes remain available to AVAudioSession.
    func setOutputRoute(_ route: OutputRoute) throws {
        let session = AVAudioSession.sharedInstance()
        switch route {
        case .speaker:
            try session.overrideOutputAudioPort(.speaker)
        case .receiver:
            try session.overrideOutputAudioPort(.none)
        }
    }

    func setMuted(_ muted: Bool) {
        stateLock.lock()
        self.muted = muted
        stateLock.unlock()
    }

    var isMuted: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return muted
    }

    /// Enqueues one mono 48 kHz PCM16LE frame (exactly 1,920 bytes).
    /// Invalid-sized payloads are ignored. Playback queue overflow drops its oldest frame.
    func enqueuePlaybackFrame(_ frame: Data) {
        guard frame.count == Self.bytesPerFrame else { return }
        stateLock.lock()
        guard running else {
            stateLock.unlock()
            return
        }
        if queuedPlaybackFrames.count >= maximumQueuedPlaybackFrames {
            queuedPlaybackFrames.removeFirst()
        }
        queuedPlaybackFrames.append(frame)
        stateLock.unlock()
        playbackQueue.async { [weak self] in self?.renderNextPlaybackFrame() }
    }

    func stop() {
        stateLock.lock()
        running = false
        queuedInputBuffers.removeAll(keepingCapacity: false)
        queuedPlaybackFrames.removeAll(keepingCapacity: false)
        pendingConvertedBytes.removeAll(keepingCapacity: false)
        stateLock.unlock()
        inputQueueReady.signal()
        inputCleanup()
        playbackQueue.async { [weak self] in
            guard let self = self else { return }
            self.player.stop()
            self.engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func resetRunning() {
        stateLock.lock()
        running = false
        stateLock.unlock()
    }

    private func inputCleanup() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        if engine.attachedNodes.contains(player) { engine.detach(player) }
    }

    private func acceptInputBuffer(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        guard running, !muted else {
            stateLock.unlock()
            return
        }
        // Copy while the tap's buffer is valid; conversion/callback work happens off the RT thread.
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            stateLock.unlock()
            return
        }
        copy.frameLength = buffer.frameLength
        if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                destination[channel].assign(from: source[channel], count: Int(buffer.frameLength))
            }
        } else if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                destination[channel].assign(from: source[channel], count: Int(buffer.frameLength))
            }
        } else {
            stateLock.unlock()
            return
        }
        if queuedInputBuffers.count >= maximumQueuedInputBuffers {
            queuedInputBuffers.removeFirst()
        }
        queuedInputBuffers.append(copy)
        stateLock.unlock()
        inputQueueReady.signal()
    }

    private func beginInputWorker() {
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            while !Thread.current.isCancelled {
                self.inputQueueReady.wait()
                if Thread.current.isCancelled { break }
                self.stateLock.lock()
                let buffer = self.queuedInputBuffers.isEmpty ? nil : self.queuedInputBuffers.removeFirst()
                let active = self.running
                self.stateLock.unlock()
                guard active else { break }
                if let buffer = buffer { self.convertInput(buffer) }
            }
        }
        inputWorker = work
        inputQueue.async(execute: work)
    }

    private func convertInput(_ input: AVAudioPCMBuffer) {
        guard let converter = converter, let targetFormat = targetFormat else { return }
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil, let samples = output.int16ChannelData else { return }
        let count = Int(output.frameLength)
        guard count > 0 else { return }
        var bytes = Data(capacity: count * 2)
        for index in 0..<count {
            let value = UInt16(bitPattern: samples[0][index])
            bytes.append(UInt8(value & 0xff))
            bytes.append(UInt8(value >> 8))
        }
        pendingConvertedBytes.append(bytes)
        while pendingConvertedBytes.count >= Self.bytesPerFrame {
            let frame = pendingConvertedBytes.prefix(Self.bytesPerFrame)
            let data = Data(frame)
            pendingConvertedBytes.removeFirst(Self.bytesPerFrame)
            onCapturedFrame?(data)
        }
    }

    private func renderNextPlaybackFrame() {
        stateLock.lock()
        guard running, !queuedPlaybackFrames.isEmpty else {
            stateLock.unlock()
            return
        }
        let data = queuedPlaybackFrames.removeFirst()
        stateLock.unlock()
        guard let format = targetFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.samplesPerFrame)),
              let destination = buffer.int16ChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(Self.samplesPerFrame)
        data.withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<Self.samplesPerFrame {
                let low = UInt16(bytes[index * 2])
                let high = UInt16(bytes[index * 2 + 1])
                destination[0][index] = Int16(bitPattern: low | (high << 8))
            }
        }
        player.scheduleBuffer(buffer) { [weak self] in
            self?.playbackQueue.async { self?.renderNextPlaybackFrame() }
        }
    }
}
