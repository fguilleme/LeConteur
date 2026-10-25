import Foundation
import NaturalLanguage
import Observation
import Translation

@MainActor @Observable
final class TranslationCoordinator {
    static var phoneLanguage: String { SystemVoiceSelection.language(Locale.preferredLanguages.first ?? Locale.current.identifier) }
    var configuration: TranslationSession.Configuration?
    private(set) var isTranslating = false {
        didSet { if oldValue != isTranslating { activityChanged(isTranslating) } }
    }
    private(set) var progress: Double = 0
    private(set) var isPreparing = false
    private(set) var status = "Préparation des langues…"
    var readyDocumentID: UUID?
    private(set) var activeDocumentID: UUID?
    var errorMessage: String?
    private var sourceDocument: ReadingDocument?
    private var savedDraft: ReadingDocument?
    private var target = "fr"
    private var source = "fr"
    private var requestID = UUID()
    private var watchdog: Task<Void, Never>?
    private var activeSessionRequest: UUID?
    private var activeSession: TranslationSession?
    private var lastConfiguration: TranslationSession.Configuration?
    private let library: LibraryStore
    private let prepareVoice: () async -> Void
    private let languageStatus: (String, String) async -> LanguageAvailability.Status
    private let fallbackLanguageStatus: (String, String) async -> LanguageAvailability.Status
    private let startupTimeout: Duration
    private let documentUpdated: (UUID) -> Void
    private let activityChanged: (Bool) -> Void

    init(library: LibraryStore,
         startupTimeout: Duration = .seconds(60),
         documentUpdated: @escaping (UUID) -> Void = { _ in },
         activityChanged: @escaping (Bool) -> Void = { _ in },
         prepareVoice: @escaping () async -> Void = { await QwenVoiceRenderer.shared.unload() },
         languageStatus: @escaping (String, String) async -> LanguageAvailability.Status = { source, target in
             let languages: LanguageAvailability
             if #available(iOS 26.4, *) { languages = LanguageAvailability(preferredStrategy: .highFidelity) }
             else { languages = LanguageAvailability() }
             return await languages.status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
         },
         fallbackLanguageStatus: @escaping (String, String) async -> LanguageAvailability.Status = { source, target in
             let languages: LanguageAvailability
             if #available(iOS 26.4, *) { languages = LanguageAvailability(preferredStrategy: .lowLatency) }
             else { languages = LanguageAvailability() }
             return await languages.status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
         }) {
        self.library = library
        self.documentUpdated = documentUpdated
        self.activityChanged = activityChanged
        self.prepareVoice = prepareVoice; self.languageStatus = languageStatus
        self.fallbackLanguageStatus = fallbackLanguageStatus; self.startupTimeout = startupTimeout
    }

