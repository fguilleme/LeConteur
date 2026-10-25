import Foundation
import MLX

/// Match Qwen's MLX reference ordering: penalty, temperature, top-k, then
/// probability filters. Filtering before temperature keeps a different set of
/// acoustic tokens, especially with the reduced French sampling temperature.
enum QwenTokenSampling {
    /// The pinned model's generation_config.json gives the residual codebooks
    /// their own distribution. A lower narration temperature must not collapse
    /// these acoustic details to the same low-entropy distribution as the talker.
    static func codePredictorLogits(_ logits: MLXArray) -> MLXArray {
        filteredLogits(logits, temperature: 0.9, topP: 1, topK: 50)
    }

    static func filteredLogits(
        _ logits: MLXArray, temperature: Float, topP: Float, topK: Int,
        repetitionPenalty: Float = 1, generatedTokens: [Int]? = nil,
        suppressTokens: [Int]? = nil, eosTokenId: Int? = nil, minP: Float = 0
    ) -> MLXArray {
        // Accumulate probabilities in float32, including for a quantized model.
        var result = logits[0..., (-1)..., 0...].squeezed(axis: 1).asType(.float32)
        let vocabulary = result.dim(-1)
        if let suppressTokens, !suppressTokens.isEmpty {
            let indices = MLXArray(suppressTokens.map { Int32($0) }).reshaped(1, -1)
            result = putAlong(result, indices,
                values: MLXArray.full(indices.shape, values: MLXArray(-Float.infinity)), axis: -1)
        }
        if let generatedTokens, repetitionPenalty != 1 {
            // Keep the existing history policy. Changing this together with
            // EOS filtering produced a 91-second rendition of a short paragraph.
            let recent = Array(Set(generatedTokens)).filter { $0 >= 0 && $0 < vocabulary }
            if !recent.isEmpty {
                let indices = MLXArray(recent.map { Int32($0) }).reshaped(1, -1)
                let selected = takeAlong(result, indices, axis: -1)
                let penalized = which(selected .< 0, selected * repetitionPenalty, selected / repetitionPenalty)
                result = putAlong(result, indices, values: penalized, axis: -1)
            }
        }
        guard temperature > 0 else { return result }
        result = result / temperature
        // Preserve the existing EOS escape hatch, at the same temperature as
        // every acoustic token. It prevents unbounded continuations when the
        // quantized model repeatedly puts EOS just outside the nucleus.
        let endLogit: MLXArray? = if let eosTokenId, eosTokenId >= 0, eosTokenId < vocabulary {
            result[0..., eosTokenId..<(eosTokenId + 1)]
        } else { nil }
        if topK > 0, topK < vocabulary {
            let indices = argPartition(-result, kth: topK - 1, axis: -1)[0..., topK...]
            result = putAlong(result, indices,
                values: MLXArray.full(indices.shape, values: MLXArray(-Float.infinity)), axis: -1)
        }
        if topP > 0, topP < 1 {
            let indices = argSort(result, axis: -1)
            let probabilities = takeAlong(softmax(result, axis: -1), indices, axis: -1)
            let cumulative = cumsum(probabilities, axis: -1)
            let order = MLXArray(0..<vocabulary).reshaped(1, -1).asType(Int32.self)
            let inverse = putAlong(MLXArray.zeros(indices.shape, type: Int32.self), indices, values: order, axis: -1)
            let keep = takeAlong(cumulative, inverse, axis: -1) .> (1 - topP)
            result = which(keep, result, MLXArray(-Float.infinity))
        }
        if minP > 0 {
            let threshold = max(result, axis: -1, keepDims: true) + Float(log(Double(minP)))
            result = which(result .>= threshold, result, MLXArray(-Float.infinity))
        }
        if let endLogit, let eosTokenId {
            let index = MLXArray([Int32(eosTokenId)]).reshaped(1, 1)
            result = putAlong(result, index, values: endLogit, axis: -1)
        }
        return result
    }
}
