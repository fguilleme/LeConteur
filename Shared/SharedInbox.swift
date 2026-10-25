import Foundation

enum SharedInbox {
    static let groupIdentifier = "group.com.guilleme.conteur"
    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)?
            .appending(path: "Inbox", directoryHint: .isDirectory)
    }

    static func stage(_ source: URL, suggestedName: String? = nil) throws {
        guard let directory else {
            throw NSError(domain: "LeConteur", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Le partage n’est pas configuré. Activez le groupe d’applications dans les deux cibles Xcode.")])
        }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 50_000_000 else {
            throw NSError(domain: "LeConteur", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "La limite d’import est de 50 Mo.")])
        }
        let name = URL(fileURLWithPath: suggestedName ?? source.lastPathComponent).lastPathComponent
        guard ["epub", "pdf", "docx", "txt", "md", "markdown"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()) else {
            throw NSError(domain: "LeConteur", code: 3, userInfo: [NSLocalizedDescriptionKey: String(localized: "Choisissez un fichier EPUB, PDF, DOCX, TXT ou Markdown.")])
        }
        let id = UUID().uuidString
        let staging = directory.appending(path: ".pending-\(id)", directoryHint: .isDirectory)
        let destination = directory.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging.appending(path: name))
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var inbox = directory
        try inbox.setResourceValues(values)
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    static func pendingFiles() throws -> [URL] {
        guard let directory, FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        return try folders.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) }
    }
}
