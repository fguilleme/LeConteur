import SwiftUI

struct SupertonicVoiceCard: View {
    @Environment(ReaderSettings.self) private var settings
    @Environment(SupertonicModelStore.self) private var model
    @Environment(PlaybackController.self) private var playback
    @State private var removing = false

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "bolt.horizontal.circle").font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Supertonic").font(.system(size: 28, design: .serif))
                    Text("RAPIDE · SUR VOTRE IPHONE").font(.system(size: 9, weight: .semibold)).tracking(1.3)
                }
                Spacer()
                Image(systemName: settings.engine == .supertonic ? "checkmark.circle.fill" : "circle")
                    .font(.title2).foregroundStyle(ConteurTheme.green)
            }
            Text("Une voix neuronale locale conçue pour préparer l’audio plus vite que sa lecture.")
                .font(.subheadline).foregroundStyle(ConteurTheme.muted)
            Text("Français, anglais, allemand, espagnol, italien, portugais, japonais, russe, arabe, coréen et 20 autres langues. Le chinois utilise automatiquement une voix iPhone.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Voix Supertonic", selection: $settings.supertonicVoice) {
                ForEach(SupertonicVoice.allCases) { voice in Text(voice.name).tag(voice) }
            }
            Picker("Vitesse de lecture", selection: $settings.speed) {
                ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { value in
                    Text("\(value.formatted())×").tag(value)
                }
            }.accessibilityIdentifier("supertonic-speed-picker")

            if model.isBusy {
                ProgressView(value: model.progress)
                HStack {
                    Text("\(model.status) · \(Int(model.progress * 100)) %").font(.caption)
                    Spacer()
                    Button("Annuler") { model.cancel() }.font(.caption)
                }
                Text("Le téléchargement continue en Wi‑Fi quand vous changez d’app ou éteignez l’écran.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.isInstalled {
                Button { playback.selectEngine(.supertonic) } label: {
                    Label(settings.engine == .supertonic ? String(localized: "Sélectionné pour vos livres") : String(localized: "Utiliser pour mes livres"), systemImage: "book")
                }.buttonStyle(.borderedProminent).foregroundStyle(.white).disabled(removing)
                Button {
                    if playback.isPreview, playback.isPlaying || playback.isPreparing { playback.stop() }
                    else { playback.previewSupertonic() }
                } label: {
                    Label(playback.isPreview && (playback.isPlaying || playback.isPreparing) ? String(localized: "Arrêter l’aperçu") : String(localized: "Écouter cette voix"),
                          systemImage: playback.isPreview && (playback.isPlaying || playback.isPreparing) ? "stop.circle" : "play.circle")
                }.disabled(removing)
                Button(removing ? String(localized: "Libération…") : String(localized: "Supprimer le modèle · 399 Mo"), role: .destructive) {
                    removing = true
                    Task {
                        if settings.engine == .supertonic { settings.engine = .system }
                        await SupertonicVoiceRenderer.shared.unload()
                        model.remove()
                        removing = false
                    }
                }.font(.caption).disabled(removing)
            } else {
                Button { model.install() } label: { Label("Installer Supertonic · 399 Mo", systemImage: "arrow.down.circle") }
                    .buttonStyle(.borderedProminent).foregroundStyle(.white)
                Text("Les poids officiels épinglés sont vérifiés avant installation. Le moteur fonctionne ensuite entièrement hors ligne.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            Text("Supertonic 3 · 99 M paramètres · modèle OpenRAIL‑M. Qwen reste disponible pendant l’évaluation de la qualité.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(22).background(ConteurTheme.wash, in: RoundedRectangle(cornerRadius: 22))
    }
}
