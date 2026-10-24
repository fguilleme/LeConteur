#if DEBUG || CONTEUR_VALIDATION
import SwiftUI

/// Explicit launch-only probe using the production playback controller and an
/// isolated library/preferences. Compiled out of ordinary Release builds.
struct QwenStreamValidationView: View {
    @State private var playback: PlaybackController
    @State private var status = "Démarrage…"
    @State private var started = false
    private let validationDocument: ReadingDocument?

    init() {
        let folder = URL.documentsDirectory.appending(path: "QwenStreamValidation/library")
        let settings = ReaderSettings(defaults: UserDefaults(suiteName: "qwen-stream-validation")!)
        settings.engine = .qwen
        settings.qwenStyle = .warm
        settings.qwenSpeaker = CommandLine.arguments.contains("--serena") ? .serena : .ryan
        settings.qwenSpeed = 2
        settings.qwenBuffer = CommandLine.arguments.contains("--buffer-30") ? .seconds30 : .automatic
        let library = LibraryStore(directory: folder)
        if CommandLine.arguments.contains("--reserve-validation") {
            var sample = try! DocumentImporter.fromText(Self.reserveText, title: "Réserve Qwen")
            sample.languageCode = "fr"
            library.add(sample)
            validationDocument = sample
        } else if CommandLine.arguments.contains("--multi-passage") {
            var sample = try! DocumentImporter.fromText(
                NarrationStyle.auditionText.replacingOccurrences(of: "fontaine. ", with: "fontaine.\n\n"), title: "Continuité Qwen")
            sample.languageCode = "fr"
            library.add(sample)
            validationDocument = sample
        } else { validationDocument = nil }
        _playback = State(initialValue: PlaybackController(library: library, settings: settings))
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform").font(.largeTitle)
            Text("Essai Qwen en continu").font(.title2)
            Text(status).multilineTextAlignment(.center)
            Text(playback.isPreparing ? playback.preparationStatus : playback.isPlaying ? "Lecture à 2×" : "Pause")
            Button("Arrêter") { playback.stop(); status = "Essai arrêté" }
        }.padding(30)
            .task {
                guard !started else { return }
                started = true
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
                if let validationDocument { playback.open(validationDocument, autoplay: true) }
                else { playback.previewQwen() }
                while !Task.isCancelled, Date().timeIntervalSince(start) < 300 {
                    peakReserve = max(peakReserve, playback.qwenBufferedPlaybackSeconds)
                    lastPlayed = max(lastPlayed, playback.qwenPlayedSeconds)
                    maximumPosition = max(maximumPosition, playback.position)
                    if playback.qwenFirstAudioSeconds != nil, !observedFirstAudio {
                        observedFirstAudio = true
                        reserveAtStart = playback.qwenBufferedPlaybackSeconds
                    }
                    if playback.qwenFirstAudioSeconds != nil, playback.isGenerating {
                        audioBeforeEnd = true
                        status = "Le son a commencé pendant la génération."
                    }
                    if playback.qwenFirstAudioSeconds != nil, playback.isPreparing, !wasBuffering {
                        pauses += 1
                        waitPositions.append(playback.qwenPlayedSeconds)
                        if abs(playback.qwenPlayedSeconds - playback.qwenCompletedAudioSeconds) > 0.05 { midPassageUnderruns += 1 }
                    }
                    wasBuffering = playback.isPreparing
                    if !CommandLine.arguments.contains("--no-pause"), audioBeforeEnd, !pausedAndResumed, playback.qwenPlayedSeconds > 1 {
                        generationBeforePause = playback.qwenFirstAudioSeconds
                        playback.pause()
                        try? await Task.sleep(for: .milliseconds(400))
                        playback.play()
                        pausedAndResumed = playback.qwenFirstAudioSeconds == generationBeforePause
                    }
                    if playback.errorMessage != nil || (!playback.isPlaying && !playback.isGenerating) { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let continuousProbe = CommandLine.arguments.contains("--reserve-validation")
                let reachedEnd = validationDocument.map { playback.position == $0.segments.count - 1 } ?? true
                let success = (!continuousProbe || (audioBeforeEnd && pauses == 0)) && playback.qwenFirstAudioSeconds != nil
                    && playback.qwenMetrics != nil && playback.errorMessage == nil && playback.notice == nil
                    && !playback.isPlaying && reachedEnd && midPassageUnderruns == 0
                var report: [String: Any] = [
                    "status": success ? "passed" : "failed", "playbackSpeed": 2,
                    "buffering": "time-reserve-with-continuous-prefetch", "multiplePassages": validationDocument != nil,
                    "bufferPreset": playback.settings.qwenBuffer.rawValue,
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
                    "error": playback.errorMessage ?? playback.notice ?? ""
                ]
                if let metrics = playback.qwenMetrics {
                    report["generationSeconds"] = metrics.generationSeconds
                    report["audioSecondsAt1x"] = metrics.audioSeconds
                    report["generationToAudioRatio"] = metrics.generationSeconds / metrics.audioSeconds
                    report["observedFootprintBytes"] = metrics.observedFootprintBytes
                    report["modelLoads"] = metrics.modelLoads
                }
                let folder = URL.documentsDirectory.appending(path: "QwenStreamValidation")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: folder.appending(path: "report.json"), options: .atomic)
                }
                playback.stop()
                await QwenVoiceRenderer.shared.unload()
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
#endif
