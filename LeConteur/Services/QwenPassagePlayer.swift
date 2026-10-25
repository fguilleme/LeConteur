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
        let wordTimeline: QwenWordTimeline
    }

    private let document: ReadingDocument
    private let render: Renderer
    private let generationPriority: TaskPriority
    private let refillResumeSeconds: Double?
    private let audio: QwenStreamPlayer
    private var buffering: QwenPassageBufferPolicy
    private var wantsPlayback = false
    private var nextPosition: Int
    private var producer: Task<Void, Never>?
    private var tracker: Task<Void, Never>?
    private var identity = UUID()
    private var generationID = UUID()
    private var reportedForegroundWait = false
    private var hasStartedCurrentReserve = false
    private(set) var isGenerationSuspended = false
    private var startedAt: Date?
    private var stopped = false
    private var passages: [Passage] = []
    private var activeID: UUID?
    private var reserveTargetSeconds = 0.0
    private var lastReserve: QwenReserveProgress?
    private var deferredError: Error?
    private(set) var failedPosition: Int?
    private(set) var isGenerating = false
    private(set) var firstAudioSeconds: Double?
    private(set) var metrics: QwenRenderMetrics?
    private(set) var completedPassages = 0
    private(set) var completedAudioSeconds = 0.0
    private(set) var generatedPassages = 0
    var onStateChanged: (() -> Void)?
    var onReserveChanged: ((QwenReserveProgress) -> Void)?
    var onPassageChanged: ((NarrationWindow) -> Void)?
    var onWord: ((NSRange) -> Void)?
    var onFinished: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onNeedsForeground: ((Int) -> Void)?

    var hasPendingGeneration: Bool { producer != nil }
    var isBuffering: Bool { audio.isBuffering }
    var isAudible: Bool { audio.isAudible }
    var hasStarted: Bool { audio.hasStarted }
    var playedSeconds: Double { audio.playedSeconds }
    var bufferedPlaybackSeconds: Double { max(0, audio.generatedSeconds - audio.playedSeconds) / rate }
    var bufferedPassages: Int { passages.count }
    #if DEBUG || CONTEUR_VALIDATION
    var onDiagnosticEvent: ((String) -> Void)?
    var diagnosticState: [String: Any] {
        var state = audio.diagnosticState
        state.merge(["nextGenerationPosition": nextPosition, "generatedPassages": generatedPassages,
                     "completedPassages": completedPassages, "reserveSeconds": bufferedPlaybackSeconds,
                     "generating": isGenerating, "audible": isAudible,
                     "generationSuspended": isGenerationSuspended]) { _, new in new }
        return state
    }
    #endif

    private func recordDiagnosticEvent(_ event: String) {
        #if DEBUG || CONTEUR_VALIDATION
        onDiagnosticEvent?(event)
        #endif
    }
    var isWaitingForForeground: Bool {
        isGenerationSuspended && !audio.inputEnded && passages.isEmpty && wantsPlayback
    }
    var rate: Double {
        get { audio.rate }
        set { audio.rate = newValue; updateState() }
    }

    init(document: ReadingDocument, start: Int, rate: Double, volume: Float = 1,
         sampleRate: Int = 24_000,
         buffering: QwenPassageBufferPolicy = .init(),
         generationPriority: TaskPriority = .userInitiated,
         refillResumeSeconds: Double? = nil,
         render: @escaping Renderer) throws {
        self.document = document
        self.nextPosition = start
        self.render = render
        self.buffering = buffering
        self.generationPriority = generationPriority
        self.refillResumeSeconds = refillResumeSeconds
        // Each enqueue is already a complete passage; no estimated duration is
        // needed, even for speakers whose delivery is much slower than expected.
        audio = try QwenStreamPlayer(sampleRate: sampleRate, rate: rate, volume: volume, minimumBufferSeconds: 0)
        audio.playbackAllowed = false
        audio.onStateChanged = { [weak self] in self?.updateState() }
        audio.onError = { [weak self] error in self?.onError?(error) }
        audio.onFinished = { [weak self] in
            guard let self, !self.stopped else { return }
            self.tracker?.cancel()
            if let error = self.deferredError { self.onError?(error) }
            else { self.onFinished?() }
        }
    }

    func play() {
        guard !stopped else { return }
        wantsPlayback = true
        reportedForegroundWait = false
        if startedAt == nil {
            startedAt = Date()
            startProducer()
            tracker = Task { [weak self] in
                while !Task.isCancelled {
                    self?.updateWord()
                    self?.publishReserve()
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
        }
        audio.play()
    }

    func pause() { wantsPlayback = false; audio.pause() }

    /// Metal must stop when the app resigns active. PCM already queued belongs
    /// to the audio session and remains playable, including from the lock screen.
    func suspendGeneration() {
        guard !stopped, !isGenerationSuspended else { return }
        isGenerationSuspended = true
        generationID = UUID()
        producer?.cancel()
        producer = nil
        isGenerating = false
        updateState()
    }

    func resumeGeneration() {
        guard !stopped, isGenerationSuspended else { return }
        isGenerationSuspended = false
        reportedForegroundWait = false
        if !audio.inputEnded { startProducer() }
        updateState()
    }

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
        onReserveChanged = nil
        onPassageChanged = nil
        onWord = nil
        onFinished = nil
        onError = nil
        onNeedsForeground = nil
        #if DEBUG || CONTEUR_VALIDATION
        onDiagnosticEvent = nil
        #endif
    }

    private func startProducer() {
        guard !isGenerationSuspended, !stopped, producer == nil else { return }
        let current = identity
        let currentGeneration = generationID
        producer = Task(priority: generationPriority) { [weak self] in
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
                    guard identity == current, generationID == currentGeneration else { return }
                    // Give Qwen a short, coherent stretch of prose instead of a
                    // succession of isolated sentences. NarrationWindow keeps
                    // the request inside one paragraph and applies hard bounds.
                    let window = NarrationWindow(document: document, start: nextPosition)
                    isGenerating = true
                    updateState()
                    recordDiagnosticEvent("qwen:renderStarted")
                    let result = try await QwenRenderRecovery.render(window.text, using: render)
                    defer { try? FileManager.default.removeItem(at: result.url) }
                    try Task.checkCancellation()
                    guard identity == current, generationID == currentGeneration else { return }
                    recordDiagnosticEvent("qwen:renderFinished")
                    let passage = Passage(window: window, start: audio.generatedSeconds, duration: result.metrics.audioSeconds,
                        wordTimeline: result.wordTimeline ?? .uniform(text: window.text, duration: result.metrics.audioSeconds))
                    commit(result.metrics, characters: window.text.count)
                    passages.append(passage)
                    try audio.appendPassage(at: result.url) { [weak self] in
                        guard let self, self.identity == current else { return }
                        self.passages.removeAll { $0.id == passage.id }
                        self.completedPassages += 1
                        self.completedAudioSeconds = passage.start + passage.duration
                    }
                    nextPosition = window.endPosition + 1
                    isGenerating = false
                    updateState()
                    recordDiagnosticEvent("qwen:audioQueued")
                }
                producer = nil
                audio.finishInput()
                updateState()
            } catch {
                guard identity == current, generationID == currentGeneration, !Task.isCancelled else { return }
                isGenerating = false
                producer = nil
                // Let valid queued passages finish, even below the reserve
                // target. A failed passage is never treated as the book's end.
                deferredError = error
                failedPosition = nextPosition
                audio.finishInput()
                updateState()
            }
        }
    }

    private func commit(_ result: QwenRenderMetrics, characters: Int) {
        buffering.record(generationSeconds: result.generationSeconds,
                         audioSeconds: result.audioSeconds, characters: characters)
        generatedPassages += 1
        let old = metrics
        metrics = QwenRenderMetrics(
            generationSeconds: (old?.generationSeconds ?? 0) + result.generationSeconds,
            audioSeconds: (old?.audioSeconds ?? 0) + result.audioSeconds,
            mlxPeakBytes: max(old?.mlxPeakBytes ?? 0, result.mlxPeakBytes),
            observedFootprintBytes: max(old?.observedFootprintBytes ?? 0, result.observedFootprintBytes),
            modelLoads: (old?.modelLoads ?? 0) + result.modelLoads)
    }

    private func updateState() {
        guard !stopped else { return }
        if passages.isEmpty { hasStartedCurrentReserve = false }
        else if audio.isAudible { hasStartedCurrentReserve = true }
        let nextCharacters = document.segments.indices.contains(nextPosition)
            ? NarrationWindow(document: document, start: nextPosition).text.count : 0
        reserveTargetSeconds = buffering.startupSeconds(nextCharacters: nextCharacters, rate: rate)
        if !audio.isAudible {
            // A user pause or interruption does not empty the queue. Resume the
            // current passage immediately; refill only after an actual underrun.
            // The displayed target is listening time, not a minimum number of
            // passages. A single long passage can already satisfy that target.
            let resumeTarget = audio.hasStarted
                ? min(reserveTargetSeconds, refillResumeSeconds ?? reserveTargetSeconds)
                : reserveTargetSeconds
            audio.playbackAllowed = hasStartedCurrentReserve || isGenerationSuspended || audio.inputEnded
                || passages.count >= 128 || bufferedPlaybackSeconds >= resumeTarget
        }
        if audio.hasStarted, firstAudioSeconds == nil, let startedAt {
            firstAudioSeconds = Date().timeIntervalSince(startedAt)
        }
        updateWord()
        publishReserve()
        onStateChanged?()
        if !stopped, wantsPlayback, isGenerationSuspended, !audio.inputEnded, passages.isEmpty, !reportedForegroundWait {
            reportedForegroundWait = true
            audio.suspendEngineWhenEmpty()
            onNeedsForeground?(nextPosition)
        }
    }

    private func publishReserve() {
        guard !stopped else { return }
        // Publish draining PCM independently of speech callbacks. Half-second
        // steps avoid invalidating SwiftUI and Now Playing on every audio tick.
        let reserve = QwenReserveProgress(
            readySeconds: floor(bufferedPlaybackSeconds * 2) / 2,
            targetSeconds: reserveTargetSeconds,
            isAutomatic: buffering.preset == .automatic,
            hasStarted: audio.hasStarted, isBuffering: audio.isBuffering,
            isPaused: !wantsPlayback, isGenerating: isGenerating,
            isComplete: audio.inputEnded && deferredError == nil, passageCount: passages.count,
            isGenerationSuspended: isGenerationSuspended, hasGenerationError: deferredError != nil)
        guard reserve != lastReserve else { return }
        lastReserve = reserve
        onReserveChanged?(reserve)
    }

    private func updateWord() {
        guard audio.isAudible, let passage = passages.last(where: { $0.start <= audio.playedSeconds }) else { return }
        if activeID != passage.id {
            activeID = passage.id
            onPassageChanged?(passage.window)
        }
        // Use source-audio time: playback rate is already accounted for by the
        // audio player. Long generated silences must not stretch word timing.
        if let range = passage.wordTimeline.range(at: audio.playedSeconds - passage.start) {
            onWord?(range)
        }
    }
}

