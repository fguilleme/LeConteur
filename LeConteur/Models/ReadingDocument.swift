import Foundation
import NaturalLanguage

struct ReadingChapter: Codable, Hashable, Sendable, Identifiable {
    var title: String
    var start: Int

    var id: Int { start }
}

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
    /// Optional keeps libraries written by earlier releases decodable.
    var chapters: [ReadingChapter]?
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
    var builtInID: String?

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
    var resolvedChapters: [ReadingChapter] {
        let stored = (chapters ?? [])
            .filter { segments.indices.contains($0.start) }
            .sorted { $0.start < $1.start }
        let unique = stored.reduce(into: [ReadingChapter]()) { result, chapter in
            guard result.last?.start != chapter.start else { return }
            result.append(ReadingChapter(title: ChapterTitles.normalized(chapter.title), start: chapter.start))
        }
        if !unique.isEmpty { return unique }
        let inferred = ChapterTitles.inferred(in: self)
        if !inferred.isEmpty { return inferred }
        return segments.isEmpty ? [] : [ReadingChapter(title: title, start: 0)]
    }

    func chapter(containing position: Int) -> ReadingChapter? {
        resolvedChapters.last { $0.start <= position }
    }

    func chapterRange(containing position: Int) -> Range<Int>? {
        let chapters = resolvedChapters
        guard let index = chapters.lastIndex(where: { $0.start <= position }) else { return nil }
        let end = index + 1 < chapters.count ? chapters[index + 1].start : segments.count
        return chapters[index].start..<max(chapters[index].start, end)
    }

    func estimatedListeningSeconds(from start: Int, to end: Int? = nil, rate: Double = 1) -> TimeInterval {
        guard !segments.isEmpty else { return 0 }
        let lower = min(max(start, 0), segments.count)
        let upper = min(max(end ?? segments.count, lower), segments.count)
        let words = segments[lower..<upper].reduce(0) { count, segment in
            count + segment.split(whereSeparator: \.isWhitespace).count
        }
        return Double(words) / (160 * max(rate, 0.25)) * 60
    }

    func secondsUntilChapterEnd(from position: Int, rate: Double = 1) -> TimeInterval {
        estimatedListeningSeconds(from: position, to: chapterRange(containing: position)?.upperBound, rate: rate)
    }

    func secondsUntilBookEnd(from position: Int? = nil, rate: Double = 1) -> TimeInterval {
        estimatedListeningSeconds(from: position ?? self.position, rate: rate)
    }

    static var welcome: ReadingDocument {
        let paragraphs = [
            String(localized: "Il y a des histoires qui commencent par un voyage. Celle-ci commence par une voix."),
            String(localized: "Imaginez un matin tranquille. La lumière glisse sur la table, le café est encore chaud et un livre vous attend. Vous n’avez pas besoin de tourner la page. Il vous suffit d’écouter."),
            String(localized: "Le Conteur donne une voix à vos textes, à vos documents et aux livres que vous aimez. Importez un fichier, choisissez votre voix et laissez les mots vous accompagner."),
            String(localized: "Tout se passe sur votre iPhone. Vos lectures restent avec vous, même lorsque le réseau disparaît. Dans un train, au détour d’une promenade, ou simplement les yeux fermés."),
            String(localized: "Vous pouvez choisir une voix de votre iPhone ou utiliser Qwen. Une fois installé, Qwen fonctionne lui aussi sans connexion."),
            String(localized: "Prenez votre temps. Accélérez la lecture, retrouvez un passage, posez un signet. Les histoires savent attendre."),
            String(localized: "Et maintenant, quel sera votre prochain voyage ?")
        ].map(TextSegmenter.split)
        var document = ReadingDocument(
        title: String(localized: "Le goût des mots"),
        author: String(localized: "Bienvenue dans Le Conteur"),
        source: String(localized: "DÉCOUVERTE"),
        segments: paragraphs.flatMap { $0 })
        var start = 0
        document.paragraphStarts = paragraphs.map { parts in
            defer { start += parts.count }
            return start
        }
        document.languageCode = Locale.current.language.languageCode?.identifier ?? "fr"
        document.builtInID = "welcome"
        return document
    }
}

enum ChapterTitles {
    private static let labelled = try! NSRegularExpression(
        pattern: #"^(chapter|chapitre|cap[ií]tulo|capitolo|kapitel|глава)\s+([ivxlcdm]+|[0-9]+)(.*)$"#,
        options: [.caseInsensitive]
    )
    private static let standaloneRoman = try! NSRegularExpression(
        pattern: #"^([ivxlcdm]+)[\s.·:–—-]*$"#,
        options: [.caseInsensitive]
    )

    static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if let match = labelled.firstMatch(in: trimmed, range: range),
           let numeralRange = Range(match.range(at: 2), in: trimmed),
           let suffixRange = Range(match.range(at: 3), in: trimmed) {
            let token = String(trimmed[numeralRange])
            let number: String
            if let roman = romanValue(token) {
                number = String(roman)
            } else if token.allSatisfy(\.isNumber) {
                number = token
            } else {
                return trimmed
            }

            let prefix = String(trimmed[..<numeralRange.lowerBound])
            let suffix = String(trimmed[suffixRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".·:\u{2013}\u{2014}-"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return suffix.isEmpty ? prefix + number : "\(prefix)\(number) — \(suffix)"
        }
        if let match = standaloneRoman.firstMatch(in: trimmed, range: range),
           let numeralRange = Range(match.range(at: 1), in: trimmed),
           let number = romanValue(String(trimmed[numeralRange])) {
            return String(number)
        }
        return trimmed
    }

    static func recognized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if labelled.firstMatch(in: trimmed, range: range) != nil { return normalized(trimmed) }
        if standaloneRoman.firstMatch(in: trimmed, range: range) != nil,
           normalized(trimmed) != trimmed.uppercased() { return normalized(trimmed) }
        return nil
    }

    static func normalizingHeadings(in text: String) -> String {
        text.components(separatedBy: .newlines).map { line in
            recognized(line) ?? line
        }.joined(separator: "\n")
    }

    static func inferred(in document: ReadingDocument) -> [ReadingChapter] {
        document.paragraphRanges.compactMap { range in
            let paragraph = document.segments[range].joined(separator: " ")
            return recognized(paragraph).map { ReadingChapter(title: $0, start: range.lowerBound) }
        }
    }

    private static func romanValue(_ token: String) -> Int? {
        let roman = token.uppercased()
        guard !roman.isEmpty, roman.allSatisfy({ "IVXLCDM".contains($0) }) else { return nil }
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]
        var total = 0
        var previous = 0
        for character in roman.reversed() {
            guard let value = values[character] else { return nil }
            if value < previous { total -= value } else { total += value; previous = value }
        }
        guard (1...3999).contains(total), romanString(total) == roman else { return nil }
        return total
    }

    private static func romanString(_ number: Int) -> String {
        let pairs = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                     (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var value = number
        var result = ""
        for (amount, token) in pairs {
            while value >= amount { result += token; value -= amount }
        }
        return result
    }
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
