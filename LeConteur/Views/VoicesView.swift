import SwiftUI
import AVFoundation

struct VoicesView: View {
    @Environment(ReaderSettings.self) private var settings
    @Environment(PlaybackController.self) private var playback
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var showLicenses = CommandLine.arguments.contains("--localization-licenses")
    @State private var showSystemVoices = CommandLine.arguments.contains("--localization-system-voices")

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    Eyebrow(text: String(localized: "UNE VOIX QUI VOUS RESSEMBLE"))
                    Text("L’art de raconter.").font(.system(size: 38, weight: .regular, design: .serif)).tracking(-1)
                    Text("Choisissez votre façon d’écouter.\nLe même plaisir, sans connexion.")
                        .font(.subheadline).foregroundStyle(ConteurTheme.muted)

                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Image(systemName: "iphone").font(.title2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Les voix de votre iPhone").font(.headline)
                                Text("Prêtes à lire · Toutes les langues installées").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            selectionMark(settings.engine == .system)
                        }.contentShape(Rectangle()).onTapGesture { playback.selectEngine(.system) }
                        Button { showSystemVoices = true } label: {
                            HStack {
                                Label("Voix préférées par langue", systemImage: "star")
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }
                        }.accessibilityIdentifier("appleVoicePreferences")
                        if settings.systemVoiceIDs.isEmpty {
                            Text("Automatique pour toutes les langues").font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            ForEach(settings.systemVoiceIDs.keys.sorted(), id: \.self) { language in
                                HStack {
                                    Text(SystemVoicesList.languageName(language))
                                    Spacer()
                                    Text(voices.first { $0.identifier == settings.systemVoiceID(for: language) }?.name ?? String(localized: "Voix indisponible"))
                                        .foregroundStyle(.secondary)
                                }.font(.subheadline)
                            }
                        }
                        Text("Une voix préférée par langue. Elle est retrouvée automatiquement à la lecture, y compris après traduction.").font(.caption).foregroundStyle(.secondary)
                        Text("Ajoutez des voix de qualité améliorée dans Réglages → Accessibilité → Lire et énoncer → Voix. Le nom du menu peut varier selon iOS.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(22).background(ConteurTheme.card, in: RoundedRectangle(cornerRadius: 22))

                    QwenVoiceCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Votre bibliothèque vous appartient", systemImage: "lock.shield").font(.subheadline.weight(.semibold))
                        Text("Aucun compte, aucune publicité, aucun document envoyé à un serveur. Les livres et leurs traductions sont stockés localement et exclus de la sauvegarde iCloud de l’app.")
                            .font(.caption).foregroundStyle(ConteurTheme.muted)
                        Button("Crédits et composants libres") { showLicenses = true }.font(.caption)
                    }.padding(.vertical, 8)
                }.padding(24)
            }
            .background(ConteurTheme.paper).foregroundStyle(ConteurTheme.ink)
            .toolbar(.hidden, for: .navigationBar)
            .task { refreshVoices() }
            .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in refreshVoices() }
            .alert("Lecture Qwen", isPresented: Binding(get: { playback.errorMessage != nil }, set: { if !$0 { playback.errorMessage = nil } })) {
                Button("D’accord", role: .cancel) { playback.errorMessage = nil }
            } message: { Text(playback.errorMessage ?? "") }
            .sheet(isPresented: $showSystemVoices) { SystemVoicesList() }
            .sheet(isPresented: $showLicenses) {
                NavigationStack {
                    ScrollView {
                        Text(licenseText)
                            .font(.footnote).padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    }.navigationTitle("Crédits").toolbar { Button("Terminer") { showLicenses = false } }
                }
            }
        }
    }

    private func refreshVoices() {
        voices = SystemVoiceSelection.installedVoices()
    }

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "Qwen3-TTS · MLX · ZIPFoundation" }
        return text
    }

    private func selectionMark(_ selected: Bool) -> some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title2)
            .foregroundStyle(selected ? ConteurTheme.green : ConteurTheme.muted.opacity(0.4))
    }
}

private struct SystemVoicesList: View {
    @Environment(ReaderSettings.self) private var settings
    @Environment(PlaybackController.self) private var playback
    @Environment(\.dismiss) private var dismiss
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var preview = AVSpeechSynthesizer()
    @State private var search = ""

