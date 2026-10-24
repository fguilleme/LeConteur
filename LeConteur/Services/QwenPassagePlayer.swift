import Foundation

/// Synthesis works ahead of playback, but only complete passages reach the audio
/// queue. Build a time-based reserve before starting, then work well ahead.
@MainActor final class QwenPassagePlayer {
    typealias Renderer = @Sendable (String) async throws -> QwenRenderedAudio
    struct Passage {
        let id = UUID()
        let window: NarrationWindow
        let start: Double
        let duration: Double
    }

    private let document: ReadingDocument
    private let render: Renderer
    private let audio: QwenStreamPlayer
    private var buffering: QwenPassageBufferPolicy
    private var wantsPlayback = false
    private var nextPosition: Int
    private var producer: Task<Void, Never>?
    private var tracker: Task<Void, Never>?
    private var identity = UUID()
    private var startedAt: Date?
    private var stopped = false
    private var passages: [Passage] = []
    private var activeID: UUID?
    private(set) var isGenerating = false
    private(set) var firstAudioSeconds: Double?
    private(set) var metrics: QwenRenderMetrics?
    private(set) var completedPassages = 0
    private(set) var completedAudioSeconds = 0.0
    private(set) var generatedPassages = 0
    var onStateChanged: (() -> Void)?
    var onPassageChanged: ((NarrationWindow) -> Void)?
    var onWord: ((NSRange) -> Void)?
    var onFinished: (() -> Void)?
    var onError: ((Error) -> Void)?

    var hasPendingGeneration: Bool { producer != nil }
    var isBuffering: Bool { audio.isBuffering }
    var isAudible: Bool { audio.isAudible }
    var hasStarted: Bool { audio.hasStarted }
    var playedSeconds: Double { audio.playedSeconds }
    var bufferedPlaybackSeconds: Double { max(0, audio.generatedSeconds - audio.playedSeconds) / rate }
    var bufferedPassages: Int { passages.count }
    var rate: Double {
        get { audio.rate }
        set { audio.rate = newValue; updateState() }
    }

    init(document: ReadingDocument, start: Int, rate: Double, volume: Float = 1,
         buffering: QwenPassageBufferPolicy = .init(),
         render: @escaping Renderer) throws {
        self.document = document
        self.nextPosition = start
        self.render = render
        self.buffering = buffering
        // Each enqueue is already a complete passage; no estimated duration is
        // needed, even for speakers whose delivery is much slower than expected.
        audio = try QwenStreamPlayer(rate: rate, volume: volume, minimumBufferSeconds: 0)
        audio.playbackAllowed = false
        audio.onStateChanged = { [weak self] in self?.updateState() }
        audio.onFinished = { [weak self] in
            guard let self, !self.stopped else { return }
            self.tracker?.cancel()
            self.onFinished?()
        }
    }

