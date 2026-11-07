import Foundation
import PDFKit
import ZIPFoundation
import NaturalLanguage
import ImageIO
import UIKit
import Vision

enum ImportFailure: LocalizedError {
    case empty, tooLarge, unsupported, invalidEPUB, lockedPDF
    var errorDescription: String? {
        switch self {
        case .empty: String(localized: "Ce document ne contient pas de texte lisible. Pour un PDF scanné, une reconnaissance de caractères est nécessaire.")
        case .tooLarge: String(localized: "Ce document est trop volumineux. La limite est de 50 Mo ou de 2 millions de caractères.")
        case .unsupported: String(localized: "Choisissez un fichier EPUB sans DRM, PDF, DOCX, TXT ou Markdown.")
        case .invalidEPUB: String(localized: "Ce livre EPUB est endommagé, protégé ou n’utilise pas un format pris en charge.")
        case .lockedPDF: String(localized: "Ce PDF est protégé par un mot de passe. Déverrouillez-le avant de l’importer.")
        }
    }
}

enum DocumentImporter {
    typealias ProgressHandler = @Sendable (_ completedPages: Int, _ totalPages: Int) -> Void

    static func fromText(_ text: String, title: String, source: String = String(localized: "TEXTE"), author: String = String(localized: "Texte personnel")) throws -> ReadingDocument {
        guard text.count <= 2_000_000 else { throw ImportFailure.tooLarge }
        let normalizedText = ChapterTitles.normalizingHeadings(in: text)
        let paragraphs = normalizedText.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n[\t ]*\n", with: "\u{001e}", options: .regularExpression)
            .components(separatedBy: "\u{001e}")
        var segments: [String] = []
        var starts: [Int] = []
        for paragraph in paragraphs {
            let parts = TextSegmenter.split(paragraph)
            if !parts.isEmpty { starts.append(segments.count); segments.append(contentsOf: parts) }
        }
        guard !segments.isEmpty else { throw ImportFailure.empty }
        let cleanTitle = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var document = ReadingDocument(title: cleanTitle.isEmpty ? String(segments[0].prefix(60)) : cleanTitle,
                               author: author, source: source, segments: segments)
        document.paragraphStarts = starts
        document.languageCode = NLLanguageRecognizer.dominantLanguage(for: String(normalizedText.prefix(4000)))?.rawValue
        let chapters = ChapterTitles.inferred(in: document)
        if !chapters.isEmpty { document.chapters = chapters }
        document.refreshWordCountIndex()
        return document
    }