    private var languages: [String] {
        Set(voices.map { SystemVoiceSelection.language($0.language) })
            .union(settings.systemVoiceIDs.keys)
            .filter { language in
                search.isEmpty || Self.languageName(language).localizedCaseInsensitiveContains(search)
                    || voicesIn(language).contains { $0.name.localizedCaseInsensitiveContains(search) || $0.language.localizedCaseInsensitiveContains(search) }
            }
            .sorted { Self.languageName($0).localizedStandardCompare(Self.languageName($1)) == .orderedAscending }
    }

    static func languageName(_ language: String) -> String {
        (Locale.current.localizedString(forLanguageCode: language) ?? language).localizedCapitalized
    }

    private func voicesIn(_ language: String) -> [AVSpeechSynthesisVoice] {
        voices.filter { SystemVoiceSelection.language($0.language) == language }
    }

    private func displayedVoicesIn(_ language: String) -> [AVSpeechSynthesisVoice] {
        let voices = voicesIn(language)
        guard !search.isEmpty, !Self.languageName(language).localizedCaseInsensitiveContains(search) else { return voices }
        return voices.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.language.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Marquez une voix d’une étoile pour chaque langue. Votre choix est conservé lorsque vous écoutez une autre langue.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if voices.isEmpty {
                        Text("Aucune voix Apple n’est disponible pour le moment. Vous pouvez en ajouter dans les réglages d’accessibilité de l’iPhone.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                ForEach(languages, id: \.self) { language in
                    Section(Self.languageName(language)) {
                        Button { playback.selectSystemVoice("", language: language) } label: {
                            HStack {
                                Text("Automatique")
                                Spacer()
                                if settings.systemVoiceID(for: language).isEmpty { Image(systemName: "checkmark") }
                            }.foregroundStyle(ConteurTheme.ink)
                        }.accessibilityIdentifier("automaticVoice.\(language)")
                        if !settings.systemVoiceID(for: language).isEmpty,
                           !voicesIn(language).contains(where: { $0.identifier == settings.systemVoiceID(for: language) }) {
                            Text("Votre voix préférée est indisponible. Une autre voix sera utilisée en attendant.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(displayedVoicesIn(language), id: \.identifier) { voice in
                            HStack(spacing: 16) {
                                Button {
                                    playback.selectSystemVoice(voice.identifier, language: language)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: settings.systemVoiceID(for: language) == voice.identifier ? "star.fill" : "star")
                                            .foregroundStyle(ConteurTheme.green)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(voice.name).foregroundStyle(ConteurTheme.ink)
                                            Text("\(voice.language)\(voice.quality == .premium ? String(localized: " · Premium") : voice.quality == .enhanced ? String(localized: " · Améliorée") : "")")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .accessibilityLabel("\(voice.name), \(voice.language)")
                                    .accessibilityValue(settings.systemVoiceID(for: language) == voice.identifier ? String(localized: "Voix préférée") : "")
                                    .accessibilityHint("Choisir comme voix préférée pour \(Self.languageName(language))")
                                Button { audition(voice) } label: {
                                    Image(systemName: "play.circle").font(.title2).frame(width: 44, height: 44)
                                }.buttonStyle(.borderless).accessibilityLabel("Écouter \(voice.name)")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Voix Apple")
            .searchable(text: $search, prompt: "Langue ou voix")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Terminer") { dismiss() } } }
            .task { voices = SystemVoiceSelection.installedVoices() }
            .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
                voices = SystemVoiceSelection.installedVoices()
            }
            .onDisappear { preview.stopSpeaking(at: .immediate) }
        }.tint(ConteurTheme.green)
    }

    private func audition(_ voice: AVSpeechSynthesisVoice) {
        playback.pause()
        preview.stopSpeaking(at: .immediate)
        let samples = ["fr": "Prenez votre temps. Chaque histoire mérite d’être écoutée.",
                       "en": "Take your time. Every story deserves to be heard.",
                       "es": "Tómate tu tiempo. Cada historia merece ser escuchada.",
                       "de": "Nimm dir Zeit. Jede Geschichte verdient es, gehört zu werden.",
                       "it": "Prenditi il tuo tempo. Ogni storia merita di essere ascoltata.",
                       "pt": "Leve o tempo que precisar. Cada história merece ser ouvida."]
        let utterance = AVSpeechUtterance(string: samples[SystemVoiceSelection.language(voice.language)] ?? "Hello.")
        utterance.voice = voice
        preview.speak(utterance)
    }
}
