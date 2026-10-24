#if DEBUG
import Foundation
import UIKit
import Translation
import AVFoundation
import SwiftUI

/// Uses isolated sample documents and preferences; never changes the reader's library.
@MainActor enum TranslationDeviceValidation {
    struct Run: Codable {
        var language: String
        var seconds: Double
        var paragraphs: Int
        var voiceLanguage: String?
        var excerpt: String
        var firstPassageSeconds: Double
        var publishedBeforeCompletion: Bool
    }
    struct Report: Codable {
        var status: String
        var runs: [Run] = []
        var error: String?
    }
    @available(iOS 26.0, *)
    static func run() async {
        let folder = URL.documentsDirectory.appending(path: "TranslationValidation")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var report = Report(status: "started")
        func save() { if let data = try? JSONEncoder().encode(report) { try? data.write(to: folder.appending(path: "report.json"), options: .atomic) } }
        save()
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let library = LibraryStore(directory: folder.appending(path: UUID().uuidString))
        var started = Date()
        var firstPassageSeconds: Double?
        var publishedBeforeCompletion = false
        let coordinator = TranslationCoordinator(library: library, documentUpdated: { id in
            if firstPassageSeconds == nil, let draft = library.document(id), !draft.segments.isEmpty {
                firstPassageSeconds = Date().timeIntervalSince(started)
                publishedBeforeCompletion = draft.isTranslationPending
                print("TRANSLATION_FIRST_PASSAGE \(firstPassageSeconds!) pending=\(draft.isTranslationPending)")
            }
        })
        do {
            let paragraphs = (1...40).map { "Ce matin, à la page \($0), Marie ouvre la porte du jardin. Elle retrouve son ami près du vieux pommier. « Le café est prêt », lui dit-elle. Ils s’assoient ensemble et prennent le temps de raconter leur voyage." }
            let original = try DocumentImporter.fromText(paragraphs.joined(separator: "\n\n"), title: "Validation traduction")
            for language in ["en", "es"] {
                report.status = "translating-\(language)"; save()
                started = Date()
                firstPassageSeconds = nil
                publishedBeforeCompletion = false
                await coordinator.request(original, targetLanguage: language)
                guard coordinator.isTranslating else { throw NSError(domain: "Validation", code: 1, userInfo: [NSLocalizedDescriptionKey: coordinator.errorMessage ?? "Traduction non démarrée"]) }
                let session: TranslationSession
                if #available(iOS 26.4, *) { session = TranslationSession(installedSource: Locale.Language(identifier: "fr"), target: Locale.Language(identifier: language), preferredStrategy: .highFidelity) }
                else { session = TranslationSession(installedSource: Locale.Language(identifier: "fr"), target: Locale.Language(identifier: language)) }
                await coordinator.translate(using: session)
                guard let id = coordinator.readyDocumentID, let translated = library.document(id), translated.languageCode == language else {
                    throw NSError(domain: "Validation", code: 2, userInfo: [NSLocalizedDescriptionKey: coordinator.errorMessage ?? "Traduction incomplète"])
                }
                let voice = SystemVoiceSelection.resolve(language: language, preferred: AVSpeechSynthesisVoice(language: "fr-FR")?.identifier ?? "")
                guard SystemVoiceSelection.language(voice?.language ?? "und") == language, translated.paragraphRanges.count == paragraphs.count,
                      publishedBeforeCompletion, !translated.isTranslationPending else { throw TranslationWorkError.incomplete }
                report.runs.append(Run(language: language, seconds: Date().timeIntervalSince(started), paragraphs: translated.paragraphRanges.count, voiceLanguage: voice?.language, excerpt: translated.segments.prefix(4).joined(separator: " "), firstPassageSeconds: firstPassageSeconds ?? 0, publishedBeforeCompletion: publishedBeforeCompletion))
                save()
            }
            report.status = "passed"
        } catch { report.status = "failed"; report.error = error.localizedDescription }
        save()
        print("TRANSLATION_VALIDATION \(report.status)")
    }
}

/// Exercises the production SwiftUI session owner, including its transition to the
/// translated reader, using an isolated library and five seconds of system audio.
struct ReaderTranslationValidationView: View {
    @State private var library: LibraryStore
    @State private var settings: ReaderSettings
    @State private var playback: PlaybackController
    @State private var coordinator: TranslationCoordinator
    @State private var report: ReaderTranslationReport
    @State private var audioTest: Task<Void, Never>?
    private let originalID: UUID

