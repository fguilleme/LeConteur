import SwiftUI

struct ReaderView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackController.self) private var playback
    @Environment(ReaderSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    let documentID: UUID
    @Environment(TranslationCoordinator.self) private var translation
    let openDocument: (UUID) -> Void
    let translate: (ReadingDocument) -> Void
    @State private var followsReading = true
    @State private var scrubPosition = 0.0
    @State private var isScrubbing = false
    @State private var showBookmarks = false
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var visibleRect = CGRect.zero
    @State private var contentHeight: CGFloat = 0
    @State private var currentWordFrame: ReaderWordFrame?
    @State private var requestedOffset: CGFloat?
    @State private var sharedBook: SharedBook?

    private var document: ReadingDocument? { library.document(documentID) }
    private var activeParagraph: Int {
        document?.paragraphRanges.firstIndex(where: { $0.contains(playback.position) }) ?? 0
    }

    var body: some View {
        NavigationStack {
            if let document {
                // Read both observable values outside the lazy row closures so every
                // speech callback invalidates the displayed highlight.
                let position = playback.position
                let wordRange = playback.wordRange
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .top, spacing: 18) {
                                    if document.coverFileName != nil {
                                        BookCover(title: document.title, coverFileName: document.coverFileName, large: true)
                                    }
                                    VStack(alignment: .leading, spacing: 10) {
                                        Eyebrow(text: document.source)
                                        Text(document.title).font(.system(size: document.coverFileName == nil ? 35 : 28, weight: .regular, design: .serif)).tracking(-0.7)
                                        Text(document.author).font(.subheadline).foregroundStyle(ConteurTheme.muted)
                                    }
                                }
                                if !document.isTranslationPending && document.resolvedLanguage != TranslationCoordinator.phoneLanguage {
                                    Button {
                                        playback.pause()
                                        translate(document)
                                    } label: {
                                        Label("Traduire en \(Locale.current.localizedString(forLanguageCode: TranslationCoordinator.phoneLanguage) ?? TranslationCoordinator.phoneLanguage)", systemImage: "translate")
                                            .font(.subheadline.weight(.semibold))
                                            .padding(.horizontal, 14).padding(.vertical, 10)
                                            .background(ConteurTheme.wash, in: Capsule())
                                    }.accessibilityIdentifier("reader-translate")
                                        .disabled(translation.isTranslating)
                                }
                                if document.isTranslationPending {
                                    let isActive = translation.isTranslating && translation.activeDocumentID == document.id
                                    if !isActive {
                                        Button {
                                            playback.pause()
                                            translate(document)
                                        } label: {
                                            Label("Reprendre la traduction", systemImage: "translate")
                                                .font(.subheadline.weight(.semibold))
                                                .padding(.horizontal, 14).padding(.vertical, 10)
                                                .background(ConteurTheme.wash, in: Capsule())
                                        }
                                        .accessibilityIdentifier("reader-translate")
                                    }
                                    if isActive {
                                        Button("Suspendre") { translation.suspend() }.font(.caption.weight(.semibold))
                                    }
                                    if let message = translation.errorMessage {
                                        Text(message).font(.caption).foregroundStyle(ConteurTheme.muted)
                                    }
                                }
                                if let original = document.translationOf {
                                    Button { openDocument(original) } label: { Label("Voir le texte original", systemImage: "text.book.closed") }.font(.caption)
                                }
                                HStack(spacing: 6) {
                                    Image(systemName: "waveform")
                                    Text(playback.voiceName)
                                    if playback.effectiveEngine != .system { Text("· Suivi des mots estimé") }
                                }.font(.caption2).foregroundStyle(ConteurTheme.muted).padding(.top, 8)
                                if let message = playback.voiceFallbackMessage {
                                    Text(message).font(.caption).foregroundStyle(ConteurTheme.muted)
                                    if playback.isUsingAppleForTranslation {
                                        Button("Écouter avec Qwen") { playback.selectEngine(.qwen) }
                                            .font(.caption.weight(.semibold))
                                    }
                                }
                            }.padding(.horizontal, 26).padding(.top, 16)
                            Rectangle().fill(ConteurTheme.ink.opacity(0.1)).frame(height: 1).padding(.horizontal, 26)
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(document.paragraphRanges.enumerated()), id: \.offset) { index, range in
                                    let content = ReaderParagraphContent(segments: Array(document.segments[range]), start: range.lowerBound, position: position, wordRange: wordRange)
                                    ReaderParagraphView(content: content, position: position, sourceRange: wordRange, textSize: settings.textSize)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 18).padding(.vertical, 16)
                                        .background(index == activeParagraph ? ConteurTheme.wash : Color.clear, in: RoundedRectangle(cornerRadius: 15))
                                        .overlay(alignment: .leading) {
                                            if index == activeParagraph {
                                                Capsule().fill(ConteurTheme.orange).frame(width: 3).padding(.vertical, 18)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                        .onTapGesture { playback.seek(to: range.lowerBound) }
                                        .accessibilityHint("Touchez deux fois pour reprendre la lecture à ce paragraphe")
                                        .accessibilityAddTraits(.isButton)
                                        .accessibilityIdentifier("reader-paragraph-\(index)")
                                        .id(index)
                                }
                            }.padding(.horizontal, 10)
                            Text(document.isTranslationPending ? String(localized: "Les prochains passages apparaîtront ici.") : String(localized: "Vous êtes arrivé à la dernière page.")).font(.caption).foregroundStyle(ConteurTheme.muted)
                                .frame(maxWidth: .infinity).padding(.vertical, 26)
                        }.coordinateSpace(name: "reader-content")
                    }
                    .scrollPosition($scrollPosition)
                    .onScrollGeometryChange(for: ReaderViewport.self) {
                        let visible = ReaderFollowScroll.visibleTextRect(offset: $0.contentOffset, size: $0.containerSize, insets: $0.contentInsets)
                        return ReaderViewport(visible: visible, contentHeight: $0.contentSize.height)
                    } action: { _, viewport in
                        visibleRect = viewport.visible
                        contentHeight = viewport.contentHeight
                    }
                    .onPreferenceChange(ReaderWordFrameKey.self) { frame in
                        guard let frame else { return }
                        currentWordFrame = frame
                        followWord(frame)
                    }
                    .onScrollPhaseChange { _, phase in
                        translation.setInterfaceScrolling(phase != .idle)
                        if phase == .interacting { followsReading = false }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !followsReading {
                            Button {
                                followsReading = true
                                requestedOffset = nil
                                if let frame = currentWordFrame, frame.position == playback.position, frame.sourceRange == playback.wordRange { followWord(frame) }
                                else { proxy.scrollTo(activeParagraph, anchor: .center) }
                            } label: { Label("Suivre la voix", systemImage: "arrow.down.to.line").font(.caption.weight(.semibold)) }
                                .padding(12).background(.regularMaterial, in: Capsule()).padding(16)
                        }
                    }
                    .onChange(of: activeParagraph) { _, index in
                        // Use the same resting point as word following. A short paragraph
                        // must not flash at the top before its word frame recentres it.
                        if followsReading { requestedOffset = nil; proxy.scrollTo(index, anchor: .center) }
                    }
                    .onAppear {
                        playback.open(document)
                        scrubPosition = Double(playback.position)
                        if playback.position > 0 { proxy.scrollTo(activeParagraph, anchor: .center) }
                    }
                    .onDisappear { translation.setInterfaceScrolling(false) }
                    .safeAreaInset(edge: .bottom, spacing: 0) { controls(document) }
                }
                .background(ConteurTheme.paper).foregroundStyle(ConteurTheme.ink)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "chevron.down") }.accessibilityLabel("Fermer le lecteur") }
                    ToolbarItem(placement: .principal) {
                        Button {
                            followsReading = false
                            requestedOffset = 0
                            withAnimation(.easeInOut(duration: 0.3)) {
                                scrollPosition.scrollTo(edge: .top)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if let image = BookCoverStore.image(named: document.coverFileName) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 24, height: 32)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                        .accessibilityHidden(true)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(document.title)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                    if document.isTranslationPending {
                                        let isActive = translation.isTranslating && translation.activeDocumentID == document.id
                                        ReaderTranslationGauge(
                                            progress: isActive ? max(translation.progress, document.translationProgress) : document.translationProgress,
                                            isActive: isActive
                                        )
                                    }
                                }
                            }
                            .frame(maxWidth: 220)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Revenir au début de \(document.title)")
                        .accessibilityIdentifier("reader-scroll-to-top")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if settings.engine == .qwen {
                                ForEach(NarrationStyle.allCases) { style in
                                    Button(style.name, systemImage: settings.qwenStyle == style ? "checkmark" : style.icon) { playback.selectQwenStyle(style) }
                                }
                                Divider()
                            }
                            Button("Mes signets", systemImage: "bookmark") { showBookmarks = true }
                            if document.translationOf != nil && !document.isTranslationPending {
                                Button("Partager la traduction", systemImage: "square.and.arrow.up") { export(document) }
                            }
                            Button("Agrandir le texte", systemImage: "textformat.size.larger") { settings.textSize = min(34, settings.textSize + 2) }
                            Button("Réduire le texte", systemImage: "textformat.size.smaller") { settings.textSize = max(16, settings.textSize - 2) }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Options de lecture")
                        .accessibilityIdentifier("reader-options")
                    }
                }
                .sheet(isPresented: $showBookmarks) {
                    NavigationStack {
                        List {
                            if document.bookmarks.isEmpty { ContentUnavailableView("Aucun signet", systemImage: "bookmark", description: Text("Marquez un passage avec le bouton signet du lecteur.")) }
                            ForEach(document.bookmarks.sorted(), id: \.self) { index in
                                if document.segments.indices.contains(index) {
                                    Button { playback.seek(to: index); followsReading = true; showBookmarks = false } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("Passage \(index + 1)").font(.caption).foregroundStyle(.secondary)
                                            Text(document.segments[index]).lineLimit(3)
                                        }
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            library.toggleBookmark(id: document.id, position: index)
                                        } label: {
                                            Label("Supprimer", systemImage: "trash")
                                        }
                                        .accessibilityIdentifier("delete-bookmark-\(index)")
                                    }
                                }
                            }
                        }.navigationTitle("Signets")
                            .toolbar { Button("Terminer") { showBookmarks = false } }
                    }.presentationDetents([.medium, .large])
                }
                .sheet(item: $sharedBook) { BookShareSheet(url: $0.url).ignoresSafeArea() }
                .alert("Lecture", isPresented: Binding(get: { playback.errorMessage != nil }, set: { if !$0 { playback.errorMessage = nil } })) {
                    Button("D’accord", role: .cancel) { playback.errorMessage = nil }
                } message: { Text(playback.errorMessage ?? "") }
            }
        }
    }

    private func export(_ document: ReadingDocument) {
        playback.pause()
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) { try EPUBExporter.export(document) }.value
                sharedBook = SharedBook(url: url)
            } catch {
                playback.errorMessage = String(format: String(localized: "Impossible de préparer l’EPUB : %@"), error.localizedDescription)
            }
        }
    }

    private func followWord(_ frame: ReaderWordFrame) {
        guard followsReading, !isScrubbing, frame.position == playback.position,
              frame.sourceRange == playback.wordRange,
              let offset = ReaderFollowScroll.offset(word: frame.rect, visible: visibleRect, contentHeight: contentHeight),
              requestedOffset.map({ abs($0 - offset) > 1 }) ?? true else { return }
        requestedOffset = offset
        withAnimation(.easeInOut(duration: 0.22)) { scrollPosition.scrollTo(y: offset) }
    }

    private func controls(_ document: ReadingDocument) -> some View {
        VStack(spacing: 12) {
            if let notice = playback.notice { Text(notice).font(.caption).foregroundStyle(ConteurTheme.muted) }
            if let reserve = playback.qwenReserve { QwenReserveGauge(reserve: reserve) }
            HStack {
                Text(playback.isWaitingForTranslation ? String(localized: "En attente de la suite…") : playback.isPreparing && playback.qwenReserve == nil ? playback.preparationStatus : document.isFinished ? String(localized: "Lecture terminée") : String(format: String(localized: "Passage %lld sur %lld"), Int64(playback.position + 1), Int64(document.segments.count)))
                Spacer()
                Text("\(Int(document.progress * 100)) %")
            }.font(.caption2).monospacedDigit().foregroundStyle(ConteurTheme.muted)
            Slider(value: $scrubPosition, in: 0...Double(max(1, document.segments.count - 1)), step: 1) { editing in
                isScrubbing = editing
                if !editing { playback.seek(to: Int(scrubPosition)) }
            }.accessibilityLabel("Position de lecture")
                .disabled(document.segments.count < 2)
                .onChange(of: playback.position) { _, value in if !isScrubbing { scrubPosition = Double(value) } }
            HStack {
                Menu {
                    ForEach(playback.effectiveEngine == .qwen ? [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5] : [0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { value in
                        Button("\(value.formatted())×") { playback.setSpeed(value) }
                    }
                } label: { Text("\(playback.playbackSpeed.formatted())×").font(.subheadline.weight(.semibold)).frame(width: 48, height: 48) }
                    .accessibilityLabel("Vitesse de lecture")
                Spacer()
                Button { playback.skip(-1) } label: { Image(systemName: "backward.end.fill").font(.title3).frame(width: 44, height: 48) }
                    .accessibilityLabel("Passage précédent").disabled(playback.position == 0)
                Button { playback.toggle() } label: {
                    ZStack {
                        Circle().fill(ConteurTheme.green).frame(width: 66, height: 66)
                        if playback.isPreparing || playback.isWaitingForTranslation { ProgressView().tint(.white) }
                        else { Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 25)).foregroundStyle(.white) }
                    }
                }.accessibilityLabel(playback.isPlaying ? String(localized: "Pause") : String(localized: "Lire"))
                Button { playback.skip(1) } label: { Image(systemName: "forward.end.fill").font(.title3).frame(width: 44, height: 48) }
                    .accessibilityLabel("Passage suivant").disabled(playback.position >= document.segments.count - 1)
                Spacer()
                Button { library.toggleBookmark(id: document.id, position: playback.position) } label: {
                    Image(systemName: document.bookmarks.contains(playback.position) ? "bookmark.fill" : "bookmark").frame(width: 48, height: 48)
                }.accessibilityLabel("Marquer ce passage")
            }.foregroundStyle(ConteurTheme.ink)
            Menu {
                ForEach([5, 15, 30, 60], id: \.self) { minutes in Button(String(format: String(localized: "%lld minutes"), Int64(minutes))) { playback.setSleepTimer(minutes: minutes) } }
                Button("Désactiver la minuterie") { playback.setSleepTimer(minutes: nil) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "moon")
                    if let deadline = playback.sleepDeadline { Text("Arrêt à \(deadline.formatted(date: .omitted, time: .shortened))") }
                    else { Text("Minuterie de sommeil") }
                }.font(.caption2).foregroundStyle(ConteurTheme.muted).frame(minHeight: 28)
            }
        }.padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 8)
            .background(ConteurTheme.paper.shadow(.drop(color: .black.opacity(0.05), radius: 12, y: -4)))
    }
}

private struct ReaderTranslationGauge: View {
    let progress: Double
    let isActive: Bool

    private var value: Double { min(1, max(0, progress)) }
    private var percentage: Int { Int((value * 100).rounded(.down)) }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isActive ? "translate" : "pause.circle")
                .font(.system(size: 8, weight: .semibold))
            ProgressView(value: value)
                .tint(isActive ? ConteurTheme.green : ConteurTheme.muted)
                .frame(maxWidth: 105)
            Text("\(percentage) %")
                .font(.system(size: 8, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(ConteurTheme.muted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isActive ? String(localized: "Traduction en cours") : String(localized: "Traduction en pause"))
        .accessibilityValue(String(format: String(localized: "%lld pour cent"), Int64(percentage)))
    }
}

private struct ReaderViewport: Equatable {
    let visible: CGRect
    let contentHeight: CGFloat
}
