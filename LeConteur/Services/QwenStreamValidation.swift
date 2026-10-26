#if DEBUG || CONTEUR_VALIDATION
import SwiftUI

/// Explicit launch-only probe using the production playback controller and an
/// isolated library/preferences. Compiled out of ordinary Release builds.
struct QwenStreamValidationView: View {
    @State private var playback: PlaybackController
    @State private var status = "Démarrage…"
    @State private var started = false
    @State private var userStopped = false
    @State private var validationDocument: ReadingDocument?
    private var backgroundProbe: Bool { CommandLine.arguments.contains("--background-validation") }
    private var supertonicProbe: Bool { CommandLine.arguments.contains("--supertonic-stream-validation") }
    private var partialTranslationProbe: Bool { CommandLine.arguments.contains("--partial-translation-validation") }
    private var generationProbe: Bool { CommandLine.arguments.contains("--continuous-generation-validation") }

    init() {
        let folder = URL.documentsDirectory.appending(path: "QwenStreamValidation/library")
        let settings = ReaderSettings(defaults: UserDefaults(suiteName: "qwen-stream-validation")!)
        let supertonicProbe = CommandLine.arguments.contains("--supertonic-stream-validation")
        settings.engine = supertonicProbe ? .supertonic : .qwen
        settings.speed = 1
        settings.qwenStyle = .warm
        settings.qwenSpeaker = CommandLine.arguments.contains("--serena") ? .serena : .ryan
        let generationProbe = CommandLine.arguments.contains("--continuous-generation-validation")
        settings.qwenSpeed = generationProbe ? 1.25 : 2
        settings.qwenBuffer = CommandLine.arguments.contains("--buffer-30") || CommandLine.arguments.contains("--background-validation") ? .seconds30 : .automatic
        if generationProbe { settings.qwenBuffer = .seconds10 }
        let library = LibraryStore(directory: folder)
        if CommandLine.arguments.contains("--partial-translation-validation") {
            var sample = try! DocumentImporter.fromText(NarrationStyle.auditionText, title: "Qwen · traduction en pause")
            sample.languageCode = "fr"
            sample.translationOf = UUID()
            sample.translationComplete = false
            library.add(sample)
            _validationDocument = State(initialValue: sample)
        } else if generationProbe || CommandLine.arguments.contains("--reserve-validation") || CommandLine.arguments.contains("--background-validation") {
            var sample = try! DocumentImporter.fromText(Self.reserveText, title: "Réserve Qwen")
            sample.languageCode = "fr"
            library.add(sample)
            _validationDocument = State(initialValue: sample)
        } else if CommandLine.arguments.contains("--multi-passage") {
            var sample = try! DocumentImporter.fromText(
                NarrationStyle.auditionText.replacingOccurrences(of: "fontaine. ", with: "fontaine.\n\n"), title: "Continuité Qwen")
            sample.languageCode = "fr"
            library.add(sample)
            _validationDocument = State(initialValue: sample)
        } else { _validationDocument = State(initialValue: nil) }
        if generationProbe {
            let archive = QwenValidationAudioArchive()
            _playback = State(initialValue: PlaybackController(library: library, settings: settings,
                renderQwen: { text, style, language, speaker, session in
                    let result = try await QwenVoiceRenderer.shared.render(text, style: style, language: language,
                        speaker: speaker, sessionID: session)
                    do { try await archive.save(result) }
                    catch { try? FileManager.default.removeItem(at: result.url); throw error }
                    return result
                }))
        } else { _playback = State(initialValue: PlaybackController(library: library, settings: settings)) }
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform").font(.largeTitle)
            Text(supertonicProbe ? "Mesure Supertonic" : "Essai Qwen en continu").font(.title2)
            Text(status).multilineTextAlignment(.center)
            Text(playback.isPreparing ? playback.preparationStatus : playback.isPlaying
                 ? "Lecture à \((supertonicProbe ? playback.settings.speed : playback.settings.qwenSpeed).formatted())×" : "Pause")
            if let reserve = playback.qwenReserve { QwenReserveGauge(reserve: reserve) }
                if backgroundProbe, playback.qwenFirstAudioSeconds != nil, !supertonicProbe {
                Button(playback.isPlaying ? "Pause" : "Lire puis verrouiller l’iPhone") { playback.toggle() }
                    .buttonStyle(.borderedProminent)
                Text("Depuis l’écran verrouillé, essayez Pause puis Lire. Attendez la fin de la réserve, puis revenez dans Le Conteur.")
                    .font(.caption)
            }
            Button("Arrêter") { userStopped = true; playback.stop(); status = "Essai arrêté" }
        }.padding(30)
            .task {
                guard !started else { return }
                started = true
                let keepsScreenAwake = CommandLine.arguments.contains("--keep-screen-awake")
                if keepsScreenAwake { UIApplication.shared.isIdleTimerDisabled = true }
                defer { if keepsScreenAwake { UIApplication.shared.isIdleTimerDisabled = false } }
                let activationDeadline = Date().addingTimeInterval(30)
                while UIApplication.shared.applicationState != .active, Date() < activationDeadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let start = Date()
                var audioBeforeEnd = false
                var pauses = 0
                var midPassageUnderruns = 0
                var waitPositions: [Double] = []
                var wasBuffering = false
                var pausedAndResumed = false
                var generationBeforePause: Double?
                var reserveAtStart = 0.0
                var peakReserve = 0.0
                var lastPlayed = 0.0
                var maximumPosition = 0
                var observedFirstAudio = false
                var trace: [[String: Any]] = []
                var nextTrace = 0.0
                var previousPlayed = 0.0
                var backgroundAudio = false
                var backgroundPause = false
                var backgroundResume = false
                var backgroundResumeRequested = false
                var exhaustedAt: Double?
                var resumedInForeground = false
                var finishedBook = false
                var foregroundResumeAt: Date?
                var completedAtExhaustion = 0.0
                var events: [[String: Any]] = []
                playback.onDiagnosticEvent = { event in
                    let background = UIApplication.shared.applicationState != .active
                    if background, event == "remote:pause" || (event == "remote:toggle" && playback.isPlaying && !playback.isPreparing) {
                        backgroundPause = true
                    }
                    if background, backgroundPause,
                       event == "remote:play" || (event == "remote:toggle" && (!playback.isPlaying || playback.isPreparing)) {
                        backgroundResumeRequested = true
                    }
                    var row: [String: Any] = ["elapsed": Date().timeIntervalSince(start), "event": event,
                                              "playing": playback.isPlaying, "preparing": playback.isPreparing]
                    row["applicationState"] = UIApplication.shared.applicationState.rawValue
                    row.merge(playback.qwenDiagnosticState) { _, new in new }
                    events.append(row)
                    print("QWEN_BACKGROUND_EVENT \(row)")
                    if generationProbe, let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
                       let line = String(data: data, encoding: .utf8) { print("QWEN_GENERATION \(line)") }
                }
                if let validationDocument { playback.open(validationDocument, autoplay: true) }
                else { playback.previewQwen() }
                while !Task.isCancelled, Date().timeIntervalSince(start) < 300 {
                    if backgroundProbe || generationProbe || supertonicProbe {
                        let elapsed = Date().timeIntervalSince(start)
                        if elapsed >= nextTrace {
                            nextTrace = elapsed + 1
                            let background = UIApplication.shared.applicationState == .background
                            let played = playback.qwenPlayedSeconds
                            let progressed = played > previousPlayed + 0.1
                            if background, progressed { backgroundAudio = true }
                            if background, !playback.isPlaying, playback.qwenFirstAudioSeconds != nil { backgroundPause = true }
                            if background, backgroundResumeRequested, playback.isPlaying, progressed { backgroundResume = true }
                            if background, playback.isPreparing, playback.qwenReserve?.passageCount == 0, exhaustedAt == nil {
                                exhaustedAt = played
                                completedAtExhaustion = playback.qwenCompletedAudioSeconds
                            }
                            if let exhaustedAt, UIApplication.shared.applicationState == .active, played > exhaustedAt + 2,
                               foregroundResumeAt == nil { foregroundResumeAt = Date() }
                            // A wall-clock position alone cannot prove hardware
                            // playback. Require a newly delivered PCM completion,
                            // and leave at least 20 seconds to hear the restart.
                            if let foregroundResumeAt, Date().timeIntervalSince(foregroundResumeAt) >= 20,
                               UIApplication.shared.applicationState == .active,
                               playback.qwenCompletedAudioSeconds > completedAtExhaustion + 1 {
                                resumedInForeground = true
                            }
                            if exhaustedAt != nil {
                                if background { status = "Réserve épuisée. Revenez dans Le Conteur pour reprendre." }
                                else if !playback.isPlaying { status = "En pause. Touchez Lire pour reprendre." }
                                else if playback.isPreparing { status = "Retour détecté. Qwen prépare la suite ; la lecture reprendra automatiquement." }
                                else { status = "La lecture a repris. Vérification pendant au moins vingt secondes…" }
                            }
                            previousPlayed = played
                            var row: [String: Any] = ["elapsed": elapsed, "background": background,
                                "applicationState": UIApplication.shared.applicationState.rawValue,
                                "protectedDataAvailable": UIApplication.shared.isProtectedDataAvailable,
                                "playing": playback.isPlaying, "preparing": playback.isPreparing, "generating": playback.isGenerating,
                                "played": played, "reserve": playback.qwenBufferedPlaybackSeconds,
                                "position": playback.position, "error": playback.errorMessage ?? ""]
                            row.merge(playback.qwenDiagnosticState) { _, new in new }
                            trace.append(row)
                            let folder = URL.documentsDirectory.appending(path: generationProbe ? "QwenContinuousValidation" : "QwenStreamValidation")
                            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            if let data = try? JSONSerialization.data(withJSONObject: trace, options: [.sortedKeys]) {
                                try? data.write(to: folder.appending(path: generationProbe ? "playback-trace.json" : "background-trace.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                            }
                            if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), let line = String(data: data, encoding: .utf8) {
                                print("QWEN_BACKGROUND \(line)")
                            }
                        }
                    }
                    peakReserve = max(peakReserve, playback.qwenBufferedPlaybackSeconds)
                    lastPlayed = max(lastPlayed, playback.qwenPlayedSeconds)
                    maximumPosition = max(maximumPosition, playback.position)
                    if playback.qwenFirstAudioSeconds != nil, !observedFirstAudio {
                        observedFirstAudio = true
                        reserveAtStart = playback.qwenBufferedPlaybackSeconds
                        if backgroundProbe, !supertonicProbe {
                            playback.pause(); status = "Réserve prête. Vous pouvez lancer l’essai écran verrouillé."
                        } else if backgroundProbe {
                            status = "Lecture en cours. Verrouillez maintenant l’iPhone."
                        }
                    }
                    if playback.qwenFirstAudioSeconds != nil, playback.isGenerating {
                        audioBeforeEnd = true
                        if !backgroundProbe { status = "Le son a commencé pendant la génération." }
                    }
                    if playback.qwenFirstAudioSeconds != nil, playback.isPreparing, !wasBuffering {
                        pauses += 1
                        waitPositions.append(playback.qwenPlayedSeconds)
                        if abs(playback.qwenPlayedSeconds - playback.qwenCompletedAudioSeconds) > 0.05 { midPassageUnderruns += 1 }
                    }
                    wasBuffering = playback.isPreparing
                    if !backgroundProbe, !CommandLine.arguments.contains("--no-pause"), audioBeforeEnd, !pausedAndResumed, playback.qwenPlayedSeconds > 1 {
                        generationBeforePause = playback.qwenFirstAudioSeconds
                        playback.pause()
                        try? await Task.sleep(for: .milliseconds(400))
                        playback.play()
                        pausedAndResumed = playback.qwenFirstAudioSeconds == generationBeforePause
                    }
                    finishedBook = observedFirstAudio && playback.document?.isFinished == true
                    if userStopped || playback.errorMessage != nil || (partialTranslationProbe && playback.isWaitingForTranslation)
                        || (backgroundProbe ? resumedInForeground || finishedBook : !playback.isPlaying && !playback.isGenerating) { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let continuousProbe = CommandLine.arguments.contains("--reserve-validation")
                let reachedEnd = validationDocument.map { playback.position == $0.segments.count - 1 } ?? true
                let playbackComplete = partialTranslationProbe ? playback.isWaitingForTranslation : !playback.isPlaying
                let expectedNotice = partialTranslationProbe && playback.isWaitingForTranslation
                let success = backgroundProbe
                    ? (supertonicProbe
                       ? backgroundAudio && finishedBook && playback.errorMessage == nil
                       : backgroundAudio && backgroundPause && backgroundResume && resumedInForeground && playback.errorMessage == nil)
                    : (!continuousProbe || (audioBeforeEnd && pauses == 0)) && playback.qwenFirstAudioSeconds != nil
                    && playback.qwenMetrics != nil && playback.errorMessage == nil && (playback.notice == nil || expectedNotice)
                    && playbackComplete && reachedEnd && midPassageUnderruns == 0
                var report: [String: Any] = [
                    "status": success ? "passed" : backgroundProbe && playback.errorMessage == nil ? "incomplete" : "failed", "playbackSpeed": playback.playbackSpeed,
                    "buffering": "time-reserve-with-continuous-prefetch", "multiplePassages": validationDocument != nil,
                    "bufferPreset": supertonicProbe ? "seconds10" : playback.settings.qwenBuffer.rawValue,
                    "supertonicProbe": supertonicProbe,
                    "partialTranslationProbe": partialTranslationProbe,
                    "actualEngine": playback.effectiveEngine.rawValue,
                    "waitingForTranslationAfterAudio": playback.isWaitingForTranslation,
                    "reserveAtStartSeconds": reserveAtStart, "peakReserveSeconds": peakReserve,
                    "lastObservedPlayedSecondsAt1x": lastPlayed,
                    "maximumPosition": maximumPosition, "reachedEnd": reachedEnd,
                    "paragraphCount": validationDocument?.paragraphRanges.count ?? 1,
                    "speaker": playback.settings.qwenSpeaker.rawValue,
                    "firstAudioSeconds": playback.qwenFirstAudioSeconds ?? 0,
                    "audioBeforeGenerationCompleted": audioBeforeEnd,
                    "pauseResumedWithoutRegeneration": pausedAndResumed,
                    "pauseTestRequested": !CommandLine.arguments.contains("--no-pause"),
                    "passageWaits": pauses, "midPassageUnderruns": midPassageUnderruns,
                    "waitPositionsAt1x": waitPositions, "elapsedSeconds": Date().timeIntervalSince(start),
                    "error": playback.errorMessage ?? (expectedNotice ? "" : playback.notice ?? "")
                ]
                if let metrics = playback.qwenMetrics {
                    report["generationSeconds"] = metrics.generationSeconds
                    report["audioSecondsAt1x"] = metrics.audioSeconds
                    report["generationToAudioRatio"] = metrics.generationSeconds / metrics.audioSeconds
                    report["observedFootprintBytes"] = metrics.observedFootprintBytes
                    report["modelLoads"] = metrics.modelLoads
                }
                if backgroundProbe {
                    report["backgroundAudio"] = backgroundAudio
                    report["backgroundPause"] = backgroundPause
                    report["backgroundResume"] = backgroundResume
                    report["resumedInForeground"] = resumedInForeground
                    report["backgroundTrace"] = trace
                    report["events"] = events
                }
                if generationProbe {
                    report["generationEvents"] = events
                    report["continuousGenerationProbe"] = true
                    report["playbackTrace"] = trace
                }
                let folder = URL.documentsDirectory.appending(path: generationProbe ? "QwenContinuousValidation" : "QwenStreamValidation")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: folder.appending(path: "report.json"), options: .atomic)
                }
                playback.stop()
                if supertonicProbe { await SupertonicVoiceRenderer.shared.unload() }
                else { await QwenVoiceRenderer.shared.unload() }
                status = success ? "Essai terminé." : "Essai interrompu."
                print("QWEN_STREAM_VALIDATION \(success ? "passed" : "failed")")
            }
    }

    private static let reserveText = """
    Le soleil venait de se lever sur le port. Élise ouvrit les volets et regarda les premiers bateaux quitter la rive. Aujourd’hui, elle avait décidé de prendre son temps.

    Dans la cuisine, une odeur de café accompagnait le bruit discret de la pluie. Sur la table, une lettre attendait depuis la veille. Elle portait simplement son prénom.

    Elle reconnut aussitôt l’écriture de son frère. Il lui racontait son voyage, les villages traversés et cette rencontre inattendue dans une petite gare de montagne.

    « Tu devrais venir », avait-il écrit. Élise sourit. Elle n’avait pas pris de vacances depuis longtemps, et l’idée de retrouver les chemins de son enfance lui plaisait.

    Un peu plus tard, elle descendit acheter du pain. Le boulanger lui demanda des nouvelles, puis lui tendit une baguette encore chaude. La matinée commençait doucement.

    En rentrant, elle s’arrêta près du vieux pont. L’eau était claire, presque immobile. Deux enfants observaient les poissons pendant que leur grand-père leur racontait une histoire.

    Élise sortit son téléphone pour répondre à la lettre. Puis elle le rangea. Elle préférait choisir du papier, trouver les mots justes et laisser à son frère le plaisir de les découvrir.

    Ce soir-là, sa réponse était prête. Elle partirait samedi, avec un petit sac et son livre préféré. Pour la première fois depuis des mois, elle attendait le week-end avec impatience.
    """
}

/// Only the fixed, fictitious probe text is retained for offline audio inspection.
/// The regular library never installs this renderer or exports book audio.
private actor QwenValidationAudioArchive {
    private let directory = URL.documentsDirectory.appending(path: "QwenContinuousValidation/audio-\(UUID())")
    private var count = 0
    func save(_ result: QwenRenderedAudio) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: result.url, to: directory.appending(path: "passage-\(count).wav"))
        count += 1
    }
}
#endif
