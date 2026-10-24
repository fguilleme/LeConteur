import AVFoundation
import MediaPlayer
import Observation
import UIKit
import Darwin

@MainActor @Observable
final class PlaybackController: NSObject {
    private(set) var documentID: UUID?
    private(set) var position = 0
    private(set) var isPlaying = false
    private(set) var isPreparing = false
    private(set) var isGenerating = false
    private(set) var qwenFirstAudioSeconds: Double?
    private(set) var sleepDeadline: Date?
    private(set) var wordRange: NSRange?
    private(set) var preparationStatus = "Préparation de la voix…"
    private(set) var qwenMetrics: QwenRenderMetrics?
    private(set) var notice: String?
    var errorMessage: String?
    private let library: LibraryStore
    let settings: ReaderSettings
    private let speech = AVSpeechSynthesizer()
    private let neural = NeuralVoiceRenderer()
    private var previewDocument: ReadingDocument?
    private var player: AVAudioPlayer?
    private var qwenPlayer: QwenPassagePlayer?
    private var qwenSessionID: UUID?
    private var audioURL: URL?
    private var utterance: AVSpeechUtterance?
    private var spokenSegments: [(index: Int, range: NSRange)] = []
    private var spokenEndPosition = 0
    private var generation: Task<Void, Never>?
    private var token = UUID()
    private var timerTask: Task<Void, Never>?
    private var wordTrackingTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var nextTranslationPosition: Int?
    private var systemVoiceForTranslation = false

    var document: ReadingDocument? { previewDocument ?? documentID.flatMap { library.document($0) } }
    var isPreview: Bool { previewDocument != nil }
    var isWaitingForTranslation: Bool { isPlaying && nextTranslationPosition != nil }
    var playbackSpeed: Double { effectiveEngine == .qwen ? settings.qwenSpeed : settings.speed }
    var qwenPlayedSeconds: Double { qwenPlayer?.playedSeconds ?? 0 }
    var qwenCompletedAudioSeconds: Double { qwenPlayer?.completedAudioSeconds ?? 0 }
    var qwenBufferedPlaybackSeconds: Double { qwenPlayer?.bufferedPlaybackSeconds ?? 0 }
    var effectiveEngine: VoiceEngine {
        if isPreview { return .qwen }
        // Keep the multi-GB Qwen model out of memory while Apple translates ahead.
        // Keep this voice for the current reading session to avoid a mid-sentence change.
        if systemVoiceForTranslation { return .system }
        switch settings.engine {
        case .qwen: return NarrationStyle.languageName(for: document?.languageCode) != nil ? .qwen : .system
        case .neural: return (document?.languageCode ?? "fr").hasPrefix("fr") ? .neural : .system
        case .system: return .system
        }
    }
    var voiceName: String {
        switch effectiveEngine {
        case .qwen: "\(settings.qwenSpeaker.name) · \(settings.qwenStyle.name)"
        case .neural: "Siwis · Neuronale"
        case .system: selectedVoice?.name ?? "Voix du texte"
        }
    }
    var selectedVoice: AVSpeechSynthesisVoice? {
        let language = document?.languageCode ?? TranslationCoordinator.phoneLanguage
        return SystemVoiceSelection.resolve(language: language, preferred: settings.systemVoiceID(for: language))
    }

