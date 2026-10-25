import Foundation
import MLX

/// Distinguish an unfinished generation from model, memory and cancellation errors.
public enum QwenGenerationError: Error, Sendable {
    case tokenLimitReached
    case invalidDiagnosticFrames
}

public enum QwenRuntime {
    public static func prepare() {
        Memory.cacheLimit = 64 * 1024 * 1024
        Memory.peakMemory = 0
    }
    public static var peakMemory: Int { Memory.peakMemory }
    public static func clearCache() { Memory.clearCache() }
}

extension Qwen3TTSModel {
    /// Runs on the caller's task, so cancellation finishes before another request can reuse
    /// the decoder. Only CPU sample arrays cross the application's actor boundary.
    public func generateChunks(
        text: String,
        instruction: String,
        language: String,
        speaker: String = "ryan",
        seed: UInt64? = nil,
        temperature: Float = 0.9,
        onCodecFrames: (([[Int32]]) -> Void)? = nil,
        onChunk: @escaping ([Float]) -> Void
    ) throws {
        // Used for controlled comparisons; ordinary reading keeps normal sampling.
        if let seed { MLXRandom.seed(seed) }
        _ = try generateVoiceDesign(
            text: text, instruct: speaker + ", " + instruction, language: language,
            refAudio: nil, refText: nil, temperature: temperature, topK: 50, topP: 1,
            repetitionPenalty: 1.05, minP: 0, maxTokens: 1400,
            streamingInterval: 1.5,
            onCodecFrames: onCodecFrames,
            onAudioChunk: { chunk in onChunk(chunk.asArray(Float.self)) }
        )
    }

    /// Diagnostic only: decode the same first 96 codec frames in a single batch,
    /// without the incremental convolution/attention caches. Never synthesize new
    /// tokens here. The bound keeps diagnostic activation memory small on iPhone.
    public func decodePrefixForValidation(_ frames: [[Int32]]) throws -> [Float] {
        try Task.checkCancellation()
        guard let speechTokenizer, let groups = config.talkerConfig?.numCodeGroups,
              !frames.isEmpty else { throw QwenGenerationError.invalidDiagnosticFrames }
        let prefix = Array(frames.prefix(96))
        let bins = speechTokenizer.decoder.config.codebookSize
        guard prefix.allSatisfy({ $0.count == groups && $0.allSatisfy({ $0 >= 0 && Int($0) < bins }) }) else {
            throw QwenGenerationError.invalidDiagnosticFrames
        }
        speechTokenizer.decoder.resetStreamingState()
        defer { speechTokenizer.decoder.resetStreamingState() }
        let codes = MLXArray(prefix.flatMap { $0 }).reshaped(1, prefix.count, groups).transposed(0, 2, 1)
        let decoded = speechTokenizer.decoder(codes).reshaped(-1)
        eval(decoded)
        try Task.checkCancellation()
        return decoded.asArray(Float.self)
    }
}