    static func fromFile(_ url: URL, coverDirectory: URL = BookCoverStore.directory,
                         progress: ProgressHandler? = nil) throws -> ReadingDocument {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        // Coordinate with Files providers so cloud-backed selections finish downloading first.
        var coordinationError: NSError?
        var result: Result<ReadingDocument, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { localURL in
            result = Result { try readFile(localURL, coverDirectory: coverDirectory, progress: progress) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ImportFailure.empty }
        return try result.get()
    }

    private static func readFile(_ url: URL, coverDirectory: URL,
                                 progress: ProgressHandler?) throws -> ReadingDocument {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 50_000_000 else { throw ImportFailure.tooLarge }
        var title = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
        var author = String(localized: "Document importé")
        var declaredLanguage: String?
        var coverData: Data?
        var importedChapters: [ReadingChapter]?
        let text: String
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let pdf = PDFDocument(url: url) else { throw ImportFailure.empty }
            guard !pdf.isLocked else { throw ImportFailure.lockedPDF }
            var pages: [String] = []
            var count = 0
            progress?(0, pdf.pageCount)
            for index in 0..<pdf.pageCount {
                let recognized: RecognizedPDFPage = autoreleasepool {
                    guard let pdfPage = pdf.page(at: index) else { return .empty }
                    let embeddedText = pdfPage.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if meaningfulCharacterCount(in: embeddedText) >= 40 {
                        return RecognizedPDFPage(body: embeddedText, footnotes: [])
                    }
                    // A number of scanned PDFs contain a searchable cover or title
                    // followed by image-only pages. PDFKit then returns just enough
                    // text for the import to look successful, while silently losing
                    // the actual book. OCR only sparse pages so ordinary PDFs retain
                    // their original, faster and more accurate text layer.
                    let scanned = (try? recognizeText(in: pdfPage)) ?? .empty
                    return meaningfulCharacterCount(in: scanned.body) > meaningfulCharacterCount(in: embeddedText)
                        ? scanned : RecognizedPDFPage(body: embeddedText, footnotes: [])
                }
                count += recognized.body.count
                guard count <= 2_000_000 else { throw ImportFailure.tooLarge }
                pages.append(recognized.body)
                progress?(index + 1, pdf.pageCount)
            }
            // Notes de bas de page are useful on the printed page, but become a
            // long interruption in an audiobook. OCR separates them from the
            // page body, so keep them out of the narrated document entirely.
            text = joinedPDFPages(pages)
            if let name = pdf.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String { author = name }
        case "epub":
            let book = try readEPUB(url)
            text = book.text
            if !book.title.isEmpty { title = book.title }
            if !book.author.isEmpty { author = book.author }
            if !book.language.isEmpty { declaredLanguage = SystemVoiceSelection.language(book.language) }
            coverData = book.cover
            importedChapters = book.chapters
        case "docx":
            let document = try readDOCX(url)
            text = document.text
            if !document.title.isEmpty { title = document.title }
            if !document.author.isEmpty { author = document.author }
            if !document.language.isEmpty { declaredLanguage = SystemVoiceSelection.language(document.language) }
        case "txt", "md", "markdown":
            let data = try Data(contentsOf: url)
            guard let decoded = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .windowsCP1252) else { throw ImportFailure.empty }
            text = decoded
        default: throw ImportFailure.unsupported
        }
        var document = try fromText(text, title: title, source: url.pathExtension.uppercased(), author: author)
        if let declaredLanguage { document.languageCode = declaredLanguage }
        if let importedChapters, !importedChapters.isEmpty { document.chapters = importedChapters }
        if let coverData { document.coverFileName = try? BookCoverStore.save(coverData, directory: coverDirectory) }
        return document
    }

    private static func meaningfulCharacterCount(in text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.alphanumerics.contains(scalar) { count += 1 }
        }
    }

    private struct OCRLine {
        let text: String
        let box: CGRect
    }

    private struct RecognizedPDFPage {
        let body: String
        let footnotes: [String]
        static let empty = RecognizedPDFPage(body: "", footnotes: [])
    }

    private static func joinedPDFPages(_ pages: [String]) -> String {
        var result = ""
        for rawPage in pages {
            let page = rawPage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !page.isEmpty else { continue }
            guard !result.isEmpty else { result = page; continue }
            if let first = page.first, first.isLowercase,
               let last = result.last, !".!?…".contains(last) {
                if last == "-" { result.removeLast() }
                else { result += " " }
                result += page
            } else {
                result += "\n\n" + page
            }
        }
        return result
    }

    private static func recognizeText(in page: PDFPage) throws -> RecognizedPDFPage {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return .empty }
        let maximumDimension: CGFloat = 2_400
        let scale = min(3, maximumDimension / max(bounds.width, bounds.height))
        let target = CGSize(width: max(1, (bounds.width * scale).rounded(.up)),
                            height: max(1, (bounds.height * scale).rounded(.up)))
        let image = page.thumbnail(of: target, for: .mediaBox)
        guard let cgImage = image.cgImage else { return .empty }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
        try handler.perform([request])
        var lines = (request.results ?? []).compactMap { observation -> OCRLine? in
            guard let text = observation.topCandidates(1).first?.string
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return OCRLine(text: text, box: observation.boundingBox)
        }
        // A fuzzy comparator can be non-transitive and reorder neighbouring
        // scan lines. Use a strict vertical order; x only breaks exact ties.
        lines.sort {
            if $0.box.midY == $1.box.midY { return $0.box.minX < $1.box.minX }
            return $0.box.midY > $1.box.midY
        }
        // Running heads commonly share the top band with a page number, but
        // Vision may return the title and number as blocks with different
        // baselines or font heights. Inspect the whole band rather than a
        // narrowly defined row. Keep genuine CHAPTER and 23.1-style headings.
        let topBand = lines.filter { $0.box.maxY > 0.86 }
        if !topBand.isEmpty {
            let topText = topBand.map(\.text).joined(separator: " ")
            let isChapterHeading = topText.localizedCaseInsensitiveContains("chapter")
            let isNumberedSection = topText.range(
                of: #"^\s*\d+(?:\.\d+)+\b"#,
                options: .regularExpression
            ) != nil
            let hasFolio = containsPageNumber(in: topText)
                || topBand.contains { containsLikelyOCRPageNumber(in: $0.text) }
            if hasFolio && !isChapterHeading && !isNumberedSection {
                lines.removeAll { $0.box.maxY > 0.86 }
            }
        }
        // A lone number at the bottom is a folio, not book content.
        lines.removeAll { $0.box.maxY < 0.08 && isOnlyPageNumber($0.text) }
        guard !lines.isEmpty else { return .empty }

        // Vision returns positioned lines rather than paragraphs. Reconstruct the
        // latter from the larger vertical gaps and first-line indentation, then
        // join ordinary wrapped lines so the reader does not pause at each scan line.
        var heights = lines.map(\.box.height).sorted()
        lines = removingLeadingRunningHeaderLines(lines, typicalHeight: heights[heights.count / 2])
        guard !lines.isEmpty else { return .empty }
        heights = lines.map(\.box.height).sorted()
        let typicalHeight = heights[heights.count / 2]
        let footnoteStart = lines.indices.first { index in
            guard index > lines.startIndex else { return false }
            let line = lines[index]
            let previous = lines[lines.index(before: index)]
            let startsFootnote = line.text.range(
                of: #"^\s*(?:\d{1,3}[.)]?|[•*])\s+"#,
                options: .regularExpression
            ) != nil
            return line.box.maxY < 0.4
                && startsFootnote
                && previous.box.minY - line.box.maxY > typicalHeight * 0.5
        }
        let split = footnoteStart ?? lines.endIndex
        let body = removingLeadingRunningHeader(from:
            paragraphs(from: Array(lines[..<split]), typicalHeight: typicalHeight, footnotes: false)
        ).joined(separator: "\n\n")
        let notes = split < lines.endIndex
            ? paragraphs(from: Array(lines[split...]), typicalHeight: typicalHeight, footnotes: true)
            : []
        return RecognizedPDFPage(body: body, footnotes: notes)
    }

    private static func removingLeadingRunningHeader(from paragraphs: [String]) -> [String] {
        guard paragraphs.count > 1 else { return paragraphs }
        let candidate = paragraphs[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let following = paragraphs[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let uppercase = candidate.uppercased() == candidate
        let words = candidate.split(whereSeparator: \.isWhitespace)
        guard uppercase, words.count >= 2, candidate.count < 120,
              following.first?.isLowercase == true, !isProtectedHeading(candidate) else { return paragraphs }
        return Array(paragraphs.dropFirst())
    }

    private static func removingLeadingRunningHeaderLines(_ lines: [OCRLine],
                                                          typicalHeight: CGFloat) -> [OCRLine] {
        guard let first = lines.first, first.box.maxY > 0.78 else { return lines }
        let candidates = lines.prefix(4)
        guard let bodyIndex = candidates.firstIndex(where: { $0.text.first?.isLowercase == true }),
              bodyIndex > 0 else { return lines }
        let headerLines = lines[..<bodyIndex]
        let header = headerLines.map(\.text).joined(separator: " ")
        let gap = max(0, lines[bodyIndex - 1].box.minY - lines[bodyIndex].box.maxY)
        guard header.uppercased() == header,
              header.split(whereSeparator: \.isWhitespace).count >= 2,
              header.count < 140,
              gap > typicalHeight * 0.5,
              !isProtectedHeading(header) else { return lines }
        return Array(lines.dropFirst(bodyIndex))
    }

    private static func isProtectedHeading(_ text: String) -> Bool {
        let normalized = text.uppercased()
        return normalized.hasPrefix("CHAPTER ")
            || normalized.hasPrefix("PART ")
            || normalized == "CONTENTS"
            || normalized.contains("TABLE OF CONTENTS")
            || normalized == "FURTHER READING"
            || text.range(of: #"^\s*\d+(?:\.\d+)+\b"#, options: .regularExpression) != nil
    }

    private static func paragraphs(from lines: [OCRLine], typicalHeight: CGFloat,
                                   footnotes: Bool) -> [String] {
        guard let first = lines.first else { return [] }
        var paragraphs: [String] = []
        var paragraph = first.text
        var previous = first
        for line in lines.dropFirst() {
            let verticalGap = max(0, previous.box.minY - line.box.maxY)
            let isIndented = line.box.minX - previous.box.minX > max(0.02, typicalHeight * 1.25)
            let startsNumberedFootnote = footnotes && line.text.range(
                of: #"^\s*\d{1,2}[.)]?\s+"#,
                options: .regularExpression
            ) != nil
            let startsParagraph = footnotes
                ? startsNumberedFootnote
                : verticalGap > typicalHeight * 0.8 || isIndented
            if startsParagraph {
                paragraphs.append(paragraph)
                paragraph = line.text
            } else if paragraph.last == "-", line.text.first?.isLowercase == true {
                paragraph.removeLast()
                paragraph += line.text
            } else {
                paragraph += " " + line.text
            }
            previous = line
        }
        paragraphs.append(paragraph)
        return paragraphs
    }

    private static func containsPageNumber(in text: String) -> Bool {
        text.range(of: #"(?:^|\s)(?:\d{2,4}|[ivxlcdm]{2,})(?:\s|$)"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isOnlyPageNumber(_ text: String) -> Bool {
        text.range(of: #"^\s*(?:\d{1,4}|[ivxlcdm]{1,8})\s*$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func containsLikelyOCRPageNumber(in text: String) -> Bool {
        text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).contains { token in
            guard (2...4).contains(token.count), token.contains(where: \.isNumber) else { return false }
            return token.allSatisfy { $0.isNumber || $0 == "I" || $0 == "l" || $0 == "|" }
        }
    }

    private static func readDOCX(_ url: URL) throws -> (text: String, title: String, author: String, language: String) {
        let archive = try Archive(url: url, accessMode: .read)
        var total: Int64 = 0
        func data(_ path: String) throws -> Data {
            guard let entry = archive[path], entry.type == .file else { throw ImportFailure.empty }
            total += Int64(entry.uncompressedSize)
            guard entry.uncompressedSize < 20_000_000, total <= 25_000_000 else { throw ImportFailure.tooLarge }
            var content = Data()
            _ = try archive.extract(entry) { content.append($0) }
            return content
        }
        let body = XMLCollector()
        try body.parse(data("word/document.xml"))
        let metadata = XMLCollector()
        if archive["docProps/core.xml"] != nil { try? metadata.parse(data("docProps/core.xml")) }
        return (body.text.trimmingCharacters(in: .whitespacesAndNewlines),
                metadata.title.trimmingCharacters(in: .whitespacesAndNewlines),
                metadata.author.trimmingCharacters(in: .whitespacesAndNewlines),
                metadata.language.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func readEPUB(_ url: URL) throws -> (text: String, title: String, author: String, language: String, cover: Data?, chapters: [ReadingChapter]) {
        let archive = try Archive(url: url, accessMode: .read)
        var total: Int64 = 0
        func data(_ path: String) throws -> Data {
            guard let entry = archive[path], entry.type == .file else { throw ImportFailure.invalidEPUB }
            total += Int64(entry.uncompressedSize)
            guard entry.uncompressedSize < 10_000_000, total <= 30_000_000 else { throw ImportFailure.tooLarge }
            var content = Data()
            _ = try archive.extract(entry) { content.append($0) }
            return content
        }
        let container = XMLCollector()
        try container.parse(data("META-INF/container.xml"))
        guard let packagePath = container.rootfile else { throw ImportFailure.invalidEPUB }
        let package = XMLCollector()
        try package.parse(data(packagePath))
        let base = URL(fileURLWithPath: "/" + packagePath).deletingLastPathComponent()
        func localPath(_ href: String, relativeTo base: URL) -> String? {
            let path = href.components(separatedBy: "#")[0].components(separatedBy: "?")[0]
            guard let decoded = path.removingPercentEncoding, !decoded.isEmpty,
                  !decoded.contains(":"), !decoded.hasPrefix("/"), !decoded.contains("\\") else { return nil }
            let resolved = base.appendingPathComponent(decoded).standardized.path
            guard !resolved.hasPrefix("/../") else { return nil }
            return String(resolved.dropFirst())
        }
        var texts: [String] = []
        var chapters: [ReadingChapter] = []
        var segmentOffset = 0
        var characterCount = 0
        for id in package.spine {
            guard let href = package.items[id] else { continue }
            guard let path = localPath(href, relativeTo: base) else { throw ImportFailure.invalidEPUB }
            let chapter = XMLCollector()
            try chapter.parse(data(path))
            let normalizedText = ChapterTitles.normalizingHeadings(in: chapter.text)
            characterCount += normalizedText.count
            guard characterCount <= 2_000_000 else { throw ImportFailure.tooLarge }
            guard let parsed = try? fromText(normalizedText, title: "", source: "EPUB", author: ""),
                  !parsed.segments.isEmpty else { continue }
            let fallback = String(format: String(localized: "Chapitre %lld"), Int64(chapters.count + 1))
            let heading = chapter.heading.trimmingCharacters(in: .whitespacesAndNewlines)
            let inferred = parsed.chapters?.first?.title
            chapters.append(ReadingChapter(title: ChapterTitles.normalized(heading.isEmpty ? (inferred ?? fallback) : heading),
                                           start: segmentOffset))
            segmentOffset += parsed.segments.count
            texts.append(normalizedText)
        }
        // Optional artwork must never prevent the text from being imported. Read it
        // after chapters so a missing or oversized cover does not consume their budget.
        var candidates = package.coverImageIDs.compactMap { package.items[$0] }
        if let id = package.legacyCoverID, let href = package.items[id] { candidates.append(href) }
        candidates += package.coverPages
        for id in ["cover", "cover-image", "coverimage"] where package.mediaTypes[id]?.hasPrefix("image/") == true {
            if let href = package.items[id] { candidates.append(href) }
        }
        var visited: Set<String> = []
        var coverBytes: Int64 = 0
        func cover(_ href: String, relativeTo base: URL, depth: Int = 0) -> Data? {
            guard depth < 3, let path = localPath(href, relativeTo: base), visited.insert(path).inserted,
                  let entry = archive[path], entry.type == .file, entry.uncompressedSize < 10_000_000 else { return nil }
            coverBytes += Int64(entry.uncompressedSize)
            guard coverBytes <= 20_000_000 else { return nil }
            var bytes = Data()
            guard (try? archive.extract(entry, consumer: { bytes.append($0) })) != nil else { return nil }
            if ["xhtml", "html", "htm", "svg"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
                let page = XMLCollector()
                guard (try? page.parse(bytes)) != nil else { return nil }
                let parent = URL(fileURLWithPath: "/" + path).deletingLastPathComponent()
                for image in page.images.prefix(4) {
                    if let result = cover(image, relativeTo: parent, depth: depth + 1) { return result }
                }
                return nil
            }
            guard CGImageSourceCreateWithData(bytes as CFData, nil) != nil else { return nil }
            return bytes
        }
        var artwork: Data?
        for candidate in candidates.prefix(8) {
            if let found = cover(candidate, relativeTo: base) { artwork = found; break }
        }
        let body = texts.joined(separator: "\n\n")
        let title = repairedMetadata(package.title, using: texts)
        return (body, title, package.author.trimmingCharacters(in: .whitespacesAndNewlines), package.language.trimmingCharacters(in: .whitespacesAndNewlines), artwork, chapters)
    }

    /// Some EPUB generators have already replaced a smart quote in the OPF title
    /// with U+FFFD, even though the same title is intact in the book body. Only use
    /// a body candidate when its letters and numbers exactly match the metadata;
    /// this avoids guessing what an actually missing character was.
    private static func repairedMetadata(_ value: String, using chapters: [String]) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.contains("\u{fffd}") else { return value }
        let key = metadataKey(value)
        guard !key.isEmpty else { return value }
        for chapter in chapters {
            for line in chapter.components(separatedBy: .newlines) {
                let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !candidate.isEmpty, !candidate.contains("\u{fffd}"),
                      candidate.count <= max(value.count + 20, 160),
                      metadataKey(candidate) == key else { continue }
                return candidate
            }
        }
        return value
    }

    private static func metadataKey(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}

enum EPUBExporter {
    static func export(_ document: ReadingDocument) throws -> URL {
        let language = SystemVoiceSelection.language(document.resolvedLanguage ?? document.languageCode ?? "und")
        let identifier = "urn:uuid:\(document.id.uuidString.lowercased())"
        let title = xml(document.title)
        let author = xml(document.author)
        let modified = ISO8601DateFormatter().string(from: Date())
        let paragraphs = document.paragraphRanges.map { range in
            "<p>\(xml(document.segments[range].joined(separator: " ")))</p>"
        }.joined(separator: "\n")

        let coverData: Data? = document.coverFileName.flatMap { name in
            guard name.range(of: "^[a-f0-9]{64}\\.jpg$", options: .regularExpression) != nil else { return nil }
            return try? Data(contentsOf: BookCoverStore.directory.appending(path: name))
        }
        let coverManifest = coverData == nil ? "" : "<item id=\"cover\" href=\"cover.jpg\" media-type=\"image/jpeg\" properties=\"cover-image\"/>"
        let coverMarkup = coverData == nil ? "" : "<img class=\"cover\" src=\"cover.jpg\" alt=\"Couverture\"/>"
        let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let package = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" unique-identifier="book-id" xmlns="http://www.idpf.org/2007/opf">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="book-id">\(identifier)</dc:identifier>
            <dc:title>\(title)</dc:title>
            <dc:creator>\(author)</dc:creator>
            <dc:language>\(xml(language))</dc:language>
            <meta property="dcterms:modified">\(modified)</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="book" href="book.xhtml" media-type="application/xhtml+xml"/>
            \(coverManifest)
          </manifest>
          <spine><itemref idref="book"/></spine>
        </package>
        """
        let nav = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(xml(language))">
          <head><title>Sommaire</title></head>
          <body><nav epub:type="toc"><h1>\(xml(String(localized: "Sommaire")))</h1><ol><li><a href="book.xhtml">\(title)</a></li></ol></nav></body>
        </html>
        """
        let book = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" lang="\(xml(language))">
          <head>
            <title>\(title)</title>
            <style>body{font-family:serif;line-height:1.55;margin:6%;}h1{text-align:center;margin-top:1.5em;}h2{text-align:center;font-weight:normal;font-size:1em;margin-bottom:3em;}.cover{display:block;max-width:70%;max-height:70vh;margin:1em auto 3em;}p{text-indent:1.2em;margin:.45em 0;}</style>
          </head>
          <body>\(coverMarkup)\(paragraphs)</body>
        </html>
        """

        let folder = URL.temporaryDirectory.appending(path: "LeConteurExports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let baseName = document.title.replacingOccurrences(of: "[^\\p{L}\\p{N} _-]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let url = folder.appending(path: (baseName.isEmpty ? String(localized: "Livre traduit") : baseName) + " – \(language.uppercased()).epub")
        try? FileManager.default.removeItem(at: url)
        let archive = try Archive(url: url, accessMode: .create)
        try add(Data("application/epub+zip".utf8), at: "mimetype", to: archive, compression: .none)
        try add(Data(container.utf8), at: "META-INF/container.xml", to: archive)
        try add(Data(package.utf8), at: "OEBPS/content.opf", to: archive)
        try add(Data(nav.utf8), at: "OEBPS/nav.xhtml", to: archive)
        try add(Data(book.utf8), at: "OEBPS/book.xhtml", to: archive)
        if let coverData { try add(coverData, at: "OEBPS/cover.jpg", to: archive) }
        return url
    }

    private static func add(_ data: Data, at path: String, to archive: Archive, compression: CompressionMethod = .deflate) throws {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: compression) { position, size in
            data.subdata(in: Int(position)..<(Int(position) + size))
        }
    }

    private static func xml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private final class XMLCollector: NSObject, XMLParserDelegate {
    var rootfile: String?
    var items: [String: String] = [:]
    var mediaTypes: [String: String] = [:]
    var coverImageIDs: [String] = []
    var legacyCoverID: String?
    var coverPages: [String] = []
    var images: [String] = []
    var spine: [String] = []
    var text = ""
    var title = ""
    var author = ""
    var language = ""
    var heading = ""
    private var elements: [String] = []
    private var headingElement: String?

    func parse(_ data: Data) throws {
        let parser = XMLParser(data: normalizedXMLData(data))
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse() else { throw ImportFailure.invalidEPUB }
    }

    /// XML defaults to UTF-8, but older EPUB tools sometimes write Windows-1252
    /// punctuation while still declaring UTF-8 (or declaring nothing). XMLParser
    /// accepts those bytes lossily and exposes replacement characters, so recover
    /// the common legacy encoding before parsing.
    private func normalizedXMLData(_ data: Data) -> Data {
        guard String(data: data, encoding: .utf8) == nil,
              !data.starts(with: [0xff, 0xfe]), !data.starts(with: [0xfe, 0xff]) else { return data }

        let prefix = String(decoding: data.prefix(256), as: UTF8.self).lowercased()
        if let declaration = prefix.range(of: "encoding") {
            let suffix = prefix[declaration.upperBound...].prefix(48)
            if !suffix.contains("utf-8") && !suffix.contains("utf8") { return data }
        }
        guard let recovered = String(data: data, encoding: .windowsCP1252) else { return data }
        return Data(recovered.utf8)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        elements.append(name)
        if heading.isEmpty, headingElement == nil, ["h1", "h2", "h3"].contains(name) { headingElement = name }
        if name == "rootfile" { rootfile = attributes["full-path"] }
        if name == "item", let id = attributes["id"], let href = attributes["href"] {
            items[id] = href
            mediaTypes[id] = attributes["media-type"]
            if attributes["properties"]?.split(whereSeparator: \.isWhitespace).contains("cover-image") == true { coverImageIDs.append(id) }
        }
        if name == "meta", attributes["name"]?.lowercased() == "cover" { legacyCoverID = attributes["content"] }
        if name == "reference", attributes["type"]?.split(whereSeparator: \.isWhitespace).contains("cover") == true,
           let href = attributes["href"] { coverPages.append(href) }
        if name == "img", let src = attributes["src"] { images.append(src) }
        if name == "image", let href = attributes["href"] ?? attributes["xlink:href"] { images.append(href) }
        if name == "itemref", attributes["linear"] != "no", let id = attributes["idref"] { spine.append(id) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if elements.last == "title" { title += string }
        if elements.last == "creator" { author += string }
        if elements.last == "language" { language += string }
        if headingElement != nil { heading += string }
        if elements.contains("body"), !elements.contains(where: { ["script", "style", "nav"].contains($0) }) { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        // A line break inside a heading is generally typographic. Keep it inside
        // the same paragraph; block elements still delimit real paragraphs.
        if name == "br" {
            text += "\n"
            if headingElement != nil { heading += " " }
        } else if ["p", "div", "li", "h1", "h2", "h3", "section"].contains(name) {
            text += "\n\n"
        }
        if headingElement == name { headingElement = nil }
        if !elements.isEmpty { elements.removeLast() }
    }
}
