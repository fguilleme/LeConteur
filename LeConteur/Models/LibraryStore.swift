import Foundation
import Observation
import AVFoundation

private final class LibraryPersistence: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.guilleme.conteur.library-persistence", qos: .utility)

    init(fileURL: URL) { self.fileURL = fileURL }

    func writeSync(_ documents: [ReadingDocument]) throws {
        try queue.sync { try writeSnapshot(documents) }
    }

    func write(_ documents: [ReadingDocument]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try writeSnapshot(documents)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func writeSnapshot(_ documents: [ReadingDocument]) throws {
        let data = try JSONEncoder().encode(documents)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}

private struct LibraryState: Codable {
    var currentDocumentID: UUID?
}

@MainActor @Observable
final class LibraryStore {
    private(set) var documents: [ReadingDocument] = []
    private(set) var currentDocumentID: UUID?
    var errorMessage: String?
    private let fileURL: URL
    private let stateURL: URL
    private let persistence: LibraryPersistence

    init(directory: URL? = nil) {
        let root = directory ?? URL.applicationSupportDirectory.appending(path: "Library", directoryHint: .isDirectory)
        fileURL = root.appending(path: "library.json")
        stateURL = root.appending(path: "library-state.json")
        persistence = LibraryPersistence(fileURL: fileURL)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let loaded = try JSONDecoder().decode([ReadingDocument].self, from: Data(contentsOf: fileURL))
                documents = Self.localizingBuiltInDocuments(in: Self.consolidatingDuplicateTranslations(in: loaded))
                if documents != loaded { save() }
            } else {
                documents = [.welcome]
                save()
            }
        } catch {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let backup = root.appending(path: "library-recovery-\(UUID().uuidString).json")
                try? FileManager.default.copyItem(at: fileURL, to: backup)
            }
            errorMessage = String(format: String(localized: "La bibliothèque n’a pas pu être ouverte. Vos fichiers ont été conservés. %@"), error.localizedDescription)
        }

        if let data = try? Data(contentsOf: stateURL),
           let state = try? JSONDecoder().decode(LibraryState.self, from: data),
           let id = state.currentDocumentID,
           documents.contains(where: { $0.id == id }) {
            currentDocumentID = id
        }
    }

    /// Built-in books follow the app language even when they were created by an
    /// earlier version. Preserve the reader state and stable ID while refreshing
    /// their localized metadata and passages.
    private static func localizingBuiltInDocuments(in documents: [ReadingDocument]) -> [ReadingDocument] {
        var result = documents
        guard let index = result.firstIndex(where: {
            $0.builtInID == "welcome" ||
                ($0.translationOf == nil && $0.source == "DÉCOUVERTE" && $0.title == "Le goût des mots")
        }) else { return result }
        let previous = result[index]
        var localized = ReadingDocument.welcome
        localized.id = previous.id
        localized.importedAt = previous.importedAt
        localized.position = min(previous.position, max(localized.segments.count - 1, 0))
        localized.isFinished = previous.isFinished
        localized.bookmarks = Set(previous.bookmarks.filter { localized.segments.indices.contains($0) })
        localized.preferredReadingID = previous.preferredReadingID
        result[index] = localized
        return result
    }

    /// A source book has one local edition per target language. Older versions of
    /// the progressive translator could create another edition when its block plan
    /// changed. Keep the most advanced edition and merge its reader state.
    private static func consolidatingDuplicateTranslations(in documents: [ReadingDocument]) -> [ReadingDocument] {
        struct TranslationKey: Hashable {
            let originalID: UUID
            let language: String
        }

        let translations = documents.filter { $0.translationOf != nil }
        let groups = Dictionary(grouping: translations) { document in
            TranslationKey(
                originalID: document.translationOf!,
                language: SystemVoiceSelection.language(document.languageCode ?? "und")
            )
        }
        var result = documents
        var replacements: [UUID: UUID] = [:]

        for group in groups.values where group.count > 1 {
            let winner = group.max { lhs, rhs in
                let lhsRank = (lhs.translationComplete == true ? 1 : 0,
                               lhs.translatedBlocks ?? 0,
                               lhs.isTranslationMetadataComplete ? 1 : 0,
                               lhs.importedAt)
                let rhsRank = (rhs.translationComplete == true ? 1 : 0,
                               rhs.translatedBlocks ?? 0,
                               rhs.isTranslationMetadataComplete ? 1 : 0,
                               rhs.importedAt)
                if lhsRank.0 != rhsRank.0 { return lhsRank.0 < rhsRank.0 }
                if lhsRank.1 != rhsRank.1 { return lhsRank.1 < rhsRank.1 }
                if lhsRank.2 != rhsRank.2 { return lhsRank.2 < rhsRank.2 }
                return lhsRank.3 < rhsRank.3
            }!
            let duplicateIDs = Set(group.map(\.id)).subtracting([winner.id])
            var merged = winner
            merged.bookmarks.formUnion(group.flatMap(\.bookmarks))
            merged.position = min(group.map(\.position).max() ?? winner.position,
                                  max(winner.segments.count - 1, 0))
            for duplicateID in duplicateIDs { replacements[duplicateID] = winner.id }
            result.removeAll { duplicateIDs.contains($0.id) }
            if let index = result.firstIndex(where: { $0.id == winner.id }) { result[index] = merged }
        }

        for index in result.indices {
            if let preferred = result[index].preferredReadingID,
               let replacement = replacements[preferred] {
                result[index].preferredReadingID = replacement
            }
        }
        return result
    }

    func document(_ id: UUID) -> ReadingDocument? { documents.first { $0.id == id } }

    /// Remember the edition most recently opened by the reader. This state is
    /// intentionally separate from playback: relaunching restores the title and
    /// position without starting audio automatically.
    @discardableResult func rememberCurrentDocument(_ id: UUID) -> Bool {
        guard document(id) != nil else { return false }
        guard currentDocumentID != id else { return true }
        let previous = currentDocumentID
        currentDocumentID = id
        guard saveState() else {
            currentDocumentID = previous
            return false
        }
        return true
    }

    /// The home card follows the edition currently owned by the player, including
    /// a newly opened book at position zero or a progressive translation. When no
    /// reader is active, retain the library's usual first-in-progress fallback.
    func featuredDocument(activeID: UUID?) -> ReadingDocument? {
        if let activeID, let active = document(activeID), !active.isFinished {
            return active
        }
        if let currentDocumentID, let current = document(currentDocumentID), !current.isFinished {
            return current
        }
        return documents.first(where: { $0.position > 0 && !$0.isFinished }) ?? documents.first
    }

    /// Library entries select an edition, not the last-used language. Offer automatic
    /// translation only until the original has a saved edition or a remembered opt-out.
    /// Selecting an unfinished translation resumes that edition directly.
    func readingRoute(for document: ReadingDocument, phoneLanguage: String) -> (document: ReadingDocument, translate: Bool) {
        let current = self.document(document.id) ?? document
        if current.translationOf != nil { return (current, current.isTranslationPending) }
        if documents.contains(where: { $0.translationOf == current.id }) { return (current, false) }
        guard let source = current.resolvedLanguage, source != phoneLanguage,
              current.preferredReadingID != current.id else { return (current, false) }
        return (current, true)
    }

    func rememberReading(originalID: UUID, readingID: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == originalID }),
              documents[index].preferredReadingID != readingID else { return }
        documents[index].preferredReadingID = readingID
        save()
    }

    /// Resolve a concurrent translation attempt to the edition already present
    /// in the library. This is a final invariant at the persistence boundary in
    /// addition to the coordinator's stable draft identifier.
    func canonicalTranslation(_ draft: ReadingDocument) -> ReadingDocument {
        guard let originalID = draft.translationOf else { return draft }
        let language = SystemVoiceSelection.language(draft.languageCode ?? "und")
        guard let existing = documents.first(where: {
            $0.id != draft.id && $0.translationOf == originalID
                && SystemVoiceSelection.language($0.languageCode ?? "und") == language
        }) else { return draft }
        var canonical = draft
        canonical.id = existing.id
        canonical.importedAt = existing.importedAt
        canonical.position = existing.position
        canonical.bookmarks.formUnion(existing.bookmarks)
        canonical.coverFileName = canonical.coverFileName ?? existing.coverFileName
        return canonical
    }

    @discardableResult func saveTranslation(_ draft: ReadingDocument) -> Bool {
        let draft = canonicalTranslation(draft)
        guard let index = documents.firstIndex(where: { $0.id == draft.id }) else { return add(draft) }
        let previous = documents[index]
        var updated = draft
        updated.position = previous.position
        updated.bookmarks = previous.bookmarks
        updated.coverFileName = draft.coverFileName ?? previous.coverFileName
        updated.isFinished = previous.isFinished && !updated.isTranslationPending
        documents[index] = updated
        guard save() else { documents[index] = previous; return false }
        return true
    }

    /// Translation publishes frequently. Keep observable state on the main actor,
    /// but serialize the expensive full-library encoding and atomic write elsewhere.
    @discardableResult func saveTranslationWithoutBlocking(_ draft: ReadingDocument) async -> Bool {
        let draft = canonicalTranslation(draft)
        if let index = documents.firstIndex(where: { $0.id == draft.id }) {
            let previous = documents[index]
            var updated = draft
            updated.position = previous.position
            updated.bookmarks = previous.bookmarks
            updated.coverFileName = draft.coverFileName ?? previous.coverFileName
            updated.isFinished = previous.isFinished && !updated.isTranslationPending
            documents[index] = updated
        } else {
            documents.insert(draft, at: 0)
        }
        let snapshot = documents
        do {
            try await persistence.write(snapshot)
            return true
        } catch {
            errorMessage = String(format: String(localized: "La sauvegarde locale a échoué : %@"), error.localizedDescription)
            return false
        }
    }

    @discardableResult func add(_ document: ReadingDocument) -> Bool {
        documents.insert(document, at: 0)
        guard save() else { documents.removeAll { $0.id == document.id }; return false }
        return true
    }

    /// Reimporting an old EPUB can refresh repaired metadata or recover its artwork
    /// without duplicating the book or losing reading progress. Translations share
    /// the same local image.
    func importDocument(_ document: ReadingDocument) -> ReadingDocument? {
        if document.source == "EPUB", let index = documents.firstIndex(where: {
            $0.source == "EPUB" && $0.segments == document.segments
        }) {
            let previous = documents
            documents[index].title = document.title
            documents[index].author = document.author
            documents[index].languageCode = document.languageCode
            if let cover = document.coverFileName {
                let originalID = documents[index].id
                documents[index].coverFileName = cover
                for translated in documents.indices where documents[translated].translationOf == originalID {
                    documents[translated].coverFileName = cover
                }
            }
            guard save() else { documents = previous; return nil }
            return documents[index]
        }
        return add(document) ? document : nil
    }

    func updatePosition(id: UUID, position: Int, finished: Bool = false) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].position = min(max(position, 0), max(documents[index].segments.count - 1, 0))
        documents[index].isFinished = finished
        save()
    }

    func toggleBookmark(id: UUID, position: Int) {
        guard let index = documents.firstIndex(where: { $0.id == id }), documents[index].segments.indices.contains(position) else { return }
        if documents[index].bookmarks.contains(position) {
            documents[index].bookmarks.remove(position)
        } else {
            documents[index].bookmarks.insert(position)
        }
        save()
    }

    func delete(_ id: UUID) {
        documents.removeAll { $0.id == id }
        save()
        if currentDocumentID == id {
            currentDocumentID = nil
            saveState()
        }
    }

    @discardableResult private func saveState() -> Bool {
        do {
            let data = try JSONEncoder().encode(LibraryState(currentDocumentID: currentDocumentID))
            try data.write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var url = stateURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            return true
        } catch {
            errorMessage = String(format: String(localized: "La sauvegarde locale a échoué : %@"), error.localizedDescription)
            return false
        }
    }

    @discardableResult private func save() -> Bool {
        do {
            try persistence.writeSync(documents)
            return true
        } catch {
            errorMessage = String(format: String(localized: "La sauvegarde locale a échoué : %@"), error.localizedDescription)
            return false
        }
    }
}

