import SwiftUI
import UIKit

struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackController.self) private var playback
    @Environment(TranslationCoordinator.self) private var translation
    let open: (ReadingDocument) -> Void
    let importFile: () -> Void
    let compose: () -> Void
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

                    if search.isEmpty, filter == 0, let featured = library.documents.first(where: { $0.position > 0 && !$0.isFinished }) ?? library.documents.first {
                        Button { open(featured) } label: {
                            HStack(alignment: .center, spacing: 21) {
                                BookCover(title: featured.title, coverFileName: featured.coverFileName, large: true)
                                    .rotationEffect(.degrees(-4)).shadow(color: ConteurTheme.ink.opacity(0.18), radius: 8, x: 2, y: 6)
                                VStack(alignment: .leading, spacing: 12) {
                                    Eyebrow(text: featured.position > 0 ? String(localized: "REPRENDRE") : String(localized: "À ÉCOUTER"))
                                    Text(featured.title).font(.system(size: 25, weight: .medium, design: .serif)).lineLimit(3)
                                    Text(String(format: String(localized: "%lld min d’écoute estimées"), Int64(featured.minutes))).font(.caption).foregroundStyle(ConteurTheme.muted)
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
                                                Text(String(format: String(localized: "·  %lld min"), Int64(document.minutes))).font(.caption)
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
