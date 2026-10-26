import AVFoundation
import MediaPlayer
import Observation
import UIKit
import Darwin

@MainActor protocol SpeechSynthesizing: AnyObject {
    var delegate: AVSpeechSynthesizerDelegate? { get set }
    var isPaused: Bool { get }
    func speak(_ utterance: AVSpeechUtterance)
    @discardableResult func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool
    @discardableResult func continueSpeaking() -> Bool
    @discardableResult func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}
extension AVSpeechSynthesizer: SpeechSynthesizing {}

@MainActor @Observable
final class PlaybackController: NSObject {
    typealias QwenRenderer = @Sendable (String, NarrationStyle, String, QwenSpeaker, UUID) async throws -> QwenRenderedAudio
    private(set) var documentID: UUID?
    private(set) var position = 0
    private(set) var isPlaying = false
    private(set) var isPreparing = false
    private(set) var isGenerating = false
    private(set) var qwenFirstAudioSeconds: Double?
    private(set) var sleepDeadline: Date?
    private(set) var wordRange: NSRange?
    private(set) var preparationStatus = String(localized: "Préparation de la voix…")
    private(set) var qwenMetrics: QwenRenderMetrics?
    private(set) var qwenReserve: QwenReserveProgress?
    private(set) var notice: String?
    var errorMessage: String?
    private let library: LibraryStore
    let settings: ReaderSettings
    private let speech: any SpeechSynthesizing
    private let renderQwen: QwenRenderer
    private var preparedVoice: PreparedVoice?
    private var requestedEngine: VoiceEngine
    private var previewDocument: ReadingDocument?
    private var previewEngine: VoiceEngine?
    private var qwenPlayer: QwenPassagePlayer?
    private var qwenSessionID: UUID?
    private var utterance: AVSpeechUtterance?
    private var spokenSegments: [(index: Int, range: NSRange)] = []
    private var spokenEndPosition = 0
    private var token = UUID()
    private var timerTask: Task<Void, Never>?
    private var systemSpeechWatchdog: Task<Void, Never>?
    private var systemSpeechRecoveryAttempts = 0
    private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var nextTranslationPosition: Int?
    private var translationIsActive = false
    @ObservationIgnored var suspendTranslation: (() -> Void)?
    private var applicationIsActive = UIApplication.shared.applicationState == .active
    private var resumeAfterInterruption = false
    private var waitingForForegroundStart = false
    private let systemSpeechTimeout: Duration
    #if DEBUG || CONTEUR_VALIDATION
    @ObservationIgnored var onDiagnosticEvent: ((String) -> Void)?
    var qwenDiagnosticState: [String: Any] { qwenPlayer?.diagnosticState ?? [:] }
    #endif

    private func recordDiagnosticEvent(_ event: String) {
        #if DEBUG || CONTEUR_VALIDATION
        onDiagnosticEvent?(event)
        #endif
    }

    var document: ReadingDocument? { previewDocument ?? documentID.flatMap { library.document($0) } }
    var isPreview: Bool { previewDocument != nil }
    var isWaitingForTranslation: Bool { isPlaying && nextTranslationPosition != nil }
    var playbackSpeed: Double { effectiveEngine == .qwen ? settings.qwenSpeed : settings.speed }
    var qwenPlayedSeconds: Double { qwenPlayer?.playedSeconds ?? 0 }
    var qwenCompletedAudioSeconds: Double { qwenPlayer?.completedAudioSeconds ?? 0 }
    var qwenBufferedPlaybackSeconds: Double { qwenPlayer?.bufferedPlaybackSeconds ?? 0 }
    var isUsingAppleForTranslation: Bool {
        !isPreview && settings.engine != .system && translationIsActive && document?.isTranslationPending == true
    }
    var voiceFallbackMessage: String? {
        if isUsingAppleForTranslation {
            return String(localized: "Voix Apple pendant la traduction. Choisir Qwen met la traduction en pause pour lire les passages déjà prêts.")
        }
        if settings.engine == .supertonic, !isSupertonicInstalled {
            return SupertonicError.missing.localizedDescription
        }
        if settings.engine != .system, effectiveEngine == .system {
            return String(format: String(localized: "%@ ne prend pas en charge la langue de ce livre. Lecture avec la voix Apple %@."), settings.engine.name, voiceName)
        }
        return nil
    }
    private var isSupertonicInstalled: Bool {
        VoiceDownloads.shared.snapshot("supertonic").installed
    }
    var effectiveEngine: VoiceEngine {
        if isPreview { return previewEngine ?? .qwen }
        // Only active translation needs the temporary Apple voice. An unfinished
        // edition on disk must not override the reader's saved Qwen preference.
        if isUsingAppleForTranslation { return .system }
        switch settings.engine {
        case .qwen:
            guard VoiceFeatures.qwenEnabled else {
                return isSupertonicInstalled && SupertonicModel.languageCode(for: document?.resolvedLanguage) != nil ? .supertonic : .system
            }
            return NarrationStyle.languageName(for: document?.resolvedLanguage) != nil ? .qwen : .system
        case .supertonic:
            return isSupertonicInstalled && SupertonicModel.languageCode(for: document?.resolvedLanguage) != nil ? .supertonic : .system
        case .system: return .system
        }
    }
    var voiceName: String {
        switch effectiveEngine {
        case .qwen: "\(settings.qwenSpeaker.name) · \(settings.qwenStyle.name)"
        case .supertonic: "Supertonic · \(settings.supertonicVoice.name)"
        case .system: selectedVoice?.name ?? "Voix du texte"
        }
    }
    var selectedVoice: AVSpeechSynthesisVoice? {
        let language = document?.languageCode ?? TranslationCoordinator.phoneLanguage
        return SystemVoiceSelection.resolve(language: language, preferred: settings.systemVoiceID(for: language))
    }

