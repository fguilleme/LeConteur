import XCTest
import Tokenizers
@testable import ConteurQwen

final class QwenTokenizerTests: XCTestCase {
    struct Example: Decodable { let text: String; let ids: [Int] }

    // Opt-in integration check against the pinned model's official Qwen2
    // tokenizer. Only vocabulary/config files are read; no model/GPU is loaded.
    func testTextTokensMatchReferenceIncludingFrenchAccentsAndSentenceEndings() async throws {
        try await checkReference(legacy: false)
    }

    func testAlreadyInstalledTokenizerGetsCanonicalAccentsWithoutRedownloadingModel() async throws {
        try await checkReference(legacy: true)
    }

    private func checkReference(legacy: Bool) async throws {
        guard let path = ProcessInfo.processInfo.environment["CONTEUR_TOKENIZER_MODEL"] else {
            throw XCTSkip("Set CONTEUR_TOKENIZER_MODEL to the local pinned Qwen model folder")
        }
        let source = URL(fileURLWithPath: path)
        let folder = URL.temporaryDirectory.appending(path: "qwen-tokenizer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: source.appending(path: "tokenizer_config.json"),
                                        to: folder.appending(path: "tokenizer_config.json"))
        try Qwen3TTSModel.generateTokenizerJson(vocabPath: source.appending(path: "vocab.json"),
            mergesPath: source.appending(path: "merges.txt"), tokenizerConfigPath: source.appending(path: "tokenizer_config.json"),
            outputPath: folder.appending(path: "tokenizer.json"))
        if legacy {
            let url = folder.appending(path: "tokenizer.json")
            var data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            data["normalizer"] = NSNull()
            try JSONSerialization.data(withJSONObject: data).write(to: url)
        }
        let tokenizer = try await AutoTokenizer.from(modelFolder: folder)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil))
            .appending(path: "QwenTokenizationCases.json")
        let cases = try JSONDecoder().decode([Example].self, from: Data(contentsOf: fixture))
        for example in cases {
            let actual = Qwen3TTSModel.encodeText(example.text, using: tokenizer)
            XCTAssertEqual(actual, example.ids, example.text)
            XCTAssertEqual(tokenizer.decode(tokens: actual), example.text)
            if !legacy { XCTAssertEqual(tokenizer.encode(text: example.text), example.ids) }
            else if !example.text.utf8.elementsEqual(example.text.precomposedStringWithCanonicalMapping.utf8) {
                XCTAssertNotEqual(tokenizer.encode(text: example.text), actual,
                    "An existing tokenizer without NFC must be corrected before encoding")
            }
        }
    }
}
