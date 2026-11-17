import SwiftUI
import UIKit
import Vision
import WebKit

struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackController.self) private var playback
    @Environment(TranslationCoordinator.self) private var translation
    let open: (ReadingDocument) -> Void
    let importFile: () -> Void
    let compose: () -> Void
    let openWeb: () -> Void
    @State private var search = ""
    @State private var filter = 0
    @State private var deleting: ReadingDocument?
    @State private var sharedBook: SharedBook?
    @State private var languageDocument: ReadingDocument?

    private var filtered: [ReadingDocument] {
        library.documents.filter {
            (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.author.localizedCaseInsensitiveContains(search))
            && (filter == 0 || (filter == 1 && $0.position > 0 && !$0.isFinished) || (filter == 2 && $0.isFinished))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack {
                        HStack(spacing: 8) { Image(systemName: "waveform"); Text("LE CONTEUR").tracking(3) }
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Image(systemName: "iphone").font(.caption)
                        Text("En local").font(.caption)
                    }.foregroundStyle(ConteurTheme.green)

                    VStack(alignment: .leading, spacing: 9) {
                        Text("Vos mots.\nVotre moment.").font(.system(size: 43, weight: .regular, design: .serif)).tracking(-1.4)
                        Text("Le plaisir de lire, les yeux fermés.").font(.subheadline).foregroundStyle(ConteurTheme.muted)
                    }

                    if search.isEmpty, filter == 0,
                       let featured = library.featuredDocument(activeID: playback.isPreview ? nil : playback.documentID) {
                        Button { open(featured) } label: {
                            HStack(alignment: .center, spacing: 21) {
                                BookCover(title: featured.title, coverFileName: featured.coverFileName, large: true)
                                    .rotationEffect(.degrees(-4)).shadow(color: ConteurTheme.ink.opacity(0.18), radius: 8, x: 2, y: 6)
                                VStack(alignment: .leading, spacing: 12) {
                                    Eyebrow(text: featured.position > 0 ? String(localized: "REPRENDRE") : String(localized: "À ÉCOUTER"))
                                    Text(featured.title).font(.system(size: 25, weight: .medium, design: .serif)).lineLimit(3)
                                    Text(remainingTime(for: featured)).font(.caption).foregroundStyle(ConteurTheme.muted)
                                    if featured.isTranslationPending {
                                        BookTranslationGauge(progress: featured.translationProgress,
                                                             isActive: translation.isTranslating && translation.activeDocumentID == featured.id,
                                                             compact: true)
                                    }
                                    HStack(spacing: 8) {
                                        Image(systemName: "play.fill").font(.system(size: 11))
                                        Text(featured.position > 0 ? String(localized: "Continuer") : String(localized: "Ouvrir le lecteur")).font(.caption.weight(.semibold))
                                    }.padding(.horizontal, 14).padding(.vertical, 11).background(ConteurTheme.green, in: Capsule()).foregroundStyle(.white)
                                }
                                Spacer(minLength: 0)
                            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                                .background(ConteurTheme.featured, in: RoundedRectangle(cornerRadius: 23))
                        }.buttonStyle(.plain)
                    }

                    HStack(alignment: .firstTextBaseline) {
                        Text("Bibliothèque").font(.system(size: 27, weight: .medium, design: .serif))
                        Text("\(library.documents.count)").font(.caption).foregroundStyle(ConteurTheme.muted)
                        Spacer()
                        Menu {
                            Button("Importer un fichier", systemImage: "doc.badge.plus", action: importFile)
                            Button("Écrire ou coller un texte", systemImage: "text.badge.plus", action: compose)
                            Button("Lire Kindle ou une page web", systemImage: "globe", action: openWeb)
                        } label: {
                            Image(systemName: "plus").font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44)
                                .background(ConteurTheme.green, in: Circle()).foregroundStyle(.white)
                        }.accessibilityLabel("Ajouter une lecture")
                    }
                    HStack(spacing: 8) {
                        ForEach(Array([String(localized: "Tout"), String(localized: "En cours"), String(localized: "Terminés")].enumerated()), id: \.offset) { index, title in
                            Button { filter = index } label: {
                                Text(title).font(.caption.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 10)
                                    .background(filter == index ? ConteurTheme.ink : ConteurTheme.card, in: Capsule())
                                    .foregroundStyle(filter == index ? ConteurTheme.paper : ConteurTheme.muted)
                            }.buttonStyle(.plain)
                        }
                    }.padding(.top, -12)
                    if library.documents.count > 1 || !search.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").foregroundStyle(ConteurTheme.muted)
                            TextField("Rechercher un titre ou un auteur", text: $search).font(.subheadline)
                                .autocorrectionDisabled()
                            if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Effacer la recherche") }
                        }.padding(13).background(ConteurTheme.card, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if filtered.isEmpty {
                        ContentUnavailableView(search.isEmpty ? String(localized: "Un peu de place pour vos histoires") : String(localized: "Aucun résultat"), systemImage: "book", description: Text("Ajoutez un EPUB, un PDF ou votre propre texte."))
                        Button("Importer un document", action: importFile).buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered) { document in
                                Button { open(document) } label: {
                                    HStack(spacing: 16) {
                                        BookCover(title: document.title, coverFileName: document.coverFileName)
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(document.title).font(.system(size: 18, weight: .medium, design: .serif)).lineLimit(2)
                                            Text(document.author).font(.caption).foregroundStyle(ConteurTheme.muted).lineLimit(1)
                                            HStack(spacing: 8) {
                                                Text(document.source).font(.system(size: 9, weight: .semibold)).tracking(1)
                                                if document.languageCode != nil {
                                                    Text("·  \(languageName(for: document))").font(.system(size: 9, weight: .semibold)).tracking(1)
                                                }
                                                Text("·  \(remainingTime(for: document))").font(.caption)
                                                if document.isFinished { Image(systemName: "checkmark.circle.fill") }
                                            }.foregroundStyle(ConteurTheme.muted)
                                            if document.isTranslationPending {
                                                BookTranslationGauge(progress: document.translationProgress,
                                                                     isActive: translation.isTranslating && translation.activeDocumentID == document.id,
                                                                     compact: true)
                                            }
                                            if document.progress > 0 && !document.isFinished { ProgressView(value: document.progress).tint(ConteurTheme.orange) }
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(ConteurTheme.muted)
                                    }.padding(.vertical, 16).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .contextMenu {
                                        Button("Ouvrir", systemImage: "book") { open(document) }
                                        if document.translationOf != nil && !document.isTranslationPending {
                                            Button("Partager la traduction", systemImage: "square.and.arrow.up") { export(document) }
                                        }
                                        Button("Langue du document", systemImage: "character.book.closed") { languageDocument = document }
                                        Button("Supprimer", systemImage: "trash", role: .destructive) { deleting = document }
                                    }
                                Divider().overlay(ConteurTheme.ink.opacity(0.06))
                            }
                        }.padding(.top, -12)
                    }
                    Label("Vos documents restent sur votre iPhone.", systemImage: "lock")
                        .font(.caption).foregroundStyle(ConteurTheme.muted).frame(maxWidth: .infinity).padding(.bottom, 16)
                }.padding(.horizontal, 24).padding(.top, 16)
            }
            .onScrollPhaseChange { _, phase in
                translation.setInterfaceScrolling(phase != .idle)
            }
            .onDisappear { translation.setInterfaceScrolling(false) }
            .background(ConteurTheme.paper).foregroundStyle(ConteurTheme.ink)
            .toolbar(.hidden, for: .navigationBar)
            .confirmationDialog("Supprimer cette lecture ?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) {
                    if let deleting { if playback.documentID == deleting.id { playback.stop() }; library.delete(deleting.id) }
                    deleting = nil
                }
            }
            .sheet(item: $sharedBook) { BookShareSheet(url: $0.url).ignoresSafeArea() }
            .sheet(item: $languageDocument) { document in
                DocumentLanguagePicker(document: library.document(document.id) ?? document) { language in
                    if library.updateLanguage(id: document.id, languageCode: language), playback.documentID == document.id {
                        playback.settingsChanged()
                    }
                }
            }
        }
    }

    private func remainingTime(for document: ReadingDocument) -> String {
        let seconds = document.isFinished ? 0 : document.secondsUntilBookEnd(rate: playback.playbackSpeed)
        let minutes = Int(ceil(seconds / 60))
        guard minutes >= 60 else {
            return String(format: String(localized: "%lld min restantes"), Int64(minutes))
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 {
            return String(format: String(localized: "%lld h restantes"), Int64(hours))
        }
        return String(
            format: String(localized: "%1$lld h %2$lld min restantes"),
            Int64(hours),
            Int64(remainingMinutes)
        )
    }

    private func export(_ document: ReadingDocument) {
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) { try EPUBExporter.export(document) }.value
                sharedBook = SharedBook(url: url)
            } catch {
                library.errorMessage = String(format: String(localized: "Impossible de préparer l’EPUB : %@"), error.localizedDescription)
            }
        }
    }

    private func languageName(for document: ReadingDocument) -> String {
        guard let languageCode = document.languageCode, !languageCode.isEmpty else { return String(localized: "LANGUE INCONNUE") }
        let code = SystemVoiceSelection.language(languageCode)
        return (Locale.current.localizedString(forLanguageCode: code) ?? code).localizedUppercase
    }
}

