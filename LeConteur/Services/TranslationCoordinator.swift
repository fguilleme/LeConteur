import Foundation
import NaturalLanguage
import Observation
import Translation
import UIKit

@MainActor @Observable
final class TranslationCoordinator {
    static var phoneLanguage: String { SystemVoiceSelection.language(Locale.preferredLanguages.first ?? Locale.current.identifier) }
    static var phoneTranslationLanguage: String { SystemVoiceSelection.localeIdentifier(Locale.preferredLanguages.first ?? Locale.current.identifier) }
    var configuration: TranslationSession.Configuration?
    private(set) var isTranslating = false {
        didSet { if oldValue != isTranslating { activityChanged(isTranslating) } }
    }
    private(set) var progress: Double = 0
    private(set) var isPreparing = false
    private(set) var isInstallingLanguages = false
    private(set) var preparationProgress: Double = 0
    private(set) var status = String(localized: "Préparation des langues…")
    var readyDocumentID: UUID?
    private(set) var activeDocumentID: UUID?
    var errorMessage: String?
    private var sourceDocument: ReadingDocument?
    private var savedDraft: ReadingDocument?
    private var translationDraftID: UUID?
    private var target = "fr"
    private var source = "fr"
    private var requestID = UUID()
    private var watchdog: Task<Void, Never>?
    private var activeSessionRequest: UUID?
    private var activeSessionToken: UUID?
    private var activeSession: TranslationSession?
    private var lastConfiguration: TranslationSession.Configuration?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var resumeAfterBackground = false
    private var isInBackground = false
    private var translatedSinceProgressUpdate = 0
    @ObservationIgnored private var interfaceIsScrolling = false
    private let library: LibraryStore
    private let prepareVoice: () async -> Void
    private let languageStatus: (String, String) async -> LanguageAvailability.Status
    private let fallbackLanguageStatus: (String, String) async -> LanguageAvailability.Status
    private let startupTimeout: Duration
    private let languageInstallationTimeout: Duration
    private let documentUpdated: (UUID) -> Void
    private let activityChanged: (Bool) -> Void

    init(library: LibraryStore,
         startupTimeout: Duration = .seconds(60),
         languageInstallationTimeout: Duration = .seconds(300),
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
        self.languageInstallationTimeout = languageInstallationTimeout
    }

