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

    private var document: ReadingDocument? { library.document(documentID) }
    private var activeParagraph: Int {
        document?.paragraphRanges.firstIndex(where: { $0.contains(playback.position) }) ?? 0
    }

    var body: some View {
        NavigationStack {
            if let document {
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
                                if document.isTranslationPending || document.resolvedLanguage != TranslationCoordinator.phoneLanguage {
                                    Button {
                                        playback.pause()
                                        translate(document)
                                    } label: {
                                        Label(document.isTranslationPending ? "Reprendre la traduction" : "Traduire en \(Locale(identifier: "fr").localizedString(forLanguageCode: TranslationCoordinator.phoneLanguage) ?? TranslationCoordinator.phoneLanguage)", systemImage: "translate")
                                            .font(.subheadline.weight(.semibold))
                                            .padding(.horizontal, 14).padding(.vertical, 10)
                                            .background(ConteurTheme.wash, in: Capsule())
                                    }.accessibilityIdentifier("reader-translate")
                                        .disabled(translation.isTranslating)
                                }
                                if document.isTranslationPending {
                                    HStack {
                                        Text(translation.isTranslating ? "La suite se traduit · \(Int(translation.progress * 100)) %" : "Traduction en pause")
                                            .font(.caption).foregroundStyle(ConteurTheme.muted)
                                        if translation.isTranslating {
                                            Button("Suspendre") { translation.cancel() }.font(.caption)
                                        }
                                    }
                                    if settings.engine == .qwen {
                                        Text("Voix iPhone pour écouter pendant la traduction.").font(.caption2).foregroundStyle(ConteurTheme.muted)
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
                            }.padding(.horizontal, 26).padding(.top, 16)
                            Rectangle().fill(ConteurTheme.ink.opacity(0.1)).frame(height: 1).padding(.horizontal, 26)
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(document.paragraphRanges.enumerated()), id: \.offset) { index, range in
                                    Text(highlightedText(document, range: range))
                                        .font(.system(size: settings.textSize, weight: .regular, design: .serif))
                                        .lineSpacing(9)
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
                                        .id(index)
                                }
                            }.padding(.horizontal, 10)
                            Text(document.isTranslationPending ? "Les prochains passages apparaîtront ici." : "Vous êtes arrivé à la dernière page.").font(.caption).foregroundStyle(ConteurTheme.muted)
                                .frame(maxWidth: .infinity).padding(.vertical, 26)
                        }
                    }
                    .onScrollPhaseChange { _, phase in if phase == .interacting { followsReading = false } }
                    .overlay(alignment: .bottomTrailing) {
                        if !followsReading {
                            Button {
                                followsReading = true
                                withAnimation { proxy.scrollTo(activeParagraph, anchor: .center) }
                            } label: { Label("Suivre la voix", systemImage: "arrow.down.to.line").font(.caption.weight(.semibold)) }
                                .padding(12).background(.regularMaterial, in: Capsule()).padding(16)
                        }
                    }
                    .onChange(of: activeParagraph) { _, index in
                        if followsReading { withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(index, anchor: .center) } }
                    }
                    .onAppear {
                        playback.open(document)
                        scrubPosition = Double(playback.position)
                        if playback.position > 0 { proxy.scrollTo(activeParagraph, anchor: .center) }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) { controls(document) }
                }
                .background(ConteurTheme.paper).foregroundStyle(ConteurTheme.ink)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "chevron.down") }.accessibilityLabel("Fermer le lecteur") }
                    ToolbarItem(placement: .principal) { Eyebrow(text: "LE PLAISIR D’ÉCOUTER") }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if settings.engine == .qwen {
                                ForEach(NarrationStyle.allCases) { style in
                                    Button(style.name, systemImage: settings.qwenStyle == style ? "checkmark" : style.icon) { settings.qwenStyle = style }
                                }
                                Divider()
                            }
                            Button("Mes signets", systemImage: "bookmark") { showBookmarks = true }
                            Button("Agrandir le texte", systemImage: "textformat.size.larger") { settings.textSize = min(34, settings.textSize + 2) }
                            Button("Réduire le texte", systemImage: "textformat.size.smaller") { settings.textSize = max(16, settings.textSize - 2) }
                        } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Options de lecture")
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
                                }
                            }
                        }.navigationTitle("Signets")
                            .toolbar { Button("Terminer") { showBookmarks = false } }
                    }.presentationDetents([.medium, .large])
                }
                .alert("Lecture", isPresented: Binding(get: { playback.errorMessage != nil }, set: { if !$0 { playback.errorMessage = nil } })) {
                    Button("D’accord", role: .cancel) { playback.errorMessage = nil }
                } message: { Text(playback.errorMessage ?? "") }
            }
        }
    }

    private func highlightedText(_ document: ReadingDocument, range: Range<Int>) -> AttributedString {
        var result = AttributedString()
        for index in range {
            let sentence = document.segments[index]
            var part = AttributedString(sentence)
            part.foregroundColor = ConteurTheme.ink.opacity(range.contains(playback.position) ? 1 : 0.76)
            if index == playback.position, let wordRange = playback.wordRange,
               let stringRange = Range(wordRange, in: sentence),
               let start = AttributedString.Index(stringRange.lowerBound, within: part),
               let end = AttributedString.Index(stringRange.upperBound, within: part) {
                part[start..<end].backgroundColor = ConteurTheme.green
                part[start..<end].foregroundColor = .white
            }
            result.append(part)
            if index < range.upperBound - 1 { result.append(AttributedString(" ")) }
        }
        return result
    }

    private func controls(_ document: ReadingDocument) -> some View {
        VStack(spacing: 12) {
            if let notice = playback.notice { Text(notice).font(.caption).foregroundStyle(ConteurTheme.muted) }
            HStack {
                Text(playback.isWaitingForTranslation ? "En attente de la suite…" : playback.isPreparing ? playback.preparationStatus : document.isFinished ? "Lecture terminée" : "Passage \(playback.position + 1) sur \(document.segments.count)")
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
                }.accessibilityLabel(playback.isPlaying ? "Pause" : "Lire")
                Button { playback.skip(1) } label: { Image(systemName: "forward.end.fill").font(.title3).frame(width: 44, height: 48) }
                    .accessibilityLabel("Passage suivant").disabled(playback.position >= document.segments.count - 1)
                Spacer()
                Button { library.toggleBookmark(id: document.id, position: playback.position) } label: {
                    Image(systemName: document.bookmarks.contains(playback.position) ? "bookmark.fill" : "bookmark").frame(width: 48, height: 48)
                }.accessibilityLabel("Marquer ce passage")
            }.foregroundStyle(ConteurTheme.ink)
            Menu {
                ForEach([5, 15, 30, 60], id: \.self) { minutes in Button("\(minutes) minutes") { playback.setSleepTimer(minutes: minutes) } }
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
