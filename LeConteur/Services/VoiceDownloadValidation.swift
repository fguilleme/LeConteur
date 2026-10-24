#if DEBUG || CONTEUR_VALIDATION
import SwiftUI
import Network

extension VoiceDownloadSpec {
    /// A separate copy of Qwen's weights, large enough to lock during transfer.
    static var validation: Self {
        let file = Self.qwen!.files.max(by: { $0.bytes < $1.bytes })!
        return Self(id: "download-validation", revision: file.sha256,
                    directory: URL.applicationSupportDirectory.appending(path: "DownloadValidation"), marker: "verified.sha256",
                    files: [file])
    }
}

@MainActor enum VoiceDownloadValidation {
    private static var lastBytes: Int64 = 0
    private static var monitor: NWPathMonitor?
    private static var network: [String: Any] = [:]
    static var log: URL { URL.documentsDirectory.appending(path: "VoiceDownloadValidation/events.jsonl") }
    static func progress(_ bytes: Int64) {
        if bytes - lastBytes >= 4_000_000 { lastBytes = bytes; record("progress", bytes: bytes) }
    }
    static func observeNetwork() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            Task { @MainActor in
                network = ["satisfied": path.status == .satisfied, "wifi": path.usesInterfaceType(.wifi),
                           "cellular": path.usesInterfaceType(.cellular), "expensive": path.isExpensive,
                           "constrained": path.isConstrained]
                record("network")
            }
        }
        self.monitor = monitor
        monitor.start(queue: DispatchQueue(label: "DownloadValidation.network"))
    }
    static func record(_ event: String, bytes: Int64? = nil, details: [String: Any] = [:]) {
        var record: [String: Any] = ["event": event, "timestamp": Date().timeIntervalSince1970,
                                      "applicationState": UIApplication.shared.applicationState.rawValue,
                                      "protectedDataAvailable": UIApplication.shared.isProtectedDataAvailable,
                                      "backgroundRefreshStatus": UIApplication.shared.backgroundRefreshStatus.rawValue,
                                      "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
                                      "network": network]
        record.merge(details) { _, new in new }
        if let bytes { record["bytes"] = bytes }
        if event == "installed" {
            record["checksumVerified"] = VoiceDownloadSpec.validation.isInstalled
            record["fileProtection"] = (try? FileManager.default.attributesOfItem(atPath: VoiceDownloadSpec.validation.directory.appending(path: VoiceDownloadSpec.validation.files[0].path).path)[.protectionKey]) as? String
        }
        do {
            if !FileManager.default.fileExists(atPath: log.path) { try VoiceDownloadDisk.write(Data(), to: log) }
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) + Data([10])
            let file = try FileHandle(forWritingTo: log)
            defer { try? file.close() }
            try file.seekToEnd(); try file.write(contentsOf: data)
        } catch { print("DOWNLOAD_VALIDATION_LOG_ERROR \(error)") }
    }
    static func cleanup() {
        VoiceDownloads.shared.forget("download-validation")
        try? FileManager.default.removeItem(at: VoiceDownloadSpec.validation.directory)
    }
}

struct VoiceDownloadValidationView: View {
    private let downloads = VoiceDownloads.shared
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "arrow.down.circle").font(.largeTitle)
            Text("Téléchargement en arrière-plan").font(.title2)
            Text("Démarrez le test, puis verrouillez immédiatement l’iPhone. Le test télécharge une copie temporaire de Qwen (1,63 Go) en Wi-Fi.").multilineTextAlignment(.center)
            Button("Démarrer le test") {
                VoiceDownloadValidation.record("started")
                downloads.install("download-validation")
            }.buttonStyle(.borderedProminent)
                .disabled(downloads.snapshot("download-validation").busy || downloads.snapshot("download-validation").installed)
            ProgressView(value: downloads.snapshot("download-validation").progress)
            Text(downloads.snapshot("download-validation").status).font(.caption)
            if let error = downloads.snapshot("download-validation").error { Text(error).foregroundStyle(.red) }
        }.padding(30).task {
            if CommandLine.arguments.contains("--cleanup-download-validation") {
                VoiceDownloadValidation.cleanup()
            } else {
                VoiceDownloadValidation.observeNetwork()
                VoiceDownloadValidation.record("opened")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            VoiceDownloadValidation.record("scene-\(String(describing: phase))")
        }
    }
}
#endif
