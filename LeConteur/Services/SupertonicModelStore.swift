import Foundation
import Observation

enum SupertonicError: LocalizedError {
    case missing, unsupportedLanguage

    var errorDescription: String? {
        switch self {
        case .missing: String(localized: "Installez d’abord Supertonic dans Voix.")
        case .unsupportedLanguage: String(localized: "Cette langue n’est pas prise en charge par Supertonic. La voix iPhone sera utilisée.")
        }
    }
}

struct SupertonicManifest: Codable, Sendable {
    let repository: String
    let revision: String
    let files: [QwenManifest.File]
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    static func bundled() throws -> Self {
        guard let url = Bundle.main.url(forResource: "SupertonicModelManifest", withExtension: "json") else {
            throw SupertonicError.missing
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

enum SupertonicModel {
    static let revision = "aafc6e32416a594460b32413efc49d7fe4ce6d46"
    static let sampleRate = 44_100
    // Leave two logical cores available for scrolling and animations while
    // allowing recent iPhones enough parallelism to refill the audio reserve.
    static var inferenceThreads: Int32 {
        Int32(max(2, min(4, ProcessInfo.processInfo.processorCount - 2)))
    }
    static var directory: URL { URL.applicationSupportDirectory.appending(path: "Voices/Supertonic-3", directoryHint: .isDirectory) }
    static var onnxDirectory: URL { directory.appending(path: "onnx", directoryHint: .isDirectory) }

    static func isInstalled(_ manifest: SupertonicManifest) -> Bool {
        let marker = try? String(contentsOf: directory.appending(path: "verified.revision"), encoding: .utf8)
        return marker == manifest.revision && manifest.files.allSatisfy { file in
            let size = try? directory.appending(path: file.path).resourceValues(forKeys: [.fileSizeKey]).fileSize
            return Int64(size ?? 0) == file.bytes
        }
    }

    static func languageCode(for language: String?) -> String? {
        guard let raw = language?.lowercased() else { return nil }
        let code = raw.split(separator: "-").first.map(String.init) ?? raw
        return supportedLanguages.contains(code) ? code : nil
    }

    static let supportedLanguages: Set<String> = [
        "en", "ko", "ja", "ar", "bg", "cs", "da", "de", "el", "es", "et", "fi", "fr", "hi", "hr",
        "hu", "id", "it", "lt", "lv", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "tr", "uk", "vi"
    ]
}

enum SupertonicVoice: String, CaseIterable, Identifiable {
    case female = "F1"
    case male = "M1"
    var id: String { rawValue }
    var name: String { self == .female ? String(localized: "Voix féminine") : String(localized: "Voix masculine") }
}

@MainActor @Observable
final class SupertonicModelStore {
    private let downloads = VoiceDownloads.shared
    private var localError: String?
    var isInstalled: Bool { downloads.snapshot("supertonic").installed }
    var isBusy: Bool { downloads.snapshot("supertonic").busy }
    var progress: Double { downloads.snapshot("supertonic").progress }
    var status: String { downloads.snapshot("supertonic").status }
    var errorMessage: String? { localError ?? downloads.snapshot("supertonic").error }

    func install() { localError = nil; downloads.install("supertonic") }
    func cancel() { downloads.cancel("supertonic") }
    func remove() {
        guard !isBusy else { return }
        downloads.forget("supertonic")
        do {
            if FileManager.default.fileExists(atPath: SupertonicModel.directory.path) {
                try FileManager.default.removeItem(at: SupertonicModel.directory)
            }
        } catch { localError = error.localizedDescription }
        downloads.refreshInstallation("supertonic")
    }
}
