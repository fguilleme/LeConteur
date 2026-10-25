#if DEBUG || CONTEUR_VALIDATION
import SwiftUI
import AVFoundation
import ConteurQwen
import Darwin

/// Opt-in synthetic comparison. Does not change reader settings or the installed model.
struct QwenPrecisionValidationView: View {
    @State private var status = "Préparation de la comparaison…"
    @State private var operation: Task<Void, Never>?
    @State private var started = false
    @State private var ready = false
    @State private var showLibrary = false
    @State private var player: QwenStreamPlayer?
    @State private var closing = false

    private static let texts = [
        "Un récit de mystère médiéval.",
        "Le soleil venait de se lever sur le port.",
        "Elle reconnut aussitôt l’écriture de son frère."
    ]
    private var folder: URL { URL.documentsDirectory.appending(path: "QwenPrecisionValidation") }

    var body: some View {
        if showLibrary { RootView() }
        else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Comparer la diction Qwen").font(.title2.bold())
                    Text("Serena · Théâtral · Français · 1×").foregroundStyle(.secondary)
                    Text("Les trois mêmes phrases, avec deux versions du modèle. Aucun extrait ne démarre automatiquement.")
                    ForEach(Self.texts, id: \.self) { Text($0).font(.body.italic()) }
                    Text(status).foregroundStyle(.secondary)
                    if operation != nil { ProgressView() }
                    if ready {
                        Button("Écouter le modèle actuel") { play("4bit") }
                            .buttonStyle(.borderedProminent)
                        Button("Écouter le modèle moins compressé") { play("6bit") }
                            .buttonStyle(.borderedProminent)
                        Button("Arrêter l’écoute") { player?.stop(); player = nil }
                    }
                    Button(closing ? "Arrêt en cours…" : "Retour à la bibliothèque") {
                        closing = true
                        player?.stop()
                        operation?.cancel()
                        Task {
                            // Let the active Metal work finish before ordinary playback can load a model.
                            await operation?.value
                            try? FileManager.default.removeItem(at: QwenPrecisionProbe.modelFolder)
                            showLibrary = true
                        }
                    }.disabled(closing)
                }.padding(28)
            }
            .task {
                guard !started else { return }
                started = true
                operation = Task { await run() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                operation?.cancel()
            }
        }
    }

    @MainActor private func run() async {
        let previousIdleSetting = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let renderer = QwenVoiceRenderer.shared
        let session = UUID()
        let probe = QwenPrecisionProbe()
        var rows: [[String: Any]] = []
        defer {
            UIApplication.shared.isIdleTimerDisabled = previousIdleSetting
            operation = nil
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let deadline = Date().addingTimeInterval(10)
            while UIApplication.shared.applicationState != .active {
                guard Date() < deadline else { throw QwenError.foregroundRequired }
                try await Task.sleep(for: .milliseconds(100))
            }
            status = "Vérification des fichiers d’essai…"
            try await probe.validateAssets()
            for version in ["4bit", "6bit"] {
                for (index, text) in Self.texts.enumerated() {
                    try Task.checkCancellation()
                    guard UIApplication.shared.applicationState == .active else { throw QwenError.foregroundRequired }
                    status = "Préparation silencieuse : \(version == "4bit" ? "modèle actuel" : "modèle moins compressé"), extrait \(index + 1)/3…"
                    let result: QwenRenderedAudio
                    if version == "4bit" {
                        result = try await renderer.render(text, style: .dramatic, language: "French",
                            speaker: .serena, sessionID: session, seed: 740)
                    } else {
                        result = try await probe.render(text, seed: 740)
                    }
                    defer { try? FileManager.default.removeItem(at: result.url) }
                    try Task.checkCancellation()
                    let destination = folder.appending(path: "\(version)-\(index).wav")
                    try Data(contentsOf: result.url).write(to: destination, options: .atomic)
                    let metrics = result.metrics
                    rows.append(["version": version, "case": index, "text": text, "seed": 740,
                        "audioSeconds": metrics.audioSeconds, "generationSeconds": metrics.generationSeconds,
                        "mlxPeakBytes": metrics.mlxPeakBytes, "observedFootprintBytes": metrics.observedFootprintBytes,
                        "modelLoads": metrics.modelLoads])
                    try writeReport(rows, status: "running")
                    print("QWEN_PRECISION \(version) case=\(index) audio=\(metrics.audioSeconds) generation=\(metrics.generationSeconds) footprint=\(metrics.observedFootprintBytes)")
                }
                // Never keep both sets of model weights in memory.
                if version == "4bit" {
                    await renderer.endSession(session)
                    await renderer.unload()
                } else { await probe.unload() }
            }
            try writeReport(rows, status: "completed")
            ready = true
            status = "Extraits prêts. Compare l’accent, les mots avalés et la fluidité à la même vitesse."
            print("QWEN_PRECISION completed")
        } catch {
            status = error is CancellationError ? "Préparation interrompue. Aucun réglage de lecture n’a changé." : error.localizedDescription
            try? writeReport(rows, status: "failed", error: status)
            print("QWEN_PRECISION failed: \(status)")
        }
        await renderer.endSession(session)
        await renderer.unload()
        await probe.unload()
    }

    private func writeReport(_ rows: [[String: Any]], status: String, error: String? = nil) throws {
        var report: [String: Any] = ["status": status, "speaker": "serena", "style": "dramatic", "language": "French",
            "scope": "Synthetic native device comparison. Timings and memory are measurements, not perceptual quality validation. No autoplay.",
            "runs": rows]
        if let error { report["error"] = error }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appending(path: "report.json"), options: .atomic)
    }

    @MainActor private func play(_ version: String) {
        player?.stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            let audio = try QwenStreamPlayer(rate: 1)
            for index in Self.texts.indices {
                try audio.appendPassage(at: folder.appending(path: "\(version)-\(index).wav"), onPlayedBack: {})
            }
            audio.finishInput()
            audio.onError = { status = $0.localizedDescription }
            player = audio
            audio.play()
        } catch { status = error.localizedDescription }
    }
}

