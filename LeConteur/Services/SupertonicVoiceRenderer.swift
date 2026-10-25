// Supertonic runtime integration adapted from Supertone's archived MIT-licensed
// Swift implementation: https://github.com/supertone-oss-archive/supertonic
import Foundation
import AVFoundation
import OnnxRuntimeBindings

private struct SupertonicConfig: Decodable {
    struct AE: Decodable { let sample_rate: Int; let base_chunk_size: Int }
    struct TTL: Decodable { let chunk_compress_factor: Int; let latent_dim: Int }
    let ae: AE
    let ttl: TTL
}

private struct SupertonicStyleFile: Decodable {
    struct Component: Decodable { let data: [[[Float]]]; let dims: [Int] }
    let style_ttl: Component
    let style_dp: Component
}

private struct SupertonicStyle {
    let ttl: ORTValue
    let dp: ORTValue
}

private final class SupertonicTextProcessor {
    private let indexer: [Int64]
    init(url: URL) throws { indexer = try JSONDecoder().decode([Int64].self, from: Data(contentsOf: url)) }

    func tensors(_ input: String, language: String) throws -> (ORTValue, ORTValue) {
        let text = Self.preprocess(input, language: language)
        let ids = text.unicodeScalars.map { Int($0.value) < indexer.count ? indexer[Int($0.value)] : -1 }
        let mask = [Float](repeating: 1, count: ids.count)
        return (
            try ORTValue(tensorData: NSMutableData(bytes: ids, length: ids.count * MemoryLayout<Int64>.size),
                         elementType: .int64, shape: [1, NSNumber(value: ids.count)]),
            try ORTValue(tensorData: NSMutableData(bytes: mask, length: mask.count * MemoryLayout<Float>.size),
                         elementType: .float, shape: [1, 1, NSNumber(value: mask.count)])
        )
    }

    private static func preprocess(_ input: String, language: String) -> String {
        var text = input.decomposedStringWithCompatibilityMapping
        text = text.unicodeScalars.filter { scalar in
            let value = scalar.value
            return !((0x1F300...0x1FAFF).contains(value) || (0x2600...0x27BF).contains(value))
        }.map(String.init).joined()
        let replacements = ["–": "-", "‑": "-", "—": "-", "_": " ", "“": "\"", "”": "\"", "‘": "'", "’": "'", "[": " ", "]": " ", "|": " ", "/": " ", "#": " "]
        for (old, new) in replacements { text = text.replacingOccurrences(of: old, with: new) }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, text.range(of: "[.!?;:,'\"…。」』】〉》›»]$", options: .regularExpression) == nil { text += "." }
        return "<\(language)>\(text)</\(language)>"
    }
}

private final class SupertonicRuntime {
    let sampleRate: Int
    private let config: SupertonicConfig
    private let processor: SupertonicTextProcessor
    private let environment: ORTEnv
    private let duration: ORTSession
    private let encoder: ORTSession
    private let estimator: ORTSession
    private let vocoder: ORTSession

    init(directory: URL) throws {
        config = try JSONDecoder().decode(SupertonicConfig.self, from: Data(contentsOf: directory.appending(path: "tts.json")))
        sampleRate = config.ae.sample_rate
        processor = try SupertonicTextProcessor(url: directory.appending(path: "unicode_indexer.json"))
        environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(SupertonicModel.inferenceThreads)
        // ORT otherwise keeps its worker threads spinning between inference
        // calls, which needlessly competes with SwiftUI's main-thread work.
        try options.addConfigEntry(withKey: "session.intra_op.allow_spinning", value: "0")
        duration = try ORTSession(env: environment, modelPath: directory.appending(path: "duration_predictor.onnx").path, sessionOptions: options)
        encoder = try ORTSession(env: environment, modelPath: directory.appending(path: "text_encoder.onnx").path, sessionOptions: options)
        estimator = try ORTSession(env: environment, modelPath: directory.appending(path: "vector_estimator.onnx").path, sessionOptions: options)
        vocoder = try ORTSession(env: environment, modelPath: directory.appending(path: "vocoder.onnx").path, sessionOptions: options)
    }

    func loadStyle(_ url: URL) throws -> SupertonicStyle {
        let style = try JSONDecoder().decode(SupertonicStyleFile.self, from: Data(contentsOf: url))
        func tensor(_ component: SupertonicStyleFile.Component) throws -> ORTValue {
            let values = component.data.flatMap { $0.flatMap { $0 } }
            return try ORTValue(tensorData: NSMutableData(bytes: values, length: values.count * MemoryLayout<Float>.size),
                                elementType: .float, shape: component.dims.map(NSNumber.init(value:)))
        }
        return try SupertonicStyle(ttl: tensor(style.style_ttl), dp: tensor(style.style_dp))
    }