enum VoiceFeatures {
    #if CONTEUR_QWEN
    static let qwenEnabled = true
    #else
    static let qwenEnabled = false
    #endif
}

enum VoiceEngine: String, CaseIterable, Identifiable {
    case system, supertonic, qwen
    var id: String { rawValue }
    var name: String {
        switch self {
        case .system: String(localized: "Voix iPhone")
        case .supertonic: String(localized: "Supertonic · Temps réel")
        case .qwen: String(localized: "Qwen · Expressif")
        }
    }
}

@MainActor @Observable
final class ReaderSettings {
    private let defaults: UserDefaults
    var engine: VoiceEngine { didSet { defaults.set(engine.rawValue, forKey: "voice.engine") } }
    var qwenStyle: NarrationStyle { didSet { defaults.set(qwenStyle.rawValue, forKey: "voice.qwenStyle") } }
    var qwenSpeaker: QwenSpeaker { didSet { defaults.set(qwenSpeaker.rawValue, forKey: "voice.qwenSpeaker") } }
    var qwenBuffer: QwenBufferPreset { didSet { defaults.set(qwenBuffer.rawValue, forKey: "voice.qwenBuffer") } }
    var supertonicVoice: SupertonicVoice { didSet { defaults.set(supertonicVoice.rawValue, forKey: "voice.supertonicVoice") } }
    private(set) var systemVoiceIDs: [String: String] {
        didSet { defaults.set(systemVoiceIDs, forKey: "voice.identifiersByLanguage") }
    }
    var speed: Double { didSet { defaults.set(speed, forKey: "voice.speed") } }
    var qwenSpeed: Double { didSet { defaults.set(qwenSpeed, forKey: "voice.qwenSpeed") } }
    var textSize: Double { didSet { defaults.set(textSize, forKey: "reader.textSize") } }

