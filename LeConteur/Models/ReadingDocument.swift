import Foundation
import NaturalLanguage

struct ReadingDocument: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var author: String
    var source: String
    var segments: [String]
    var importedAt = Date()
    var position = 0
    var isFinished = false
    var bookmarks: Set<Int> = []
    var paragraphStarts: [Int] = []
    var translationOf: UUID?
    var translationVersion: Int?
    var languageCode: String?
    var coverFileName: String?
    var preferredReadingID: UUID?
    var translationComplete: Bool?
    var translationTitleComplete: Bool?
    var translationAuthorComplete: Bool?
    var translatedBlocks: Int?
    var translationTotalBlocks: Int?
    var translationFingerprint: String?

    var isTranslationPending: Bool { translationOf != nil && translationComplete == false }
    var isTranslationMetadataComplete: Bool {
        translationTitleComplete == true && translationAuthorComplete == true
    }
    var translationProgress: Double {
        guard let total = translationTotalBlocks, total > 0 else {
            return translationComplete == true ? 1 : 0
        }
        return min(1, max(0, Double(translatedBlocks ?? 0) / Double(total)))
    }
    var resolvedLanguage: String? {
        let code = languageCode ?? NLLanguageRecognizer.dominantLanguage(for: segments.prefix(8).joined(separator: " "))?.rawValue
        return code.map(SystemVoiceSelection.language)
    }

    var wordCount: Int { segments.reduce(0) { $0 + $1.split(whereSeparator: \.isWhitespace).count } }
    var minutes: Int { max(1, Int(ceil(Double(wordCount) / 160))) }
    var progress: Double { isFinished ? 1 : Double(position) / Double(max(segments.count, 1)) }
    var preview: String { segments.first ?? "" }
    var paragraphRanges: [Range<Int>] {
        let starts = paragraphStarts.isEmpty ? Array(segments.indices) : paragraphStarts
        return starts.enumerated().map { offset, start in
            start..<(offset + 1 < starts.count ? starts[offset + 1] : segments.count)
        }
    }

    static let welcome: ReadingDocument = {
        let text = """
        Il y a des histoires qui commencent par un voyage. Celle-ci commence par une voix.

        Imaginez un matin tranquille. La lumière glisse sur la table, le café est encore chaud et un livre vous attend. Vous n’avez pas besoin de tourner la page. Il vous suffit d’écouter.

        Le Conteur donne une voix à vos textes, à vos documents et aux livres que vous aimez. Importez un fichier, choisissez votre voix et laissez les mots vous accompagner.

        Tout se passe sur votre iPhone. Vos lectures restent avec vous, même lorsque le réseau disparaît. Dans un train, au détour d’une promenade, ou simplement les yeux fermés.

        Vous pouvez choisir une voix de votre iPhone ou télécharger la voix neuronale française. Une fois installée, elle aussi fonctionne sans connexion.

        Prenez votre temps. Accélérez la lecture, retrouvez un passage, posez un signet. Les histoires savent attendre.

        Et maintenant, quel sera votre prochain voyage ?
        """
        let paragraphs = text.components(separatedBy: "\n\n").map(TextSegmenter.split)
        var document = ReadingDocument(
        title: "Le goût des mots",
        author: "Bienvenue dans Le Conteur",
        source: "DÉCOUVERTE",
        segments: paragraphs.flatMap { $0 })
        var start = 0
        document.paragraphStarts = paragraphs.map { parts in
            defer { start += parts.count }
            return start
        }
        document.languageCode = "fr"
        return document
    }()
}

enum TextSegmenter {
    /// Keep speech requests short so seeking and cancellation remain responsive.
    static func split(_ text: String) -> [String] {
        let clean = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = clean
        var result: [String] = []
        tokenizer.enumerateTokens(in: clean.startIndex..<clean.endIndex) { range, _ in
            let sentence = String(clean[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            var chunk = ""
            for word in sentence.split(whereSeparator: \.isWhitespace) {
                if chunk.count + word.count > 360 && !chunk.isEmpty {
                    result.append(chunk)
                    chunk = ""
                }
                // A malformed document can contain a very long token.
                if word.count > 360 {
                    if !chunk.isEmpty { result.append(chunk); chunk = "" }
                    var rest = word[...]
                    while !rest.isEmpty {
                        let end = rest.index(rest.startIndex, offsetBy: min(360, rest.count))
                        result.append(String(rest[..<end]))
                        rest = rest[end...]
                    }
                } else {
                    chunk += (chunk.isEmpty ? "" : " ") + word
                }
            }
            if !chunk.isEmpty { result.append(chunk) }
            return true
        }
        return result
    }
}
