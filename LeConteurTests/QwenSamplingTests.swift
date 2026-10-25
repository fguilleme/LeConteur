import XCTest
import MLX
@testable import ConteurQwen

final class QwenSamplingTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        #if targetEnvironment(simulator)
        throw XCTSkip("MLX requires a physical device; its backend cannot initialize in the iOS simulator, including CPU mode")
        #endif
    }

    func testTemperatureIsAppliedBeforeNucleusSelectionAndOnlyOnce() {
        let result = filtered([4, 3, 2, 1], temperature: 0.5, topP: 0.7)
        XCTAssertEqual(result[0], 8)
        XCTAssertTrue(result.dropFirst().allSatisfy { $0 == -.infinity },
            "At temperature 0.5 the leading token alone covers 70%; filtering first incorrectly keeps two")
    }

    func testCodePredictorKeepsItsOwnTemperatureAndProbabilityMass() {
        let values: [Float] = [4, 3, 2, 1]
        let result = QwenTokenSampling.codePredictorLogits(MLXArray(values).reshaped(1, 1, values.count)).asArray(Float.self)
        for (actual, original) in zip(result, values) {
            XCTAssertEqual(actual, original / 0.9, accuracy: 0.00001)
        }
        XCTAssertTrue(result.allSatisfy(\.isFinite),
            "The residual acoustic codebooks use top-p 1; French narration must not prune them at temperature 0.5")
    }

    func testRepetitionPolicyIsPreservedWhenScalingTemperature() {
        let result = filtered([4, -2, 3], temperature: 1, repetitionPenalty: 2,
            generatedTokens: [2] + Array(repeating: 0, count: 63) + [1])
        XCTAssertEqual(result, [2, -4, 1.5], "Changing filter ordering must preserve the existing repetition policy")
    }

    func testSuppressionAndGreedySelectionPrecedeProbabilityFilters() {
        let result = filtered([10, 4, 3], temperature: 0, topP: 0.01, topK: 1, suppressTokens: [0])
        XCTAssertEqual(result, [-.infinity, 4, 3])
    }

    func testEndTokenRemainsAvailableAtTheRequestedTemperature() {
        let early = filtered([4, 3, -10], temperature: 0.5, topK: 1, eosTokenId: 2)
        XCTAssertEqual(early, [8, -.infinity, -20], "Preserve the EOS escape hatch without changing its temperature")
        let ending = filtered([1, 2, 9], temperature: 0.5, topK: 1, eosTokenId: 2)
        XCTAssertEqual(ending, [-.infinity, -.infinity, 18], "A probable EOS is still allowed to end a passage")
    }

    private func filtered(_ values: [Float], temperature: Float, topP: Float = 1, topK: Int = 0,
                          repetitionPenalty: Float = 1, generatedTokens: [Int]? = nil,
                          suppressTokens: [Int]? = nil, eosTokenId: Int? = nil) -> [Float] {
        QwenTokenSampling.filteredLogits(MLXArray(values).reshaped(1, 1, values.count),
            temperature: temperature, topP: topP, topK: topK,
            repetitionPenalty: repetitionPenalty, generatedTokens: generatedTokens,
            suppressTokens: suppressTokens, eosTokenId: eosTokenId).asArray(Float.self)
    }
}
