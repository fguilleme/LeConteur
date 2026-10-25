import SwiftUI

struct QwenVoiceCard: View {
    @Environment(ReaderSettings.self) private var settings
    @Environment(QwenModelStore.self) private var model
    @Environment(PlaybackController.self) private var playback
    @State private var removing = false

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "waveform.path").font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Qwen").font(.system(size: 28, design: .serif))
                    Text("TROIS FAÇONS DE RACONTER").font(.system(size: 9, weight: .semibold)).tracking(1.3)
                }
                Spacer()
                Image(systemName: settings.engine == .qwen ? "checkmark.circle.fill" : "circle")
                    .font(.title2).foregroundStyle(ConteurTheme.green)
            }
            Text("Une narration expressive, créée sur votre iPhone. Choisissez l’émotion qui accompagne vos livres.")
                .font(.subheadline).foregroundStyle(ConteurTheme.muted)
            Text("Langues prises en charge : français, anglais, espagnol, allemand, italien, portugais, russe, japonais, coréen et chinois.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Voix Qwen", selection: Binding(get: { settings.qwenSpeaker }, set: { playback.selectQwenSpeaker($0) })) {
                ForEach(QwenSpeaker.allCases) { voice in Text(voice.name).tag(voice) }
            }.accessibilityIdentifier("qwen-speaker-picker")
            Text(settings.qwenSpeaker.description).font(.caption).foregroundStyle(ConteurTheme.muted)
            Text("La langue indiquée est celle d’origine de la voix. La lecture suit la langue du livre ; l’accent peut varier.")
                .font(.caption2).foregroundStyle(.secondary)
            Picker("Style Qwen", selection: Binding(get: { settings.qwenStyle }, set: { playback.selectQwenStyle($0) })) {
                ForEach(NarrationStyle.allCases) { style in Text(style.name).tag(style) }
            }.pickerStyle(.segmented).accessibilityIdentifier("qwen-style-picker")
            Label(settings.qwenStyle.subtitle, systemImage: settings.qwenStyle.icon)
                .font(.subheadline).foregroundStyle(ConteurTheme.green)
            Picker("Vitesse Qwen", selection: $settings.qwenSpeed) {
                ForEach([1.0, 1.25, 1.5, 1.75, 2.0, 2.5], id: \.self) { value in
                    Text("\(value.formatted())×").tag(value)
                }
            }.accessibilityIdentifier("qwen-speed-picker")
            HStack {
                Text("Réserve audio").font(.subheadline)
                Spacer()
                Picker("Réserve Qwen", selection: $settings.qwenBuffer) {
                    ForEach(QwenBufferPreset.allCases) { preset in Text(preset.name).tag(preset) }
                }.accessibilityIdentifier("qwen-buffer-picker")
            }
            Text("Une réserve plus longue réduit les pauses entre paragraphes, mais retarde le démarrage. Les secondes correspondent à la durée d’écoute, à la vitesse choisie.")
                .font(.caption).foregroundStyle(.secondary)

            if !QwenModel.supported {
                Text(QwenError.unavailable.localizedDescription).font(.caption).foregroundStyle(.secondary)
            } else if model.isBusy {
                ProgressView(value: model.progress)
                Text("Vous pouvez changer d’app ou éteindre l’écran.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("\(model.status) · \(Int(model.progress * 100)) %").font(.caption)
                    Spacer()
                    Button("Annuler") { model.cancel() }.font(.caption)
                }
            } else if model.isInstalled {
                if let message = playback.voiceFallbackMessage {
                    Text(message).font(.caption).foregroundStyle(ConteurTheme.muted)
                }
                Button {
                    playback.selectEngine(.qwen)
                } label: {
                    Label(playback.isUsingAppleForTranslation ? String(localized: "Écouter avec Qwen") : settings.engine == .qwen ? String(localized: "Sélectionné pour vos livres") : String(localized: "Utiliser pour mes livres"), systemImage: "book")
                }.buttonStyle(.borderedProminent).foregroundStyle(.white).disabled(removing)
                    .accessibilityIdentifier("qwen-select-engine")
                Button {
                    if playback.isPreview, playback.isPlaying || playback.isPreparing { playback.stop() }
                    else { playback.previewQwen() }
                } label: {
                    Label(playback.isPreview && (playback.isPlaying || playback.isPreparing) ? String(localized: "Arrêter l’aperçu") : String(localized: "Écouter ce style"),
                          systemImage: playback.isPreview && (playback.isPlaying || playback.isPreparing) ? "stop.circle" : "play.circle")
                }.disabled(removing).accessibilityIdentifier("qwen-preview")
                if playback.isPreview, let reserve = playback.qwenReserve {
                    QwenReserveGauge(reserve: reserve)
                }
                if playback.isPreview, let notice = playback.notice { Text(notice).font(.caption).foregroundStyle(ConteurTheme.muted) }
                if let metrics = playback.qwenMetrics {
                    Text("Dernier essai : \(Int(metrics.audioSeconds)) s d’audio préparées en \(Int(metrics.generationSeconds)) s.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                DisclosureGroup("Le texte des trois aperçus") {
                    Text(NarrationStyle.auditionText).font(.system(.subheadline, design: .serif)).padding(.top, 8)
                }.font(.caption)
                Button(removing ? String(localized: "Libération…") : String(localized: "Supprimer le modèle · 2,31 Go"), role: .destructive) {
                    removing = true
                    Task {
                        await playback.releaseQwen()
                        if settings.engine == .qwen { settings.engine = .system }
                        model.remove()
                        removing = false
                    }
                }.font(.caption).disabled(removing)
            } else {
                Button { model.install() } label: { Label("Installer Qwen · 2,31 Go", systemImage: "arrow.down.circle") }
                    .buttonStyle(.borderedProminent).foregroundStyle(.white).accessibilityIdentifier("qwen-download")
                Text("Le téléchargement continue en Wi-Fi quand vous changez d’app ou éteignez l’écran. Les fichiers terminés sont conservés si vous l’interrompez.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            Text("Qwen prépare plusieurs passages avant de lire et continue à prendre de l’avance pendant l’écoute. Automatique adapte la réserve à la vitesse et au temps de préparation. Écran éteint ou dans une autre app, la réserve reste lisible. Une fois vide, la lecture attend votre retour dans Le Conteur pour préparer la suite. Le suivi des mots est estimé.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22).background(ConteurTheme.wash, in: RoundedRectangle(cornerRadius: 22))
        .onDisappear { if playback.isPreview { playback.stop() } }
    }
}