    /// Readable passages are published without waiting for the rest of the book.
    func request(_ selection: ReadingDocument, targetLanguage: String) async {
        let wasUsingSession = activeSession != nil
        cancel()
        let request = requestID
        if wasUsingSession {
            // Let the cancelled Translation framework task leave its inference
            // call before SwiftUI creates a replacement session. Starting both
            // at once can trip an internal framework assertion.
            try? await Task.sleep(for: .milliseconds(150))
            guard requestID == request, !Task.isCancelled else { return }
        }
        errorMessage = nil
        target = SystemVoiceSelection.localeIdentifier(targetLanguage)
        let targetBaseLanguage = SystemVoiceSelection.language(target)
        if selection.resolvedLanguage == targetBaseLanguage && !selection.isTranslationPending {
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
            errorMessage = String(localized: "La langue de ce texte n’a pas pu être détectée. Vous pouvez lire l’original.")
            cancel()
            return
        }
        source = SystemVoiceSelection.localeIdentifier(document.languageCode ?? detected)
        guard SystemVoiceSelection.language(source) != targetBaseLanguage else { readyDocumentID = document.id; return }
        if let existing = library.documents.first(where: {
            $0.translationOf == document.id && SystemVoiceSelection.language($0.languageCode ?? "und") == targetBaseLanguage
        }) {
            if !existing.isTranslationPending && existing.isTranslationMetadataComplete { readyDocumentID = existing.id; return }
            savedDraft = existing
            translationDraftID = existing.id
            activeDocumentID = existing.id
            readyDocumentID = existing.id
        }
        if translationDraftID == nil { translationDraftID = UUID() }
        sourceDocument = document
        isTranslating = true
        isPreparing = true
        progress = 0
        isInstallingLanguages = false
        preparationProgress = 0.05
        status = String(localized: "Préparation des langues…")
        armWatchdog(request: request, duration: startupTimeout)
        // Playback is paused by the caller. Do not retain a multi-GB voice beside Translation.
        await prepareVoice()
        guard requestID == request else { return }
        guard !Task.isCancelled else { cancel(); return }
        preparationProgress = 0.15
        var useLowLatency = false
        let availability: LanguageAvailability.Status
        if #available(iOS 26.4, *) {
            // A whole book is sustained background work, not an isolated sentence.
            // Prefer Apple's smaller low-latency model even when the high-fidelity
            // model is installed: it leaves substantially more CPU/GPU time to the UI.
            let lowLatencyAvailability = await fallbackLanguageStatus(source, target)
            guard requestID == request else { return }
            guard !Task.isCancelled else { cancel(); return }
            preparationProgress = 0.25
            if lowLatencyAvailability != .unsupported {
                availability = lowLatencyAvailability
                useLowLatency = true
            } else {
                availability = await languageStatus(source, target)
                guard requestID == request else { return }
                guard !Task.isCancelled else { cancel(); return }
            }
        } else {
            let primaryAvailability = await languageStatus(source, target)
            guard requestID == request else { return }
            guard !Task.isCancelled else { cancel(); return }
            preparationProgress = 0.25
            if primaryAvailability == .unsupported {
                availability = await fallbackLanguageStatus(source, target)
                guard requestID == request else { return }
                guard !Task.isCancelled else { cancel(); return }
            } else {
                availability = primaryAvailability
            }
        }
        preparationProgress = 0.35
        guard availability != .unsupported else {
            errorMessage = String(localized: "Cette paire de langues n’est pas prise en charge par la traduction Apple. L’original reste disponible.")
            cancel()
            return
        }
        #if DEBUG
        print("[Translation] request source=\(source) target=\(target) availability=\(availability) lowLatency=\(useLowLatency)")
        #endif
        isInstallingLanguages = availability != .installed
        status = isInstallingLanguages ? String(localized: "Installation des langues avec iOS…") : String(localized: "Préparation de la traduction…")
        // The initial language download may take several minutes, but cannot leave the UI
        // waiting forever. Installed languages should start promptly.
        armWatchdog(
            request: request,
            duration: availability == .installed ? startupTimeout : languageInstallationTimeout,
            message: availability == .installed ? nil : String(localized: "L’installation des langues par iOS prend trop de temps. Ouvrez Réglages › Apps › Traduire › Langues téléchargées, installez les deux langues, puis réessayez.")
        )
        var next: TranslationSession.Configuration
        if #available(iOS 26.4, *) {
            next = TranslationSession.Configuration(source: Locale.Language(identifier: source), target: Locale.Language(identifier: target), preferredStrategy: useLowLatency ? .lowLatency : .highFidelity)
        } else {
            next = TranslationSession.Configuration(source: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
        }
        if var previous = lastConfiguration, previous.source == next.source, previous.target == next.target {
            previous.invalidate()
            next = previous
        }
        lastConfiguration = next
        configuration = next
        preparationProgress = 0.45
    }

    func translate(using session: TranslationSession) async {
        guard let document = sourceDocument, isTranslating, activeSessionRequest != requestID else { return }
        guard session.sourceLanguage?.languageCode?.identifier == SystemVoiceSelection.language(source),
              session.targetLanguage?.languageCode?.identifier == SystemVoiceSelection.language(target) else { return }
        let request = requestID
        let sessionToken = UUID()
        activeSession = session
        activeSessionRequest = request
        activeSessionToken = sessionToken
        #if DEBUG
        if #available(iOS 26.4, *) {
            print("[Translation] session source=\(String(describing: session.sourceLanguage)) target=\(String(describing: session.targetLanguage)) canRequestDownloads=\(session.canRequestDownloads) strategy=\(session.preferredStrategy)")
        } else if #available(iOS 26.0, *) {
            print("[Translation] session source=\(String(describing: session.sourceLanguage)) target=\(String(describing: session.targetLanguage)) canRequestDownloads=\(session.canRequestDownloads)")
        } else {
            print("[Translation] session source=\(String(describing: session.sourceLanguage)) target=\(String(describing: session.targetLanguage))")
        }
        #endif
        preparationProgress = max(preparationProgress, 0.5)
        let language = target
        let sourceLanguage = source
        do {
            let work = await Task.detached(priority: .utility) {
                TranslationWork(document: document, source: sourceLanguage, target: language)
            }.value
            let checkpoint = try TranslationCheckpoint(fingerprint: work.fingerprint)
            var output = await Task.detached(priority: .utility) {
                checkpoint.load(count: work.blocks.count)
            }.value
            guard requestID == request, activeSessionToken == sessionToken else { return }
            // A changed block plan invalidates old translated segments, not the
            // library edition itself. Restart inside the existing document so a
            // resume never creates a duplicate row.
            var draft: ReadingDocument
            if let savedDraft, savedDraft.translationFingerprint == work.fingerprint {
                draft = savedDraft
            } else {
                draft = work.draft(original: document, language: language, replacing: savedDraft)
            }
            draft.id = translationDraftID ?? draft.id
            draft = library.canonicalTranslation(draft)
            translationDraftID = draft.id
            activeDocumentID = draft.id
            func publishAvailable() async throws {
                guard requestID == request, activeSessionToken == sessionToken else { throw CancellationError() }
                guard work.appendAvailable(output, to: &draft) else { return }
                draft = library.canonicalTranslation(draft)
                translationDraftID = draft.id
                activeDocumentID = draft.id
                guard await library.saveTranslationWithoutBlocking(draft) else {
                    throw NSError(domain: "Translation", code: 1, userInfo: [NSLocalizedDescriptionKey: library.errorMessage ?? String(localized: "La traduction n’a pas pu être sauvegardée.")])
                }
                library.rememberReading(originalID: document.id, readingID: draft.id)
                if readyDocumentID != draft.id { readyDocumentID = draft.id }
                preparationProgress = 1
                documentUpdated(draft.id)
            }
            func updateProgress() {
                let completed = output.filter { !$0.isEmpty }.count
                progress = Double(completed) / Double(max(1, output.count))
                status = String(format: String(localized: "%lld / %lld passages traduits"), Int64(completed), Int64(output.count))
            }
            progress = Double(output.filter { !$0.isEmpty }.count) / Double(max(1, output.count))
            try await publishAvailable()
            guard requestID == request, activeSessionToken == sessionToken else { return }
            try await session.prepareTranslation()
            #if DEBUG
            print("[Translation] prepareTranslation completed")
            #endif
            try Task.checkCancellation()
            guard requestID == request, activeSessionToken == sessionToken else { return }
            isInstallingLanguages = false
            status = String(localized: "Préparation de la traduction…")
            preparationProgress = max(preparationProgress, 0.65)
            if draft.translationTitleComplete != true {
                try await waitForInterfaceIdle(request: request)
                guard requestID == request, activeSessionToken == sessionToken else { return }
                armWatchdog(request: request)
                let translatedTitle = try await session.translate(document.title)
                    .targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard requestID == request, activeSessionToken == sessionToken else { return }
                guard !translatedTitle.isEmpty else { throw TranslationWorkError.incomplete }
                draft.title = translatedTitle
                draft.translationTitleComplete = true
                guard await library.saveTranslationWithoutBlocking(draft) else {
                    throw NSError(domain: "Translation", code: 2, userInfo: [NSLocalizedDescriptionKey: library.errorMessage ?? String(localized: "Le titre traduit n’a pas pu être sauvegardé.")])
                }
                documentUpdated(draft.id)
                preparationProgress = max(preparationProgress, 0.75)
                try await Task.sleep(for: .milliseconds(80))
            }
            if draft.translationAuthorComplete != true {
                try await waitForInterfaceIdle(request: request)
                guard requestID == request, activeSessionToken == sessionToken else { return }
                armWatchdog(request: request)
                let originalAuthor = document.author.trimmingCharacters(in: .whitespacesAndNewlines)
                if originalAuthor.isEmpty {
                    draft.author = ""
                } else {
                    let translatedAuthor = try await session.translate(originalAuthor)
                        .targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard requestID == request, activeSessionToken == sessionToken else { return }
                    guard !translatedAuthor.isEmpty else { throw TranslationWorkError.incomplete }
                    draft.author = translatedAuthor
                }
                draft.translationAuthorComplete = true
                guard await library.saveTranslationWithoutBlocking(draft) else {
                    throw NSError(domain: "Translation", code: 3, userInfo: [NSLocalizedDescriptionKey: library.errorMessage ?? String(localized: "L’auteur traduit n’a pas pu être sauvegardé.")])
                }
                documentUpdated(draft.id)
                preparationProgress = max(preparationProgress, 0.85)
                try await Task.sleep(for: .milliseconds(80))
            }
            if draft.translationComplete == true {
                checkpoint.remove()
                cancel()
                readyDocumentID = draft.id
                return
            }
            isPreparing = false
            translatedSinceProgressUpdate = 0
            updateProgress()
            let remaining = work.blocks.indices.filter { output[$0].isEmpty }
            // Translate one block at a time at utility priority. Brief gaps let scrolling,
            // speech highlighting and gestures win over sustained model inference.
            for index in remaining {
                try await waitForInterfaceIdle(request: request)
                guard requestID == request, activeSessionToken == sessionToken else { return }
                armWatchdog(request: request)
                let inferenceStarted = ContinuousClock.now
                let response = try await session.translate(work.blocks[index].text)
                let inferenceDuration = inferenceStarted.duration(to: .now)
                try Task.checkCancellation()
                guard requestID == request, activeSessionToken == sessionToken else { return }
                let translatedText = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !translatedText.isEmpty else { throw TranslationWorkError.incomplete }
                try await Task.detached(priority: .utility) {
                    try checkpoint.save(translatedText, at: index)
                }.value
                output[index] = translatedText
                let contiguous = output.prefix { !$0.isEmpty }.count
                let unpublished = contiguous - (draft.translatedBlocks ?? 0)
                if unpublished >= 8 || (draft.translatedBlocks ?? 0) == 0 || contiguous == output.count {
                    try await publishAvailable()
                }
                translatedSinceProgressUpdate += 1
                if unpublished >= 8 || contiguous == output.count || translatedSinceProgressUpdate >= 3 {
                    updateProgress()
                    translatedSinceProgressUpdate = 0
                }
                armWatchdog(request: request)
                let cooldown = isInBackground
                    ? Duration.milliseconds(100)
                    : TranslationInferencePacer.cooldown(after: inferenceDuration)
                try await Task.sleep(for: cooldown)
                watchdog?.cancel()
            }
            try await publishAvailable()
            guard !draft.isTranslationPending else { throw TranslationWorkError.incomplete }
            checkpoint.remove()
            cancel()
            readyDocumentID = draft.id
        } catch {
            #if DEBUG
            print("[Translation] failed: \(String(reflecting: error))")
            #endif
            guard requestID == request, activeSessionToken == sessionToken else { return }
            if isInBackground {
                errorMessage = nil
                deferTranslationUntilForeground()
                return
            }
            errorMessage = Task.isCancelled || error is CancellationError
                ? String(localized: "Traduction interrompue. Les passages terminés sont sauvegardés ; relancez la traduction pour reprendre.")
                : String(format: String(localized: "La traduction n’a pas abouti : %@ Les passages terminés sont sauvegardés."), error.localizedDescription)
            cancel()
        }
    }

    /// Apple Translation can briefly monopolize enough CPU/GPU time to make a
    /// SwiftUI scroll hitch. Do not start another inference while the user's
    /// finger is down or the scroll view is decelerating. The current small
    /// block is allowed to finish, then translation waits for a stable idle.
    func setInterfaceScrolling(_ isScrolling: Bool) {
        interfaceIsScrolling = isScrolling
    }

    private func waitForInterfaceIdle(request: UUID) async throws {
        try Task.checkCancellation()
        guard requestID == request else { throw CancellationError() }
        var didWait = false
        while interfaceIsScrolling {
            didWait = true
            try Task.checkCancellation()
            guard requestID == request else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(50))
        }
        if didWait {
            // Avoid restarting model work during the final layout frames after
            // momentum scrolling has stopped.
            try await Task.sleep(for: .milliseconds(120))
        }
    }

    private func armWatchdog(request: UUID, duration: Duration = .seconds(90), message: String? = nil) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self, self.requestID == request, self.isTranslating else { return }
            self.errorMessage = message ?? String(localized: "La traduction ne répond plus. Vous pouvez lire l’original et réessayer avec Traduire. Les passages terminés sont sauvegardés.")
            self.cancel()
        }
    }

    func suspend() {
        guard isTranslating else { return }
        errorMessage = String(localized: "Traduction mise en pause. Les passages prêts restent lisibles. Touchez Reprendre la traduction pour continuer.")
        cancel()
    }

    /// Keep the current Translation session alive for the finite grace period iOS
    /// grants when the user briefly switches apps. If that time expires, preserve
    /// the checkpoint and restart automatically when Le Conteur becomes active.
    func applicationDidEnterBackground() {
        isInBackground = true
        guard isTranslating, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Book translation") { [weak self] in
            Task { @MainActor in self?.deferTranslationUntilForeground() }
        }
    }

    func applicationDidBecomeActive() {
        isInBackground = false
        finishBackgroundTask()
        guard resumeAfterBackground, let document = sourceDocument else { return }
        let language = target
        resumeAfterBackground = false
        Task { await request(document, targetLanguage: language) }
    }

    /// The visible reader owns the session so iOS can present its language-download UI.
    /// If the reader closes, invalidate the configuration so the root view takes over
    /// without treating cancellation of the old view-bound session as a translation error.
    func handoffSessionToBackground() {
        guard isTranslating, var next = configuration else { return }
        watchdog?.cancel()
        watchdog = nil
        if #available(iOS 26.0, *) { activeSession?.cancel() }
        activeSession = nil
        activeSessionRequest = nil
        activeSessionToken = nil
        next.invalidate()
        lastConfiguration = next
        configuration = next
        armWatchdog(request: requestID)
    }

    private func deferTranslationUntilForeground() {
        guard isTranslating else { finishBackgroundTask(); return }
        resumeAfterBackground = true
        watchdog?.cancel()
        watchdog = nil
        if #available(iOS 26.0, *) { activeSession?.cancel() }
        activeSession = nil
        requestID = UUID()
        activeSessionRequest = nil
        activeSessionToken = nil
        configuration = nil
        isTranslating = false
        isPreparing = false
        isInstallingLanguages = false
        preparationProgress = 0
        activeDocumentID = nil
        finishBackgroundTask()
    }

    private func finishBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    func cancel() {
        finishBackgroundTask()
        watchdog?.cancel()
        watchdog = nil
        if #available(iOS 26.0, *) { activeSession?.cancel() }
        activeSession = nil
        requestID = UUID()
        activeSessionRequest = nil
        activeSessionToken = nil
        configuration = nil
        isTranslating = false
        isPreparing = false
        isInstallingLanguages = false
        preparationProgress = 0
        sourceDocument = nil
        savedDraft = nil
        translationDraftID = nil
        activeDocumentID = nil
        readyDocumentID = nil
        resumeAfterBackground = false
    }

}

/// Apple Translation performs its inference outside Swift concurrency, so task
/// priority alone cannot protect animation frames. Match each inference burst
/// with a bounded rest period to avoid sustained resource saturation.
enum TranslationInferencePacer {
    static let foregroundDutyCycle = 0.45
    static let minimumCooldown = Duration.milliseconds(350)
    static let maximumCooldown = Duration.milliseconds(1_500)

    static func cooldown(after work: Duration) -> Duration {
        let seconds = max(0, Double(work.components.seconds)
            + Double(work.components.attoseconds) / 1_000_000_000_000_000_000)
        let desired = seconds * (1 / foregroundDutyCycle - 1)
        let minimum = durationSeconds(minimumCooldown)
        let maximum = durationSeconds(maximumCooldown)
        return .milliseconds(Int64((min(maximum, max(minimum, desired)) * 1_000).rounded()))
    }

    private static func durationSeconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }
}
