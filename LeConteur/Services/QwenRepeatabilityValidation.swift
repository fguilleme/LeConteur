#if DEBUG || CONTEUR_VALIDATION
import SwiftUI
import CryptoKit

/// Synthetic, opt-in device diagnostic. Never plays audio or changes preferences.
/// A fixed seed is a repeatability control, not a proposed accent correction.
struct QwenRepeatabilityValidationView: View {
    @State private var status = "Préparation du contrôle…"
    @State private var started = false
    @State private var showLibrary = false
    @State private var operation: Task<Void, Never>?

    var body: some View {
        if showLibrary { RootView() }
        else {
            VStack(spacing: 24) {
                Text("Vérification de la voix Qwen").font(.title2.bold())
                Text("Contrôle silencieux, aucun extrait ne sera joué.")
                Text(status).multilineTextAlignment(.center)
                if operation != nil { ProgressView() }
                Button("Retour à la bibliothèque") {
                    operation?.cancel()
                    showLibrary = true
                }.buttonStyle(.borderedProminent)
            }.padding(28)
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
        UIApplication.shared.isIdleTimerDisabled = true
        let session = UUID()
        let renderer = QwenVoiceRenderer.shared
        let folder = URL.documentsDirectory.appending(path: "QwenRepeatabilityValidation")
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            operation = nil
            Task { await renderer.endSession(session); await renderer.unloadIfIdle() }
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // A launch task may run during the foreground transition.
            let deadline = Date().addingTimeInterval(10)
            while UIApplication.shared.applicationState != .active {
                guard Date() < deadline else { throw QwenError.foregroundRequired }
                try await Task.sleep(for: .milliseconds(100))
            }
            let text = "Élise ouvrit les volets et regarda les premiers bateaux quitter la rive."
            let cases: [(name: String, text: String, seed: UInt64, unload: Bool)] = [
                ("initial", text, 740, false),
                ("intervening", "Elle reconnut aussitôt l’écriture de son frère.", 741, false),
                ("repeated-warm", text, 740, false),
                ("different-seed", text, 741, false),
                ("repeated-reloaded", text, 740, true)
            ]
            var rows: [[String: Any]] = []
            for (index, item) in cases.enumerated() {
                try Task.checkCancellation()
                guard UIApplication.shared.applicationState == .active else { throw QwenError.foregroundRequired }
                if item.unload {
                    await renderer.endSession(session)
                    await renderer.unload()
                }
                status = "Comparaison \(index + 1) sur \(cases.count)…"
                let destination = folder.appending(path: item.name)
                let result = try await renderer.render(item.text, style: .dramatic, language: "French", speaker: .serena,
                    sessionID: session, seed: item.seed, decoderDiagnosticFolder: destination)
                defer { try? FileManager.default.removeItem(at: result.url) }
                try Task.checkCancellation()
                let audio = try Data(contentsOf: result.url)
                try audio.write(to: destination.appending(path: "generation.wav"), options: .atomic)
                let frames = try Data(contentsOf: destination.appending(path: "codec-frames.json"))
                func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
                rows.append(["case": item.name, "text": item.text, "seed": item.seed,
                    "modelLoads": result.metrics.modelLoads, "audioSeconds": result.metrics.audioSeconds,
                    "generationSeconds": result.metrics.generationSeconds,
                    "codecSHA256": hash(frames), "wavSHA256": hash(audio)])
                let report: [String: Any] = ["speaker": "serena", "style": "dramatic", "language": "French",
                    "scope": "Synthetic repeatability control on device. Same-seed equality does not establish pronunciation, accent or perceptual quality. No audio played.",
                    "status": index == cases.count - 1 ? "completed" : "running", "runs": rows]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: folder.appending(path: "report.json"), options: .atomic)
                print("QWEN_REPEATABILITY \(item.name) tokens=\(hash(frames)) audio=\(hash(audio))")
            }
            status = "Contrôle terminé. Aucun son n’a été joué."
            print("QWEN_REPEATABILITY completed")
        } catch {
            status = error is CancellationError ? "Contrôle interrompu." : error.localizedDescription
            if let data = try? JSONSerialization.data(withJSONObject: ["status": "failed", "error": status]) {
                try? data.write(to: folder.appending(path: "error.json"), options: .atomic)
            }
            print("QWEN_REPEATABILITY failed: \(error.localizedDescription)")
        }
    }
}
#endif