/// A separate, serialized model only used after the production renderer is unloaded.
private actor QwenPrecisionProbe {
    static var modelFolder: URL { URL.documentsDirectory.appending(path: "QwenPrecisionModel") }
    private var model: Qwen3TTSModel?
    private var runtimePrepared = false

    func validateAssets() throws {
        let manifest = try JSONDecoder().decode(QwenManifest.self, from: Data(contentsOf: Self.modelFolder.appending(path: "manifest.json")))
        guard manifest.repository == "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-6bit",
              manifest.revision == "1c6c0ff58c43afa8df571facde2efa077efd85e2" else { throw QwenError.invalidFile("manifest.json") }
        let baseline = try QwenManifest.bundled()
        for file in manifest.files {
            try Task.checkCancellation()
            guard !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains("..") else { throw QwenError.invalidFile(file.path) }
            let destination = Self.modelFolder.appending(path: file.path)
            if !FileManager.default.fileExists(atPath: destination.path),
               baseline.files.contains(where: { $0.path == file.path && $0.sha256 == file.sha256 && $0.bytes == file.bytes }) {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Identical decoder and tokenizer assets; no extra 683 MB transfer or copy.
                try FileManager.default.linkItem(at: QwenModel.directory.appending(path: file.path), to: destination)
            }
            try QwenManifest.validate(file, at: destination)
        }
    }

    func render(_ text: String, seed: UInt64) async throws -> QwenRenderedAudio {
        try Task.checkCancellation()
        let started = Date()
        let needsLoading = model == nil
        QwenRuntime.prepare()
        runtimePrepared = true
        defer { QwenRuntime.clearCache() }
        if needsLoading {
            guard os_proc_available_memory() > 3_900_000_000 else { throw QwenError.insufficientMemory }
            model = try await Qwen3TTSModel.fromModelDirectory(Self.modelFolder)
        }
        guard let model else { throw QwenError.missing }
        var samples: [Float] = []
        var footprint = Self.memoryFootprint()
        try model.generateChunks(text: text, instruction: NarrationStyle.dramatic.instruction(language: "French"),
            language: "French", speaker: "serena", seed: seed) { chunk in
                samples.append(contentsOf: chunk)
                footprint = max(footprint, Self.memoryFootprint())
            }
        try Task.checkCancellation()
        guard samples.count > model.sampleRate / 10, samples.allSatisfy(\.isFinite),
              samples.contains(where: { abs($0) > 0.001 }) else { throw QwenError.emptyAudio }
        let url = URL.temporaryDirectory.appending(path: "conteur-qwen-precision-\(UUID().uuidString).wav")
        do {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(model.sampleRate), channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else { throw QwenError.emptyAudio }
            buffer.frameLength = buffer.frameCapacity
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            file.close()
            return QwenRenderedAudio(url: url, metrics: QwenRenderMetrics(
                generationSeconds: Date().timeIntervalSince(started), audioSeconds: Double(samples.count) / Double(model.sampleRate),
                mlxPeakBytes: QwenRuntime.peakMemory, observedFootprintBytes: footprint, modelLoads: needsLoading ? 1 : 0))
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }

    func unload() {
        guard runtimePrepared else { return }
        model = nil
        QwenRuntime.clearCache()
        runtimePrepared = false
    }

    private static func memoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
#endif