    private enum PreparedVoice: Equatable {
        case system(identifier: String?, rate: Float)
        case qwen(speaker: QwenSpeaker, style: NarrationStyle, language: String)
        case supertonic(voice: SupertonicVoice, language: String)
    }

    private var chosenVoice: PreparedVoice {
        switch effectiveEngine {
        case .system: .system(identifier: selectedVoice?.identifier, rate: SystemVoiceSelection.speechRate(for: settings.speed))
        case .qwen: .qwen(speaker: settings.qwenSpeaker, style: settings.qwenStyle,
                         language: NarrationStyle.languageName(for: document?.resolvedLanguage) ?? "French")
        case .supertonic: .supertonic(voice: settings.supertonicVoice,
                                     language: SupertonicModel.languageCode(for: document?.resolvedLanguage) ?? "fr")
        }
    }

    init(library: LibraryStore, settings: ReaderSettings, speech: any SpeechSynthesizing = AVSpeechSynthesizer(),
         systemSpeechTimeout: Duration = .seconds(20),
         renderQwen: @escaping QwenRenderer = { text, style, language, speaker, session in
             try await QwenVoiceRenderer.shared.render(text, style: style, language: language, speaker: speaker, sessionID: session)
         }) {
        self.library = library
        self.settings = settings
        self.speech = speech
        self.systemSpeechTimeout = systemSpeechTimeout
        self.renderQwen = renderQwen
        requestedEngine = settings.engine
        if let restoredID = library.currentDocumentID,
           let restoredDocument = library.document(restoredID) {
            documentID = restoredID
            position = restoredDocument.isFinished ? 0 : restoredDocument.position
        }
        super.init()
        speech.delegate = self
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let kind = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                if kind == AVAudioSession.InterruptionType.began.rawValue { self?.audioInterruptionBegan() }
                else if kind == AVAudioSession.InterruptionType.ended.rawValue {
                    self?.audioInterruptionEnded(shouldResume: AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume))
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { Task { @MainActor in self?.pause() } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applicationWillResignActive()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applicationDidEnterBackground() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applicationDidBecomeActive() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.qwenPlayer?.hasPendingGeneration == true {
                    let available = os_proc_available_memory()
                    #if DEBUG || CONTEUR_VALIDATION
                    print("QWEN memory warning; process headroom: \(available)")
                    #endif
                    // MLX already has a bounded 64 MiB cache. A global warning alone
                    // doesn't mean this process has exhausted its extended memory
                    // allowance. Stop before headroom becomes small; don't discard a
                    // healthy stream on every global warning.
                    guard available < 700_000_000 else { return }
                    self.stopAudio()
                    self.notice = String(localized: "Préparation arrêtée pour libérer de la mémoire. Réessayez sur un passage plus court.")
                }
                await QwenVoiceRenderer.shared.unloadIfIdle()
            }
        })
    }

    func open(_ document: ReadingDocument, autoplay: Bool = false) {
        configureRemoteCommands()
        previewDocument = nil
        previewEngine = nil
        library.rememberCurrentDocument(document.id)
        if documentID != document.id {
            stopAudio()
            documentID = document.id
            position = document.isFinished ? 0 : document.position
            requestedEngine = settings.engine
        }
        refreshRequestedEngine()
        discardObsoleteAudio()
        updateNowPlaying()
        if autoplay { play() }
    }

    func toggle() { isPlaying || isPreparing ? pause() : play() }

    func applicationWillResignActive() {
        recordDiagnosticEvent("willResignActive")
        prepareForBackgroundPlayback()
    }

    func applicationDidEnterBackground() {
        recordDiagnosticEvent("didEnterBackground")
        prepareForBackgroundPlayback()
    }

    private func prepareForBackgroundPlayback() {
        let wasActive = applicationIsActive
        applicationIsActive = false
        SupertonicInferencePacer.shared.setBackgrounded(true)
        guard wasActive else { return }

        switch effectiveEngine {
        case .system:
            // AVSpeechSynthesizer continues through the .playback audio session.
            break
        case .qwen:
            // Qwen uses Metal, which cannot start new work while the application
            // is inactive. Keep its already queued PCM playing from the lock screen.
            qwenPlayer?.suspendGeneration()
            finishBackgroundTask()
            Task { await QwenVoiceRenderer.shared.unload() }
        case .supertonic:
            if isPlaying {
                // Supertonic is CPU/ONNX based. Its queued audio and producer can
                // therefore keep refilling while the background-audio session is
                // active. Pace inference below iOS's background CPU watchdog;
                // queued PCM keeps playing while the producer briefly rests.
                if isGenerating { beginBackgroundTask() }
            } else {
                qwenPlayer?.suspendGeneration()
                finishBackgroundTask()
                Task { await SupertonicVoiceRenderer.shared.unload() }
            }
        }
    }

    func applicationDidBecomeActive() {
        recordDiagnosticEvent("didBecomeActive")
        applicationIsActive = true
        SupertonicInferencePacer.shared.setBackgrounded(false)
        if qwenPlayer != nil {
            notice = nil
            qwenPlayer?.resumeGeneration()
            if isPlaying { play() } // Reactivate the session if iOS suspended it after the reserve emptied.
        }
        else if waitingForForegroundStart, isPlaying { waitingForForegroundStart = false; play() }
    }

    func audioInterruptionBegan() {
        recordDiagnosticEvent("interruptionBegan")
        let wasPlaying = isPlaying
        pause()
        resumeAfterInterruption = wasPlaying
    }

    func audioInterruptionEnded(shouldResume: Bool) {
        recordDiagnosticEvent("interruptionEnded:resume=\(shouldResume)")
        let resume = resumeAfterInterruption && shouldResume
        resumeAfterInterruption = false
        if resume { play() }
    }

    func play() {
        resumeAfterInterruption = false
        guard let document, !document.segments.isEmpty else { return }
        configureRemoteCommands()
        // A paused utterance / Qwen reserve belongs to the voice that produced it.
        // Reconcile here too: returning to the book must not depend on a view's
        // onChange having run before the user taps Play.
        refreshRequestedEngine()
        discardObsoleteAudio()
        if document.isFinished { position = 0 }
        notice = nil
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
        } catch { errorMessage = error.localizedDescription; return }
        isPlaying = true
        if let next = nextTranslationPosition {
            if document.segments.indices.contains(next) {
                nextTranslationPosition = nil
                position = next
                speakCurrent()
            } else if document.isTranslationPending {
                notice = String(localized: "La suite est en cours de traduction…")
            } else { finishReading(document) }
            updateNowPlaying()
            return
        }
        if let qwenPlayer, effectiveEngine != .system {
            qwenPlayer.rate = playbackSpeed
            if effectiveEngine == .qwen { qwenPlayer.setBufferPreset(settings.qwenBuffer) }
            qwenPlayer.play()
        } else if speech.isPaused, utterance != nil, effectiveEngine == .system {
            speech.continueSpeaking()
            if let utterance { armSystemSpeechWatchdog(for: utterance) }
        } else { speakCurrent() }
        updateNowPlaying()
    }

    func pause() {
        resumeAfterInterruption = false
        waitingForForegroundStart = false
        isPlaying = false
        if let qwenPlayer {
            qwenPlayer.pause()
            isPreparing = false
            // Preserve the current reserve, but cap additional work during pause.
            updateNowPlaying()
            return
        }
        if isPreparing {
            token = UUID()
            isPreparing = false
        }
        speech.pauseSpeaking(at: .immediate)
        systemSpeechWatchdog?.cancel()
        systemSpeechWatchdog = nil
        finishBackgroundTask()
        updateNowPlaying()
    }

    func stop() {
        stopAudio()
        previewDocument = nil
        previewEngine = nil
        documentID = nil
        for (command, target) in remoteCommandTargets { command.removeTarget(target) }
        remoteCommandTargets.removeAll()
        setSleepTimer(minutes: nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func seek(to newPosition: Int) {
        guard let document else { return }
        let resume = isPlaying || isPreparing
        stopAudio()
        position = min(max(0, newPosition), document.segments.count - 1)
        library.updatePosition(id: document.id, position: position)
        if resume { play() }
        updateNowPlaying()
    }

    func skip(_ offset: Int) { seek(to: position + offset) }

    func settingsChanged() {
        if isPreview { stop(); return }
        let resume = isPlaying || isPreparing
        refreshRequestedEngine()
        let discarded = discardObsoleteAudio()
        if discarded && resume { play() }
        updateNowPlaying()
    }

    func selectEngine(_ engine: VoiceEngine) {
        guard engine != .qwen || VoiceFeatures.qwenEnabled else { return }
        settings.engine = engine
        requestedEngine = engine
        // An explicit Qwen selection must take effect even if it was already
        // checked while a temporary Apple voice was reading the translation.
        if engine != .system { suspendTranslation?() }
        settingsChanged()
    }

    func selectSystemVoice(_ identifier: String, language: String) {
        settings.preferSystemVoice(identifier, for: language)
        selectEngine(.system)
    }

    func selectQwenSpeaker(_ speaker: QwenSpeaker) {
        settings.qwenSpeaker = speaker
        selectEngine(.qwen)
    }

    func selectQwenStyle(_ style: NarrationStyle) {
        settings.qwenStyle = style
        selectEngine(.qwen)
    }

    private func refreshRequestedEngine() {
        guard requestedEngine != settings.engine else { return }
        requestedEngine = settings.engine
        if settings.engine != .system { suspendTranslation?() }
    }

    func translationActivityChanged(_ active: Bool) {
        let resume = isPlaying || isPreparing
        translationIsActive = active
        let discarded = discardObsoleteAudio()
        if discarded && resume { play() }
        updateNowPlaying()
    }

    func prepareForTranslation() async {
        let session = qwenSessionID
        if qwenPlayer != nil { stopAudio() }
        if let session { await QwenVoiceRenderer.shared.endSession(session) }
        await QwenVoiceRenderer.shared.unload()
        await SupertonicVoiceRenderer.shared.unload()
    }

    @discardableResult private func discardObsoleteAudio() -> Bool {
        guard let preparedVoice, preparedVoice != chosenVoice else { return false }
        let waitingPosition = nextTranslationPosition
        stopAudio()
        nextTranslationPosition = waitingPosition
        return true
    }

    func setSpeed(_ value: Double) {
        if effectiveEngine == .qwen { settings.qwenSpeed = QwenStreamPlayer.clampedRate(value) }
        else { settings.speed = value }
    }

    func speedChanged() {
        if let qwenPlayer, effectiveEngine != .system {
            qwenPlayer.rate = playbackSpeed
            updateNowPlaying()
        } else if effectiveEngine == .system {
            settingsChanged()
        }
    }

    func qwenBufferChanged() {
        qwenPlayer?.setBufferPreset(settings.qwenBuffer)
        updateNowPlaying()
    }

    func previewQwen() {
        guard VoiceFeatures.qwenEnabled else { return }
        stopAudio()
        guard let sample = try? DocumentImporter.fromText(NarrationStyle.auditionText, title: "Trois façons de raconter", source: "APERÇU QWEN") else { return }
        previewDocument = sample
        previewEngine = .qwen
        documentID = sample.id
        configureRemoteCommands()
        position = 0
        play()
    }

    func previewSupertonic() {
        stopAudio()
        guard let sample = try? DocumentImporter.fromText(NarrationStyle.auditionText,
                                                           title: "Une voix plus fluide", source: "APERÇU SUPERTONIC") else { return }
        previewDocument = sample
        previewEngine = .supertonic
        documentID = sample.id
        configureRemoteCommands()
        position = 0
        play()
    }

    func releaseQwen() async {
        let session = qwenSessionID
        if effectiveEngine == .qwen { stop() }
        if let session { await QwenVoiceRenderer.shared.endSession(session) }
        await QwenVoiceRenderer.shared.unload()
    }

    func setSleepTimer(minutes: Int?) {
        timerTask?.cancel()
        sleepDeadline = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
        guard let minutes else { return }
        timerTask = Task {
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            pause()
            sleepDeadline = nil
        }
    }

    private func speakCurrent(recoveringSystemSpeech: Bool = false) {
        guard let document, document.segments.indices.contains(position) else { return }
        if let deadline = sleepDeadline, Date() >= deadline { pause(); setSleepTimer(minutes: nil); return }
        library.updatePosition(id: document.id, position: position)
        let window = effectiveEngine != .system
            ? NarrationWindow(sentenceIn: document, at: position)
            : NarrationWindow(document: document, start: position)
        let text = window.text
        spokenSegments = window.segments
        spokenEndPosition = window.endPosition
        wordRange = nil
        preparedVoice = chosenVoice
        switch effectiveEngine {
        case .system:
            guard let voice = selectedVoice else {
                isPlaying = false
                errorMessage = String(localized: "Aucune voix n’est disponible pour la langue de ce texte. Ajoutez une voix dans les réglages d’accessibilité d’iOS.")
                return
            }
            let next = AVSpeechUtterance(string: text)
            next.voice = voice
            next.rate = SystemVoiceSelection.speechRate(for: settings.speed)
            next.postUtteranceDelay = 0.18
            utterance = next
            if !recoveringSystemSpeech { systemSpeechRecoveryAttempts = 0 }
            speech.speak(next)
            armSystemSpeechWatchdog(for: next)
        case .qwen:
            startQwen(language: NarrationStyle.languageName(for: document.resolvedLanguage) ?? "French")
        case .supertonic:
            startSupertonic(language: SupertonicModel.languageCode(for: document.resolvedLanguage) ?? "fr")
        }
        updateNowPlaying()
    }

    /// AVSpeechSynthesizer can exceptionally stop producing callbacks while still
    /// appearing active. Restart the current sentence locally instead of requiring
    /// the reader view (and its synthesizer state) to be torn down and reopened.
    private func armSystemSpeechWatchdog(for expectedUtterance: AVSpeechUtterance) {
        systemSpeechWatchdog?.cancel()
        systemSpeechWatchdog = Task { [weak self, weak expectedUtterance] in
            guard let expectedUtterance else { return }
            do { try await Task.sleep(for: self?.systemSpeechTimeout ?? .seconds(20)) }
            catch { return }
            guard let self, self.isPlaying, self.effectiveEngine == .system,
                  self.utterance === expectedUtterance else { return }
            if self.systemSpeechRecoveryAttempts < 2 {
                self.systemSpeechRecoveryAttempts += 1
                self.speech.stopSpeaking(at: .immediate)
                self.utterance = nil
                self.speakCurrent(recoveringSystemSpeech: true)
            } else {
                self.stopAudio()
                self.errorMessage = String(localized: "La voix Apple ne répond plus. Touchez Lire pour reprendre le passage.")
                self.updateNowPlaying()
            }
        }
    }

    private func startQwen(language: String) {
        guard let document else { return }
        guard applicationIsActive else {
            waitingForForegroundStart = true
            isPreparing = true
            notice = String(localized: "Ouvrez l’app pour préparer la lecture Qwen.")
            return
        }
        waitingForForegroundStart = false
        let currentToken = UUID()
        token = currentToken
        qwenMetrics = nil
        qwenFirstAudioSeconds = nil
        isPreparing = true
        preparationStatus = String(localized: "Préparation de la réserve audio…")
        do {
            let style = settings.qwenStyle
            let speaker = settings.qwenSpeaker
            qwenSessionID = currentToken
            let render = renderQwen
            let passagePlayer = try QwenPassagePlayer(document: document, start: position, rate: settings.qwenSpeed,
                                                      buffering: .init(preset: settings.qwenBuffer)) { text in
                try await render(text, style, language, speaker, currentToken)
            }
            qwenPlayer = passagePlayer
            #if DEBUG || CONTEUR_VALIDATION
            passagePlayer.onDiagnosticEvent = { [weak self] event in
                guard let self, self.token == currentToken else { return }
                self.recordDiagnosticEvent(event)
            }
            #endif
            passagePlayer.onReserveChanged = { [weak self] reserve in
                guard let self, self.token == currentToken else { return }
                self.qwenReserve = reserve
            }
            passagePlayer.onStateChanged = { [weak self, weak passagePlayer] in
                guard let self, let passagePlayer, self.token == currentToken else { return }
                self.isPreparing = self.isPlaying && passagePlayer.isBuffering
                let action = passagePlayer.hasStarted ? String(localized: "Reconstitution") : String(localized: "Préparation")
                self.preparationStatus = String(format: String(localized: "%@ de la réserve · %lld s prêtes"), action, Int64(passagePlayer.bufferedPlaybackSeconds))
                self.qwenFirstAudioSeconds = passagePlayer.firstAudioSeconds
                self.qwenMetrics = passagePlayer.metrics
                if passagePlayer.hasPendingGeneration { self.qwenSessionID = currentToken }
                else { self.endQwenSession() }
                if self.isGenerating != passagePlayer.isGenerating {
                    self.isGenerating = passagePlayer.isGenerating
                    if self.isGenerating { self.beginBackgroundTask() }
                    else { self.finishBackgroundTask() }
                }
                // Stay awake between renders while listening, but let a paused
                // phone sleep once its bounded reserve has finished generating.
                ReadingIdleTimer.isGenerating = passagePlayer.isGenerating || (self.isPlaying && passagePlayer.hasPendingGeneration)
                self.updateNowPlaying()
            }
            passagePlayer.onPassageChanged = { [weak self] window in
                guard let self, self.token == currentToken else { return }
                self.spokenSegments = window.segments
                self.spokenEndPosition = window.endPosition
                self.wordRange = nil
            }
            passagePlayer.onWord = { [weak self] range in
                guard let self, self.token == currentToken else { return }
                self.updateSpokenRange(range)
            }
            passagePlayer.onFinished = { [weak self] in
                guard let self, self.token == currentToken else { return }
                self.advance()
            }
            passagePlayer.onNeedsForeground = { [weak self] nextPosition in
                guard let self, self.token == currentToken else { return }
                self.position = nextPosition
                self.wordRange = nil
                self.library.updatePosition(id: document.id, position: nextPosition)
                self.notice = String(localized: "Réserve Qwen épuisée. Ouvrez l’app pour préparer la suite.")
                self.updateNowPlaying()
            }
            passagePlayer.onError = { [weak self, weak passagePlayer] error in
                guard let self, self.token == currentToken else { return }
                if let failedPosition = passagePlayer?.failedPosition {
                    self.position = failedPosition
                    self.library.updatePosition(id: document.id, position: failedPosition)
                }
                self.stopAudio()
                self.errorMessage = error.localizedDescription
                self.updateNowPlaying()
            }
            passagePlayer.play()
        } catch {
            endQwenSession()
            stopAudio()
            errorMessage = error.localizedDescription
        }
    }

    private func startSupertonic(language: String) {
        guard let document else { return }
        guard applicationIsActive else {
            waitingForForegroundStart = true
            isPreparing = true
            notice = String(localized: "Ouvrez l’app pour préparer la lecture Supertonic.")
            return
        }
        waitingForForegroundStart = false
        let currentToken = UUID()
        token = currentToken
        qwenMetrics = nil
        qwenFirstAudioSeconds = nil
        isPreparing = true
        preparationStatus = String(localized: "Préparation de la voix…")
        do {
            let voice = settings.supertonicVoice
            let passagePlayer = try QwenPassagePlayer(document: document, start: position, rate: settings.speed,
                                                      sampleRate: SupertonicModel.sampleRate,
                                                      // Supertonic's background throughput is deliberately throttled
                                                      // below iOS's CPU watchdog limit. A fixed startup reserve avoids
                                                      // the automatic mode starting after one second and underrunning
                                                      // as soon as the display is locked.
                                                      buffering: .init(preset: .seconds10,
                                                                       minimumAheadSeconds: 30),
                                                      generationPriority: .utility,
                                                      refillResumeSeconds: 4) { text in
                try await SupertonicVoiceRenderer.shared.render(text, language: language, voice: voice)
            }
            qwenPlayer = passagePlayer
            #if DEBUG || CONTEUR_VALIDATION
            passagePlayer.onDiagnosticEvent = { [weak self] event in
                guard let self, self.token == currentToken else { return }
                self.recordDiagnosticEvent("supertonic:\(event)")
            }
            #endif
            passagePlayer.onReserveChanged = { [weak self] reserve in
                guard let self, self.token == currentToken else { return }
                self.qwenReserve = reserve
            }
            passagePlayer.onStateChanged = { [weak self, weak passagePlayer] in
                guard let self, let passagePlayer, self.token == currentToken else { return }
                self.isPreparing = self.isPlaying && passagePlayer.isBuffering
                self.preparationStatus = String(format: String(localized: "Préparation de la réserve · %lld s prêtes"), Int64(passagePlayer.bufferedPlaybackSeconds))
                self.qwenFirstAudioSeconds = passagePlayer.firstAudioSeconds
                self.qwenMetrics = passagePlayer.metrics
                if self.isGenerating != passagePlayer.isGenerating {
                    self.isGenerating = passagePlayer.isGenerating
                    if self.isGenerating, !self.applicationIsActive { self.beginBackgroundTask() }
                    else if !self.isGenerating { self.finishBackgroundTask() }
                }
                self.updateNowPlaying()
            }
            passagePlayer.onPassageChanged = { [weak self] window in
                guard let self, self.token == currentToken else { return }
                self.spokenSegments = window.segments; self.spokenEndPosition = window.endPosition; self.wordRange = nil
            }
            passagePlayer.onWord = { [weak self] range in
                guard let self, self.token == currentToken else { return }; self.updateSpokenRange(range)
            }
            passagePlayer.onFinished = { [weak self] in
                guard let self, self.token == currentToken else { return }; self.advance()
            }
            passagePlayer.onNeedsForeground = { [weak self] nextPosition in
                guard let self, self.token == currentToken else { return }
                self.position = nextPosition; self.library.updatePosition(id: document.id, position: nextPosition)
                self.notice = String(localized: "Ouvrez l’app pour préparer la suite.")
            }
            passagePlayer.onError = { [weak self] error in
                guard let self, self.token == currentToken else { return }; self.stopAudio(); self.errorMessage = error.localizedDescription
            }
            passagePlayer.play()
        } catch {
            stopAudio(); errorMessage = error.localizedDescription
        }
    }

    private func advance() {
        guard isPlaying, let document else { return }
        isPreparing = false
        qwenPlayer?.stop()
        qwenPlayer = nil
        qwenReserve = nil
        endQwenSession()
        utterance = nil
        wordRange = nil
        if spokenEndPosition + 1 < document.segments.count {
            position = spokenEndPosition + 1
            speakCurrent()
        } else if document.isTranslationPending {
            nextTranslationPosition = spokenEndPosition + 1
            position = document.segments.count - 1
            notice = String(localized: "La suite est en cours de traduction…")
            library.updatePosition(id: document.id, position: position)
            updateNowPlaying()
        } else { finishReading(document) }
    }

    func translationUpdated(_ id: UUID) {
        guard documentID == id, isWaitingForTranslation else { return }
        play()
    }

    private func finishReading(_ document: ReadingDocument) {
        isPlaying = false
        nextTranslationPosition = nil
        position = document.segments.count - 1
        library.updatePosition(id: document.id, position: position, finished: true)
        setSleepTimer(minutes: nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        updateNowPlaying()
    }

    private func stopAudio() {
        resumeAfterInterruption = false
        waitingForForegroundStart = false
        preparedVoice = nil
        token = UUID()
        isGenerating = false
        qwenPlayer?.stop()
        qwenPlayer = nil
        qwenReserve = nil
        endQwenSession()
        systemSpeechWatchdog?.cancel()
        systemSpeechWatchdog = nil
        systemSpeechRecoveryAttempts = 0
        wordRange = nil
        utterance = nil
        speech.stopSpeaking(at: .immediate)
        isPlaying = false
        isPreparing = false
        nextTranslationPosition = nil
        finishBackgroundTask()
    }

    private func endQwenSession() {
        guard let session = qwenSessionID else { return }
        qwenSessionID = nil
        Task {
            await QwenVoiceRenderer.shared.endSession(session)
            await QwenVoiceRenderer.shared.unloadIfIdle()
        }
    }

    private func updateSpokenRange(_ range: NSRange) {
        guard let item = spokenSegments.first(where: { NSIntersectionRange($0.range, range).length > 0 }) else { return }
        if position != item.index {
            position = item.index
            if let documentID { library.updatePosition(id: documentID, position: position) }
        }
        let intersection = NSIntersectionRange(item.range, range)
        wordRange = NSRange(location: intersection.location - item.range.location, length: intersection.length)
        if let utterance, effectiveEngine == .system {
            systemSpeechRecoveryAttempts = 0
            armSystemSpeechWatchdog(for: utterance)
        }
    }

    private func beginBackgroundTask() {
        finishBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Narration") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Expiration is expected after a short grace period. Supertonic
                // may continue under the audio background mode while sound is
                // playing, so ending this task must not turn into a user pause.
                if self.effectiveEngine == .qwen || !self.isPlaying {
                    self.qwenPlayer?.suspendGeneration()
                }
                self.finishBackgroundTask()
            }
        }
    }

    private func finishBackgroundTask() {
        ReadingIdleTimer.isGenerating = false
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }

    private func updateNowPlaying() {
        guard let document else { return }
        let waitingLabel = effectiveEngine == .supertonic
            ? String(localized: "Supertonic · ouvrez Le Conteur pour la suite")
            : String(localized: "Qwen · ouvrez Le Conteur pour la suite")
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: document.title,
            MPMediaItemPropertyArtist: qwenPlayer?.isWaitingForForeground == true || waitingForForegroundStart ? waitingLabel : voiceName,
            MPMediaItemPropertyAlbumTitle: "Le Conteur",
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying && !isPreparing ? playbackSpeed : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
    }

    private func configureRemoteCommands() {
        guard remoteCommandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        for (command, action) in [(center.playCommand, RemotePlaybackCommand.play), (center.pauseCommand, .pause),
                                  (center.togglePlayPauseCommand, .toggle), (center.nextTrackCommand, .next), (center.previousTrackCommand, .previous)] {
            command.isEnabled = true
            let target = command.addTarget { [weak self] _ in
                guard self != nil else { return .noSuchContent }
                Task { @MainActor in self?.handleRemoteCommand(action) }
                return .success
            }
            remoteCommandTargets.append((command, target))
        }
    }

    enum RemotePlaybackCommand { case play, pause, toggle, next, previous }

    func handleRemoteCommand(_ command: RemotePlaybackCommand) {
        recordDiagnosticEvent("remote:\(command)")
        switch command {
        case .play: play()
        case .pause: pause()
        // Now Playing shows Play while waiting for more PCM (playback rate 0).
        // That visible Play must keep the request to resume, not turn it into a
        // user pause just because the controller is still preparing audio.
        case .toggle: isPlaying && !isPreparing ? pause() : play()
        case .next: skip(1)
        case .previous: skip(-1)
        }
    }
}

