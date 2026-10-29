import SwiftUI
import UniformTypeIdentifiers
import Translation

@main
struct LeConteurApp: App {
    @UIApplicationDelegateAdaptor(ConteurAppDelegate.self) private var appDelegate
    @State private var library: LibraryStore
    @State private var settings: ReaderSettings
    @State private var playback: PlaybackController
    @State private var translation: TranslationCoordinator
    @State private var qwenStore = QwenModelStore()
    @State private var supertonicStore = SupertonicModelStore()

    init() {
        let library = LibraryStore()
        let settings = ReaderSettings()
        _library = State(initialValue: library)
        _settings = State(initialValue: settings)
        let playback = PlaybackController(library: library, settings: settings)
        _playback = State(initialValue: playback)
        let translation = TranslationCoordinator(library: library,
            documentUpdated: { playback.translationUpdated($0) },
            activityChanged: { playback.translationActivityChanged($0) },
            prepareVoice: { await playback.prepareForTranslation() })
        playback.suspendTranslation = { [weak translation] in translation?.suspend() }
        _translation = State(initialValue: translation)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG || CONTEUR_VALIDATION
                if CommandLine.arguments.contains("--voice-download-validation") {
                    VoiceDownloadValidationView()
                } else if CommandLine.arguments.contains("--qwen-repeatability-validation") {
                    QwenRepeatabilityValidationView()
                } else if CommandLine.arguments.contains("--qwen-precision-validation") {
                    QwenPrecisionValidationView()
                } else if CommandLine.arguments.contains("--qwen-pronunciation-validation") || CommandLine.arguments.contains("--qwen-stability-validation") || CommandLine.arguments.contains("--qwen-silence-validation") || CommandLine.arguments.contains("--qwen-decoder-validation") || CommandLine.arguments.contains("--qwen-refill-validation") || CommandLine.arguments.contains("--qwen-short-text-validation") {
                    QwenPronunciationValidationView()
                } else if CommandLine.arguments.contains("--qwen-stream-validation") || CommandLine.arguments.contains("--supertonic-stream-validation") {
                    QwenStreamValidationView()
                } else { normalContent }
                #else
                normalContent
                #endif
            }
            .environment(library).environment(settings).environment(playback)
            .environment(translation).environment(qwenStore).environment(supertonicStore)
            .tint(ConteurTheme.green)
        }
    }

    @ViewBuilder private var normalContent: some View {
        #if DEBUG
        if CommandLine.arguments.contains("--reserve-gauge-validation") {
            QwenReserveGaugeValidationView()
        } else if CommandLine.arguments.contains("--reader-translation-validation") {
            ReaderTranslationValidationView()
        } else if CommandLine.arguments.contains("--qwen-validation") || CommandLine.arguments.contains("--translation-validation") {
            DeviceValidationView(store: qwenStore)
        } else { RootView() }
        #else
        RootView()
        #endif
    }
}

private struct ReaderSelection: Identifiable {
    let id: UUID
    var automaticallyTranslate = false
    var keepsBackgroundTranslation = false
}

struct RootView: View {
    private enum Tab: Hashable { case library, voices }

    @Environment(LibraryStore.self) private var library
    @Environment(ReaderSettings.self) private var settings
    @Environment(PlaybackController.self) private var playback
    @Environment(TranslationCoordinator.self) private var translation
    @Environment(\.scenePhase) private var scenePhase
    @State private var reader: ReaderSelection?
    @State private var selectedTab: Tab = CommandLine.arguments.contains("--localization-voices") ? .voices : .library
    @State private var showImporter = false
    @State private var showComposer = CommandLine.arguments.contains("--localization-compose")
    @State private var importing = false
    @State private var processingInbox = false
    @State private var error: String?