    func synthesize(text: String, language: String, style: SupertonicStyle, steps: Int = 6, speed: Float = 1.05) throws -> [Float] {
        let (textIDs, textMask) = try processor.tensors(text, language: language)
        let durationOutput = try duration.run(withInputs: ["text_ids": textIDs, "style_dp": style.dp, "text_mask": textMask],
                                              outputNames: ["duration"], runOptions: nil)
        let durationData = try durationOutput["duration"]!.tensorData() as Data
        let predicted = durationData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard let predictedSeconds = predicted.first else { throw QwenError.emptyAudio }
        let seconds = predictedSeconds / speed
        guard seconds.isFinite, seconds > 0.05 else { throw QwenError.emptyAudio }
        let encoded = try encoder.run(withInputs: ["text_ids": textIDs, "style_ttl": style.ttl, "text_mask": textMask],
                                      outputNames: ["text_emb"], runOptions: nil)["text_emb"]!

        let chunk = config.ae.base_chunk_size * config.ttl.chunk_compress_factor
        let latentLength = max(1, (Int(seconds * Float(sampleRate)) + chunk - 1) / chunk)
        let latentDimension = config.ttl.latent_dim * config.ttl.chunk_compress_factor
        var latent = (0..<(latentDimension * latentLength)).map { _ in Self.gaussian() }
        let mask = [Float](repeating: 1, count: latentLength)
        let total = [Float(steps)]
        let totalValue = try Self.tensor(total, shape: [1])
        let maskValue = try Self.tensor(mask, shape: [1, 1, NSNumber(value: latentLength)])

        for step in 0..<steps {
            try Task.checkCancellation()
            let latentValue = try Self.tensor(latent, shape: [1, NSNumber(value: latentDimension), NSNumber(value: latentLength)])
            let currentValue = try Self.tensor([Float(step)], shape: [1])
            let output = try estimator.run(withInputs: [
                "noisy_latent": latentValue, "text_emb": encoded, "style_ttl": style.ttl,
                "latent_mask": maskValue, "text_mask": textMask,
                "current_step": currentValue, "total_step": totalValue
            ], outputNames: ["denoised_latent"], runOptions: nil)
            let data = try output["denoised_latent"]!.tensorData() as Data
            latent = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        let final = try Self.tensor(latent, shape: [1, NSNumber(value: latentDimension), NSNumber(value: latentLength)])
        let output = try vocoder.run(withInputs: ["latent": final], outputNames: ["wav_tts"], runOptions: nil)
        let data = try output["wav_tts"]!.tensorData() as Data
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return Array(samples.prefix(min(samples.count, Int(seconds * Float(sampleRate)))))
    }

    private static func tensor(_ values: [Float], shape: [NSNumber]) throws -> ORTValue {
        try ORTValue(tensorData: NSMutableData(bytes: values, length: values.count * MemoryLayout<Float>.size),
                     elementType: .float, shape: shape)
    }

    private static func gaussian() -> Float {
        let a = Float.random(in: 0.0001...1)
        let b = Float.random(in: 0...1)
        return sqrt(-2 * log(a)) * cos(2 * .pi * b)
    }
}

actor SupertonicVoiceRenderer {
    static let shared = SupertonicVoiceRenderer()
    private var runtime: SupertonicRuntime?
    private var styles: [SupertonicVoice: SupertonicStyle] = [:]

    func render(_ text: String, language: String, voice: SupertonicVoice) async throws -> QwenRenderedAudio {
        let manifest = try SupertonicManifest.bundled()
        guard SupertonicModel.isInstalled(manifest) else { throw SupertonicError.missing }
        guard let code = SupertonicModel.languageCode(for: language) else { throw SupertonicError.unsupportedLanguage }
        let started = Date()
        let runtime = try runtime ?? SupertonicRuntime(directory: SupertonicModel.onnxDirectory)
        self.runtime = runtime
        let style: SupertonicStyle
        if let cached = styles[voice] { style = cached }
        else {
            style = try runtime.loadStyle(SupertonicModel.directory.appending(path: "voice_styles/\(voice.rawValue).json"))
            styles[voice] = style
        }
        let chunks = Self.chunks(text, maximumCharacters: code == "ja" || code == "ko" ? 120 : 300)
        var samples: [Float] = []
        for (index, chunk) in chunks.enumerated() {
            if index > 0 { samples.append(contentsOf: repeatElement(0, count: Int(Double(runtime.sampleRate) * 0.18))) }
            samples.append(contentsOf: try runtime.synthesize(text: chunk, language: code, style: style))
        }
        try Task.checkCancellation()
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else { throw QwenError.emptyAudio }
        let url = URL.temporaryDirectory.appending(path: "conteur-supertonic-\(UUID().uuidString).wav")
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(runtime.sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw QwenError.emptyAudio }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        file.close()
        let audioSeconds = Double(samples.count) / Double(runtime.sampleRate)
        return QwenRenderedAudio(url: url,
                                 metrics: .init(generationSeconds: Date().timeIntervalSince(started), audioSeconds: audioSeconds,
                                                mlxPeakBytes: 0, observedFootprintBytes: 0),
                                 wordTimeline: QwenWordTimeline(text: text, samples: samples, sampleRate: runtime.sampleRate))
    }

    func unload() { styles.removeAll(); runtime = nil }

    private static func chunks(_ text: String, maximumCharacters: Int) -> [String] {
        guard text.count > maximumCharacters else { return [text] }
        var result: [String] = []
        var remainder = text[...]
        let preferredBreaks = CharacterSet(charactersIn: ".!?;:。！？；：、, ")
        while remainder.count > maximumCharacters {
            let limit = remainder.index(remainder.startIndex, offsetBy: maximumCharacters)
            let prefix = remainder[..<limit]
            let split = prefix.indices.reversed().first { index in
                prefix[index].unicodeScalars.allSatisfy(preferredBreaks.contains)
            } ?? limit
            let end = split == remainder.startIndex ? limit : remainder.index(after: split)
            let chunk = remainder[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { result.append(chunk) }
            remainder = remainder[end...]
        }
        let last = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { result.append(last) }
        return result
    }
}
