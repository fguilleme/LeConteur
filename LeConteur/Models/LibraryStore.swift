import Foundation
import Observation
import AVFoundation

@MainActor @Observable
final class LibraryStore {
    private(set) var documents: [ReadingDocument] = []
    var errorMessage: String?
    private let fileURL: URL

    init(directory: URL? = nil) {
        let root = directory ?? URL.applicationSupportDirectory.appending(path: "Library", directoryHint: .isDirectory)
        fileURL = root.appending(path: "library.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                documents = try JSONDecoder().decode([ReadingDocument].self, from: Data(contentsOf: fileURL))
            } else {
                documents = [.welcome]
                save()
            }
        } catch {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let backup = root.appending(path: "library-recovery-\(UUID().uuidString).json")
                try? FileManager.default.copyItem(at: fileURL, to: backup)
            }
            errorMessage = "La bibliothèque n’a pas pu être ouverte. Vos fichiers ont été conservés. \(error.localizedDescription)"
        }
    }

    func document(_ id: UUID) -> ReadingDocument? { documents.first { $0.id == id } }

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

    @discardableResult func saveTranslation(_ draft: ReadingDocument) -> Bool {
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

    @discardableResult func add(_ document: ReadingDocument) -> Bool {
        documents.insert(document, at: 0)
        guard save() else { documents.removeAll { $0.id == document.id }; return false }
        return true
    }

    /// Reimporting an old EPUB can recover its artwork without duplicating the book
    /// or losing reading progress. Translations share the same local image.
    func importDocument(_ document: ReadingDocument) -> ReadingDocument? {
        if document.source == "EPUB", let index = documents.firstIndex(where: {
            $0.source == "EPUB" && $0.title == document.title && $0.author == document.author && $0.segments == document.segments
        }) {
            let previous = documents
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
    }

    @discardableResult private func save() -> Bool {
        do {
            let data = try JSONEncoder().encode(documents)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var url = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            return true
        } catch {
            errorMessage = "La sauvegarde locale a échoué : \(error.localizedDescription)"
            return false
        }
    }
}

enum VoiceEngine: String, CaseIterable, Identifiable {
    case system, neural, qwen
    var id: String { rawValue }
    var name: String {
        switch self {
        case .system: "Voix iPhone"
        case .neural: "Siwis"
        case .qwen: "Qwen · Expressif"
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
         legacyVoiceLanguage: (String) -> String? = { AVSpeechSynthesisVoice(identifier: $0)?.language }) {
        self.defaults = defaults
        engine = VoiceEngine(rawValue: defaults.string(forKey: "voice.engine") ?? "") ?? .system
        qwenStyle = NarrationStyle(rawValue: defaults.string(forKey: "voice.qwenStyle") ?? "") ?? .warm
        qwenSpeaker = QwenSpeaker(rawValue: defaults.string(forKey: "voice.qwenSpeaker") ?? "") ?? .ryan
        qwenBuffer = QwenBufferPreset(rawValue: defaults.string(forKey: "voice.qwenBuffer") ?? "") ?? .automatic
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
}
