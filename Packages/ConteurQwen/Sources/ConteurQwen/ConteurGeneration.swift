import Foundation
import MLX

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
        onChunk: @escaping ([Float]) -> Void
    ) throws {
        _ = try generateVoiceDesign(
            text: text, instruct: speaker + ", " + instruction, language: language,
            refAudio: nil, refText: nil, temperature: 0.75, topK: 50, topP: 0.95,
            repetitionPenalty: 1.05, minP: 0, maxTokens: 1400,
            streamingInterval: 1.5,
            onAudioChunk: { chunk in onChunk(chunk.asArray(Float.self)) }
        )
    }
}
