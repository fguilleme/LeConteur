import Foundation
import PDFKit
import ZIPFoundation
import NaturalLanguage
import ImageIO

enum ImportFailure: LocalizedError {
    case empty, tooLarge, unsupported, invalidEPUB, lockedPDF
    var errorDescription: String? {
        switch self {
        case .empty: "Ce document ne contient pas de texte lisible. Pour un PDF scanné, une reconnaissance de caractères est nécessaire."
        case .tooLarge: "Ce document est trop volumineux. La limite est de 50 Mo ou de 2 millions de caractères."
        case .unsupported: "Choisissez un fichier PDF, EPUB sans DRM, TXT ou Markdown."
        case .invalidEPUB: "Ce livre EPUB est endommagé, protégé ou n’utilise pas un format pris en charge."
        case .lockedPDF: "Ce PDF est protégé par un mot de passe. Déverrouillez-le avant de l’importer."
        }
    }
}

enum DocumentImporter {
    static func fromText(_ text: String, title: String, source: String = "TEXTE", author: String = "Texte personnel") throws -> ReadingDocument {
        guard text.count <= 2_000_000 else { throw ImportFailure.tooLarge }
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n[\t ]*\n", with: "\u{001e}", options: .regularExpression)
            .components(separatedBy: "\u{001e}")
        var segments: [String] = []
        var starts: [Int] = []
        for paragraph in paragraphs {
            let parts = TextSegmenter.split(paragraph)
            if !parts.isEmpty { starts.append(segments.count); segments.append(contentsOf: parts) }
        }
        guard !segments.isEmpty else { throw ImportFailure.empty }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var document = ReadingDocument(title: cleanTitle.isEmpty ? String(segments[0].prefix(60)) : cleanTitle,
                               author: author, source: source, segments: segments)
        document.paragraphStarts = starts
        document.languageCode = NLLanguageRecognizer.dominantLanguage(for: String(text.prefix(4000)))?.rawValue
        return document
    }

    static func fromFile(_ url: URL, coverDirectory: URL = BookCoverStore.directory) throws -> ReadingDocument {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        // Coordinate with Files providers so cloud-backed selections finish downloading first.
        var coordinationError: NSError?
        var result: Result<ReadingDocument, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { localURL in
            result = Result { try readFile(localURL, coverDirectory: coverDirectory) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ImportFailure.empty }
        return try result.get()
    }

    private static func readFile(_ url: URL, coverDirectory: URL) throws -> ReadingDocument {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 50_000_000 else { throw ImportFailure.tooLarge }
        var title = url.deletingPathExtension().lastPathComponent
        var author = "Document importé"
        var coverData: Data?
        let text: String
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let pdf = PDFDocument(url: url) else { throw ImportFailure.empty }
            guard !pdf.isLocked else { throw ImportFailure.lockedPDF }
            var pages: [String] = []
            var count = 0
            for index in 0..<pdf.pageCount {
                let page = pdf.page(at: index)?.string ?? ""
                count += page.count
                guard count <= 2_000_000 else { throw ImportFailure.tooLarge }
                pages.append(page)
            }
            text = pages.joined(separator: "\n\n")
            if let name = pdf.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String { author = name }
        case "epub":
            let book = try readEPUB(url)
            text = book.text
            if !book.title.isEmpty { title = book.title }
            if !book.author.isEmpty { author = book.author }
            coverData = book.cover
        case "txt", "md", "markdown":
            let data = try Data(contentsOf: url)
            guard let decoded = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .windowsCP1252) else { throw ImportFailure.empty }
            text = decoded
        default: throw ImportFailure.unsupported
        }
        var document = try fromText(text, title: title, source: url.pathExtension.uppercased(), author: author)
        if let coverData { document.coverFileName = try? BookCoverStore.save(coverData, directory: coverDirectory) }
        return document
    }

    private static func readEPUB(_ url: URL) throws -> (text: String, title: String, author: String, cover: Data?) {
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
        var characterCount = 0
        for id in package.spine {
            guard let href = package.items[id] else { continue }
            guard let path = localPath(href, relativeTo: base) else { throw ImportFailure.invalidEPUB }
            let chapter = XMLCollector()
            try chapter.parse(data(path))
            characterCount += chapter.text.count
            guard characterCount <= 2_000_000 else { throw ImportFailure.tooLarge }
            texts.append(chapter.text)
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
        return (texts.joined(separator: "\n\n"), package.title.trimmingCharacters(in: .whitespacesAndNewlines), package.author.trimmingCharacters(in: .whitespacesAndNewlines), artwork)
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
    private var elements: [String] = []

    func parse(_ data: Data) throws {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse() else { throw ImportFailure.invalidEPUB }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        elements.append(name)
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
        if elements.contains("body"), !elements.contains(where: { ["script", "style", "nav"].contains($0) }) { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if ["p", "div", "br", "li", "h1", "h2", "h3", "section"].contains(elements.last ?? "") { text += "\n\n" }
        if !elements.isEmpty { elements.removeLast() }
    }
}