/// Only committed audio counts; a render in flight has no reliable percentage.
/// The target is the minimum reserve for starting/refilling, not queue capacity.
struct QwenReserveProgress: Equatable {
    let readySeconds: Double
    let targetSeconds: Double
    let isAutomatic: Bool
    let hasStarted: Bool
    let isBuffering: Bool
    let isPaused: Bool
    let isGenerating: Bool
    let isComplete: Bool
    let passageCount: Int
    let isGenerationSuspended: Bool
    var hasGenerationError: Bool = false

    var fraction: Double { isComplete ? 1 : min(1, max(0, readySeconds / max(0.1, targetSeconds))) }
    var amount: String {
        isComplete ? "\(Int(readySeconds)) s prêtes" : "\(Int(readySeconds)) s · objectif \(Int(ceil(targetSeconds))) s"
    }
    var status: String {
        if isPaused { return isGenerating ? String(localized: "En pause · préparation de la suite") : String(localized: "En pause · réserve conservée") }
        if hasGenerationError { return String(localized: "Lecture de la réserve · la suite devra être réessayée") }
        if isComplete { return String(localized: "Toute la suite est prête") }
        if isGenerationSuspended {
            return passageCount == 0 ? String(localized: "Ouvrez l’app pour préparer la suite") : String(localized: "Lecture de la réserve · génération en pause")
        }
        if isBuffering {
            if !hasStarted && passageCount == 0 { return String(localized: "Préparation du premier passage…") }
            return hasStarted ? String(localized: "Recharge avant reprise…") : String(localized: "Remplissage avant lecture…")
        }
        return isGenerating ? String(localized: "La suite se prépare pendant l’écoute") : String(localized: "Réserve disponible")
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

    init(preset: QwenBufferPreset = .automatic, minimumAutomaticSeconds: Double = 12,
         minimumAheadSeconds: Double = 60) {
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
        // slower than listening: a partial target merely causes short, repeated
        // refill cycles. In that case, fill the whole bounded reserve before
        // starting again. It cannot make inference real-time, but it makes the
        // unavoidable waits much less frequent.
        let generationTime = samples.reduce(0) { $0 + $1.seconds }
        let generatedAudio = samples.reduce(0) { $0 + $1.audio }
        let throughput = generationTime > 0 ? generatedAudio / generationTime : rate
        if !samples.isEmpty, throughput * 0.85 < rate { return aheadSeconds }
        return min(aheadSeconds, max(minimumAutomaticSeconds, predicted * 1.35 + 2))
    }
}
