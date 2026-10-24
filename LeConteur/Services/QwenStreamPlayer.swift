import AVFoundation
import QuartzCore

/// Queues PCM as it arrives. Completion means both end-of-input and all buffers
/// played; an empty queue during inference is only a temporary underrun.
@MainActor final class QwenStreamPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let tempo = AVAudioUnitTimePitch()
    private let format: AVAudioFormat
    private var identity = UUID()
    private var pending = 0
    private var completedSeconds = 0.0
    private var clockStart: CFTimeInterval?
    private var clockSeconds = 0.0
    private var wantsPlayback = false
    private var didFinish = false
    private var buffering: QwenBufferPolicy
    private(set) var inputEnded = false
    private(set) var generatedSeconds = 0.0
    private(set) var hasStarted = false
    var onStateChanged: (() -> Void)?
    var onFinished: (() -> Void)?
    /// Higher-level passage buffering can hold the queue without turning a
    /// preparation wait into a user pause. Never interrupts audio already playing.
    var playbackAllowed = true {
        didSet { if oldValue != playbackAllowed { updateState() } }
    }

    var isBuffering: Bool { wantsPlayback && !inputEnded && !isAudible && !didFinish }
    var isAudible: Bool { wantsPlayback && pending > 0 && node.isPlaying }
    var playedSeconds: Double {
        let elapsed = clockStart.map { (CACurrentMediaTime() - $0) * Double(tempo.rate) } ?? 0
        return min(generatedSeconds, max(completedSeconds, clockSeconds + elapsed))
    }
    var rate: Double {
        get { Double(tempo.rate) }
        set {
            clockSeconds = playedSeconds
            if clockStart != nil { clockStart = CACurrentMediaTime() }
            tempo.rate = Float(Self.clampedRate(newValue))
            updateState()
        }
    }

    static func clampedRate(_ value: Double) -> Double {
        value.isFinite ? min(2.5, max(0.75, value)) : 2
    }

    init(sampleRate: Int = 24_000, rate: Double, volume: Float = 1,
         estimatedAudioSeconds: Double = 0, minimumBufferSeconds: Double = 2) throws {
        guard sampleRate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1) else {
            throw QwenError.emptyAudio
        }
        self.format = format
        self.buffering = QwenBufferPolicy(estimatedSeconds: estimatedAudioSeconds, minimumSeconds: minimumBufferSeconds)
        engine.attach(node)
        engine.attach(tempo)
        engine.connect(node, to: tempo, format: format)
        engine.connect(tempo, to: engine.mainMixerNode, format: format)
        tempo.rate = Float(Self.clampedRate(rate))
        tempo.pitch = 0
        node.volume = volume
    }

    func append(_ chunk: QwenAudioChunk) throws {
        guard !inputEnded, !didFinish, chunk.sampleRate == Int(format.sampleRate),
              !chunk.samples.isEmpty, chunk.samples.count <= chunk.sampleRate * 10,
              chunk.samples.allSatisfy(\.isFinite),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw QwenError.emptyAudio }
        buffer.frameLength = buffer.frameCapacity
        chunk.samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        try schedule(buffer)
    }

    /// Commit a whole generated passage atomically. The audio thread has every
    /// sample before playback starts, so inference cannot interrupt a word.
    func appendPassage(at url: URL, onPlayedBack: @escaping @MainActor @Sendable () -> Void) throws {
        guard !inputEnded, !didFinish else { throw QwenError.emptyAudio }
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat == format, file.length > 0,
              file.length <= Int64(format.sampleRate * 120),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw QwenError.emptyAudio
        }
        guard let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192),
              let destination = buffer.floatChannelData?[0] else { throw QwenError.emptyAudio }
        // AVAudioFile may return fewer frames than requested before EOF (for
        // example at the converter's internal block boundary). Keep reading.
        var offset = 0
        while offset < Int(file.length) {
            try file.read(into: scratch, frameCount: AVAudioFrameCount(min(8_192, Int(file.length) - offset)))
            guard scratch.frameLength > 0, let source = scratch.floatChannelData?[0] else { throw QwenError.emptyAudio }
            destination.advanced(by: offset).update(from: source, count: Int(scratch.frameLength))
            offset += Int(scratch.frameLength)
        }
        buffer.frameLength = AVAudioFrameCount(offset)
        try schedule(buffer, onPlayedBack: onPlayedBack)
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, onPlayedBack: (@MainActor @Sendable () -> Void)? = nil) throws {
        if !engine.isRunning { try engine.start() }
        let seconds = Double(buffer.frameLength) / format.sampleRate
        generatedSeconds += seconds
        buffering.received(seconds: seconds, at: CACurrentMediaTime())
        pending += 1
        let current = identity
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.identity == current else { return }
                self.completedSeconds += seconds
                self.pending -= 1
                if self.pending == 0 {
                    self.node.pause()
                    self.clockStart = nil
                    self.clockSeconds = self.completedSeconds
                }
                onPlayedBack?()
                self.updateState()
            }
        }
        updateState()
    }

    func play() {
        wantsPlayback = true
        updateState()
    }

    func pause() {
        clockSeconds = playedSeconds
        clockStart = nil
        wantsPlayback = false
        node.pause()
        onStateChanged?()
    }

    func finishInput() {
        inputEnded = true
        updateState()
    }

    func stop() {
        identity = UUID() // Ignore callbacks caused by stop(), including already queued ones.
        wantsPlayback = false
        didFinish = true
        clockStart = nil
        node.stop()
        engine.stop()
        onStateChanged = nil
        onFinished = nil
    }

    private func updateState() {
        let buffered = max(0, generatedSeconds - playedSeconds)
        let target = buffering.targetSeconds(rate: rate, played: playedSeconds)
        if wantsPlayback, playbackAllowed, pending > 0, !node.isPlaying, inputEnded || buffered >= target {
            clockStart = CACurrentMediaTime()
            node.play()
            hasStarted = true
        }
        onStateChanged?()
        if wantsPlayback, inputEnded, pending == 0, !didFinish {
            didFinish = true
            onFinished?()
        }
    }
}

/// Estimate the reserve needed to bridge slower generation, excluding cold model
/// loading from throughput. Underruns refill this reserve before playback resumes.
struct QwenBufferPolicy {
    let estimatedSeconds: Double
    let minimumSeconds: Double
    private var firstArrival: Double?
    private var secondsAfterFirst = 0.0
    private var generationRate: Double?

    mutating func received(seconds: Double, at time: Double) {
        guard let firstArrival else { self.firstArrival = time; return }
        secondsAfterFirst += seconds
        let elapsed = time - firstArrival
        if elapsed > 0.05 { generationRate = secondsAfterFirst / elapsed }
    }

    func targetSeconds(rate: Double, played: Double) -> Double {
        let minimum = minimumSeconds * rate
        guard let generationRate, estimatedSeconds > played else { return minimum }
        // Allow 15% headroom for varying token/decode costs and device load.
        let deficit = max(0, 1 - generationRate * 0.85 / rate)
        let remaining = max(0, estimatedSeconds - played)
        return max(minimum, remaining * deficit + (deficit > 0 ? rate * 0.75 : 0))
    }
}