struct SharedBook: Identifiable {
    let id = UUID()
    let url: URL
}

struct BookShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct WebReadingView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = WebReadingBrowser()
    @State private var address = "https://lire.amazon.fr/kindle-library"
    @State private var isExtracting = false
    @State private var showsImportPreparation = false
    @State private var readerHeightBeforeImport: CGFloat?
    @State private var errorMessage: String?
    let read: (ReadingDocument) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !isExtracting || !browser.usesFixedPagination {
                    HStack(spacing: 10) {
                        TextField("Adresse de la page", text: $address)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .onSubmit(openAddress)
                        Button("Aller", action: openAddress)
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(ConteurTheme.card)
                }

                WebReadingBrowserView(browser: browser)
                    .overlay {
                        if browser.isLoading { ProgressView().controlSize(.large) }
                    }
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { height in
                        if !isExtracting, height > 0 {
                            readerHeightBeforeImport = height
                        }
                    }
                    .frame(height: isExtracting && browser.usesFixedPagination
                           ? readerHeightBeforeImport : nil)

                VStack(spacing: 10) {
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                    }
                    Button {
                        if isExtracting {
                            browser.finishCaptureNow()
                        } else {
                            showsImportPreparation = true
                        }
                    } label: {
                        Label(isExtracting ? String(localized: "Terminer l’import maintenant") : String(localized: "Importer ce livre"),
                              systemImage: isExtracting ? "stop.circle" : "text.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(browser.isLoading)
                    if isExtracting {
                        Text(browser.captureStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    if !isExtracting {
                        Text("Le Conteur parcourt le livre jusqu’à sa fin et ignore toujours les champs de connexion. Votre session Amazon reste dans ce navigateur.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(14).background(ConteurTheme.wash)
            }
            .background(ConteurTheme.paper)
            .navigationTitle("Lecture web")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(isExtracting && browser.usesFixedPagination ? .hidden : .visible,
                     for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
                if !isExtracting {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button { browser.goBack() } label: { Image(systemName: "chevron.backward") }
                            .disabled(!browser.canGoBack)
                        Button { browser.goForward() } label: { Image(systemName: "chevron.forward") }
                            .disabled(!browser.canGoForward)
                        Spacer()
                        Button { browser.loadKindle() } label: { Label("Kindle", systemImage: "book") }
                        Spacer()
                        Button { browser.reload() } label: { Image(systemName: "arrow.clockwise") }
                    }
                }
            }
            .onChange(of: browser.currentURL) { _, value in
                if let value { address = value.absoluteString }
            }
            .overlay {
                if showsImportPreparation {
                    ZStack {
                        Color.black.opacity(0.62)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture {}
                        VStack(alignment: .leading, spacing: 18) {
                            Text("Préparer l’import")
                                .font(.title3.bold())
                            Text("Avant de commencer, allez à la couverture du livre afin que Le Conteur puisse capturer son image et son titre.")
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.82))
                            Button {
                                showsImportPreparation = false
                                Task { await readCurrentPage() }
                            } label: {
                                Text("La couverture est affichée")
                                    .fontWeight(.semibold)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(red: 0.27, green: 0.50, blue: 0.33))
                            Button("Pas encore") {
                                showsImportPreparation = false
                            }
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .buttonStyle(.bordered)
                            .tint(.white)
                        }
                        .foregroundStyle(.white)
                        .padding(24)
                        .frame(maxWidth: 380)
                        .background(Color(red: 0.07, green: 0.10, blue: 0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .stroke(.white.opacity(0.18), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
                        .padding(24)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.easeOut(duration: 0.18), value: showsImportPreparation)
        }
    }

    private func openAddress() {
        errorMessage = nil
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains("://") { value = "https://" + value }
        guard let url = URL(string: value), url.scheme?.lowercased() == "https" else {
            errorMessage = String(localized: "Cette adresse web n’est pas valide.")
            return
        }
        browser.load(url)
    }

    @MainActor private func readCurrentPage() async {
        isExtracting = true
        errorMessage = nil
        defer { isExtracting = false }
        do {
            // The import controls and bottom toolbar disappear here, changing
            // the web view height. Kindle's paginated reader does not always
            // notice that resize by itself and can clip its final text line.
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(180))
            let hidesPaginatedChrome = browser.usesFixedPagination
            if hidesPaginatedChrome {
                browser.setCaptureChromeHidden(true)
            }
            browser.refreshReaderLayout()
            try? await Task.sleep(for: .milliseconds(320))
            let capture = try await browser.captureVisibleText()
            let title = capture.title.trimmingCharacters(in: .whitespacesAndNewlines)
            var document = try DocumentImporter.fromText(
                capture.text,
                title: title.isEmpty ? String(localized: "Lecture web") : title,
                source: String(localized: "WEB"),
                author: capture.host
            )
            if let coverData = capture.coverData {
                document.coverFileName = try? BookCoverStore.save(coverData)
            }
            read(document)
        } catch {
            errorMessage = error.localizedDescription
        }
        if browser.usesFixedPagination {
            browser.setCaptureChromeHidden(false)
        }
    }
}

@MainActor final class WebReadingBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var currentURL: URL?
    @Published private(set) var captureStatus = String(localized: "Analyse du livre…")
    var usesFixedPagination: Bool { currentURL?.path.contains("/sample/") == true }
    let webView: WKWebView
    private let captureHandler: WebReadingCaptureHandler
    private var frameCaptures: [String: WebFrameCapture] = [:]
    private var captureShouldFinish = false
    private var isCaptureActive = false
    private var attemptedKindleSampleASINs: Set<String> = []

    override init() {
        let captureHandler = WebReadingCaptureHandler()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.userContentController.add(captureHandler, name: "leConteurCapture")
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.frameCaptureScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))
        self.captureHandler = captureHandler
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        captureHandler.browser = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        loadKindle()
    }

    func loadKindle() {
        load(URL(string: "https://lire.amazon.fr/kindle-library")!)
    }

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }
    func reload() { webView.reload() }
    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }
    func refreshReaderLayout() {
        webView.setNeedsLayout()
        webView.layoutIfNeeded()
        webView.evaluateJavaScript(
            "window.__leConteurScrollAll && window.__leConteurScrollAll('layout', 0)",
            completionHandler: nil
        )
    }
    func setCaptureChromeHidden(_ hidden: Bool) {
        isCaptureActive = hidden
        let action = hidden ? "captureOn" : "captureOff"
        webView.evaluateJavaScript(
            "window.__leConteurScrollAll && window.__leConteurScrollAll('\(action)', 0)",
            completionHandler: nil
        )
    }
    func finishCaptureNow() {
        captureShouldFinish = true
        captureStatus = String(localized: "Finalisation de l’import…")
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        frameCaptures.removeAll()
        refresh()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refresh()
        guard let url = webView.url else { return }
        Task { [weak self] in
            await self?.tryKindleSampleFallback(from: url)
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { refresh() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { refresh() }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard isCaptureActive,
              navigationAction.targetFrame?.isMainFrame != false else {
            decisionHandler(.allow)
            return
        }
        // Page turns in Kindle update the reader in place. A main-frame link
        // during capture is therefore a footnote, citation, ad, or accidental
        // synthetic tap and must never take the scanner away from the book.
        let staysInKindleReader = Self.isSameKindleReaderDocument(
            webView.url,
            navigationAction.request.url
        )
        if navigationAction.navigationType == .linkActivated && !staysInKindleReader {
            decisionHandler(.cancel)
        } else if navigationAction.request.url != webView.url && !staysInKindleReader {
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    nonisolated static func isSameKindleReaderDocument(_ current: URL?, _ requested: URL?) -> Bool {
        guard let current, let requested,
              current.scheme?.caseInsensitiveCompare(requested.scheme ?? "") == .orderedSame,
              current.host?.caseInsensitiveCompare(requested.host ?? "") == .orderedSame,
              current.host()?.localizedCaseInsensitiveContains("amazon.") == true else { return false }
        func sampleID(in url: URL) -> String? {
            let components = url.pathComponents
            guard let sample = components.firstIndex(where: {
                $0.caseInsensitiveCompare("sample") == .orderedSame
            }), components.indices.contains(sample + 1) else { return nil }
            return components[sample + 1].uppercased()
        }
        guard let currentID = sampleID(in: current), let requestedID = sampleID(in: requested) else {
            return false
        }
        return currentID == requestedID
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard !isCaptureActive else { return nil }
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url { load(url) }
        return nil
    }

    private func refresh() {
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        currentURL = webView.url
    }

    private func tryKindleSampleFallback(from url: URL) async {
        guard let fallback = Self.kindleSampleFallbackURL(from: url),
              let asin = fallback.pathComponents.last,
              !attemptedKindleSampleASINs.contains(asin) else { return }

        // Amazon construit parfois cette page après la fin de la navigation.
        // Sonder quelques fois évite de rater le message sans retarder les
        // lecteurs Kindle qui fonctionnent normalement dans le navigateur.
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(350)) }
            guard webView.url == url else { return }
            let value = try? await webView.evaluateJavaScript("""
                (() => {
                  const text = document.body ? document.body.innerText : '';
                  const hasAppStoreLink = Array.from(document.links || []).some(link =>
                    /(?:apps\\.apple\\.com|itunes\\.apple\\.com)/i.test(link.href || '')
                  );
                  return { text, hasAppStoreLink };
                })()
                """)
            guard let probe = value as? [String: Any] else { continue }
            let text = probe["text"] as? String ?? ""
            let hasAppStoreLink = probe["hasAppStoreLink"] as? Bool ?? false
            if Self.looksLikeKindleAppRequired(text, hasAppStoreLink: hasAppStoreLink) {
                attemptedKindleSampleASINs.insert(asin)
                load(fallback)
                return
            }
        }
    }

    nonisolated static func kindleSampleFallbackURL(from url: URL) -> URL? {
        guard let host = url.host?.lowercased(), host.contains("amazon."),
              !url.path.lowercased().hasPrefix("/sample/") else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let asin = components.queryItems?.first(where: {
                  $0.name.caseInsensitiveCompare("asin") == .orderedSame
              })?.value?.uppercased(),
              asin.count == 10,
              asin.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) else { return nil }
        components.path = "/sample/\(asin)"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    nonisolated static func looksLikeKindleAppRequired(_ pageText: String,
                                                        hasAppStoreLink: Bool) -> Bool {
        let text = pageText.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                    locale: Locale(identifier: "en_US_POSIX"))
        if text.contains("kindle app is required") || text.contains("application kindle est requise") {
            return true
        }
        return hasAppStoreLink && text.contains("kindle")
            && (text.contains("ne peut etre ouvert") || text.contains("can only be opened"))
    }

    fileprivate func captureVisibleText() async throws -> WebPageCapture {
        let ownsCaptureState = !isCaptureActive
        isCaptureActive = true
        defer { if ownsCaptureState { isCaptureActive = false } }
        if let value = try? await webView.evaluateJavaScript("window.__leConteurCapture && window.__leConteurCapture()"),
           let result = value as? [String: Any] {
            receiveCapture(result, frameURL: webView.url)
        }

        // Kindle affiche le livre dans un cadre provenant d'un autre sous-domaine.
        // Le script injecté dans chaque cadre peut lire son propre document sans
        // franchir la frontière de sécurité entre Amazon et le livre.
        try? await Task.sleep(for: .milliseconds(120))
        if webView.url?.host()?.localizedCaseInsensitiveContains("amazon.") == true,
           let book = try? await recognizeDisplayedText(), book.text.count >= 20 {
            return WebPageCapture(
                text: Self.normalizingKindleText(book.text),
                title: preferredBookTitle(visualCandidate: book.titleCandidate),
                host: webView.url?.host() ?? "amazon.fr",
                coverData: book.coverData
            )
        }
        guard let capture = frameCaptures.values.max(by: { $0.rank < $1.rank }),
              capture.text.count >= 20 else { throw WebReadingError.noVisibleText }
        return WebPageCapture(
            text: Self.normalizingKindleText(capture.text),
            title: capture.title.isEmpty ? webView.title ?? "" : capture.title,
            host: webView.url?.host() ?? capture.host,
            coverData: nil
        )
    }

    private func recognizeDisplayedText() async throws -> WebOCRBook {
        let viewportHeight = max(1, webView.bounds.height)
        let trimsPaginatedReaderChrome = webView.url?.path.contains("/sample/") == true
        var combined = ""
        var firstPageCover: Data?
        var firstPageTitle = ""
        var unchangedScreens = 0
        var farthestKindlePage = 0
        captureShouldFinish = false
        captureStatus = String(localized: "Recherche du début du livre…")
        _ = try? await webView.evaluateJavaScript("window.__leConteurScrollAll && window.__leConteurScrollAll('start', 0)")
        // Pour les extraits Kindle paginés, l'utilisateur confirme déjà que la
        // couverture est affichée avant de lancer l'import. Chercher encore le
        // début peut cliquer indéfiniment sur la navigation de couverture.
        if !trimsPaginatedReaderChrome {
            await rewindPaginatedReaderIfNeeded()
        }
        defer {
            captureStatus = String(localized: "Analyse du livre…")
        }

        // Le lecteur Kindle déroule le livre au lieu d'exposer son texte.
        // Photographier des vues qui se chevauchent permet de reconstituer le
        // contenu, même lorsque son DOM est volontairement inaccessible. Le
        // plafond protège uniquement contre une page qui bouclerait sans fin.
        for screen in 0..<2400 {
            captureStatus = String(localized: "Analyse du livre… écran \(screen + 1)")
            try await Task.sleep(for: .milliseconds(screen == 0 ? 900 : 450))
            let image = try await webView.takeSnapshot(configuration: nil)
            guard let cgImage = image.cgImage else { continue }
            let recognized = try await Self.recognizeText(
                in: cgImage,
                trimsPaginatedReaderChrome: trimsPaginatedReaderChrome
            )
            if screen == 0 {
                firstPageCover = image.jpegData(compressionQuality: 0.86)
                firstPageTitle = recognized.titleCandidate
            }
            if let page = recognized.pageNumber {
                // À la dernière page, certains lecteurs Kindle renvoient vers
                // une page antérieure au lieu de désactiver la navigation.
                // Ne jamais incorporer ce retour en arrière au livre importé.
                if farthestKindlePage > 0, page + 1 < farthestKindlePage { break }
                farthestKindlePage = max(farthestKindlePage, page)
            }
            let merged = Self.mergingOCR(combined, with: recognized.text)
            if merged.count <= combined.count + 12 { unchangedScreens += 1 }
            else { unchangedScreens = 0 }
            combined = merged

            if captureShouldFinish || recognized.isLastPage
                || unchangedScreens >= 6 || combined.count >= 1_950_000 { break }
            _ = try? await webView.evaluateJavaScript(
                "window.__leConteurScrollAll && window.__leConteurScrollAll('advance', \(viewportHeight * 0.68))"
            )
        }
        return WebOCRBook(text: combined, titleCandidate: firstPageTitle, coverData: firstPageCover)
    }

    private func rewindPaginatedReaderIfNeeded() async {
        var previous = ""
        var unchangedScreens = 0
        let trimsPaginatedReaderChrome = webView.url?.path.contains("/sample/") == true
        // A continuous Kindle book is already at scroll offset zero and has no
        // side control, so this exits after two harmless checks. Samples use a
        // left arrow; compare their OCR until that arrow no longer changes the
        // displayed page, which means the beginning has been reached.
        for step in 0..<1200 {
            try? await Task.sleep(for: .milliseconds(step == 0 ? 500 : 320))
            guard let image = try? await webView.takeSnapshot(configuration: nil),
                  let cgImage = image.cgImage,
                  let recognized = try? await Self.recognizeText(
                    in: cgImage,
                    trimsPaginatedReaderChrome: trimsPaginatedReaderChrome
                  ) else { break }
            let current = recognized.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            // L'import demande maintenant de partir de la couverture. Les
            // extraits Kindle l'indiquent par 0 % ; dans ce cas, tenter encore
            // de reculer peut viser un autre contrôle de navigation et laisser
            // la recherche tourner indéfiniment sur la couverture.
            if current.range(
                of: #"(?:^|\s)0\s*%(?:\s|$)"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                break
            }
            if current == previous { unchangedScreens += 1 }
            else { previous = current; unchangedScreens = 0 }
            if unchangedScreens >= 2 { break }
            _ = try? await webView.evaluateJavaScript(
                "window.__leConteurScrollAll && window.__leConteurScrollAll('retreat', 0)"
            )
        }
    }

    private func preferredBookTitle(visualCandidate: String) -> String {
        let candidates = frameCaptures.values.map(\.title) + [webView.title ?? ""]
        if let title = candidates.lazy.map(Self.cleanBookTitle).first(where: {
            !Self.isGenericBookTitle($0) && !Self.looksLikePublisher($0)
                && ChapterTitles.recognized($0) == nil
        }) {
            return title
        }
        let title = Self.cleanBookTitle(visualCandidate)
        if !Self.isGenericBookTitle(title), !Self.looksLikePublisher(title),
           ChapterTitles.recognized(title) == nil {
            return title
        }
        return String(localized: "Livre Kindle")
    }

    nonisolated private static func cleanBookTitle(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: #"\s*[|–—-]\s*(Kindle|Amazon).*$"#,
                                  with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func isGenericBookTitle(_ value: String) -> Bool {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return value.isEmpty || ["kindle", "amazon", "lire", "lecture web", "read.amazon.com",
                                 "read.amazon.fr", "bibliotheque kindle", "kindle library"]
            .contains(folded)
    }

    nonisolated private static func looksLikePublisher(_ value: String) -> Bool {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let words = Set(folded.split { !$0.isLetter }.map(String.init))
        let publisherWords: Set<String> = ["edition", "editions", "publisher", "publishing",
                                           "press", "editeur", "editorial", "media", "books"]
        return value.split(whereSeparator: \.isWhitespace).count <= 5
            && !words.isDisjoint(with: publisherWords)
    }

    nonisolated private static func recognizeText(
        in cgImage: CGImage,
        trimsPaginatedReaderChrome: Bool = false
    ) async throws -> WebOCRRecognition {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([request])
            var lines = (request.results ?? []).compactMap { observation -> WebOCRLine? in
                guard let text = observation.topCandidates(1).first?.string
                    .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                return WebOCRLine(text: text, box: observation.boundingBox)
            }
            lines.sort {
                if abs($0.box.midY - $1.box.midY) < 0.006 { return $0.box.minX < $1.box.minX }
                return $0.box.midY > $1.box.midY
            }
            guard !lines.isEmpty else {
                return WebOCRRecognition(
                    text: "", titleCandidate: "", isLastPage: false, pageNumber: nil
                )
            }
            let typicalHeight = lines.map(\.box.height).sorted()[lines.count / 2]
            let eligible = lines.filter { line in
                let clean = cleanBookTitle(line.text)
                return clean.count >= 3 && clean.count <= 100
                    && clean.rangeOfCharacter(from: .letters) != nil
                    && line.box.height >= typicalHeight * 1.3
                    && !isGenericBookTitle(clean)
                    && !looksLikePublisher(clean)
                    && ChapterTitles.recognized(clean) == nil
            }
            let anchor = eligible.max { left, right in
                let leftScore = left.box.height * (1 + left.box.midY * 0.22)
                let rightScore = right.box.height * (1 + right.box.midY * 0.22)
                return leftScore < rightScore
            }
            let titleCandidate: String
            if let anchor {
                titleCandidate = eligible.filter {
                    abs($0.box.midY - anchor.box.midY) <= 0.22
                        && $0.box.height >= anchor.box.height * 0.62
                }.sorted { $0.box.midY > $1.box.midY }
                    .map(\.text).joined(separator: " ")
            } else {
                titleCandidate = ""
            }
            // Pendant l'import, le bandeau Kindle supérieur est désormais
            // refermé avant la capture. Ne retirer que sa très petite marge :
            // l'ancien seuil à 0,79 supprimait plusieurs lignes réellement
            // visibles au début de chaque page.
            let readableLines = (trimsPaginatedReaderChrome
                ? lines.filter { $0.box.midY > 0.08 && $0.box.midY < 0.965 }
                : lines).filter {
                    !Self.isEdgeNavigationMarker($0.text, box: $0.box)
                        && !Self.isLikelyOCRFootnoteMarker(
                            $0.text,
                            box: $0.box,
                            typicalHeight: typicalHeight
                        )
                }
            // Le compteur Kindle est volontairement exclu du texte du livre,
            // mais il donne un signal de fin beaucoup plus fiable que plusieurs
            // captures OCR presque identiques.
            let bottomChrome = lines.filter { $0.box.midY <= 0.14 }
                .map(\.text).joined(separator: " ")
            let pagePosition = Self.kindlePagePosition(bottomChrome)
            let isLastPage = trimsPaginatedReaderChrome
                && (Self.looksLikeLastKindlePage(bottomChrome)
                    || pagePosition.map { $0.current >= $0.total } == true)
            var result = ""
            var previous: WebOCRLine?
            for line in readableLines {
                var separator = ""
                if let previous {
                    let verticalGap = previous.box.minY - line.box.maxY
                    separator = verticalGap > typicalHeight * 1.15 ? "\n\n" : " "
                }
                result = Self.joiningOCRFragments(result, line.text, separator: separator)
                previous = line
            }
            return WebOCRRecognition(
                text: result,
                titleCandidate: titleCandidate,
                isLastPage: isLastPage,
                pageNumber: pagePosition?.current
            )
        }.value
    }

    nonisolated private static func looksLikeLastKindlePage(_ value: String) -> Bool {
        if value.range(of: #"(?:^|\s)100\s*%(?:\s|$)"#,
                       options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return kindlePagePosition(value).map { $0.current >= $0.total } == true
    }

    nonisolated private static func kindlePagePosition(
        _ value: String
    ) -> (current: Int, total: Int)? {
        let expression = try! NSRegularExpression(
            pattern: #"(?i)(\d+)\s*(?:sur|of|von|de|/)\s*(\d+)"#
        )
        let string = value as NSString
        let range = NSRange(location: 0, length: string.length)
        for match in expression.matches(in: value, range: range) {
            guard match.numberOfRanges >= 3 else { continue }
            if let current = Int(string.substring(with: match.range(at: 1))),
               let total = Int(string.substring(with: match.range(at: 2))),
               total > 0, current >= 0, current <= total {
                return (current, total)
            }
        }
        return nil
    }

    nonisolated static func mergingOCR(_ existing: String, with addition: String) -> String {
        struct Token {
            let comparable: String
            let range: NSRange
        }
        func tokens(in value: String) -> [Token] {
            let expression = try! NSRegularExpression(pattern: #"\S+"#)
            let whole = NSRange(location: 0, length: (value as NSString).length)
            return expression.matches(in: value, range: whole).map { match in
                let raw = (value as NSString).substring(with: match.range)
                let comparable = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .filter { $0.isLetter || $0.isNumber }
                return Token(comparable: comparable, range: match.range)
            }
        }
        let oldWords = tokens(in: existing)
        let newWords = tokens(in: addition)
        guard !newWords.isEmpty else { return Self.removingSoftHyphens(from: existing) }
        guard !oldWords.isEmpty else { return Self.removingSoftHyphens(from: addition) }
        let oldComparable = oldWords.map(\.comparable)
        let newComparable = newWords.map(\.comparable)

        // Drop overlapping words without flattening the remaining OCR text.
        // The whitespace immediately before the first new word tells us whether
        // Vision saw a real paragraph gap or merely the next line/screen.
        func appendingTail(dropping tokenCount: Int) -> String {
            guard tokenCount < newWords.count else { return existing }
            let tailStart = newWords[tokenCount].range.location
            let boundaryStart = tokenCount > 0 ? NSMaxRange(newWords[tokenCount - 1].range) : 0
            let source = addition as NSString
            let boundary = source.substring(with: NSRange(location: boundaryStart,
                                                           length: max(0, tailStart - boundaryStart)))
            let tail = source.substring(from: tailStart)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tail.isEmpty else { return existing }
            let separator = boundary.range(of: #"\n[\t ]*\n"#, options: .regularExpression) != nil
                ? "\n\n" : " "
            return Self.joiningOCRFragments(existing, tail, separator: separator)
        }

        // Les captures se chevauchent volontairement. Vision peut toutefois
        // changer un ou deux mots à la jonction. Chercher la plus longue suite
        // commune permet de retrouver l'alignement malgré cette variation,
        // puis de retirer toute la partie de la nouvelle capture qui se trouve
        // déjà à la fin du texte assemblé.
        let oldStart = max(0, oldWords.count - 240)
        let newLimit = min(newWords.count, 240)
        var previous = Array(repeating: 0, count: newLimit + 1)
        var bestLength = 0
        var bestOldEnd = 0
        var bestNewEnd = 0
        if newLimit > 0 {
            for oldIndex in oldStart..<oldWords.count {
                var current = Array(repeating: 0, count: newLimit + 1)
                for newIndex in 0..<newLimit where !oldComparable[oldIndex].isEmpty {
                    if oldComparable[oldIndex] == newComparable[newIndex] {
                        current[newIndex + 1] = previous[newIndex] + 1
                        if current[newIndex + 1] > bestLength {
                            bestLength = current[newIndex + 1]
                            bestOldEnd = oldIndex + 1
                            bestNewEnd = newIndex + 1
                        }
                    }
                }
                previous = current
            }
        }
        if bestLength >= 6 {
            let oldMatchStart = bestOldEnd - bestLength
            let newMatchStart = bestNewEnd - bestLength
            let oldTrailingWords = oldWords.count - bestOldEnd
            let maximumNewPrefix = min(36, max(8, newWords.count / 4))
            // A genuine overlap begins near the top of the new screenshot and
            // ends near the tail already assembled. Repeated Kindle chrome can
            // also form a long match, but usually appears after most of the new
            // page; accepting it would discard that page almost completely.
            if newMatchStart <= maximumNewPrefix && oldTrailingWords <= 36 {
                let overlap = newMatchStart + oldWords.count - oldMatchStart
                if overlap <= newWords.count {
                    return appendingTail(dropping: overlap)
                }
            }
        }

        let maximum = min(140, oldWords.count, newWords.count)
        var overlap = 0
        if maximum >= 4 {
            for count in stride(from: maximum, through: 4, by: -1) {
                let left = oldComparable.suffix(count)
                let right = newComparable.prefix(count)
                if left == right { overlap = count; break }
            }
        }
        if overlap == 0 {
            // Un écran identique ne doit pas être ajouté une seconde fois.
            let oldTail = oldComparable.suffix(min(24, oldWords.count))
            let newHead = newComparable.prefix(min(24, newWords.count))
            if oldTail == newHead { return existing }
        }
        if overlap > 0 { return appendingTail(dropping: overlap) }

        // An OCR mismatch should not invent a paragraph in the middle of an
        // unfinished sentence. Genuine paragraph starts normally follow final
        // punctuation and begin with an uppercase letter.
        let previousText = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty else { return existing }
        let terminal = previousText.last.map { ".!?…»\"”.".contains($0) } == true
        let startsUppercase = next.first(where: \.isLetter)?.isUppercase == true
        return Self.joiningOCRFragments(
            previousText,
            next,
            separator: terminal && startsUppercase ? "\n\n" : " "
        )
    }

    /// Vision returns one observation per displayed line. Kindle may insert a
    /// hyphen solely to wrap a word, and joining those observations with a
    /// normal space would turn `pro-` + `grammes` into two spoken words. Only
    /// remove a line-final hyphen before a lowercase continuation; punctuation,
    /// em dashes, paragraph boundaries, and ordinary in-line compounds remain.
    nonisolated static func joiningOCRFragments(_ existing: String,
                                                _ addition: String,
                                                separator: String = " ") -> String {
        let left = Self.removingSoftHyphens(from: existing)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let right = Self.removingSoftHyphens(from: addition)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }

        let hyphenationMarks: Set<Character> = ["-", "‐", "‑"]
        let continuesWord = right.first(where: { !$0.isWhitespace })?.isLowercase == true
        let leftWithoutMark = left.dropLast()
        let followsLetter = leftWithoutMark.last?.isLetter == true
        if separator != "\n\n", let mark = left.last,
           hyphenationMarks.contains(mark), followsLetter, continuesWord {
            return String(leftWithoutMark) + right
        }
        return left + separator + right
    }

    nonisolated static func removingSoftHyphens(from value: String) -> String {
        value.replacingOccurrences(of: "\u{00AD}", with: "")
    }

    nonisolated static func isEdgeNavigationMarker(_ value: String, box: CGRect) -> Bool {
        let marker = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !marker.isEmpty,
              marker.range(of: #"^[<>‹›〈〉❮❯]+$"#, options: .regularExpression) != nil else {
            return false
        }
        return box.midX < 0.055 || box.midX > 0.945
    }

    nonisolated static func isLikelyOCRFootnoteMarker(_ value: String,
                                                      box: CGRect,
                                                      typicalHeight: CGFloat) -> Bool {
        let marker = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typicalHeight > 0,
              marker.range(
                of: #"^(?:[0-9]{1,3}|[⁰¹²³⁴⁵⁶⁷⁸⁹]{1,3})$"#,
                options: .regularExpression
              ) != nil else { return false }
        return box.height < typicalHeight * 0.84 && box.width < 0.065
    }

    /// Kindle footnote anchors may be OCRed as their own line between the two
    /// halves of a wrapped word: `com-`, `3`, `pagnie`. Remove only a short
    /// isolated note marker in that exact context, then restore the word.
    nonisolated static func normalizingKindleText(_ value: String) -> String {
        let withoutSoftHyphens = Self.removingSoftHyphens(from: value)
        return withoutSoftHyphens.replacingOccurrences(
            of: #"(?<=\p{L})[-‐‑](?:\s+[0-9]{1,3}|\s*[⁰¹²³⁴⁵⁶⁷⁸⁹]{1,3})\s+(?=\p{Ll})"#,
            with: "",
            options: .regularExpression
        )
    }

    fileprivate func receiveCapture(_ result: [String: Any], frameURL: URL?) {
        guard let rawText = result["text"] as? String else { return }
        let text = Self.normalizingKindleText(rawText)
        let key = (result["href"] as? String) ?? frameURL?.absoluteString ?? UUID().uuidString
        frameCaptures[key] = WebFrameCapture(
            text: text,
            title: result["title"] as? String ?? "",
            host: result["host"] as? String ?? frameURL?.host() ?? "",
            isSelection: result["selected"] as? Bool ?? false,
            capturedAt: .now
        )
    }

    private static let frameCaptureScript = #"""
    (() => {
      if (window.__leConteurCaptureInstalled) return;
      window.__leConteurCaptureInstalled = true;
      const clean = value => (value || '').replace(/\u00AD/g, '').replace(/\s+/g, ' ').trim();
      const snapshot = () => {
        const entries = [];
        if (!document.body) return null;
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        let node;
        while ((node = walker.nextNode())) {
          const text = clean(node.nodeValue);
          const parent = node.parentElement;
          if (!text || !parent || parent.closest('script,style,noscript,nav,header,footer,button,input,textarea,select,[aria-hidden="true"]')) continue;
          if (/^(?:[0-9]{1,3}|[⁰¹²³⁴⁵⁶⁷⁸⁹]{1,3})$/.test(text) && parent.closest('a[href]')) continue;
          const style = getComputedStyle(parent);
          if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          const rect = range.getBoundingClientRect();
          if (!rect.width || !rect.height || rect.bottom < 0 || rect.top > innerHeight || rect.right < 0 || rect.left > innerWidth) continue;
          if (parseFloat(style.fontSize) < 11) continue;
          const edgeMarker = /^[<>‹›〈〉❮❯]+$/.test(text)
            && (rect.left + rect.width / 2 < innerWidth * 0.055
              || rect.left + rect.width / 2 > innerWidth * 0.945);
          if (edgeMarker) continue;
          entries.push({ text, top: rect.top, left: rect.left });
        }
        entries.sort((a, b) => Math.abs(a.top - b.top) > 3 ? a.top - b.top : a.left - b.left);
        const lines = [];
        for (const entry of entries) {
          if (lines[lines.length - 1] !== entry.text) lines.push(entry.text);
        }
        const selection = clean(getSelection && getSelection().toString());
        const metaTitle = document.querySelector('meta[property="og:title"]')?.content;
        const readerTitle = [
          '[data-testid*="book-title" i]', '[class*="bookTitle" i]',
          '[id*="book-title" i]', '[aria-label*="book title" i]'
        ].map(selector => document.querySelector(selector))
          .find(element => clean(element?.textContent))?.textContent;
        return {
          text: (selection || lines.join('\n\n')).slice(0, 2000000),
          title: clean(readerTitle || metaTitle || document.title).replace(/\s*[|–—-]\s*(Kindle|Amazon).*$/i, ''),
          host: location.hostname.replace(/^www\./, ''),
          href: location.href,
          selected: selection.length > 0
        };
      };
      const report = () => {
        const value = snapshot();
        if (value) window.webkit.messageHandlers.leConteurCapture.postMessage(value);
        return value;
      };
      const childFrames = (action, amount) => {
        for (const frame of document.querySelectorAll('iframe')) {
          try { frame.contentWindow.postMessage({ source: 'le-conteur', action, amount }, '*'); } catch (_) {}
        }
      };
      const scrollingTarget = () => {
        const candidates = [document.scrollingElement, ...document.querySelectorAll('*')].filter(Boolean);
        let best = document.scrollingElement || document.documentElement;
        let distance = Math.max(0, best.scrollHeight - best.clientHeight);
        for (const element of candidates) {
          const available = Math.max(0, element.scrollHeight - element.clientHeight);
          if (available <= distance + 4) continue;
          const style = getComputedStyle(element);
          if (element === document.scrollingElement || /(auto|scroll|overlay)/.test(style.overflowY)) {
            best = element;
            distance = available;
          }
        }
        return best;
      };
      const horizontalPageControl = direction => {
        const wanted = direction > 0
          ? /(?:\b(?:next|suivant|suivante|forward|right)\b|page\s+suivante|next(?:page|button|arrow))/i
          : /(?:\b(?:previous|precedent|précédent|précédente|back|left)\b|page\s+précédente|previous(?:page|button|arrow))/i;
        const elements = [...document.querySelectorAll('button,[role="button"],a,[tabindex]')];
        const visible = elements.filter(element => {
          const rect = element.getBoundingClientRect();
          const style = getComputedStyle(element);
          return rect.width >= 12 && rect.height >= 12 && rect.bottom > 0 && rect.top < innerHeight
            && rect.right > 0 && rect.left < innerWidth && style.visibility !== 'hidden'
            && style.display !== 'none' && Number(style.opacity) !== 0
            && !element.disabled && element.getAttribute('aria-disabled') !== 'true';
        });
        const label = element => clean([
          element.getAttribute('aria-label'), element.getAttribute('title'),
          element.getAttribute('data-testid'), element.textContent
        ].filter(Boolean).join(' '));
        let control = visible.find(element => wanted.test(label(element)));
        if (!control) {
          control = visible.filter(element => {
            const rect = element.getBoundingClientRect();
            const middle = rect.top + rect.height / 2;
            const atSide = direction > 0 ? rect.right >= innerWidth * 0.88 : rect.left <= innerWidth * 0.12;
            return atSide && middle >= innerHeight * 0.22 && middle <= innerHeight * 0.84
              && rect.width <= innerWidth * 0.22 && rect.height <= innerHeight * 0.45;
          }).sort((left, right) => {
            const a = left.getBoundingClientRect();
            const b = right.getBoundingClientRect();
            return Math.abs((a.top + a.height / 2) - innerHeight / 2)
              - Math.abs((b.top + b.height / 2) - innerHeight / 2);
          })[0];
        }
        if (!control) {
          const x = direction > 0 ? innerWidth * 0.975 : innerWidth * 0.025;
          let edge = document.elementFromPoint(x, innerHeight * 0.55);
          control = edge?.closest?.('button,[role="button"],a,[tabindex]') || edge;
        }
        if (!control || control === document.body || control === document.documentElement) return false;
        control.scrollIntoView({ block: 'nearest', inline: 'nearest' });
        const rect = control.getBoundingClientRect();
        const x = direction > 0 ? Math.min(innerWidth - 2, rect.right - 2) : Math.max(2, rect.left + 2);
        const y = Math.min(innerHeight - 2, Math.max(2, rect.top + rect.height / 2));
        for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click']) {
          control.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, view: window }));
        }
        // Certains contrôles Kindle ignorent les événements synthétiques mais
        // répondent à l'activation DOM standard, comme un toucher utilisateur.
        if (typeof control.click === 'function') control.click();
        return true;
      };
      const scroll = (action, amount) => {
        const target = scrollingTarget();
        if (action === 'captureOn') {
          for (const element of document.querySelectorAll('header,[role="banner"]')) {
            if (element.dataset.leConteurVisibility === undefined) {
              element.dataset.leConteurVisibility = element.style.visibility || '';
            }
            element.style.setProperty('visibility', 'hidden', 'important');
          }
          // Le lecteur Kindle affiche son chrome dans des éléments qui ne sont
          // pas toujours accessibles par des sélecteurs stables. Un toucher au
          // centre de la page est son mécanisme normal pour le refermer.
          requestAnimationFrame(() => {
            const x = innerWidth * 0.5;
            const y = innerHeight * 0.58;
            const hit = document.elementFromPoint(x, y);
            if (!hit) return;
            // A footnote or citation can cover the nominal centre point. Send
            // the gesture to the page rather than activating that link.
            const element = hit.closest('a,button,[role="button"],[onclick]')
              ? (document.body || document.documentElement) : hit;
            for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click']) {
              const EventType = type.startsWith('pointer') && typeof PointerEvent === 'function'
                ? PointerEvent : MouseEvent;
              element.dispatchEvent(new EventType(type, {
                bubbles: true, cancelable: true, clientX: x, clientY: y,
                pointerType: 'touch', isPrimary: true, view: window
              }));
            }
          });
        }
        if (action === 'captureOff') {
          for (const element of document.querySelectorAll('[data-le-conteur-visibility]')) {
            const previous = element.dataset.leConteurVisibility || '';
            if (previous) element.style.visibility = previous;
            else element.style.removeProperty('visibility');
            delete element.dataset.leConteurVisibility;
          }
        }
        if (action === 'save') window.__leConteurSavedScroll = { target, top: target.scrollTop };
        if (action === 'start') target.scrollTop = 0;
        if (action === 'layout') {
          requestAnimationFrame(() => dispatchEvent(new Event('resize')));
        }
        let paged = false;
        if (action === 'retreat' && Math.max(0, target.scrollHeight - target.clientHeight) <= 4) {
          paged = horizontalPageControl(-1);
        }
        if (action === 'advance') {
          const before = target.scrollTop;
          const maximum = Math.max(0, target.scrollHeight - target.clientHeight);
          target.scrollTop = Math.min(maximum, target.scrollTop + Number(amount || 0));
          if (maximum <= 4 || Math.abs(target.scrollTop - before) < 2) {
            paged = horizontalPageControl(1);
          }
        }
        if (action === 'restore' && window.__leConteurSavedScroll) {
          window.__leConteurSavedScroll.target.scrollTop = window.__leConteurSavedScroll.top;
        }
        childFrames(action, amount);
        setTimeout(report, paged ? 260 : 100);
        return { top: target.scrollTop, maximum: Math.max(0, target.scrollHeight - target.clientHeight), paged };
      };
      let timer;
      const later = () => { clearTimeout(timer); timer = setTimeout(report, 120); };
      window.__leConteurCapture = report;
      window.__leConteurScrollAll = scroll;
      addEventListener('message', event => {
        if (event.data?.source === 'le-conteur') scroll(event.data.action, event.data.amount);
      });
      addEventListener('load', later);
      addEventListener('scroll', later, { passive: true, capture: true });
      document.addEventListener('selectionchange', later);
      new MutationObserver(later).observe(document.documentElement, { childList: true, subtree: true, characterData: true });
      setTimeout(report, 100);
      setTimeout(report, 700);
      setTimeout(report, 2000);
    })();
    """#
}

private final class WebReadingCaptureHandler: NSObject, WKScriptMessageHandler {
    weak var browser: WebReadingBrowser?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let result = message.body as? [String: Any] else { return }
        Task { @MainActor [weak browser] in
            browser?.receiveCapture(result, frameURL: message.frameInfo.request.url)
        }
    }
}

private struct WebFrameCapture {
    let text: String
    let title: String
    let host: String
    let isSelection: Bool
    let capturedAt: Date

    var rank: Int {
        // Une sélection explicite doit toujours gagner. À défaut, le cadre du
        // livre est généralement celui qui contient le plus de texte lisible.
        (isSelection ? 10_000_000 : 0) + min(text.count, 9_000_000)
    }
}

private struct WebOCRLine {
    let text: String
    let box: CGRect
}

private struct WebOCRRecognition: Sendable {
    let text: String
    let titleCandidate: String
    let isLastPage: Bool
    let pageNumber: Int?
}

private struct WebOCRBook {
    let text: String
    let titleCandidate: String
    let coverData: Data?
}

private struct WebReadingBrowserView: UIViewRepresentable {
    let browser: WebReadingBrowser
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}

private struct WebPageCapture {
    let text: String
    let title: String
    let host: String
    let coverData: Data?
}

private enum WebReadingError: LocalizedError {
    case noVisibleText
    var errorDescription: String? {
        String(localized: "Aucun texte lisible n’est visible. Ouvrez un livre, affichez une page de texte, puis réessayez. Vous pouvez aussi sélectionner précisément le passage à lire.")
    }
}

struct ComposeView: View {
    @Environment(\.dismiss) private var dismiss
    var save: (ReadingDocument) -> Void
    @State private var title = ""
    @State private var text = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Une idée, un article,\nune histoire.").font(.system(size: 32, design: .serif))
                TextField("Titre de votre lecture", text: $title).textFieldStyle(.roundedBorder)
                TextEditor(text: $text).scrollContentBackground(.hidden).padding(12)
                    .background(ConteurTheme.card, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(alignment: .topLeading) { if text.isEmpty { Text("Écrivez ou collez votre texte ici…").foregroundStyle(.tertiary).padding(20).allowsHitTesting(false) } }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }.padding(24).background(ConteurTheme.paper)
                .navigationTitle("Nouveau texte").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Ajouter") {
                            do { let document = try DocumentImporter.fromText(text, title: title); dismiss(); save(document) }
                            catch { self.error = error.localizedDescription }
                        }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}