    init() {
        let folder = URL.documentsDirectory.appending(path: "ReaderTranslationValidation")
        let report = ReaderTranslationReport(folder: folder)
        let library = LibraryStore(directory: folder.appending(path: UUID().uuidString))
        let settings = ReaderSettings(defaults: UserDefaults(suiteName: "conteur-reader-validation")!)
        settings.engine = .system
        settings.speed = 1
        let english = "This morning, Marie opens the garden door. She finds her friend near the old apple tree. The coffee is ready, she says. They sit together and take the time to talk about their journey."
        let french = "Ce matin, Marie ouvre la porte du jardin. Elle retrouve son ami près du vieux pommier. Le café est prêt, lui dit-elle. Ils s’assoient ensemble et prennent le temps de raconter leur voyage."
        let text = TranslationCoordinator.phoneLanguage == "en" ? french : english
        let first = TranslationCoordinator.phoneLanguage == "en" ? "Bonjour." : "Hello."
        let original = try! DocumentImporter.fromText(([first] + Array(repeating: text, count: 39)).joined(separator: "\n\n"), title: "Essai de lecture progressive")
        library.add(original)
        let playback = PlaybackController(library: library, settings: settings)
        let coordinator = TranslationCoordinator(library: library, documentUpdated: { id in
            guard let draft = library.document(id) else { return }
            report.published(draft)
            playback.translationUpdated(id)
        })
        originalID = original.id
        _library = State(initialValue: library); _settings = State(initialValue: settings)
        _playback = State(initialValue: playback); _coordinator = State(initialValue: coordinator)
        _report = State(initialValue: report)
    }

    var body: some View {
        ReadingSessionView(documentID: originalID, automaticallyTranslate: true)
            .environment(library).environment(settings).environment(playback).environment(coordinator)
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onChange(of: playback.documentID) { _, id in
                guard id != originalID, id != nil, !report.readerOpenedBeforeCompletion else { return }
                report.readerOpenedBeforeCompletion = coordinator.isTranslating && playback.document?.isTranslationPending == true
                report.save()
                playback.play()
                audioTest = Task {
                    try? await Task.sleep(for: .seconds(5))
                    playback.pause()
                }
            }
            .onChange(of: playback.wordRange) { _, range in
                if range != nil, coordinator.isTranslating {
                    report.audioBeforeCompletion = true
                    report.save()
                }
            }
            .onChange(of: playback.isWaitingForTranslation) { _, waiting in
                if waiting { report.waitedForNextPassage = true; report.save() }
                else if report.waitedForNextPassage, playback.isPlaying {
                    report.resumedAfterWaiting = true; report.save()
                }
            }
            .onChange(of: coordinator.isTranslating) { _, active in
                if !active {
                    report.status = coordinator.errorMessage == nil && report.completed && report.readerOpenedBeforeCompletion && report.audioBeforeCompletion ? "passed" : "failed"
                    report.error = coordinator.errorMessage
                    report.save()
                    print("READER_TRANSLATION_VALIDATION \(report.status)")
                }
            }
            .onDisappear { audioTest?.cancel(); playback.stop(); UIApplication.shared.isIdleTimerDisabled = false }
    }
}

@MainActor @Observable final class ReaderTranslationReport {
    let folder: URL
    let started = Date()
    var status = "started"
    var firstPassageSeconds: Double?
    var seconds = 0.0
    var readerOpenedBeforeCompletion = false
    var audioBeforeCompletion = false
    var waitedForNextPassage = false
    var resumedAfterWaiting = false
    var completed = false
    var paragraphs = 0
    var language = ""
    var error: String?

    init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        save()
    }
    func published(_ document: ReadingDocument) {
        seconds = Date().timeIntervalSince(started)
        if firstPassageSeconds == nil { firstPassageSeconds = seconds }
        completed = !document.isTranslationPending
        paragraphs = document.paragraphRanges.count
        language = document.languageCode ?? ""
        save()
    }
    func save() {
        let data: [String: Any] = ["status": status, "firstPassageSeconds": firstPassageSeconds ?? 0,
            "playbackSpeed": 1, "systemSpeechRate": SystemVoiceSelection.speechRate(for: 1),
            "seconds": seconds, "readerOpenedBeforeCompletion": readerOpenedBeforeCompletion,
            "audioBeforeCompletion": audioBeforeCompletion, "waitedForNextPassage": waitedForNextPassage,
            "resumedAfterWaiting": resumedAfterWaiting, "completed": completed,
            "paragraphs": paragraphs, "language": language, "error": error ?? ""]
        if let json = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: folder.appending(path: "report.json"), options: .atomic)
        }
    }
}
#endif