    /// Readable passages are published without waiting for the rest of the book.
    func request(_ selection: ReadingDocument, targetLanguage: String) async {
        cancel()
        let request = requestID
        errorMessage = nil
        target = SystemVoiceSelection.language(targetLanguage)
        if selection.resolvedLanguage == target && !selection.isTranslationPending {
            readyDocumentID = selection.id
            return
        }
        // Start from the original, even if the reader currently shows a translation.
        var document = selection
        var seen: Set<UUID> = [document.id]
        while let id = document.translationOf, !seen.contains(id), let original = library.document(id) {
            seen.insert(id)
            document = original
        }
        guard let detected = document.resolvedLanguage else {
            errorMessage = "La langue de ce texte n’a pas pu être détectée. Vous pouvez lire l’original."
            cancel()
            return
        }
        source = SystemVoiceSelection.language(detected)
        guard source != target else { readyDocumentID = document.id; return }
        if let existing = library.documents.first(where: {
            $0.translationOf == document.id && SystemVoiceSelection.language($0.languageCode ?? "und") == target
        }) {
            if !existing.isTranslationPending && existing.isTranslationMetadataComplete { readyDocumentID = existing.id; return }
            savedDraft = existing
            activeDocumentID = existing.id
            readyDocumentID = existing.id
        }
        sourceDocument = document
        isTranslating = true
        isPreparing = true
        progress = 0
        status = "Préparation des langues…"
        armWatchdog(request: request, duration: startupTimeout)
        // Playback is paused by the caller. Do not retain a multi-GB voice beside Translation.
        await prepareVoice()
        guard requestID == request else { return }
        guard !Task.isCancelled else { cancel(); return }
        var availability = await languageStatus(source, target)
        guard requestID == request else { return }
        guard !Task.isCancelled else { cancel(); return }
        // On iOS 26.4+, a high-fidelity availability check only considers Apple
        // Intelligence models. A language such as Russian may still be supported by
        // the traditional models shared with the Translate app. The configured
        // high-fidelity session will automatically fall back to those models.
        if availability == .unsupported {
            availability = await fallbackLanguageStatus(source, target)
            guard requestID == request else { return }
            guard !Task.isCancelled else { cancel(); return }
        }
        guard availability != .unsupported else {
            errorMessage = "Cette paire de langues n’est pas prise en charge par la traduction Apple. L’original reste disponible."
            cancel()
            return
        }
        status = availability == .installed ? "Préparation de la traduction…" : "Installation des langues avec iOS…"
        // The initial language download may take several minutes, but cannot leave the UI
        // waiting forever. Installed languages should start promptly.
        armWatchdog(request: request, duration: availability == .installed ? startupTimeout : .seconds(600))
        var next: TranslationSession.Configuration
        if #available(iOS 26.4, *) {
            next = TranslationSession.Configuration(source: Locale.Language(identifier: source), target: Locale.Language(identifier: target), preferredStrategy: .highFidelity)
        } else {
            next = TranslationSession.Configuration(source: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
        }
        if var previous = lastConfiguration, previous.source == next.source, previous.target == next.target {
            previous.invalidate()
            next = previous
        }
        lastConfiguration = next
        configuration = next
    }