@MainActor enum ReadingIdleTimer {
    static var isGenerating = false { didSet { update() } }
    static var isTranslating = false { didSet { update() } }
    private static func update() {
        UIApplication.shared.isIdleTimerDisabled = isGenerating || isTranslating
    }
}

extension PlaybackController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.utterance === utterance else { return }
            self.updateSpokenRange(characterRange)
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.utterance === utterance else { return }
            self.systemSpeechWatchdog?.cancel()
            self.systemSpeechWatchdog = nil
            self.systemSpeechRecoveryAttempts = 0
            self.advance()
        }
    }
}

struct NarrationWindow: Sendable {
    let text: String
    let segments: [(index: Int, range: NSRange)]
    let endPosition: Int

    /// Imported and translated segments already follow sentence boundaries.
    /// Keep one per Qwen request, including the importer's bounded pieces for
    /// exceptionally long sentences. Do not regroup them into a paragraph.
    init(sentenceIn document: ReadingDocument, at position: Int) {
        text = document.segments.indices.contains(position) ? document.segments[position] : ""
        segments = document.segments.indices.contains(position)
            ? [(position, NSRange(location: 0, length: text.utf16.count))] : []
        endPosition = position
    }

    /// Groups a few neighbouring sentences from the current paragraph into a
    /// bounded Qwen request. Keeping paragraph boundaries as hard boundaries
    /// avoids manufacturing pauses and pronunciation artefacts at joins.
    init(document: ReadingDocument, start: Int, characterLimit: Int = 280,
         sentenceLimit: Int = 3) {
        let paragraph = document.paragraphRanges.first { $0.contains(start) } ?? start..<(start + 1)
        var text = ""
        var mapping: [(index: Int, range: NSRange)] = []
        for index in start..<paragraph.upperBound where document.segments.indices.contains(index) {
            guard mapping.count < max(1, sentenceLimit) else { break }
            let sentence = document.segments[index]
            let separatorLength = text.isEmpty ? 0 : 1
            guard text.isEmpty || text.count + separatorLength + sentence.count <= characterLimit else { break }
            if !text.isEmpty { text += " " }
            let offset = text.utf16.count
            text += sentence
            mapping.append((index, NSRange(location: offset, length: sentence.utf16.count)))
        }
        self.text = text
        segments = mapping
        endPosition = mapping.last?.index ?? start
    }
}
