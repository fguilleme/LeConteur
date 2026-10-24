import Foundation
import Observation
import CryptoKit
import SherpaOnnx

enum NeuralVoiceError: LocalizedError {
    case missing, invalidDownload, initialization, generation
    var errorDescription: String? {
        switch self {
        case .missing: "Téléchargez d’abord la voix Siwis dans l’onglet Voix."
        case .invalidDownload: "Le téléchargement est incomplet ou invalide. Réessayez avec une connexion stable."
        case .initialization: "La voix neuronale n’a pas pu démarrer. Essayez de relancer l’app."
        case .generation: "La voix n’a pas pu lire ce passage. Vous pouvez choisir une voix iPhone."
        }
    }
}

enum NeuralModel {
    static let fileName = "fr_FR-siwis-medium.onnx"
    static let byteCount = 63_201_421
    static let sha256 = "830f55d861ce7c8a442fd5593890ff5ee50c9d5efd4c4f42d24d537fe46d2d52"
    static let downloadURL = URL(string: "https://huggingface.co/csukuangfj/vits-piper-fr_FR-siwis-medium/resolve/6b956227093bc8f9c05e5549508c4a510e97ef26/fr_FR-siwis-medium.onnx")!
    static var directory: URL { URL.applicationSupportDirectory.appending(path: "Voices", directoryHint: .isDirectory) }
    static var fileURL: URL { directory.appending(path: fileName) }

    static func validate(_ url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == byteCount else { throw NeuralVoiceError.invalidDownload }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw NeuralVoiceError.invalidDownload }
    }
}

@MainActor @Observable
final class NeuralModelStore {
    private let downloads = VoiceDownloads.shared
    var isInstalled: Bool { downloads.snapshot("siwis").installed }
    var isDownloading: Bool { downloads.snapshot("siwis").busy }
    var progress: Double { downloads.snapshot("siwis").progress }
    var status: String { downloads.snapshot("siwis").status }
    var errorMessage: String? { downloads.snapshot("siwis").error }
    func download() { downloads.install("siwis") }
    func cancelDownload() { downloads.cancel("siwis") }
}

/// The actor serializes the native inference engine and keeps heavy work off the UI thread.
actor NeuralVoiceRenderer {
    private var engine: SherpaOnnxOfflineTtsWrapper?
    private let modelURL: URL

    init(modelURL: URL = NeuralModel.fileURL) { self.modelURL = modelURL }

    func render(_ text: String, speed: Double) throws -> URL {
        try Task.checkCancellation()
        if engine == nil {
            guard FileManager.default.fileExists(atPath: modelURL.path) else { throw NeuralVoiceError.missing }
            guard let assets = Bundle.main.url(forResource: "VoiceAssets", withExtension: nil) else { throw NeuralVoiceError.initialization }
            let vits = sherpaOnnxOfflineTtsVitsModelConfig(
                model: modelURL.path,
                tokens: assets.appending(path: "tokens.txt").path,
                dataDir: assets.appending(path: "espeak-ng-data").path)
            let model = sherpaOnnxOfflineTtsModelConfig(vits: vits, numThreads: 2)
            var config = sherpaOnnxOfflineTtsConfig(model: model, maxNumSentences: 4)
            let candidate = SherpaOnnxOfflineTtsWrapper(config: &config)
            guard candidate.tts != nil else { throw NeuralVoiceError.initialization }
            engine = candidate
        }
        guard let engine else { throw NeuralVoiceError.initialization }
        let audio = engine.generate(text: text, sid: 0, speed: Float(speed))
        try Task.checkCancellation()
        guard audio.audio != nil, audio.n > 0 else { throw NeuralVoiceError.generation }
        let output = URL.temporaryDirectory.appending(path: "conteur-\(UUID().uuidString).wav")
        guard audio.save(filename: output.path) == 1 else { throw NeuralVoiceError.generation }
        return output
    }
}
