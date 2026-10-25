#if DEBUG
import AVFoundation
import SwiftUI

/// Silent, delayed PCM exercises the production reader/queue on Simulator.
/// Uses temporary data and isolated preferences; never loads the Qwen model.
struct QwenReserveGaugeValidationView: View {
    @State private var library: LibraryStore
    @State private var settings: ReaderSettings
    @State private var playback: PlaybackController
    @State private var translation: TranslationCoordinator
    @State private var document: ReadingDocument
    @State private var folder: URL
    @State private var suite: String
    @State private var started = false

    init() {
        let folder = URL.temporaryDirectory.appending(path: "reserve-gauge-\(UUID())")
        let suite = "reserve-gauge-\(UUID())"
        _folder = State(initialValue: folder)
        _suite = State(initialValue: suite)
        let settings = ReaderSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.engine = .qwen
        let singlePassage = CommandLine.arguments.contains("--single-passage-reserve")
        settings.qwenSpeed = singlePassage ? 1.25 : 2
        settings.qwenBuffer = singlePassage ? .seconds10 : .seconds30
        let library = LibraryStore(directory: folder)
        var document = try! DocumentImporter.fromText((1...10).map {
            "À la page \($0), Marie ouvre la porte du jardin. Elle retrouve son ami près du vieux pommier. Ils s’assoient ensemble et prennent le temps de raconter leur voyage."
        }.joined(separator: "\n\n"), title: "Essai de jauge")
        document.languageCode = "fr"
        library.add(document)
        _document = State(initialValue: document)
        let playback = PlaybackController(library: library, settings: settings, renderQwen: { text, _, _, _, _ in
            let delay: Double = singlePassage ? (text.hasPrefix("À la page 1,") ? 0.25 : 15) : 4
            let duration: Double = singlePassage ? 28.75 : 12
            try await Task.sleep(for: .seconds(delay))
            let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * 24_000))!
            pcm.frameLength = pcm.frameCapacity
            pcm.floatChannelData![0].update(repeating: 0, count: Int(pcm.frameLength))
            let url = URL.temporaryDirectory.appending(path: "reserve-gauge-\(UUID()).wav")
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: pcm)
            file.close()
            return QwenRenderedAudio(url: url, metrics: .init(generationSeconds: delay, audioSeconds: duration,
                                                             mlxPeakBytes: 0, observedFootprintBytes: 0))
        })
        _library = State(initialValue: library)
        _settings = State(initialValue: settings)
        _playback = State(initialValue: playback)
        _translation = State(initialValue: TranslationCoordinator(library: library))
    }

    var body: some View {
        ReaderView(documentID: document.id, openDocument: { _ in }, translate: { _ in })
            .environment(library).environment(settings).environment(playback).environment(translation)
            .task {
                guard !started else { return }
                started = true
                while UIApplication.shared.applicationState != .active {
                    try? await Task.sleep(for: .milliseconds(100))
                    if Task.isCancelled { return }
                }
                playback.open(document, autoplay: true)
            }
            .onDisappear {
                playback.stop()
                UserDefaults.standard.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: folder)
            }
    }
}
#endif