    func play() {
        guard !stopped else { return }
        wantsPlayback = true
        if startedAt == nil {
            startedAt = Date()
            startProducer()
            tracker = Task { [weak self] in
                while !Task.isCancelled {
                    self?.updateWord()
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
        }
        audio.play()
    }

    func pause() { wantsPlayback = false; audio.pause() }

    func setBufferPreset(_ preset: QwenBufferPreset) {
        buffering.preset = preset
        updateState() // Applies at the next start/refill; never stops audible PCM.
    }

    func stop() {
        stopped = true
        wantsPlayback = false
        identity = UUID()
        producer?.cancel()
        producer = nil
        tracker?.cancel()
        tracker = nil
        audio.stop()
        passages.removeAll()
        isGenerating = false
        onStateChanged = nil
        onPassageChanged = nil
        onWord = nil
        onFinished = nil
        onError = nil
    }

    private func startProducer() {
        let current = identity
        producer = Task { [weak self] in
            guard let self else { return }
            do {
                while document.segments.indices.contains(nextPosition) {
                    // Audio is inexpensive compared with the model. Bound it by
                    // listening time, rather than starving synthesis after only
                    // two paragraphs. A user pause still limits speculative work.
                    while (!wantsPlayback && passages.count >= 2)
                        || (wantsPlayback && (bufferedPlaybackSeconds >= buffering.aheadSeconds || passages.count >= 128)) {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    try Task.checkCancellation()
                    guard identity == current else { return }
                    let window = NarrationWindow(document: document, start: nextPosition, characterLimit: 360)
                    isGenerating = true
                    onStateChanged?()
                    let result = try await render(window.text)
                    defer { try? FileManager.default.removeItem(at: result.url) }
                    try Task.checkCancellation()
                    guard identity == current else { return }
                    let passage = Passage(window: window, start: audio.generatedSeconds, duration: result.metrics.audioSeconds)
                    buffering.record(generationSeconds: result.metrics.generationSeconds,
                                     audioSeconds: result.metrics.audioSeconds, characters: window.text.count)
                    passages.append(passage)
                    generatedPassages += 1
                    let old = metrics
                    metrics = QwenRenderMetrics(
                        generationSeconds: (old?.generationSeconds ?? 0) + result.metrics.generationSeconds,
                        audioSeconds: (old?.audioSeconds ?? 0) + result.metrics.audioSeconds,
                        mlxPeakBytes: max(old?.mlxPeakBytes ?? 0, result.metrics.mlxPeakBytes),
                        observedFootprintBytes: max(old?.observedFootprintBytes ?? 0, result.metrics.observedFootprintBytes),
                        modelLoads: (old?.modelLoads ?? 0) + result.metrics.modelLoads)
                    nextPosition = window.endPosition + 1
                    try audio.appendPassage(at: result.url) { [weak self] in
                        guard let self, self.identity == current else { return }
                        self.passages.removeAll { $0.id == passage.id }
                        self.completedPassages += 1
                        self.completedAudioSeconds = passage.start + passage.duration
                    }
                    isGenerating = false
                    updateState()
                }
                producer = nil
                audio.finishInput()
                updateState()
            } catch {
                guard identity == current, !Task.isCancelled else { return }
                isGenerating = false
                producer = nil
                onError?(error)
            }
        }
    }

    private func updateState() {
        if !audio.isAudible {
            let nextCharacters = document.segments.indices.contains(nextPosition)
                ? NarrationWindow(document: document, start: nextPosition, characterLimit: 360).text.count : 0
            audio.playbackAllowed = audio.inputEnded || passages.count >= 128 || (passages.count >= 2
                && bufferedPlaybackSeconds >= buffering.startupSeconds(nextCharacters: nextCharacters, rate: rate))
        }
        if audio.hasStarted, firstAudioSeconds == nil, let startedAt {
            firstAudioSeconds = Date().timeIntervalSince(startedAt)
        }
        updateWord()
        onStateChanged?()
    }

    private func updateWord() {
        guard audio.isAudible, let passage = passages.last(where: { $0.start <= audio.playedSeconds }) else { return }
        if activeID != passage.id {
            activeID = passage.id
            onPassageChanged?(passage.window)
        }
        // Complete audio gives a known duration. Word timing remains estimated;
        // it no longer changes whenever another decoder chunk arrives.
        let text = passage.window.text as NSString
        let fraction = min(1, max(0, (audio.playedSeconds - passage.start) / max(0.1, passage.duration)))
        let offset = Int(fraction * Double(text.length))
        let expression = try? NSRegularExpression(pattern: "\\S+")
        if let range = expression?.matches(in: passage.window.text, range: NSRange(location: 0, length: text.length))
            .last(where: { $0.range.location <= offset })?.range {
            onWord?(range)
        }
    }
}

/// Seconds here are listening seconds, so 30 s at 2× reserves 60 s of PCM.
/// Automatic sizing ignores the first cold load and uses recent warm renders.
struct QwenPassageBufferPolicy {
    var preset: QwenBufferPreset = .automatic
    var minimumAutomaticSeconds = 12.0
    var minimumAheadSeconds = 60.0
    private var samples: [(seconds: Double, audio: Double, characters: Int)] = []
    private var seenFirst = false

    init(preset: QwenBufferPreset = .automatic, minimumAutomaticSeconds: Double = 12, minimumAheadSeconds: Double = 60) {
        self.preset = preset
        self.minimumAutomaticSeconds = minimumAutomaticSeconds
        self.minimumAheadSeconds = minimumAheadSeconds
    }

    var aheadSeconds: Double { max(minimumAheadSeconds, (preset.seconds ?? 0) * 2) }
    mutating func record(generationSeconds: Double, audioSeconds: Double, characters: Int) {
        defer { seenFirst = true }
        guard seenFirst, generationSeconds.isFinite, generationSeconds > 0,
              audioSeconds.isFinite, audioSeconds > 0, characters > 0 else { return }
        samples.append((generationSeconds, audioSeconds, characters))
        if samples.count > 4 { samples.removeFirst() }
    }
    func startupSeconds(nextCharacters: Int, rate: Double = 1) -> Double {
        if let seconds = preset.seconds { return seconds }
        let predicted = samples.map { $0.seconds * Double(max(1, nextCharacters)) / Double($0.characters) }.max() ?? 0
        // Bridging just the next paragraph is insufficient when every render is
        // slower than listening. Also cover the measured deficit over the next
        // minute of listening, with headroom for variable inference costs.
        let generationTime = samples.reduce(0) { $0 + $1.seconds }
        let generatedAudio = samples.reduce(0) { $0 + $1.audio }
        let throughput = generationTime > 0 ? generatedAudio / generationTime : rate
        let deficit = samples.isEmpty ? 0 : max(0, 1 - throughput * 0.85 / rate)
        return min(aheadSeconds, max(minimumAutomaticSeconds, predicted * 1.35 + 2, aheadSeconds * deficit))
    }
}
