import SwiftUI

struct OnlineVoiceCard: View {
    let provider: OnlineVoiceProvider
    @Environment(ReaderSettings.self) private var settings
    @Environment(PlaybackController.self) private var playback
    @State private var key = ""
    @State private var hasKey = false
    @State private var voices: [OnlineVoice] = []
    @State private var isLoading = false
    @State private var isEditingKey = false
    @State private var showsVoicePicker = false
    @State private var errorMessage: String?

    private var selectedVoiceID: String { settings.onlineVoiceID(for: provider) }
    private var selectedVoiceName: String { settings.onlineVoiceName(for: provider) }
    private var isSelected: Bool { settings.engine == provider.engine }
    private var isPreviewing: Bool {
        playback.isPreview && playback.effectiveEngine == provider.engine
            && (playback.isPlaying || playback.isPreparing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: provider == .elevenLabs ? "waveform.badge.mic" : "fish")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.name).font(.system(size: 28, design: .serif))
                    Text("HAUTE QUALITÉ · EN LIGNE").font(.system(size: 9, weight: .semibold)).tracking(1.3)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2).foregroundStyle(ConteurTheme.green)
            }

            Text(String(format: String(localized: "Des voix naturelles, expressives et multilingues générées par %@."), provider.name))
                .font(.subheadline).foregroundStyle(ConteurTheme.muted)
            Text("La lecture nécessite Internet et consomme les crédits de votre compte. Seuls les passages lus sont envoyés au fournisseur choisi.")
                .font(.caption).foregroundStyle(.secondary)

            Link(destination: provider.keyURL) {
                Label("Créer ou gérer ma clé API", systemImage: "arrow.up.right.square")
            }

            if !hasKey || isEditingKey {
                SecureField("Clé API", text: $key)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(ConteurTheme.paper, in: RoundedRectangle(cornerRadius: 12))
                HStack {
                    Button("Enregistrer la clé") { saveKey() }
                        .buttonStyle(.borderedProminent).foregroundStyle(.white)
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                    if hasKey { Button("Annuler") { key = ""; isEditingKey = false } }
                }
            } else {
                HStack {
                    Label("Clé API enregistrée dans le trousseau", systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button("Remplacer la clé") { isEditingKey = true }
                        Button("Supprimer la clé", role: .destructive) { removeKey() }
                    } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                }

                Button { showsVoicePicker = true } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selectedVoiceName.isEmpty ? String(localized: "Choisir une voix") : selectedVoiceName)
                            Text("Voix disponibles sur mon compte")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isLoading { ProgressView() }
                        else { Image(systemName: "chevron.right").font(.caption) }
                    }
                }
                .disabled(isLoading)

                HStack {
                    Button { Task { await loadVoices() } } label: {
                        Label("Actualiser les voix", systemImage: "arrow.clockwise")
                    }.disabled(isLoading)
                    Spacer()
                    if !selectedVoiceID.isEmpty {
                        Button {
                            if isPreviewing { playback.stop() }
                            else { playback.previewOnline(provider) }
                        } label: {
                            Label(isPreviewing
                                  ? String(localized: "Arrêter l’aperçu") : String(localized: "Écouter cette voix"),
                                  systemImage: isPreviewing
                                  ? "stop.circle" : "play.circle")
                        }
                    }
                }.font(.subheadline)

                if !selectedVoiceID.isEmpty {
                    Button { playback.selectEngine(provider.engine) } label: {
                        Label(isSelected ? String(localized: "Sélectionné pour vos livres") : String(localized: "Utiliser pour mes livres"), systemImage: "book")
                    }.buttonStyle(.borderedProminent).foregroundStyle(.white)
                }
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(22)
        .background(ConteurTheme.wash, in: RoundedRectangle(cornerRadius: 22))
        .task {
            hasKey = OnlineAPIKeyStore.contains(provider)
            if hasKey { await loadVoices() }
        }
        .sheet(isPresented: $showsVoicePicker) {
            OnlineVoicePicker(provider: provider, voices: voices, selectedID: selectedVoiceID) { voice in
                settings.selectOnlineVoice(voice)
                playback.selectEngine(provider.engine)
            }
        }
    }

    private func saveKey() {
        errorMessage = nil
        do {
            try OnlineAPIKeyStore.save(key, for: provider)
            key = ""
            hasKey = true
            isEditingKey = false
            Task { await loadVoices() }
        } catch { errorMessage = error.localizedDescription }
    }

    private func removeKey() {
        errorMessage = nil
        do {
            if settings.engine == provider.engine { playback.selectEngine(.system) }
            try OnlineAPIKeyStore.remove(provider)
            hasKey = false
            voices = []
            key = ""
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor private func loadVoices() async {
        guard hasKey, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            voices = try await OnlineTTSClient.shared.voices(for: provider)
            if voices.isEmpty { errorMessage = String(localized: "Aucune voix n’est disponible avec cette clé API.") }
        } catch { errorMessage = error.localizedDescription }
        isLoading = false
    }
}

private struct OnlineVoicePicker: View {
    let provider: OnlineVoiceProvider
    let voices: [OnlineVoice]
    let selectedID: String
    let select: (OnlineVoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [OnlineVoice] {
        guard !search.isEmpty else { return voices }
        return voices.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.details.localizedCaseInsensitiveContains(search)
                || $0.languages.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { voice in
                Button {
                    select(voice)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(voice.name).foregroundStyle(ConteurTheme.ink)
                            if !voice.details.isEmpty {
                                Text(voice.details).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                        if voice.id == selectedID { Image(systemName: "checkmark").foregroundStyle(ConteurTheme.green) }
                    }
                }
            }
            .overlay { if voices.isEmpty { ContentUnavailableView("Aucune voix", systemImage: "waveform.slash") } }
            .navigationTitle(provider.name)
            .searchable(text: $search, prompt: "Nom, langue ou accent")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } } }
        }.tint(ConteurTheme.green)
    }
}
