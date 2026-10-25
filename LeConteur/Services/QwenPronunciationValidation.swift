#if DEBUG || CONTEUR_VALIDATION
import SwiftUI
import AVFoundation

/// Launch-only listening comparison. Both versions use the same synthetic text,
/// speaker, style, speed and per-passage seed. Each run changes only the
/// instruction or the sampling temperature, selected by its launch flag.
struct QwenPronunciationValidationView: View {
    @Environment(ReaderSettings.self) private var settings
    @State private var status = "Préparation des extraits…"
    @State private var started = false
    @State private var ready = false
    @State private var showLibrary = false
    @State private var rate = 2.0
    @State private var player: QwenStreamPlayer?
    @State private var operation: Task<Void, Never>?
    @State private var files: [[URL]] = [[], []]
    private var stabilityProbe: Bool { CommandLine.arguments.contains("--qwen-stability-validation") }
    private var silenceProbe: Bool { CommandLine.arguments.contains("--qwen-silence-validation") }
    private var decoderProbe: Bool { CommandLine.arguments.contains("--qwen-decoder-validation") }
    private var refillProbe: Bool { CommandLine.arguments.contains("--qwen-refill-validation") }
    private var shortTextProbe: Bool { CommandLine.arguments.contains("--qwen-short-text-validation") }
    private var folder: URL {
        URL.documentsDirectory.appending(path: shortTextProbe ? "QwenShortTextValidation" : refillProbe ? "QwenRefillValidation" : decoderProbe ? "QwenDecoderValidation" : silenceProbe ? "QwenSilenceValidation" : stabilityProbe ? "QwenStabilityValidation" : "QwenPronunciationValidation")
    }
    private var paragraphs: [String] { silenceProbe || decoderProbe || refillProbe ? [
        "Le soleil venait de se lever sur le port. Élise ouvrit les volets et regarda les premiers bateaux quitter la rive. Aujourd’hui, elle avait décidé de prendre son temps.",
        "Elle reconnut aussitôt l’écriture de son frère. Il lui racontait son voyage, les villages traversés et cette rencontre inattendue dans une petite gare de montagne."
    ] : [
        "Lorsque le train s’est arrêté, elle n’a d’abord reconnu personne. Puis elle a aperçu son frère, qui l’attendait au bout du quai. « Tu n’as pas oublié notre promesse ? » lui a-t-elle demandé.",
        "Il lui a répondu qu’il n’avait rien oublié. Malgré les années écoulées, il se souvenait de chaque détail : la maison au bord de l’eau, les fenêtres ouvertes et leurs longues conversations du dimanche."
    ] }

