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
                                                if document.source == "EPUB" {
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
        }
    }

    private func remainingTime(for document: ReadingDocument) -> String {
        let seconds = document.isFinished ? 0 : document.secondsUntilBookEnd(rate: playback.playbackSpeed)
        let minutes = Int(ceil(seconds / 60))
        return String(format: String(localized: "%lld min restantes"), Int64(minutes))
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
    @State private var errorMessage: String?
    let read: (ReadingDocument) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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

                WebReadingBrowserView(browser: browser)
                    .overlay {
                        if browser.isLoading { ProgressView().controlSize(.large) }
                    }

                VStack(spacing: 10) {
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                    }
                    Button {
                        if isExtracting {
                            browser.finishCaptureNow()
                        } else {
                            Task { await readCurrentPage() }
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
                    Text("Le Conteur parcourt le livre jusqu’à sa fin et ignore toujours les champs de connexion. Votre session Amazon reste dans ce navigateur.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(14).background(ConteurTheme.wash)
            }
            .background(ConteurTheme.paper)
            .navigationTitle("Lecture web")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
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
            .onChange(of: browser.currentURL) { _, value in
                if let value { address = value.absoluteString }
            }
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
    }
}

@MainActor private final class WebReadingBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var currentURL: URL?
    @Published private(set) var captureStatus = String(localized: "Analyse du livre…")
    let webView: WKWebView
    private let captureHandler: WebReadingCaptureHandler
    private var frameCaptures: [String: WebFrameCapture] = [:]
    private var captureShouldFinish = false

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
    func finishCaptureNow() {
        captureShouldFinish = true
        captureStatus = String(localized: "Finalisation de l’import…")
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        frameCaptures.removeAll()
        refresh()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { refresh() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { refresh() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { refresh() }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url { load(url) }
        return nil
    }

    private func refresh() {
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        currentURL = webView.url
    }

    func captureVisibleText() async throws -> WebPageCapture {
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
                text: book.text,
                title: preferredBookTitle(visualCandidate: book.titleCandidate),
                host: webView.url?.host() ?? "amazon.fr",
                coverData: book.coverData
            )
        }
        guard let capture = frameCaptures.values.max(by: { $0.rank < $1.rank }),
              capture.text.count >= 20 else { throw WebReadingError.noVisibleText }
        return WebPageCapture(
            text: capture.text,
            title: capture.title.isEmpty ? webView.title ?? "" : capture.title,
            host: webView.url?.host() ?? capture.host,
            coverData: nil
        )
    }

    private func recognizeDisplayedText() async throws -> WebOCRBook {
        let originalOffset = webView.scrollView.contentOffset
        let viewportHeight = max(1, webView.bounds.height)
        var combined = ""
        var firstPageCover: Data?
        var firstPageTitle = ""
        var unchangedScreens = 0
        captureShouldFinish = false
        captureStatus = String(localized: "Recherche du début du livre…")
        _ = try? await webView.evaluateJavaScript("window.__leConteurScrollAll && window.__leConteurScrollAll('save', 0)")
        _ = try? await webView.evaluateJavaScript("window.__leConteurScrollAll && window.__leConteurScrollAll('start', 0)")
        defer {
            captureStatus = String(localized: "Analyse du livre…")
            webView.evaluateJavaScript("window.__leConteurScrollAll && window.__leConteurScrollAll('restore', 0)", completionHandler: nil)
            webView.scrollView.setContentOffset(originalOffset, animated: false)
        }

        // Le lecteur Kindle déroule le livre au lieu d'exposer son texte.
        // Photographier des vues qui se chevauchent permet de reconstituer le
        // contenu, même lorsque son DOM est volontairement inaccessible. Le
        // plafond protège uniquement contre une page qui bouclerait sans fin.
        for screen in 0..<2400 {
            captureStatus = String(localized: "Analyse du livre… écran \(screen + 1)")
            try await Task.sleep(for: .milliseconds(screen == 0 ? 900 : 380))
            let image = try await webView.takeSnapshot(configuration: nil)
            guard let cgImage = image.cgImage else { continue }
            let recognized = try await Self.recognizeText(in: cgImage)
            if screen == 0 {
                firstPageCover = image.jpegData(compressionQuality: 0.86)
                firstPageTitle = recognized.titleCandidate
            }
            let merged = Self.mergingOCR(combined, with: recognized.text)
            if merged.count <= combined.count + 12 { unchangedScreens += 1 }
            else { unchangedScreens = 0 }
            combined = merged

            if captureShouldFinish || unchangedScreens >= 6 || combined.count >= 1_950_000 { break }
            _ = try? await webView.evaluateJavaScript(
                "window.__leConteurScrollAll && window.__leConteurScrollAll('advance', \(viewportHeight * 0.68))"
            )
        }
        return WebOCRBook(text: combined, titleCandidate: firstPageTitle, coverData: firstPageCover)
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

    nonisolated private static func recognizeText(in cgImage: CGImage) async throws -> WebOCRRecognition {
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
            guard !lines.isEmpty else { return WebOCRRecognition(text: "", titleCandidate: "") }
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
            var result = ""
            var previous: WebOCRLine?
            for line in lines {
                if let previous {
                    let verticalGap = previous.box.minY - line.box.maxY
                    result += verticalGap > typicalHeight * 1.15 ? "\n\n" : " "
                }
                result += line.text
                previous = line
            }
            return WebOCRRecognition(text: result, titleCandidate: titleCandidate)
        }.value
    }

    nonisolated private static func mergingOCR(_ existing: String, with addition: String) -> String {
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
        guard !newWords.isEmpty else { return existing }
        guard !oldWords.isEmpty else { return addition }
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
            return existing.trimmingCharacters(in: .whitespacesAndNewlines) + separator + tail
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
            let overlap = min(newWords.count, newMatchStart + oldWords.count - oldMatchStart)
            return appendingTail(dropping: overlap)
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
        return previousText + (terminal && startsUppercase ? "\n\n" : " ") + next
    }

    fileprivate func receiveCapture(_ result: [String: Any], frameURL: URL?) {
        guard let text = result["text"] as? String else { return }
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
      const clean = value => (value || '').replace(/\s+/g, ' ').trim();
      const snapshot = () => {
        const entries = [];
        if (!document.body) return null;
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        let node;
        while ((node = walker.nextNode())) {
          const text = clean(node.nodeValue);
          const parent = node.parentElement;
          if (!text || !parent || parent.closest('script,style,noscript,nav,header,footer,button,input,textarea,select,[aria-hidden="true"]')) continue;
          const style = getComputedStyle(parent);
          if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          const rect = range.getBoundingClientRect();
          if (!rect.width || !rect.height || rect.bottom < 0 || rect.top > innerHeight || rect.right < 0 || rect.left > innerWidth) continue;
          if (parseFloat(style.fontSize) < 11) continue;
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
      const scroll = (action, amount) => {
        const target = scrollingTarget();
        if (action === 'save') window.__leConteurSavedScroll = { target, top: target.scrollTop };
        if (action === 'start') target.scrollTop = 0;
        if (action === 'advance') target.scrollTop = Math.min(target.scrollHeight - target.clientHeight, target.scrollTop + Number(amount || 0));
        if (action === 'restore' && window.__leConteurSavedScroll) {
          window.__leConteurSavedScroll.target.scrollTop = window.__leConteurSavedScroll.top;
        }
        childFrames(action, amount);
        setTimeout(report, 100);
        return { top: target.scrollTop, maximum: Math.max(0, target.scrollHeight - target.clientHeight) };
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
