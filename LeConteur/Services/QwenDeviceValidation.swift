#if DEBUG
import Foundation
import UIKit
import SwiftUI

/// Explicit developer-only device probe; never runs in a normal app launch.
@MainActor enum QwenDeviceValidation {
    struct Run: Codable {
        let style: String
        let metrics: QwenRenderMetrics
    }
    struct Report: Codable {
        var status: String
        var runs: [Run] = []
        var error: String?
    }

    static func run(store: QwenModelStore, styles: [NarrationStyle] = NarrationStyle.allCases) async {
        let folder = URL.documentsDirectory.appending(path: "QwenValidation", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var report = Report(status: "waiting-for-model")
        func save() {
            if let data = try? JSONEncoder().encode(report) { try? data.write(to: folder.appending(path: "report.json"), options: .atomic) }
        }
        save()
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        do {
            let deadline = Date().addingTimeInterval(120)
            while store.isBusy || UIApplication.shared.applicationState != .active {
                guard Date() < deadline else { throw QwenError.foregroundRequired }
                try await Task.sleep(for: .milliseconds(250))
            }
            guard store.isInstalled else { throw QwenError.missing }
            for style in styles {
                report.status = "generating-\(style.rawValue)"; save()
                let operation = Task { try await QwenVoiceRenderer.shared.render(NarrationStyle.auditionText, style: style, language: "French") }
                let observer = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in operation.cancel() }
                defer { NotificationCenter.default.removeObserver(observer) }
                let result = try await operation.value
                let output = folder.appending(path: "\(style.rawValue).wav")
                if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
                try FileManager.default.moveItem(at: result.url, to: output)
                report.runs.append(Run(style: style.rawValue, metrics: result.metrics))
                save()
            }
            report.status = "passed"
        } catch {
            report.status = "failed"; report.error = error.localizedDescription
        }
        save()
        await QwenVoiceRenderer.shared.unload()
        print("QWEN_VALIDATION \(report.status)")
    }
}
struct DeviceValidationView: View {
    let store: QwenModelStore
    @State private var finished = false
    @State private var started = false
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform").font(.largeTitle)
            Text("Vérification sur iPhone").font(.title2)
            Text(finished ? "Essai terminé. L’app sera relancée pour la lecture." : "Essai local en cours. Gardez cet écran ouvert quelques minutes.")
                .multilineTextAlignment(.center)
            if !finished { ProgressView() }
        }.padding(30)
        .task {
            guard !started else { return }
            started = true
            if CommandLine.arguments.contains("--qwen-validation") {
                let styles: [NarrationStyle] = CommandLine.arguments.contains("--dramatic-only") ? [.dramatic] : NarrationStyle.allCases
                await QwenDeviceValidation.run(store: store, styles: styles)
            } else if #available(iOS 26.0, *) { await TranslationDeviceValidation.run() }
            finished = true
        }
    }
}
#endif