    var body: some View {
        if showLibrary { RootView() }
        else {
            ScrollView {
                VStack(spacing: 20) {
                    Text(shortTextProbe ? "Vérification silencieuse de Qwen" : refillProbe ? "Mesure de la recharge Qwen" : decoderProbe ? "Vérification du décodeur Qwen" : silenceProbe ? "Pauses dans la voix Qwen" : stabilityProbe ? "Stabilité de l’accent Qwen" : "Prononciation Qwen").font(.title2.bold())
                    Text("Même texte, même voix, même vitesse.").font(.subheadline)
                    Text(status).multilineTextAlignment(.center)
                    if !ready, operation != nil { ProgressView() }
                    if ready {
                        Picker("Vitesse de comparaison", selection: $rate) {
                            Text("1×").tag(1.0)
                            Text("2×").tag(2.0)
                            if ![1.0, 2.0].contains(rate) { Text("Vitesse actuelle").tag(rate) }
                        }.pickerStyle(.segmented)
                        Button(silenceProbe ? "Enregistrement original" : stabilityProbe ? "Variation standard" : "Ancienne consigne") { play(version: 0) }.buttonStyle(.bordered)
                        Button(silenceProbe ? "Silences raccourcis" : stabilityProbe ? "Variation réduite" : "Consigne en français") { play(version: 1) }.buttonStyle(.borderedProminent)
                        Button("Arrêter l’écoute") { player?.stop(); player = nil }
                        ForEach(paragraphs, id: \.self) { Text($0).font(.body).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                    Button("Retour à la bibliothèque") {
                        operation?.cancel(); player?.stop(); player = nil; showLibrary = true
                    }
                }.padding(28)
            }
            .task {
                guard !started else { return }
                started = true
                rate = settings.qwenSpeed
                // Capture preferences once, so both versions retain the same voice.
                let speaker = settings.qwenSpeaker
                let style = settings.qwenStyle
                operation = Task { await generate(speaker: speaker, style: style) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                if !ready { operation?.cancel() }
            }
            .onChange(of: rate) { player?.rate = rate }
        }
    }

    @MainActor private func generate(speaker: QwenSpeaker, style: NarrationStyle) async {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false; operation = nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if silenceProbe {
                try prepareSilenceComparison()
                status = "Même enregistrement, seuls les longs silences sont raccourcis. Aucun nouveau calcul Qwen pendant l’écoute."
                ready = true
                print("QWEN_SILENCE ready: 2 recorded synthetic passages, raw and compacted")
                return
            }
            let deadline = Date().addingTimeInterval(30)
            while UIApplication.shared.applicationState != .active {
                guard Date() < deadline else { throw QwenError.foregroundRequired }
                try await Task.sleep(for: .milliseconds(100))
            }
            if shortTextProbe {
                let session = UUID()
                defer { Task { await QwenVoiceRenderer.shared.endSession(session); await QwenVoiceRenderer.shared.unloadIfIdle() } }
                for seed: UInt64 in [740, 741] {
                    status = "Analyse d’un court titre, essai \(seed - 739) sur 2… Aucun son ne sera joué."
                    let destination = folder.appending(path: "current-\(seed)")
                    let result = try await QwenVoiceRenderer.shared.render("Un récit de mystère médiéval",
                        style: .dramatic, language: "French", speaker: .serena, sessionID: session,
                        seed: seed, decoderDiagnosticFolder: destination,
                        progress: { print("QWEN_SHORT seed=\(seed) audioSeconds=\($0)") })
                    defer { try? FileManager.default.removeItem(at: result.url) }
                    let audio = destination.appending(path: "generation.wav")
                    if FileManager.default.fileExists(atPath: audio.path) { try FileManager.default.removeItem(at: audio) }
                    try FileManager.default.copyItem(at: result.url, to: audio)
                    print("QWEN_SHORT seed=\(seed) generationSeconds=\(result.metrics.generationSeconds) audioSeconds=\(result.metrics.audioSeconds)")
                }
                status = "Mesure terminée. Aucun son n’a été joué."
                print("QWEN_SHORT completed")
                return
            }
            if refillProbe {
                try await measureRefill()
                status = "Mesure terminée. Aucun son n’a été joué."
                print("QWEN_REFILL completed")
                await QwenVoiceRenderer.shared.unload()
                return
            }
            if decoderProbe {
                for (index, text) in paragraphs.enumerated() {
                    status = "Vérification silencieuse du passage \(index + 1) sur 2…"
                    let destination = folder.appending(path: "passage-\(index)")
                    let result = try await QwenVoiceRenderer.shared.render(text, style: .warm, language: "French", speaker: .serena,
                        seed: UInt64(740 + index), decoderDiagnosticFolder: destination)
                    defer { try? FileManager.default.removeItem(at: result.url) }
                    let audio = destination.appending(path: "generation.wav")
                    if FileManager.default.fileExists(atPath: audio.path) { try FileManager.default.removeItem(at: audio) }
                    try FileManager.default.copyItem(at: result.url, to: audio)
                }
                status = "Vérification terminée. Les mesures sont enregistrées. Aucun son n’a été joué."
                print("QWEN_DECODER completed")
                await QwenVoiceRenderer.shared.unload()
                return
            }
            for (index, text) in paragraphs.enumerated() {
                for version in 0..<2 {
                    status = "Préparation de l’extrait \(index * 2 + version + 1) sur 4…"
                    let instruction = !stabilityProbe && version == 0 ? "Read in French. " + style.instruction : style.instruction(language: "French")
                    let temperature: Float = stabilityProbe && version == 1 ? 0.5 : 0.75
                    let result = try await QwenVoiceRenderer.shared.render(text, style: style, language: "French", speaker: speaker,
                        instructionOverride: instruction, seed: UInt64(740 + index), temperature: temperature)
                    defer { try? FileManager.default.removeItem(at: result.url) }
                    try Task.checkCancellation()
                    let destination = folder.appending(path: "\(version == 0 ? "before" : "after")-\(index).wav")
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    try FileManager.default.copyItem(at: result.url, to: destination)
                    files[version].append(destination)
                }
            }
            status = "Les deux versions sont prêtes. Comparez l’accent et l’articulation sur les deux paragraphes."
            ready = true
            print("QWEN_PRONUNCIATION ready: 4 synthetic excerpts, stability=\(stabilityProbe)")
        } catch {
            status = error is CancellationError ? "Essai interrompu. Relancez l’essai en gardant l’app ouverte." : error.localizedDescription
            print("QWEN_PRONUNCIATION failed: \(error.localizedDescription)")
        }
        await QwenVoiceRenderer.shared.unload()
    }

    @MainActor private func measureRefill() async throws {
        let session = UUID()
        defer { Task {
            await QwenVoiceRenderer.shared.endSession(session)
            await QwenVoiceRenderer.shared.unloadIfIdle()
        } }
        status = "Chargement du modèle, puis mesure sur des textes fictifs…"
        let warmup = try await QwenVoiceRenderer.shared.render(paragraphs[0],
            style: .warm, language: "French", speaker: .serena, sessionID: session, seed: 740,
            progress: { print("QWEN_REFILL warmupAudioSeconds=\($0)") })
        print("QWEN_REFILL warmupFinished generationSeconds=\(warmup.metrics.generationSeconds) audioSeconds=\(warmup.metrics.audioSeconds)")
        try? FileManager.default.removeItem(at: warmup.url)
        let document = try DocumentImporter.fromText(paragraphs.joined(separator: " "), title: "Recharge fictive")
        var trials: [[String: Any]] = []
        for limit in [360, 180] {
            var position = 0
            var runs: [[String: Any]] = []
            while position < document.segments.count {
                let window = NarrationWindow(document: document, start: position, characterLimit: limit)
                status = "Mesure silencieuse : passages de \(limit) caractères au maximum…"
                let started = Date()
                let result = try await QwenVoiceRenderer.shared.render(window.text, style: .warm,
                    language: "French", speaker: .serena, sessionID: session, seed: UInt64(910 + position),
                    progress: { print("QWEN_REFILL limit=\(limit) position=\(window.segments.first?.index ?? 0) audioSeconds=\($0)") })
                defer { try? FileManager.default.removeItem(at: result.url) }
                let output = folder.appending(path: "limit-\(limit)-position-\(position).wav")
                if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
                try FileManager.default.copyItem(at: result.url, to: output)
                let row: [String: Any] = ["start": position, "end": window.endPosition,
                    "characters": window.text.count, "text": window.text,
                    "generationSeconds": result.metrics.generationSeconds,
                    "elapsedSeconds": Date().timeIntervalSince(started),
                    "audioSeconds": result.metrics.audioSeconds, "modelLoads": result.metrics.modelLoads]
                runs.append(row)
                print("QWEN_REFILL \(String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)")
                position = window.endPosition + 1
            }
            trials.append(["characterLimit": limit, "runs": runs])
            let report: [String: Any] = ["speaker": "serena", "style": "warm", "language": "French",
                "rate": 1.25, "targetSeconds": 10, "coldLoadExcluded": true, "trials": trials,
                "scope": "Single synthetic paragraph; timing comparison, not listening-quality validation."]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appending(path: "report.json"))
        }
    }

    @MainActor private func prepareSilenceComparison() throws {
        let sourceRoot = URL.documentsDirectory.appending(path: "QwenContinuousValidation")
        let sources = try FileManager.default.contentsOfDirectory(at: sourceRoot, includingPropertiesForKeys: [.creationDateKey])
            .filter { $0.lastPathComponent.hasPrefix("audio-") }
            .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) >
                ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
        guard let source = sources.first else { throw QwenError.emptyAudio }
        for (index, passage) in [0, 2].enumerated() {
            let inputURL = source.appending(path: "passage-\(passage).wav")
            let input = try AVAudioFile(forReading: inputURL)
            let format = input.processingFormat
            guard input.length > 0, input.length <= 120 * 24_000,
                  let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192) else { throw QwenError.emptyAudio }
            var samples: [Float] = []
            while input.framePosition < input.length {
                try input.read(into: scratch)
                guard scratch.frameLength > 0, let channel = scratch.floatChannelData?[0] else { throw QwenError.emptyAudio }
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(scratch.frameLength)))
            }
            let compacted = QwenSilenceCompactor.compact(samples, sampleRate: Int(format.sampleRate), style: .warm)
            let outputURL = folder.appending(path: "after-\(index).wav")
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(compacted.samples.count)),
                  let channel = buffer.floatChannelData?[0] else { throw QwenError.emptyAudio }
            buffer.frameLength = buffer.frameCapacity
            compacted.samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
            let output = try AVAudioFile(forWriting: outputURL, settings: format.settings)
            try output.write(from: buffer)
            output.close()
            files[0].append(inputURL)
            files[1].append(outputURL)
            print("QWEN_SILENCE passage=\(passage) removedSeconds=\(compacted.removedSeconds) pauses=\(compacted.shortenedPauses)")
        }
    }

    @MainActor private func play(version: Int) {
        player?.stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            let audio = try QwenStreamPlayer(rate: rate)
            for file in files[version] { try audio.appendPassage(at: file, onPlayedBack: {}) }
            audio.finishInput()
            audio.onError = { error in status = error.localizedDescription }
            player = audio
            audio.play()
        } catch { status = error.localizedDescription }
    }
}
#endif
