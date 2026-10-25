import SwiftUI

/// Owns the native translation session for the whole reader presentation. Switching
/// from the original to the first translated paragraphs must not destroy that session.
struct ReadingSessionView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackController.self) private var playback
    @Environment(TranslationCoordinator.self) private var translation
    let documentID: UUID
    let automaticallyTranslate: Bool
    let usesBackgroundTranslationSession: Bool
    @State private var currentID: UUID?
    @State private var showTranslation = false
    @State private var didOpen = false
    @State private var targetLanguage = TranslationCoordinator.phoneTranslationLanguage
    @State private var requestTask: Task<Void, Never>?

    private var document: ReadingDocument? { library.document(currentID ?? documentID) }
    private var languageName: String { Locale.current.localizedString(forIdentifier: targetLanguage) ?? targetLanguage }

    var body: some View {
        ZStack {
            ReaderView(documentID: currentID ?? documentID, openDocument: openOriginal, translate: start)
                .id(currentID ?? documentID)
                .allowsHitTesting(!showTranslation)
                .accessibilityHidden(showTranslation)
            if showTranslation {
                Color.black.opacity(0.2).ignoresSafeArea()
                VStack(spacing: 22) {
                    HStack {
                        Color.clear.frame(width: 44, height: 44)
                        Spacer()
                        Image(systemName: "translate").font(.system(size: 38))
                        Spacer()
                        Button(action: dismissTranslationPreparation) {
                            Image(systemName: "xmark")
                                .font(.body.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .background(ConteurTheme.card, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Annuler")
                        .accessibilityIdentifier("translation-close")
                    }
                    Text("Traduction en \(languageName)")
                        .font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                    if let error = translation.errorMessage {
                        Text(error).font(.subheadline).foregroundStyle(ConteurTheme.muted)
                        Button("Réessayer") { if let document { start(document) } }
                    } else {
                        VStack(spacing: 8) {
                            HStack {
                                Text(translation.status)
                                Spacer()
                                if !translation.isInstallingLanguages {
                                    Text("\(Int((translation.preparationProgress * 100).rounded())) %")
                                        .monospacedDigit()
                                }
                            }
                            if translation.isInstallingLanguages {
                                ProgressView()
                                    .progressViewStyle(.linear)
                                    .tint(ConteurTheme.green)
                            } else {
                                ProgressView(value: translation.preparationProgress)
                                    .tint(ConteurTheme.green)
                            }
                        }
                        .font(.subheadline).foregroundStyle(ConteurTheme.muted)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(translation.status)
                        .accessibilityValue(translation.isInstallingLanguages
                            ? String(localized: "Téléchargement géré par iOS")
                            : String(format: String(localized: "%lld pour cent"), Int64((translation.preparationProgress * 100).rounded())))
                        if translation.isInstallingLanguages {
                            Text("Première installation : cela peut prendre plusieurs minutes. Gardez l’app ouverte et connectée au Wi-Fi.")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(ConteurTheme.ink)
                        }
                        Text("La lecture sera disponible dès les premiers passages. La suite se traduira pendant que vous lisez.")
                            .font(.footnote).foregroundStyle(ConteurTheme.muted)
                    }
                    Button("Lire l’original") {
                        if let document { openOriginal(document.translationOf ?? document.id) }
                    }
                    .font(.body.weight(.semibold)).frame(minHeight: 44)
                    .accessibilityIdentifier("translation-original")
                }
                .multilineTextAlignment(.center)
                .padding(28).frame(maxWidth: 420)
                .background(ConteurTheme.paper, in: RoundedRectangle(cornerRadius: 28))
                .padding(24)
                .accessibilityIdentifier("translation-prompt")
            }
        }
        .onAppear {
            guard !didOpen else { return }
            didOpen = true
            if automaticallyTranslate, let document { start(document) }
            else if !usesBackgroundTranslationSession,
                    let document, document.translationOf != nil, !document.isTranslationMetadataComplete {
                repairMetadata(document)
            }
        }
        .onChange(of: translation.readyDocumentID) { _, id in
            guard let id else { return }
            currentID = id
            showTranslation = false
        }
        .onChange(of: translation.isTranslating) { _, active in
            ReadingIdleTimer.isTranslating = active
        }
        .onDisappear {
            ReadingIdleTimer.isTranslating = false
            if !usesBackgroundTranslationSession { translation.handoffSessionToBackground() }
        }
        .translationTask(usesBackgroundTranslationSession ? nil : translation.configuration) { session in
            await Task(priority: .utility) { await translation.translate(using: session) }.value
        }
        .interactiveDismissDisabled(showTranslation)
    }

    private func start(_ document: ReadingDocument) {
        playback.pause()
        requestTask?.cancel()
        translation.errorMessage = nil
        targetLanguage = document.isTranslationPending
            ? (document.languageCode ?? document.resolvedLanguage ?? TranslationCoordinator.phoneTranslationLanguage)
            : TranslationCoordinator.phoneTranslationLanguage
        showTranslation = !document.isTranslationPending
        // A failed or interrupted first attempt must not trap the next book opening.
        // Publishing a translation replaces this choice with its persistent edition.
        if document.translationOf == nil { library.rememberReading(originalID: document.id, readingID: document.id) }
        requestTask = Task { await translation.request(document, targetLanguage: targetLanguage) }
    }

    private func openOriginal(_ id: UUID) {
        requestTask?.cancel()
        translation.cancel()
        library.rememberReading(originalID: id, readingID: id)
        currentID = id
        showTranslation = false
    }

    private func dismissTranslationPreparation() {
        requestTask?.cancel()
        translation.cancel()
        showTranslation = false
    }

    private func repairMetadata(_ document: ReadingDocument) {
        requestTask?.cancel()
        requestTask = Task {
            await translation.request(document, targetLanguage: document.languageCode ?? document.resolvedLanguage ?? TranslationCoordinator.phoneTranslationLanguage)
        }
    }
}
