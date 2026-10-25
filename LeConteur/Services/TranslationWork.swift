import Foundation
import CryptoKit

/// Translate neighbouring sentences together, without crossing paragraph boundaries.
struct TranslationWork {
    struct Block: Codable {
        let text: String
        let paragraph: Int
    }
    let blocks: [Block]
    let fingerprint: String

    init(document: ReadingDocument, source: String, target: String) {
        var blocks: [Block] = []
        for (paragraph, range) in document.paragraphRanges.enumerated() {
            var text = ""
            for index in range {
                let sentence = document.segments[index]
                if !text.isEmpty && text.count + sentence.count + 1 > 900 {
                    blocks.append(Block(text: text, paragraph: paragraph))
                    text = ""
                }
                text += (text.isEmpty ? "" : " ") + sentence
            }
            if !text.isEmpty { blocks.append(Block(text: text, paragraph: paragraph)) }
        }
        self.blocks = blocks
        // Version the plan to avoid reusing older sentence-by-sentence translations.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(blocks)
        var hash = SHA256()
        hash.update(data: Data("paragraph-v2|\(source)|\(target)|\(document.title)|".utf8))
        hash.update(data: data)
        fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func document(from output: [String], original: ReadingDocument, language: String) throws -> ReadingDocument {
        guard output.count == blocks.count, !output.isEmpty,
              output.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw TranslationWorkError.incomplete
        }
        var result = draft(original: original, language: language)
        appendAvailable(output, to: &result)
        return result
    }

    func draft(original: ReadingDocument, language: String) -> ReadingDocument {
        var result = ReadingDocument(title: original.title, author: original.author,
                                     source: "TRADUIT · \(language.uppercased())", segments: [])
        result.translationOf = original.id
        result.coverFileName = original.coverFileName
        result.languageCode = language
        result.translationVersion = 1
        result.translationComplete = false
        result.translationTitleComplete = false
        result.translationAuthorComplete = false
        result.translatedBlocks = 0
        result.translationTotalBlocks = blocks.count
        result.translationFingerprint = fingerprint
        return result
    }

    /// Publish only a contiguous prefix. Once visible, segments and their offsets
    /// are immutable: the audio player can keep reading while more text is appended.
    @discardableResult func appendAvailable(_ output: [String], to result: inout ReadingDocument) -> Bool {
        let before = result.translatedBlocks ?? 0
        var index = before
        while index < min(output.count, blocks.count) {
            let text = output[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { break }
            if index == 0 || blocks[index - 1].paragraph != blocks[index].paragraph {
                result.paragraphStarts.append(result.segments.count)
            }
            result.segments += TextSegmenter.split(text)
            index += 1
        }
        result.translatedBlocks = index
        result.translationComplete = index == blocks.count
        return index > before
    }
}

enum TranslationWorkError: LocalizedError {
    case incomplete
    var errorDescription: String? { "Un passage n’a pas été traduit. Les passages terminés sont conservés pour réessayer." }
}

/// Each completed block is committed atomically. A crash cannot discard earlier blocks.
struct TranslationCheckpoint {
    let directory: URL
    init(fingerprint: String, root: URL = URL.applicationSupportDirectory.appending(path: "Translations")) throws {
        directory = root.appending(path: fingerprint, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var root = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
    }
    func load(count: Int) -> [String] {
        (0..<count).map { index in (try? String(contentsOf: file(index), encoding: .utf8)) ?? "" }
    }
    func save(_ text: String, at index: Int) throws {
        try Data(text.utf8).write(to: file(index), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    private func file(_ index: Int) -> URL { directory.appending(path: "\(index).txt") }
}