    var body: some View {
        TabView(selection: $selectedTab) {
            LibraryView(open: open, importFile: { showImporter = true }, compose: { showComposer = true })
                .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
                .tabItem { Label("Bibliothèque", systemImage: "books.vertical") }
                .tag(Tab.library)
            VoicesView()
                .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
                .tabItem { Label("Voix", systemImage: "waveform") }
                .tag(Tab.voices)
        }
        .sheet(item: $reader) { selection in
            ReadingSessionView(documentID: selection.id,
                               automaticallyTranslate: selection.automaticallyTranslate,
                               usesBackgroundTranslationSession: selection.keepsBackgroundTranslation)
        }
        .translationTask(reader == nil || reader?.keepsBackgroundTranslation == true ? translation.configuration : nil) { session in
            await Task(priority: .utility) { await translation.translate(using: session) }.value
        }
        .sheet(isPresented: $showComposer) { ComposeView { document in if library.add(document) { open(document) } } }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [
            UTType("org.idpf.epub-container") ?? .data,
            .pdf,
            UTType("org.openxmlformats.wordprocessingml.document") ?? .data,
            .plainText,
            UTType("net.daringfireball.markdown") ?? .plainText
        ]) { result in
            switch result {
            case .success(let url): Task { await importFile(url) }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .onOpenURL { url in Task { await importFile(url) } }
        .task { await consumeInbox() }
        .task {
            #if DEBUG
            if CommandLine.arguments.contains("--localization-reader") {
                try? await Task.sleep(for: .milliseconds(350))
                if reader == nil, let document = library.documents.first {
                    open(document)
                }
            }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                VoiceDownloads.shared.foreground()
                translation.applicationDidBecomeActive()
                Task { await consumeInbox() }
            } else if phase == .background {
                translation.applicationDidEnterBackground()
            }
        }
        .onChange(of: settings.engine) { playback.settingsChanged() }
        .onChange(of: settings.qwenStyle) { playback.settingsChanged() }
        .onChange(of: settings.qwenSpeaker) { if playback.effectiveEngine == .qwen { playback.settingsChanged() } }
        .onChange(of: settings.supertonicVoice) { if playback.effectiveEngine == .supertonic { playback.settingsChanged() } }
        .onChange(of: settings.elevenLabsVoiceID) { if playback.effectiveEngine == .elevenLabs { playback.settingsChanged() } }
        .onChange(of: settings.fishAudioVoiceID) { if playback.effectiveEngine == .fishAudio { playback.settingsChanged() } }
        .onChange(of: settings.systemVoiceIDs) { old, new in
            let language = SystemVoiceSelection.language(playback.document?.languageCode ?? TranslationCoordinator.phoneLanguage)
            if old[language] != new[language], playback.effectiveEngine == .system { playback.settingsChanged() }
        }
        .onChange(of: settings.speed) { if playback.effectiveEngine != .qwen { playback.speedChanged() } }
        .onChange(of: settings.qwenSpeed) { if playback.effectiveEngine == .qwen { playback.speedChanged() } }
        .onChange(of: settings.qwenBuffer) { playback.qwenBufferChanged() }
        .onChange(of: library.errorMessage) { _, message in if let message { error = message; library.errorMessage = nil } }
        .overlay {
            if importing {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    VStack(spacing: 20) {
                        ProgressView()
                        Text("Ouverture du document…").font(.title3.bold())
                    }
                    .padding(28).background(ConteurTheme.paper, in: RoundedRectangle(cornerRadius: 24))
                }
            }
        }
        .alert("Le Conteur", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("D’accord", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    @ViewBuilder private var miniPlayer: some View {
        if let document = playback.document, !playback.isPreview {
            HStack(spacing: 14) {
                Button { open(document) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform").font(.title2).frame(width: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(document.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if let reserve = playback.qwenReserve {
                                QwenReserveGauge(reserve: reserve, compact: true)
                            } else {
                                Text(playback.isPreparing ? String(localized: "Préparation de la voix…") : playback.voiceName).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Button { playback.toggle() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                }.accessibilityLabel(playback.isPlaying ? "Pause" : "Lire")
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(ConteurTheme.wash).foregroundStyle(ConteurTheme.ink)
        }
    }

    private func open(_ document: ReadingDocument) {
        playback.pause()
        let route = library.readingRoute(for: document, phoneLanguage: TranslationCoordinator.phoneLanguage)
        // Opening a readable edition must not tear down and recreate an active
        // Apple Translation session. The root keeps owning that session while
        // the reader sheet simply displays the same progressively saved book.
        let isActiveTranslation = translation.isTranslating
            && translation.activeDocumentID == route.document.id
        let keepCurrentSession = translation.isTranslating
            && (!route.translate || isActiveTranslation)
        library.rememberCurrentDocument(route.document.id)
        reader = ReaderSelection(id: route.document.id,
                                 automaticallyTranslate: route.translate && !isActiveTranslation,
                                 keepsBackgroundTranslation: keepCurrentSession)
    }

    private func importFile(_ url: URL) async {
        importing = true
        defer { importing = false }
        do {
            let document = try await Task.detached(priority: .userInitiated) { try DocumentImporter.fromFile(url) }.value
            if let saved = library.importDocument(document) { open(saved) }
        } catch { self.error = error.localizedDescription }
    }

    private func consumeInbox() async {
        guard !processingInbox else { return }
        processingInbox = true
        defer { processingInbox = false }
        do {
            for url in try SharedInbox.pendingFiles() {
                do {
                    let document = try await Task.detached { try DocumentImporter.fromFile(url) }.value
                    guard library.importDocument(document) != nil else { return }
                    try FileManager.default.removeItem(at: url.deletingLastPathComponent())
                } catch {
                    // Keep an unreadable original for recovery, outside the pending queue.
                    let failed = url.deletingLastPathComponent().deletingLastPathComponent().appending(path: ".failed-\(UUID().uuidString)")
                    try? FileManager.default.moveItem(at: url.deletingLastPathComponent(), to: failed)
                    self.error = "\(url.lastPathComponent) : \(error.localizedDescription)"
                }
            }
        } catch { self.error = error.localizedDescription }
    }
}