    func translate(using session: TranslationSession) async {
        guard let document = sourceDocument, isTranslating, activeSessionRequest != requestID else { return }
        guard session.sourceLanguage?.languageCode?.identifier == source,
              session.targetLanguage?.languageCode?.identifier == target else { return }
        let request = requestID
        activeSession = session
        activeSessionRequest = request
        let language = target
        do {
            let work = TranslationWork(document: document, source: source, target: language)
            let checkpoint = try TranslationCheckpoint(fingerprint: work.fingerprint)
            var output = checkpoint.load(count: work.blocks.count)
            var draft = savedDraft?.translationComplete == true || savedDraft?.translationFingerprint == work.fingerprint
                ? savedDraft! : work.draft(original: document, language: language)
            activeDocumentID = draft.id
            func publishAvailable() throws {
                guard work.appendAvailable(output, to: &draft) else { return }
                guard library.saveTranslation(draft) else {
                    throw NSError(domain: "Translation", code: 1, userInfo: [NSLocalizedDescriptionKey: library.errorMessage ?? "La traduction n’a pas pu être sauvegardée."])
                }
                library.rememberReading(originalID: document.id, readingID: draft.id)
                if readyDocumentID != draft.id { readyDocumentID = draft.id }
                documentUpdated(draft.id)
            }
            func updateProgress() {
                let completed = output.filter { !$0.isEmpty }.count
                progress = Double(completed) / Double(max(1, output.count))
                status = "\(completed) / \(output.count) passages traduits"
            }
            progress = Double(output.filter { !$0.isEmpty }.count) / Double(max(1, output.count))
            try publishAvailable()
            try await session.prepareTranslation()
            try Task.checkCancellation()
            guard requestID == request else { return }
            if draft.translationTitleComplete != true {
                armWatchdog(request: request)
                let translatedTitle = try await session.translate(document.title)
                    .targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !translatedTitle.isEmpty else { throw TranslationWorkError.incomplete }
                draft.title = translatedTitle
                draft.translationTitleComplete = true
                guard library.saveTranslation(draft) else {
                    throw NSError(domain: "Translation", code: 2, userInfo: [NSLocalizedDescriptionKey: library.errorMessage ?? "Le titre traduit n’a pas pu être sauvegardé."])
                }
                documentUpdated(draft.id)
            }
            if draft.translationAuthorComplete != true {
                armWatchdog(request: request)
                let originalAuthor = document.author.trimmingCharacters(in: .whitespacesAndNewlines)
                if originalAuthor.isEmpty {
                    draft.author = ""
                } else {
                    let translatedAuthor = try await session.translate(originalAuthor)
                        .targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !translatedAuthor.isEmpty else { throw TranslationWorkError.incomplete }
                    draft.author = translatedAuthor
                }
                draft.translationAuthorComplete = true
                guard library.saveTranslation(draft) else {
                    throw NSError(domain: "Translation", code: 3, userInfo: [NSLocalizedDescriptionKey: library.errorMessage ?? "L’auteur traduit n’a pas pu être sauvegardé."])
                }
                documentUpdated(draft.id)
            }
            if draft.translationComplete == true {
                checkpoint.remove()
                cancel()
                readyDocumentID = draft.id
                return
            }
            isPreparing = false
            updateProgress()
            let remaining = work.blocks.indices.filter { output[$0].isEmpty }
            // Small bounded batches release Apple response objects regularly. Results arrive
            // one by one, so progress and checkpoints advance even on a slow paragraph.
            for start in stride(from: 0, to: remaining.count, by: 2) {
                let indices = Array(remaining[start..<min(start + 2, remaining.count)])
                let batch = indices.map { TranslationSession.Request(sourceText: work.blocks[$0].text, clientIdentifier: String($0)) }
                armWatchdog(request: request)
                for try await response in session.translate(batch: batch) {
                    try Task.checkCancellation()
                    guard requestID == request else { return }
                    guard let key = response.clientIdentifier, let index = Int(key), indices.contains(index),
                          !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranslationWorkError.incomplete }
                    try checkpoint.save(response.targetText, at: index)
                    output[index] = response.targetText
                    try publishAvailable()
                    updateProgress()
                    armWatchdog(request: request)
                }
                watchdog?.cancel()
                try Task.checkCancellation()
                guard requestID == request else { return }
                guard indices.allSatisfy({ !output[$0].isEmpty }) else { throw TranslationWorkError.incomplete }
            }
            guard !draft.isTranslationPending else { throw TranslationWorkError.incomplete }
            checkpoint.remove()
            cancel()
            readyDocumentID = draft.id
        } catch {
            guard requestID == request else { return }
            errorMessage = Task.isCancelled || error is CancellationError
                ? "Traduction interrompue. Les passages terminés sont sauvegardés ; relancez la traduction pour reprendre."
                : "La traduction n’a pas abouti : \(error.localizedDescription) Les passages terminés sont sauvegardés."
            cancel()
        }
    }

    private func armWatchdog(request: UUID, duration: Duration = .seconds(90)) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self, self.requestID == request, self.isTranslating else { return }
            self.errorMessage = "La traduction ne répond plus. Vous pouvez lire l’original et réessayer avec Traduire. Les passages terminés sont sauvegardés."
            self.cancel()
        }
    }

    func suspend() {
        guard isTranslating else { return }
        errorMessage = "Traduction mise en pause. Les passages prêts restent lisibles. Touchez Reprendre la traduction pour continuer."
        cancel()
    }

    func cancel() {
        watchdog?.cancel()
        watchdog = nil
        if #available(iOS 26.0, *) { activeSession?.cancel() }
        activeSession = nil
        requestID = UUID()
        activeSessionRequest = nil
        configuration = nil
        isTranslating = false
        isPreparing = false
        sourceDocument = nil
        savedDraft = nil
        activeDocumentID = nil
        readyDocumentID = nil
    }

}
