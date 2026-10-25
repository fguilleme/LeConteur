import Foundation
import CryptoKit
import Observation

enum QwenError: LocalizedError {
    case missing, invalidFile(String), insufficientSpace, unavailable, emptyAudio, foregroundRequired, insufficientMemory, generationLimitReached
    var errorDescription: String? {
        switch self {
        case .missing: String(localized: "Installez d’abord Qwen dans Voix.")
        case .invalidFile(let file): String(localized: "Le fichier Qwen \(file) est incomplet ou invalide. Relancez l’installation.")
        case .insufficientSpace: String(localized: "Libérez au moins 3 Go sur l’iPhone pour installer Qwen.")
        case .unavailable: String(localized: "Qwen nécessite un iPhone avec au moins 8 Go de mémoire. Les voix iPhone restent disponibles.")
        case .emptyAudio: String(localized: "Qwen n’a pas produit d’audio utilisable. Réessayez sur un passage plus court.")
        case .generationLimitReached: String(localized: "Qwen n’a pas réussi à terminer ce passage. Touchez Lire pour le réessayer.")
        case .insufficientMemory: String(localized: "La mémoire disponible est insuffisante pour Qwen. Fermez les autres apps puis réessayez, ou choisissez une voix iPhone.")
        case .foregroundRequired: String(localized: "Gardez Le Conteur ouvert pendant la préparation Qwen. Touchez Lire pour reprendre.")
        }
    }
}

struct QwenManifest: Codable, Sendable {
    struct File: Codable, Sendable {
        let path: String
        let bytes: Int64
        let sha256: String
    }
    let repository: String
    let revision: String
    let files: [File]
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    static func bundled() throws -> Self {
        guard let url = Bundle.main.url(forResource: "QwenModelManifest", withExtension: "json") else { throw QwenError.missing }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    static func validate(_ file: File, at url: URL) throws {
        guard Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) == file.bytes else { throw QwenError.invalidFile(file.path) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == file.sha256 else { throw QwenError.invalidFile(file.path) }
    }
}

enum QwenModel {
    static var directory: URL { URL.applicationSupportDirectory.appending(path: "Voices/Qwen3-1.7B-4bit", directoryHint: .isDirectory) }
    static var supported: Bool { ProcessInfo.processInfo.physicalMemory >= 7_000_000_000 }
    static func filesPresent(_ manifest: QwenManifest) -> Bool {
        manifest.files.allSatisfy { file in
            let size = try? directory.appending(path: file.path).resourceValues(forKeys: [.fileSizeKey]).fileSize
            return Int64(size ?? 0) == file.bytes
        }
    }
    static func isInstalled(_ manifest: QwenManifest) -> Bool {
        let revision = try? String(contentsOf: directory.appending(path: "verified.revision"), encoding: .utf8)
        return revision == manifest.revision && filesPresent(manifest)
    }
}

@MainActor @Observable
final class QwenModelStore {
    private let downloads = VoiceDownloads.shared
    private var localError: String?
    var isInstalled: Bool { downloads.snapshot("qwen").installed }
    var isBusy: Bool { downloads.snapshot("qwen").busy }
    var progress: Double { downloads.snapshot("qwen").progress }
    var status: String { downloads.snapshot("qwen").status }
    var errorMessage: String? { localError ?? downloads.snapshot("qwen").error }

    init() {
        // A local Xcode/devicectl transfer still requires checksum verification.
        if let manifest = try? QwenManifest.bundled(), !isInstalled, QwenModel.filesPresent(manifest) { install() }
    }

    func install() {
        guard QwenModel.supported else { localError = QwenError.unavailable.localizedDescription; return }
        localError = nil
        downloads.install("qwen")
    }
    func cancel() { downloads.cancel("qwen") }
    /// The caller must stop and unload the renderer first.
    func remove() {
        guard !isBusy else { return }
        downloads.forget("qwen")
        do {
            if FileManager.default.fileExists(atPath: QwenModel.directory.path) { try FileManager.default.removeItem(at: QwenModel.directory) }
        } catch { localError = error.localizedDescription }
        downloads.refreshInstallation("qwen")
    }
}