    init(library: LibraryStore, settings: ReaderSettings) {
        self.library = library
        self.settings = settings
        super.init()
        speech.delegate = self
        configureRemoteCommands()
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let kind = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if kind == AVAudioSession.InterruptionType.began.rawValue { Task { @MainActor in self?.pause() } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { Task { @MainActor in self?.pause() } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.effectiveEngine == .qwen else { return }
                if self.qwenPlayer?.hasPendingGeneration == true {
                    self.stopAudio()
                    self.notice = QwenError.foregroundRequired.localizedDescription
                }
                Task { await QwenVoiceRenderer.shared.unload() }
            }
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
                    self.notice = "Préparation arrêtée pour libérer de la mémoire. Réessayez sur un passage plus court."
                }
                await QwenVoiceRenderer.shared.unloadIfIdle()
            }
        })
    }

    func open(_ document: ReadingDocument, autoplay: Bool = false) {
        previewDocument = nil
        if documentID != document.id {
            stopAudio()
            documentID = document.id
            position = document.isFinished ? 0 : document.position
            systemVoiceForTranslation = document.isTranslationPending && settings.engine == .qwen
        }
        updateNowPlaying()
        if autoplay { play() }
    }

    func toggle() { isPlaying || isPreparing ? pause() : play() }

    func play() {
        guard let document, !document.segments.isEmpty else { return }
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
                notice = "La suite est en cours de traduction…"
            } else { finishReading(document) }
            updateNowPlaying()
            return
        }
        if let qwenPlayer, effectiveEngine == .qwen {
            qwenPlayer.play()
        } else if speech.isPaused, utterance != nil, effectiveEngine == .system {
            speech.continueSpeaking()
        } else if let player, effectiveEngine != .system {
            player.play()
        } else { speakCurrent() }
        updateNowPlaying()
    }

    func pause() {
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
            generation?.cancel()
            generation = nil
            isPreparing = false
        }
        speech.pauseSpeaking(at: .immediate)
        player?.pause()
        finishBackgroundTask()
        updateNowPlaying()
    }

    func stop() {
        stopAudio()
        previewDocument = nil
        documentID = nil
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
        let waitingPosition = nextTranslationPosition
        stopAudio()
        nextTranslationPosition = waitingPosition
        systemVoiceForTranslation = document?.isTranslationPending == true && settings.engine == .qwen
        if resume { play() }
        if settings.engine != .qwen { Task { await QwenVoiceRenderer.shared.unload() } }
    }

    func setSpeed(_ value: Double) {
        if effectiveEngine == .qwen { settings.qwenSpeed = QwenStreamPlayer.clampedRate(value) }
        else { settings.speed = value }
    }

    func speedChanged() {
        if let qwenPlayer, effectiveEngine == .qwen {
            qwenPlayer.rate = settings.qwenSpeed
            updateNowPlaying()
        } else if effectiveEngine != .qwen { settingsChanged() }
    }

    func qwenBufferChanged() {
        qwenPlayer?.setBufferPreset(settings.qwenBuffer)
        updateNowPlaying()
    }

    func previewQwen() {
        stopAudio()
        guard let sample = try? DocumentImporter.fromText(NarrationStyle.auditionText, title: "Trois façons de raconter", source: "APERÇU QWEN") else { return }
        previewDocument = sample
        documentID = sample.id
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

    private func speakCurrent() {
        guard let document, document.segments.indices.contains(position) else { return }
        if let deadline = sleepDeadline, Date() >= deadline { pause(); setSleepTimer(minutes: nil); return }
        library.updatePosition(id: document.id, position: position)
        // Give the narrator a whole paragraph of context instead of restarting after every sentence.
        let window = NarrationWindow(document: document, start: position, characterLimit: effectiveEngine == .qwen ? 360 : 900)
        let text = window.text
        spokenSegments = window.segments
        spokenEndPosition = window.endPosition
        wordRange = nil
        // Siwis is French. Other languages use the corresponding system voice.
        switch effectiveEngine {
        case .system:
            guard let voice = selectedVoice else {
                isPlaying = false
                errorMessage = "Aucune voix n’est disponible pour la langue de ce texte. Ajoutez une voix dans les réglages d’accessibilité d’iOS."
                return
            }
            let next = AVSpeechUtterance(string: text)
            next.voice = voice
            next.rate = SystemVoiceSelection.speechRate(for: settings.speed)
            next.postUtteranceDelay = 0.18
            utterance = next
            speech.speak(next)
        case .qwen:
            startQwen(language: NarrationStyle.languageName(for: document.languageCode) ?? "French")
        case .neural:
            isPreparing = true
            preparationStatus = "Préparation de la voix…"
            let currentToken = UUID()
            token = currentToken
            let speed = settings.speed
            beginBackgroundTask()
            generation = Task {
                do {
                    let url = try await neural.render(text, speed: speed)
                    guard !Task.isCancelled, token == currentToken, isPlaying else {
                        try? FileManager.default.removeItem(at: url)
                        return
                    }
                    audioURL = url
                    player = try AVAudioPlayer(contentsOf: url)
                    player?.delegate = self
                    player?.prepareToPlay()
                    guard player?.play() == true else { throw NeuralVoiceError.generation }
                    trackNeuralWords(text)
                    isPreparing = false
                    finishBackgroundTask()
                } catch {
                    guard token == currentToken, !Task.isCancelled else { return }
                    stopAudio()
                    errorMessage = error.localizedDescription
                    updateNowPlaying()
                }
            }
        }
        updateNowPlaying()
    }

    private func startQwen(language: String) {
        guard let document else { return }
        guard UIApplication.shared.applicationState == .active else {
            isPlaying = false
            notice = QwenError.foregroundRequired.localizedDescription
            return
        }
        let currentToken = UUID()
        token = currentToken
        qwenMetrics = nil
        qwenFirstAudioSeconds = nil
        isPreparing = true
        preparationStatus = "Préparation de la réserve audio…"
        do {
            let style = settings.qwenStyle
            let speaker = settings.qwenSpeaker
            qwenSessionID = currentToken
            let passagePlayer = try QwenPassagePlayer(document: document, start: position, rate: settings.qwenSpeed,
                                                    buffering: .init(preset: settings.qwenBuffer)) { text in
                try await QwenVoiceRenderer.shared.render(text, style: style, language: language, speaker: speaker, sessionID: currentToken)
            }
            qwenPlayer = passagePlayer
            passagePlayer.onStateChanged = { [weak self, weak passagePlayer] in
                guard let self, let passagePlayer, self.token == currentToken else { return }
                self.isPreparing = self.isPlaying && passagePlayer.isBuffering
                self.preparationStatus = "\(passagePlayer.hasStarted ? "Reconstitution" : "Préparation") de la réserve · \(Int(passagePlayer.bufferedPlaybackSeconds)) s prêtes"
                self.qwenFirstAudioSeconds = passagePlayer.firstAudioSeconds
                self.qwenMetrics = passagePlayer.metrics
                if !passagePlayer.hasPendingGeneration { self.endQwenSession() }
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
            passagePlayer.onError = { [weak self] error in
                guard let self, self.token == currentToken else { return }
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

    private func advance() {
        guard isPlaying, let document else { return }
        isPreparing = false
        qwenPlayer?.stop()
        qwenPlayer = nil
        endQwenSession()
        clearAudioFile()
        player = nil
        utterance = nil
        wordTrackingTask?.cancel()
        wordRange = nil
        if spokenEndPosition + 1 < document.segments.count {
            position = spokenEndPosition + 1
            speakCurrent()
        } else if document.isTranslationPending {
            nextTranslationPosition = spokenEndPosition + 1
            position = document.segments.count - 1
            notice = "La suite est en cours de traduction…"
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
        token = UUID()
        generation?.cancel()
        generation = nil
        isGenerating = false
        qwenPlayer?.stop()
        qwenPlayer = nil
        endQwenSession()
        wordTrackingTask?.cancel()
        wordTrackingTask = nil
        wordRange = nil
        utterance = nil
        speech.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
        clearAudioFile()
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

    private func clearAudioFile() {
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        audioURL = nil
    }

    private func trackNeuralWords(_ text: String) {
        wordTrackingTask?.cancel()
        let nsText = text as NSString
        let expression = try? NSRegularExpression(pattern: "\\S+")
        let ranges = expression?.matches(in: text, range: NSRange(location: 0, length: nsText.length)).map(\.range) ?? []
        wordTrackingTask = Task {
            while !Task.isCancelled, let player {
                if player.isPlaying, player.duration > 0 {
                    let offset = Int(player.currentTime / player.duration * Double(nsText.length))
                    if let range = ranges.last(where: { $0.location <= offset }) { updateSpokenRange(range) }
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
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
    }

    private func beginBackgroundTask() {
        finishBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Narration") { [weak self] in
            Task { @MainActor in self?.pause() }
        }
    }

    private func finishBackgroundTask() {
        ReadingIdleTimer.isGenerating = false
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }

    private func updateNowPlaying() {
        guard let document else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: document.title,
            MPMediaItemPropertyArtist: voiceName,
            MPMediaItemPropertyAlbumTitle: "Le Conteur",
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying && !isPreparing ? playbackSpeed : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.play() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(1) }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(-1) }; return .success }
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
            self.advance()
        }
    }
}

struct NarrationWindow: Sendable {
    let text: String
    let segments: [(index: Int, range: NSRange)]
    let endPosition: Int

    init(document: ReadingDocument, start: Int, characterLimit: Int = 900) {
        let paragraph = document.paragraphRanges.first { $0.contains(start) } ?? start..<(start + 1)
        var text = ""
        var mapping: [(index: Int, range: NSRange)] = []
        for index in start..<paragraph.upperBound where document.segments.indices.contains(index) {
            let sentence = document.segments[index]
            if !text.isEmpty && text.count + sentence.count + 1 > characterLimit { break }
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

extension PlaybackController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            if flag { self.advance() }
            else { self.stopAudio(); self.errorMessage = "La lecture audio a été interrompue." }
        }
    }
}