    func systemVoiceID(for language: String) -> String {
        systemVoiceIDs[SystemVoiceSelection.language(language)] ?? ""
    }

    func preferSystemVoice(_ identifier: String, for language: String) {
        let key = SystemVoiceSelection.language(language)
        if identifier.isEmpty { systemVoiceIDs.removeValue(forKey: key) }
        else { systemVoiceIDs[key] = identifier }
    }

    init(defaults: UserDefaults = .standard,
         qwenEnabled: Bool = VoiceFeatures.qwenEnabled,
         legacyVoiceLanguage: (String) -> String? = { AVSpeechSynthesisVoice(identifier: $0)?.language }) {
        self.defaults = defaults
        let savedEngine = defaults.string(forKey: "voice.engine") ?? ""
        let restoredEngine: VoiceEngine
        if savedEngine.isEmpty {
            restoredEngine = .supertonic
        } else {
            restoredEngine = VoiceEngine(rawValue: savedEngine) ?? .system
        }
        let resolvedEngine: VoiceEngine
        if restoredEngine == .qwen, !qwenEnabled {
            resolvedEngine = (try? SupertonicManifest.bundled()).map { SupertonicModel.isInstalled($0) } == true ? .supertonic : .system
            defaults.set(resolvedEngine.rawValue, forKey: "voice.engine")
        } else {
            resolvedEngine = restoredEngine
        }
        engine = resolvedEngine
        if savedEngine.isEmpty || savedEngine == "neural" {
            defaults.set(resolvedEngine.rawValue, forKey: "voice.engine")
        }
        Self.removeLegacySiwisModel()
        qwenStyle = NarrationStyle(rawValue: defaults.string(forKey: "voice.qwenStyle") ?? "") ?? .warm
        qwenSpeaker = QwenSpeaker(rawValue: defaults.string(forKey: "voice.qwenSpeaker") ?? "") ?? .ryan
        qwenBuffer = QwenBufferPreset(rawValue: defaults.string(forKey: "voice.qwenBuffer") ?? "") ?? .automatic
        supertonicVoice = SupertonicVoice(rawValue: defaults.string(forKey: "voice.supertonicVoice") ?? "") ?? .female
        if let saved = defaults.dictionary(forKey: "voice.identifiersByLanguage") as? [String: String] {
            systemVoiceIDs = saved
        } else {
            // Migrate the existing choice once, without resurrecting it after
            // the user later switches that language back to Automatic.
            var migrated: [String: String] = [:]
            if let old = defaults.string(forKey: "voice.identifier"), !old.isEmpty,
               let language = legacyVoiceLanguage(old) {
                migrated[SystemVoiceSelection.language(language)] = old
            }
            systemVoiceIDs = migrated
            defaults.set(migrated, forKey: "voice.identifiersByLanguage")
        }
        speed = defaults.object(forKey: "voice.speed") as? Double ?? 1
        qwenSpeed = QwenStreamPlayer.clampedRate(defaults.object(forKey: "voice.qwenSpeed") as? Double ?? 2)
        textSize = defaults.object(forKey: "reader.textSize") as? Double ?? 22
    }

    private static func removeLegacySiwisModel() {
        let directory = URL.applicationSupportDirectory.appending(path: "Voices", directoryHint: .isDirectory)
        for name in ["fr_FR-siwis-medium.onnx", "verified.sha256"] {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }
}
