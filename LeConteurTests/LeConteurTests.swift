import XCTest
import AVFoundation
import CryptoKit
import Translation
import NaturalLanguage
import UIKit
import ZIPFoundation
@testable import LeConteur

final class LeConteurTests: XCTestCase {
    @MainActor func testQwenChainsGenerationWhilePreviouslyQueuedPassageIsStillPlaying() async throws {
        let document = try DocumentImporter.fromText("Un passage assez long. Le passage suivant. Encore un passage.", title: "Génération continue")
        let renderer = QwenTestRenderer(delays: [0.02, 0.25, 0.25], audioSeconds: [5])
        let player = try QwenPassagePlayer(document: document, start: 0, rate: 1.25, volume: 0,
            buffering: .init(minimumAutomaticSeconds: 0.2)) { try await renderer.render($0) }
        defer { player.stop() }
        var requests: [(audible: Bool, reserve: Double, completed: Int, elapsedAfterPrevious: Double)] = []
        var lastCompleted: Date?
        player.onDiagnosticEvent = { event in
            if event == "qwen:renderFinished" { lastCompleted = Date() }
            if event == "qwen:renderStarted" {
                requests.append((player.isAudible, player.bufferedPlaybackSeconds, player.completedPassages,
                                 lastCompleted.map { Date().timeIntervalSince($0) } ?? 0))
            }
        }
        player.onError = { XCTFail("Unexpected error: \($0)") }
        player.play()
        let deadline = Date().addingTimeInterval(5)
        while requests.count < 3 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(requests.count, 3)
        let rendered = await renderer.texts
        XCTAssertEqual(document.paragraphRanges.count, 1)
        XCTAssertEqual(rendered, document.segments, "Send each sentence separately, even within the same paragraph")
        for request in requests.dropFirst() {
            XCTAssertTrue(request.audible)
            XCTAssertGreaterThan(request.reserve, 2)
            XCTAssertEqual(request.completed, 0, "Generation must not wait for even the first queued passage to finish playing")
            XCTAssertLessThan(request.elapsedAfterPrevious, 0.5, "Request the next render immediately after committing the previous audio")
        }
    }

    @MainActor func testQwenRefillsFullReserveBeforeTheCurrentPassageFinishesPlaying() async throws {
        let document = try DocumentImporter.fromText("Le passage actuel.\n\nLe prochain passage.", title: "Recharge anticipée")
        let renderer = QwenTestRenderer(delays: [0.02], audioSeconds: [4])
        let player = try QwenPassagePlayer(document: document, start: 0, rate: 1.25, volume: 0,
            buffering: .init(minimumAutomaticSeconds: 0.2, minimumAheadSeconds: 2)) { try await renderer.render($0) }
        defer { player.stop() }
        var requests = 0
        var nextReserve = 0.0
        var nextAudible = false
        var nextCompleted = -1
        player.onDiagnosticEvent = { event in
            guard event == "qwen:renderStarted" else { return }
            requests += 1
            if requests == 2 {
                nextReserve = player.bufferedPlaybackSeconds
                nextAudible = player.isAudible
                nextCompleted = player.completedPassages
            }
        }
        player.onError = { XCTFail("Unexpected error: \($0)") }
        player.play()
        let deadline = Date().addingTimeInterval(5)
        while player.generatedPassages < 1 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(requests, 1, "Wait only while the reserve is at capacity")
        while requests < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(requests, 2)
        XCTAssertTrue(nextAudible)
        XCTAssertEqual(nextCompleted, 0)
        XCTAssertGreaterThan(nextReserve, 1.5, "Refill as soon as the reserve drops below capacity, not after it empties")
        XCTAssertLessThan(nextReserve, 2)
    }

    @MainActor func testQwenSentenceQueueResumesMidParagraphAndReanchorsHighlightWithoutGaps() async throws {
        let document = try DocumentImporter.fromText("La phrase déjà lue. Élodie voit l’océan 🌊. Puis elle reprend son récit.", title: "Phrase par phrase")
        XCTAssertEqual(document.segments.count, 3)
        let renderer = QwenTestRenderer(delays: [0.02], audioSeconds: [0.9, 1.1])
        let player = try QwenPassagePlayer(document: document, start: 1, rate: 1.25, volume: 0,
            buffering: .init(minimumAutomaticSeconds: 0.2)) { try await renderer.render($0) }
        defer { player.stop() }
        var starts: [Int] = []
        var firstWords: [Int: NSRange] = [:]
        var current: NarrationWindow?
        var gaps = 0
        var finished = false
        player.onPassageChanged = { window in
            current = window
            starts.append(window.endPosition)
            XCTAssertEqual(window.segments.count, 1)
            XCTAssertEqual(window.segments.first?.index, window.endPosition)
        }
        player.onWord = { range in
            guard let window = current else { return XCTFail("Words need their sentence mapping first") }
            XCTAssertLessThanOrEqual(NSMaxRange(range), window.text.utf16.count)
            if firstWords[window.endPosition] == nil { firstWords[window.endPosition] = range }
        }
        player.onStateChanged = { if player.hasStarted && player.isBuffering { gaps += 1 } }
        player.onFinished = { finished = true }
        player.onError = { XCTFail("Unexpected error: \($0)") }
        player.play()
        let deadline = Date().addingTimeInterval(5)
        while !finished && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(finished)
        let rendered = await renderer.texts
        XCTAssertEqual(rendered, Array(document.segments.dropFirst()), "Resuming must not repeat the start of the paragraph")
        XCTAssertEqual(starts, [1, 2])
        XCTAssertEqual(firstWords[1]?.location, 0)
        XCTAssertEqual(firstWords[2]?.location, 0, "The next sentence must use its own audio timeline")
        XCTAssertEqual(player.completedPassages, 2)
        XCTAssertEqual(gaps, 0, "A sentence boundary must not empty or restart the reserve")
    }

    @MainActor func testQwenStartsFromOnePassageOnceListeningReserveIsReached() async throws {
        let document = try DocumentImporter.fromText("Un long passage.\n\nLa suite encore en préparation.", title: "Objectif atteint")
        let renderer = QwenTestRenderer(delays: [0.02, 10], audioSeconds: [28.75, 1])
        let player = try QwenPassagePlayer(document: document, start: 0, rate: 1.25, volume: 0,
                                          buffering: .init(preset: .seconds10)) { try await renderer.render($0) }
        defer { player.stop() }
        var reserve: QwenReserveProgress?
        player.onReserveChanged = { reserve = $0 }
        player.play()
        let deadline = Date().addingTimeInterval(3)
        while player.generatedPassages == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(player.generatedPassages, 1)
        XCTAssertEqual(player.bufferedPassages, 1)
        XCTAssertGreaterThan(player.bufferedPlaybackSeconds, 20, "28.75 s of PCM gives 23 s at 1.25×")
        XCTAssertTrue(player.isAudible, "An objective of 10 s must not wait for a second passage when 23 s are ready")
        XCTAssertFalse(player.isBuffering)
        XCTAssertEqual(reserve?.targetSeconds, 10)
        XCTAssertEqual(reserve?.isBuffering, false)
        XCTAssertTrue(player.isGenerating, "The following passage should keep generating during playback")
    }

    @MainActor func testQwenLoweringReserveStartsAnAlreadyReadySinglePassage() async throws {
        let document = try DocumentImporter.fromText("Un long passage.\n\nLa suite en préparation.", title: "Nouvel objectif")
        let renderer = QwenTestRenderer(delays: [0.02, 10], audioSeconds: [28.75, 1])
        let player = try QwenPassagePlayer(document: document, start: 0, rate: 1.25, volume: 0,
                                          buffering: .init(preset: .seconds30)) { try await renderer.render($0) }
        defer { player.stop() }
        player.play()
        let deadline = Date().addingTimeInterval(3)
        while player.generatedPassages == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(player.generatedPassages, 1)
        XCTAssertEqual(player.bufferedPlaybackSeconds, 23, accuracy: 0.05)
        XCTAssertTrue(player.isBuffering, "23 seconds must still wait when the objective is 30 seconds")
        XCTAssertFalse(player.isAudible)
        player.setBufferPreset(.seconds10)
        XCTAssertTrue(player.isAudible, "Changing the objective must immediately release the existing audio")
        XCTAssertFalse(player.isBuffering)
        XCTAssertEqual(player.generatedPassages, 1, "No regeneration is needed")
    }

    @MainActor func testQwenRefillsFromOnePassageAfterActualUnderrun() async throws {
        let document = try DocumentImporter.fromText("Premier passage.\n\nDeuxième passage.\n\nLongue reprise.\n\nLa suite.", title: "Recharge")
        let renderer = QwenTestRenderer(delays: [0.02, 0.02, 7, 10], audioSeconds: [6.5, 6.5, 28.75, 1])
        let player = try QwenPassagePlayer(document: document, start: 0, rate: 1.25, volume: 0,
                                          buffering: .init(preset: .seconds10)) { try await renderer.render($0) }
        defer { player.stop() }
        var starts: [String] = []
        var finished = false
        player.onPassageChanged = { starts.append($0.text) }
        player.onFinished = { finished = true }
        player.play()
        let startDeadline = Date().addingTimeInterval(3)
        while !player.isAudible && Date() < startDeadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(player.isAudible)
        player.rate = 2.5 // Drain the first reserve before the deliberately slow third render.
        let emptyDeadline = Date().addingTimeInterval(6)
        while player.bufferedPassages > 0 && Date() < emptyDeadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(player.completedPassages, 2)
        XCTAssertEqual(player.bufferedPassages, 0)
        XCTAssertTrue(player.isBuffering)
        XCTAssertFalse(finished)
        player.rate = 1.25
        let refillDeadline = Date().addingTimeInterval(3)
        while player.generatedPassages < 3 && Date() < refillDeadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(player.generatedPassages, 3)
        XCTAssertEqual(player.bufferedPassages, 1)
        XCTAssertGreaterThan(player.bufferedPlaybackSeconds, 20)
        XCTAssertTrue(player.isAudible, "After an empty queue, one 23-second passage must restart a 10-second reserve")
        XCTAssertFalse(player.isBuffering)
        XCTAssertEqual(starts, Array(document.segments.prefix(3)), "The refill must not repeat or skip a passage")
        XCTAssertTrue(player.isGenerating)
    }

    @MainActor func testQwenPauseResumesExistingAudioBelowReserveTarget() async throws {
        let document = try DocumentImporter.fromText((0..<12).map { "Passage \($0)." }.joined(separator: "\n\n"), title: "Reprise immédiate")
        let renderer = QwenTestRenderer(delays: Array(repeating: 0.01, count: 10) + [3])
        let player = try QwenPassagePlayer(document: document, start: 0, rate: 1, volume: 0,
                                          buffering: .init(preset: .seconds10)) { try await renderer.render($0) }
        defer { player.stop() }
        player.play()
        let deadline = Date().addingTimeInterval(5)
        while !player.isAudible && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(player.isAudible)
        try await Task.sleep(for: .milliseconds(150))
        player.pause()
        let ready = player.bufferedPlaybackSeconds
        let played = player.playedSeconds
        let generated = player.generatedPassages
        XCTAssertLessThan(ready, 10)
        XCTAssertGreaterThan(ready, 1)
        player.play()
        XCTAssertTrue(player.isAudible, "Pause/Play must not wait to rebuild the initial reserve")
        XCTAssertFalse(player.isBuffering)
        XCTAssertEqual(player.generatedPassages, generated, "No new generation is needed to resume prepared PCM")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThan(player.playedSeconds, played)
        player.pause()
        player.suspendGeneration()
        player.resumeGeneration()
        XCTAssertFalse(player.isAudible, "Returning to the app respects an explicit pause")
        player.play()
        XCTAssertTrue(player.isAudible, "Foreground resume retains the same playable reserve")
    }

    @MainActor func testQwenBackgroundKeepsPCMResumesAndRetriesOnlyUnfinishedPassage() async throws {
        let document = try DocumentImporter.fromText("Un passage.\n\nUn autre.\n\nLe dernier.", title: "Arrière-plan")
        let renderer = QwenTestRenderer(delays: [0.03, 0.6, 0.03])
        let player = try QwenPassagePlayer(document: document, start: 0, rate: 1, volume: 0,
                                          buffering: .init(preset: .seconds30)) { try await renderer.render($0) }
        defer { player.stop() }
        var foregroundPositions: [Int] = []
        var finished = false
        var starts: [String] = []
        player.onNeedsForeground = { foregroundPositions.append($0) }
        player.onPassageChanged = { starts.append($0.text) }
        player.onFinished = { finished = true }
        player.onError = { XCTFail("Unexpected error: \($0)") }
        player.play()
        let deadline = Date().addingTimeInterval(8)
        while player.generatedPassages < 1 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        player.suspendGeneration()
        XCTAssertTrue(player.isAudible, "Use the available reserve even below the normal startup target")
        XCTAssertFalse(player.isGenerating)
        player.pause()
        let retained = player.bufferedPlaybackSeconds
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(player.bufferedPlaybackSeconds, retained, accuracy: 0.01)
        player.play()
        while foregroundPositions.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertEqual(foregroundPositions, [1])
        XCTAssertFalse(finished, "Exhausted reserve must not mark the unfinished book as read")
        XCTAssertTrue(player.isWaitingForForeground)
        XCTAssertEqual(player.completedPassages, 1)
        player.resumeGeneration()
        while !finished && Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(finished)
        XCTAssertEqual(starts, document.segments, "No skipped or repeated audio after the foreground transition")
        XCTAssertEqual(player.completedPassages, 3)
        let texts = await renderer.texts
        XCTAssertEqual(texts, [document.segments[0], document.segments[1], document.segments[1], document.segments[2]])
        for file in await renderer.outputFiles { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
    }

    @MainActor func testQwenRemotePlayInBackgroundKeepsVoiceAndReserveThenWaitsForForeground() async throws {
        let (library, _) = translationContext()
        let suite = "qwen-background-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderSettings(defaults: defaults)
        settings.engine = .qwen
        settings.qwenSpeed = 1
        settings.qwenBuffer = .seconds30
        let speech = RecordingSpeechSynthesizer()
        let renderer = QwenTestRenderer(delays: [0.03, 0.6, 0.03])
        let playback = PlaybackController(library: library, settings: settings, speech: speech,
                                          renderQwen: { text, _, _, _, _ in try await renderer.render(text) })
        defer { playback.stop() }
        var document = try DocumentImporter.fromText("Un passage.\n\nUn autre.\n\nLe dernier.", title: "Télécommande")
        document.languageCode = "fr"
        library.add(document)
        playback.open(document, autoplay: true)
        let deadline = Date().addingTimeInterval(8)
        while playback.qwenReserve?.readySeconds == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        playback.applicationWillResignActive()
        playback.applicationDidEnterBackground()
        XCTAssertTrue(playback.isPlaying)
        XCTAssertNotNil(playback.qwenReserve)
        playback.handleRemoteCommand(.pause)
        let retained = playback.qwenBufferedPlaybackSeconds
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(playback.qwenBufferedPlaybackSeconds, retained, accuracy: 0.01)
        playback.handleRemoteCommand(.play)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertFalse(playback.isPreparing, "Remote Play must use the queued audio while the app is inactive")
        while playback.position == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertEqual(playback.position, 1)
        XCTAssertTrue(playback.isPreparing)
        XCTAssertEqual(playback.effectiveEngine, .qwen)
        XCTAssertTrue(speech.utterances.isEmpty, "The user chose to wait for Qwen, never switch to Apple")
        XCTAssertFalse(try XCTUnwrap(library.document(document.id)).isFinished)
        playback.handleRemoteCommand(.toggle)
        XCTAssertTrue(playback.isPlaying, "The lock screen displays Play when the reserve is empty")
        XCTAssertTrue(playback.isPreparing, "Play must retain the request to resume on returning to the app")
        playback.handleRemoteCommand(.toggle)
        XCTAssertTrue(playback.isPlaying, "Repeated remote Play during a refill must not cancel the pending resume")
        playback.applicationDidBecomeActive()
        while playback.isPlaying && Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(try XCTUnwrap(library.document(document.id)).isFinished)
        XCTAssertTrue(speech.utterances.isEmpty)
        XCTAssertEqual(playback.settings.engine, .qwen)
    }

    @MainActor func testRemoteQwenStartWaitsForForegroundAndExplicitPauseCancelsAutomaticResume() async throws {
        let (library, _) = translationContext()
        let suite = "qwen-background-start-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderSettings(defaults: defaults)
        settings.engine = .qwen
        let renderer = RecordingQwenVoiceRenderer()
        let playback = PlaybackController(library: library, settings: settings,
                                          renderQwen: { text, style, _, speaker, _ in try await renderer.render(text, style: style, speaker: speaker) })
        defer { playback.stop() }
        playback.open(try XCTUnwrap(library.documents.first))
        playback.applicationWillResignActive()
        playback.applicationDidEnterBackground()
        playback.handleRemoteCommand(.play)
        XCTAssertTrue(playback.isPreparing)
        let requests = await renderer.requests
        XCTAssertTrue(requests.isEmpty)
        playback.handleRemoteCommand(.pause)
        playback.applicationDidBecomeActive()
        XCTAssertFalse(playback.isPlaying)
        playback.applicationWillResignActive()
        playback.handleRemoteCommand(.play)
        playback.applicationDidBecomeActive()
        try await renderer.waitForRequests(1)
        XCTAssertTrue(playback.isPlaying)
    }

    @MainActor func testAudioInterruptionResumesOnlyIfPlayingAndUserHasNotPaused() throws {
        let (library, _) = translationContext()
        let suite = "audio-interruption-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = RecordingSpeechSynthesizer()
        let playback = PlaybackController(library: library, settings: ReaderSettings(defaults: defaults), speech: speech)
        defer { playback.stop() }
        playback.open(try XCTUnwrap(library.documents.first), autoplay: true)
        playback.applicationWillResignActive()
        XCTAssertTrue(playback.isPlaying, "Switching apps alone is not an audio interruption")
        playback.audioInterruptionBegan()
        playback.audioInterruptionEnded(shouldResume: true)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(speech.continuations, 1)
        playback.audioInterruptionBegan()
        playback.handleRemoteCommand(.pause)
        playback.audioInterruptionEnded(shouldResume: true)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(speech.continuations, 1)
        playback.handleRemoteCommand(.play)
        playback.audioInterruptionBegan()
        playback.audioInterruptionEnded(shouldResume: false)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(speech.continuations, 2)
    }

    @MainActor func testAppleVoiceStallRestartsCurrentPassageWithoutClosingReader() async throws {
        let (library, _) = translationContext()
        let suite = "apple-stall-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = RecordingSpeechSynthesizer()
        let playback = PlaybackController(library: library, settings: ReaderSettings(defaults: defaults),
                                          speech: speech, systemSpeechTimeout: .milliseconds(25))
        defer { playback.stop() }
        let document = try XCTUnwrap(library.documents.first)
        playback.open(document)
        playback.seek(to: 2)
        playback.play()
        XCTAssertEqual(speech.utterances.count, 1)
        let deadline = Date().addingTimeInterval(1)
        while speech.utterances.count < 2 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let restarted = try XCTUnwrap(speech.utterances.dropFirst().first)
        XCTAssertEqual(speech.utterances[0].speechString, restarted.speechString)
        XCTAssertEqual(playback.position, 2)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertNil(playback.errorMessage)
    }

    @MainActor func testPausingAppleVoiceCancelsStallRecovery() async throws {
        let (library, _) = translationContext()
        let suite = "apple-stall-pause-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = RecordingSpeechSynthesizer()
        let playback = PlaybackController(library: library, settings: ReaderSettings(defaults: defaults),
                                          speech: speech, systemSpeechTimeout: .milliseconds(25))
        defer { playback.stop() }
        playback.open(try XCTUnwrap(library.documents.first), autoplay: true)
        playback.pause()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(speech.utterances.count, 1)
        XCTAssertFalse(playback.isPlaying)
    }

    @MainActor func testPausedApplePlaybackUsesNewVoiceWhenReaderReopensWithoutViewCallback() throws {
        let (library, _) = translationContext()
        let suite = "voice-reopen-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderSettings(defaults: defaults)
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("fr") }
        guard voices.count >= 2 else { throw XCTSkip("Requires two installed French Apple voices") }
        settings.preferSystemVoice(voices[0].identifier, for: "fr")
        let speech = RecordingSpeechSynthesizer()
        let playback = PlaybackController(library: library, settings: settings, speech: speech)
        defer { playback.stop() }
        let document = try XCTUnwrap(library.documents.first)
        playback.open(document)
        playback.seek(to: 2)
        playback.play()
        playback.pause()
        XCTAssertEqual(speech.utterances.last?.voice?.identifier, voices[0].identifier)
        // Deliberately omit the SwiftUI settingsChanged callback.
        settings.preferSystemVoice(voices[1].identifier, for: "fr")
        playback.open(try XCTUnwrap(library.document(document.id)))
        XCTAssertFalse(playback.isPlaying)
        playback.play()
        XCTAssertEqual(speech.utterances.count, 2)
        XCTAssertEqual(speech.continuations, 0, "Never resume the old paused utterance")
        XCTAssertEqual(speech.utterances.last?.voice?.identifier, voices[1].identifier)
        XCTAssertEqual(speech.utterances.last?.speechString, NarrationWindow(document: document, start: 2).text)
        XCTAssertEqual(playback.position, 2)
        playback.settingsChanged() // A delayed view callback must not restart it again.
        XCTAssertEqual(speech.utterances.count, 2)
        playback.pause()
        settings.preferSystemVoice(voices[0].identifier, for: "fr")
        playback.play() // The mini-player can resume without reopening ReaderView.
        XCTAssertEqual(speech.utterances.count, 3)
        XCTAssertEqual(speech.utterances.last?.voice?.identifier, voices[0].identifier)
        playback.selectSystemVoice(voices[1].identifier, language: "fr")
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(speech.utterances.count, 4)
        XCTAssertEqual(speech.utterances.last?.voice?.identifier, voices[1].identifier)
        XCTAssertEqual(playback.position, 2)
    }

    @MainActor func testUnchangedVoiceAndOtherLanguageFavoriteKeepPausedAppleUtterance() throws {
        let (library, _) = translationContext()
        let suite = "voice-unchanged-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderSettings(defaults: defaults)
        let speech = RecordingSpeechSynthesizer()
        let playback = PlaybackController(library: library, settings: settings, speech: speech)
        defer { playback.stop() }
        let document = try XCTUnwrap(library.documents.first)
        playback.open(document, autoplay: true)
        playback.pause()
        playback.selectSystemVoice("english-preference", language: "en")
        playback.open(document)
        playback.play()
        XCTAssertEqual(speech.utterances.count, 1)
        XCTAssertEqual(speech.continuations, 1)
        XCTAssertEqual(speech.utterances.first?.voice?.identifier, playback.selectedVoice?.identifier)
    }

    @MainActor func testQwenVoiceAndStyleChangesDiscardPausedReserveAndCanSwitchToApple() async throws {
        let (library, _) = translationContext()
        let suite = "voice-qwen-change-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderSettings(defaults: defaults)
        settings.engine = .qwen
        let speech = RecordingSpeechSynthesizer()
        let renderer = RecordingQwenVoiceRenderer()
        let playback = PlaybackController(library: library, settings: settings, speech: speech,
                                         renderQwen: { text, style, _, speaker, _ in
            try await renderer.render(text, style: style, speaker: speaker)
        })
        defer { playback.stop() }
        let document = try XCTUnwrap(library.documents.first)
        playback.open(document)
        playback.seek(to: 2)
        playback.play()
        try await renderer.waitForRequests(1)
        XCTAssertNotNil(playback.qwenReserve)
        playback.pause()
        settings.qwenSpeaker = .serena
        playback.open(document)
        playback.play()
        try await renderer.waitForRequests(2)
        settings.qwenStyle = .dramatic
        playback.settingsChanged()
        try await renderer.waitForRequests(3)
        let requests = await renderer.requests
        XCTAssertEqual(requests.map(\.speaker), [.ryan, .serena, .serena])
        XCTAssertEqual(requests.map(\.style), [.warm, .warm, .dramatic])
        XCTAssertTrue(requests.allSatisfy { $0.text == document.segments[2] })
        playback.pause()
        settings.engine = .system // Exercise resume without any SwiftUI callback.
        playback.play()
        XCTAssertEqual(playback.effectiveEngine, .system)
        XCTAssertEqual(playback.position, 2)
        XCTAssertEqual(speech.utterances.count, 1)
        XCTAssertFalse(playback.isPreparing)
        XCTAssertNil(playback.qwenReserve, "Apple playback must not retain the previous Qwen reserve")
    }

    @MainActor func testChoosingQwenSpeakerAndStyleReplacesAppleAtTheCurrentPassage() async throws {
        let (library, _) = translationContext()
        let suite = "voice-picker-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderSettings(defaults: defaults)
        let speech = RecordingSpeechSynthesizer()
        let renderer = RecordingQwenVoiceRenderer()
        let playback = PlaybackController(library: library, settings: settings, speech: speech,
            renderQwen: { text, style, _, speaker, _ in try await renderer.render(text, style: style, speaker: speaker) })
        defer { playback.stop() }
        playback.open(try XCTUnwrap(library.documents.first))
        playback.seek(to: 2)
        playback.play()
        playback.selectQwenSpeaker(.serena)
        try await renderer.waitForRequests(1)
        XCTAssertEqual(settings.engine, .qwen)
        XCTAssertEqual(playback.effectiveEngine, .qwen)
        XCTAssertEqual(speech.utterances.count, 1)
        XCTAssertEqual(playback.position, 2)
        playback.selectQwenStyle(.dramatic)
        try await renderer.waitForRequests(2)
        let requests = await renderer.requests
        XCTAssertEqual(requests.map(\.speaker), [.serena, .serena])
        XCTAssertEqual(requests.map(\.style), [.warm, .dramatic])
        XCTAssertEqual(playback.position, 2)
    }

    @MainActor func testCompletedTranslationRestoresQwenWithoutReselectingTheVoice() async throws {
        let (library, _) = translationContext()
        let suite = "voice-after-translation-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderSettings(defaults: defaults)
        settings.engine = .qwen
        let speech = RecordingSpeechSynthesizer()
        let renderer = RecordingQwenVoiceRenderer()
        let playback = PlaybackController(library: library, settings: settings, speech: speech,
            renderQwen: { text, style, _, speaker, _ in try await renderer.render(text, style: style, speaker: speaker) })
        defer { playback.stop() }
        var document = try XCTUnwrap(library.documents.first)
        document.id = UUID()
        document.translationOf = UUID()
        document.translationComplete = false
        XCTAssertTrue(library.add(document))
        playback.translationActivityChanged(true)
        playback.open(document, autoplay: true)
        XCTAssertEqual(playback.effectiveEngine, .system)
        XCTAssertNotNil(playback.voiceFallbackMessage)
        playback.pause()
        document.translationComplete = true
        XCTAssertTrue(library.saveTranslation(document))
        playback.translationActivityChanged(false)
        XCTAssertEqual(playback.effectiveEngine, .qwen)
        XCTAssertFalse(speech.isPaused, "Discard the temporary Apple utterance")
        XCTAssertFalse(playback.isPlaying)
        playback.open(document)
        playback.play()
        try await renderer.waitForRequests(1)
        XCTAssertEqual(speech.utterances.count, 1, "The resumed passage must use Qwen, not another Apple utterance")
        XCTAssertNil(playback.voiceFallbackMessage)
    }

    @MainActor func testPausedPartialTranslationUsesSelectedQwenImmediately() async throws {
        let (library, _) = translationContext()
        let suite = "voice-partial-translation-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderSettings(defaults: defaults)
        settings.engine = .qwen
        let speech = RecordingSpeechSynthesizer()
        let renderer = RecordingQwenVoiceRenderer()
        let playback = PlaybackController(library: library, settings: settings, speech: speech,
            renderQwen: { text, style, _, speaker, _ in try await renderer.render(text, style: style, speaker: speaker) })
        defer { playback.stop() }
        var document = try XCTUnwrap(library.documents.first)
        document.id = UUID()
        document.translationOf = UUID()
        document.translationComplete = false
        library.add(document)
        playback.open(document, autoplay: true)
        try await renderer.waitForRequests(1)
        XCTAssertEqual(playback.effectiveEngine, .qwen)
        XCTAssertTrue(speech.utterances.isEmpty)
        XCTAssertNil(playback.voiceFallbackMessage)
    }

    @MainActor func testExplicitQwenSelectionSuspendsActiveTranslationAndReplacesApple() async throws {
        let (library, _) = translationContext()
        let suite = "voice-active-translation-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderSettings(defaults: defaults)
        settings.engine = .qwen
        let speech = RecordingSpeechSynthesizer()
        let renderer = RecordingQwenVoiceRenderer()
        let playback = PlaybackController(library: library, settings: settings, speech: speech,
            renderQwen: { text, style, _, speaker, _ in try await renderer.render(text, style: style, speaker: speaker) })
        defer { playback.stop() }
        let original = try XCTUnwrap(library.documents.first)
        var draft = original
        draft.id = UUID()
        draft.languageCode = "en"
        draft.translationOf = original.id
        draft.translationComplete = false
        library.add(draft)
        let translation = TranslationCoordinator(library: library,
            activityChanged: { playback.translationActivityChanged($0) },
            prepareVoice: {}, languageStatus: { _, _ in .installed })
        defer { translation.cancel() }
        playback.suspendTranslation = { [weak translation] in translation?.suspend() }
        await translation.request(draft, targetLanguage: "en")
        XCTAssertTrue(translation.isTranslating)
        playback.open(draft, autoplay: true)
        playback.seek(to: 2)
        XCTAssertEqual(playback.effectiveEngine, .system)
        let appleCount = speech.utterances.count
        playback.selectEngine(.qwen) // Already selected in preferences.
        try await renderer.waitForRequests(1)
        XCTAssertFalse(translation.isTranslating)
        XCTAssertNil(translation.configuration)
        XCTAssertEqual(playback.effectiveEngine, .qwen)
        XCTAssertEqual(playback.position, 2)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(speech.utterances.count, appleCount)
        XCTAssertFalse(speech.isPaused)
        XCTAssertTrue(try XCTUnwrap(library.document(draft.id)).isTranslationPending, "Pausing translation retains its saved draft")
    }

    func testQwenInstructionsUseTheSpokenLanguageForEveryStyle() {
        for (name, code) in [("French", "fr"), ("English", "en"), ("Spanish", "es"),
                             ("German", "de"), ("Italian", "it"), ("Portuguese", "pt"),
                             ("Russian", "ru"), ("Japanese", "ja"), ("Korean", "ko"), ("Chinese", "zh-Hans")] {
            let instructions = NarrationStyle.allCases.map { $0.instruction(language: name) }
            XCTAssertEqual(Set(instructions).count, 3)
            for instruction in instructions {
                XCTAssertEqual(NLLanguageRecognizer.dominantLanguage(for: instruction)?.rawValue, code, name)
            }
        }
    }

    @MainActor func testQwenUsesTranslatedTextAndTargetLanguageWhenChangingEdition() async throws {
        let (library, _) = translationContext()
        let suite = "qwen-translated-language-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderSettings(defaults: defaults)
        settings.engine = .qwen
        settings.qwenSpeaker = .serena
        let renderer = RecordingQwenVoiceRenderer()
        let playback = PlaybackController(library: library, settings: settings,
            renderQwen: { text, style, language, speaker, _ in
                try await renderer.render(text, style: style, speaker: speaker, language: language)
            })
        defer { playback.stop() }
        var original = try DocumentImporter.fromText("The train arrived before sunrise.", title: "Language test")
        original.languageCode = "en"
        library.add(original)
        let work = TranslationWork(document: original, source: "en", target: "fr")
        let french = try work.document(from: ["Le train est arrivé avant le lever du soleil."], original: original, language: "fr-FR")
        library.add(french)
        playback.open(french, autoplay: true)
        try await renderer.waitForRequests(1)
        playback.open(original, autoplay: true)
        try await renderer.waitForRequests(2)
        let requests = await renderer.requests
        XCTAssertEqual(requests.map(\.language), ["French", "English"])
        XCTAssertEqual(requests.map(\.text), [french.segments.joined(separator: " "), original.segments.joined(separator: " ")])
        XCTAssertEqual(requests.map(\.speaker), [.serena, .serena])
    }

    @MainActor func testQwenLanguageMetadataAcceptsRegionsCaseAndEPUBThreeLetterCodes() throws {
        for code in ["fr", "fr-FR", "fr_FR", "FR", "fra", "fre"] {
            XCTAssertEqual(NarrationStyle.languageName(for: code), "French", code)
        }
        for code in ["en_US", "EN-us", "eng"] {
            XCTAssertEqual(NarrationStyle.languageName(for: code), "English", code)
        }
        XCTAssertNil(NarrationStyle.languageName(for: "nl"))
    }

    func testReaderHighlightKeepsUnicodeOffsetsAndAdvancesInsideParagraph() throws {
        let segments = ["L’été 🌿 arrive.", "Puis Zoé ouvre la fenêtre."]
        let range = (segments[1] as NSString).range(of: "Zoé")
        let content = ReaderParagraphContent(segments: segments, start: 5, position: 6, wordRange: range)
        XCTAssertEqual(content.currentWord, "Zoé")
        XCTAssertEqual(content.highlight?.location, segments[0].utf16.count + 1 + range.location)
        let next = ReaderParagraphContent(segments: segments, start: 5, position: 6,
                                          wordRange: (segments[1] as NSString).range(of: "fenêtre"))
        XCTAssertEqual(next.currentWord, "fenêtre")
        XCTAssertNotEqual(content.highlight, next.highlight)
        XCTAssertEqual(ReaderParagraphContent(segments: segments, start: 5, position: 6, wordRange: nil).currentWord, "Puis")
        XCTAssertNil(ReaderParagraphContent(segments: segments, start: 5, position: 7, wordRange: range).highlight)
        XCTAssertNil(ReaderParagraphContent(segments: segments, start: 5, position: 6, wordRange: NSRange(location: 900, length: 3)).highlight)
    }

    func testReaderHighlightUsesChineseWordBoundariesBeforeAppleVoiceCallback() throws {
        let sentence = "当前章节已经准备好。"
        let initial = ReaderParagraphContent(segments: [sentence], start: 0, position: 0, wordRange: nil)
        XCTAssertEqual(initial.currentWord, "当前")
        XCTAssertLessThan(try XCTUnwrap(initial.highlight).length, sentence.utf16.count,
                          "A Chinese sentence must not be highlighted as one whitespace-delimited word")

        let appleRange = (sentence as NSString).range(of: "准备")
        let spoken = ReaderParagraphContent(segments: [sentence], start: 0, position: 0, wordRange: appleRange)
        XCTAssertEqual(spoken.currentWord, "准备", "Keep Apple's exact UTF-16 speech range once available")
    }

    @MainActor func testReaderHighlightMovesToActualLineWithoutChangingParagraph() throws {
        let text = "Début " + Array(repeating: "une longue phrase dans le même paragraphe", count: 20).joined(separator: " ") + " arrivée"
        let view = ReaderParagraphTextView()
        let firstRange = (text as NSString).range(of: "Début")
        view.configure(content: .init(segments: [text], start: 0, position: 0, wordRange: firstRange), textSize: 22)
        let size = view.sizeThatFits(CGSize(width: 250, height: 100_000))
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        let first = try XCTUnwrap(view.currentWordRect())
        let lastRange = (text as NSString).range(of: "arrivée")
        view.configure(content: .init(segments: [text], start: 0, position: 0, wordRange: lastRange), textSize: 22)
        view.layoutIfNeeded()
        let last = try XCTUnwrap(view.currentWordRect())
        XCTAssertGreaterThan(last.minY, first.maxY + 400, "Follow the spoken line even inside one long paragraph")
        XCTAssertNil(view.attributedText.attribute(.backgroundColor, at: firstRange.location, effectiveRange: nil))
        XCTAssertNotNil(view.attributedText.attribute(.backgroundColor, at: lastRange.location, effectiveRange: nil))
        view.configure(content: .init(segments: [text], start: 0, position: 0, wordRange: lastRange), textSize: 30)
        view.frame.size = view.sizeThatFits(CGSize(width: 250, height: 100_000))
        view.layoutIfNeeded()
        XCTAssertGreaterThan(try XCTUnwrap(view.currentWordRect()).minY, last.minY)
    }

    func testReaderFollowsWordBeyondViewportAndAfterBackwardSeek() throws {
        let visible = CGRect(x: 0, y: 0, width: 300, height: 400)
        XCTAssertNil(ReaderFollowScroll.offset(word: CGRect(x: 10, y: 100, width: 40, height: 25), visible: visible, contentHeight: 2000))
        let word = CGRect(x: 10, y: 1450, width: 40, height: 25)
        let offset = try XCTUnwrap(ReaderFollowScroll.offset(word: word, visible: visible, contentHeight: 2000))
        XCTAssertEqual(offset, word.midY - visible.height / 2,
                       "Paragraph and word following must share one centred destination")
        let advanced = visible.offsetBy(dx: 0, dy: offset)
        XCTAssertTrue(advanced.contains(word))
        XCTAssertNil(ReaderFollowScroll.offset(word: word, visible: advanced, contentHeight: 2000))
        XCTAssertEqual(ReaderFollowScroll.offset(word: CGRect(x: 10, y: 10, width: 40, height: 25), visible: advanced, contentHeight: 2000), 0)
    }

    func testReaderScrollsBeforeWordIsCoveredByPlaybackControls() throws {
        let visible = ReaderFollowScroll.visibleTextRect(offset: CGPoint(x: 0, y: -74), size: CGSize(width: 440, height: 590),
                                                        insets: .init(top: 74, leading: 0, bottom: 230, trailing: 0))
        XCTAssertEqual(visible, CGRect(x: 0, y: 0, width: 440, height: 590))
        let coveredWord = CGRect(x: 20, y: 640, width: 65, height: 28)
        let offset = try XCTUnwrap(ReaderFollowScroll.offset(word: coveredWord, visible: visible, contentHeight: 1800))
        XCTAssertTrue(visible.offsetBy(dx: 0, dy: offset).contains(coveredWord))
    }

    @MainActor func testQwenReserveAbsorbsSlowNextParagraphWithoutGaps() async throws {
        let document = try DocumentImporter.fromText("Première phrase.\n\nDeuxième phrase.\n\nTroisième phrase.", title: "Continuité")
        let renderer = QwenTestRenderer(delays: [0.05, 1.4, 0.05])
        let player = try QwenPassagePlayer(document: document, start: 0, rate: 2, volume: 0) { text in
            try await renderer.render(text)
        }
        defer { player.stop() }
        var finished = 0
        var starts: [String] = []
        var gaps: [Double] = []
        var wasBuffering = false
        player.onPassageChanged = { starts.append($0.text) }
        player.onFinished = { finished += 1 }
        player.onError = { XCTFail("Unexpected error: \($0)") }
        player.onStateChanged = {
            if player.hasStarted && player.isBuffering && !wasBuffering { gaps.append(player.playedSeconds) }
            wasBuffering = player.isBuffering
        }
        player.play()
        let deadline = Date().addingTimeInterval(8)
        while finished == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(starts, document.segments)
        XCTAssertTrue(gaps.isEmpty, "Reserve preparation must absorb the deliberately slow second paragraph before starting")
        XCTAssertEqual(player.completedPassages, 3)
        XCTAssertEqual(player.metrics?.audioSeconds, 3)
    }

    @MainActor func testQwenWorksMoreThanTwoPassagesAheadWhileReading() async throws {
        let document = try DocumentImporter.fromText((0..<12).map { "Passage numéro \($0)." }.joined(separator: "\n\n"), title: "Avance")
        let renderer = QwenTestRenderer(delays: [0.04])
        let player = try QwenPassagePlayer(document: document, start: 0, rate: 2, volume: 0,
                                          buffering: .init(minimumAutomaticSeconds: 0.5, minimumAheadSeconds: 2)) { text in
            try await renderer.render(text)
        }
        defer { player.stop() }
        var finished = false
        var overlap = false
        var peak = 0
        var gaps = 0
        player.onFinished = { finished = true }
        player.onError = { XCTFail("Unexpected error: \($0)") }
        player.onStateChanged = {
            peak = max(peak, player.bufferedPassages)
            overlap = overlap || (player.isAudible && player.isGenerating)
            if player.hasStarted && player.isBuffering { gaps += 1 }
        }
        player.play()
        let deadline = Date().addingTimeInterval(12)
        while !finished && Date() < deadline { try await Task.sleep(for: .milliseconds(40)) }
        XCTAssertTrue(finished)
        XCTAssertTrue(overlap)
        XCTAssertGreaterThan(peak, 2)
        XCTAssertLessThanOrEqual(peak, 6, "The time reserve may overshoot by only one generated passage")
        XCTAssertEqual(gaps, 0)
        XCTAssertEqual(player.completedPassages, 12)
    }

    @MainActor func testQwenReserveGaugeUsesCommittedListeningSecondsAndTracksSettings() async throws {
        let document = try DocumentImporter.fromText("Un passage.\n\nUn autre.\n\nLe dernier.", title: "Jauge")
        let renderer = QwenTestRenderer(delays: [0.05])
        let player = try QwenPassagePlayer(document: document, start: 0, rate: 2, volume: 0,
                                          buffering: .init(preset: .seconds30)) { try await renderer.render($0) }
        defer { player.stop() }
        var snapshots: [QwenReserveProgress] = []
        player.onReserveChanged = { snapshots.append($0) }
        player.play()
        XCTAssertEqual(snapshots.last?.readySeconds, 0, "In-flight synthesis is not playable reserve")
        XCTAssertEqual(snapshots.last?.targetSeconds, 30)
        player.pause()
        let deadline = Date().addingTimeInterval(4)
        while player.generatedPassages < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        var reserve = try XCTUnwrap(snapshots.last)
        XCTAssertEqual(reserve.readySeconds, 1, "Two seconds of PCM give one second of listening at 2×")
        XCTAssertTrue(reserve.isPaused)
        XCTAssertFalse(reserve.isComplete)
        XCTAssertEqual(reserve.fraction, 1.0 / 30, accuracy: 0.001)
        player.rate = 1
        player.setBufferPreset(.seconds60)
        reserve = try XCTUnwrap(snapshots.last)
        XCTAssertEqual(reserve.readySeconds, 2)
        XCTAssertEqual(reserve.targetSeconds, 60)
        XCTAssertFalse(reserve.isAutomatic)
        player.setBufferPreset(.automatic)
        XCTAssertTrue(try XCTUnwrap(snapshots.last).isAutomatic)
        player.stop()
        let count = snapshots.count
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(snapshots.count, count, "A discarded queue must not publish a stale gauge")
    }

    @MainActor func testQwenReserveGaugePublishesConsumptionAndCompletesShortBooks() async throws {
        let document = try DocumentImporter.fromText("Première phrase.\n\nDeuxième phrase.\n\nDernière phrase.", title: "Jauge courte")
        let renderer = QwenTestRenderer(delays: [0.05])
        let player = try QwenPassagePlayer(document: document, start: 0, rate: 1, volume: 0,
                                          buffering: .init(preset: .seconds30)) { try await renderer.render($0) }
        defer { player.stop() }
        var snapshots: [QwenReserveProgress] = []
        var finished = false
        player.onReserveChanged = { snapshots.append($0) }
        player.onFinished = { finished = true }
        player.onError = { XCTFail("Unexpected error: \($0)") }
        player.play()
        let deadline = Date().addingTimeInterval(6)
        while !finished && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(finished, "A short book must start below the requested reserve once all audio is ready")
        let ready = snapshots.filter { $0.isComplete && $0.hasStarted }
        XCTAssertTrue(ready.allSatisfy { $0.fraction == 1 })
        XCTAssertGreaterThan(ready.count, 3, "Publish consumption without waiting for paragraph boundaries")
        XCTAssertGreaterThan(try XCTUnwrap(ready.first).readySeconds, try XCTUnwrap(ready.last).readySeconds)
        XCTAssertTrue(snapshots.contains { !$0.isComplete && $0.readySeconds > 0 && $0.fraction < 1 })
    }

    func testQwenReserveIgnoresColdLoadAndHonorsManualPresets() {
        var policy = QwenPassageBufferPolicy()
        policy.record(generationSeconds: 90, audioSeconds: 20, characters: 100)
        XCTAssertEqual(policy.startupSeconds(nextCharacters: 100), 12)
        policy.record(generationSeconds: 10, audioSeconds: 20, characters: 100)
        XCTAssertEqual(policy.startupSeconds(nextCharacters: 200), 29, accuracy: 0.01)
        policy.preset = .seconds10
        XCTAssertEqual(policy.startupSeconds(nextCharacters: 300), 10)
        policy.preset = .seconds60
        XCTAssertEqual(policy.startupSeconds(nextCharacters: 10), 60)
        XCTAssertEqual(policy.aheadSeconds, 120)

        var slow = QwenPassageBufferPolicy()
        slow.record(generationSeconds: 90, audioSeconds: 8, characters: 100)
        slow.record(generationSeconds: 10, audioSeconds: 8, characters: 100)
        XCTAssertEqual(slow.startupSeconds(nextCharacters: 100, rate: 2), 39.6, accuracy: 0.01)
        XCTAssertEqual(slow.startupSeconds(nextCharacters: 100, rate: 1), 19.2, accuracy: 0.01)
    }

    @MainActor func testQwenReserveSettingPersistsIndependently() {
        let suite = "qwen-buffer-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderSettings(defaults: defaults)
        XCTAssertEqual(settings.qwenBuffer, .automatic)
        settings.qwenBuffer = .seconds30
        settings.qwenSpeed = 2.5
        settings.qwenSpeaker = .serena
        let restored = ReaderSettings(defaults: defaults)
        XCTAssertEqual(restored.qwenBuffer, .seconds30)
        XCTAssertEqual(restored.qwenSpeed, 2.5)
        XCTAssertEqual(restored.qwenSpeaker, .serena)
        defaults.set("invalid", forKey: "voice.qwenBuffer")
        XCTAssertEqual(ReaderSettings(defaults: defaults).qwenBuffer, .automatic)
    }

    @MainActor func testQwenPrefetchIsBoundedAndPauseDoesNotRegenerate() async throws {
        let document = try DocumentImporter.fromText("Un passage.\n\nUn autre passage.\n\nLe dernier.", title: "Pause")
        let renderer = QwenTestRenderer(delays: [0.03])
        let player = try QwenPassagePlayer(document: document, start: 0, rate: 1, volume: 0) { text in
            try await renderer.render(text)
        }
        defer { player.stop() }
        var finished = false
        player.onFinished = { finished = true }
        player.onError = { XCTFail("Unexpected error: \($0)") }
        player.play()
        player.pause()
        let deadline = Date().addingTimeInterval(5)
        while player.generatedPassages < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(player.generatedPassages, 2, "A pause must not generate the whole book")
        XCTAssertFalse(player.isAudible)
        XCTAssertFalse(finished)
        player.rate = 2
        player.play()
        while !finished && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(finished)
        let rendered = await renderer.texts
        XCTAssertEqual(rendered, document.segments, "Resume must not synthesize any passage twice")
    }

    @MainActor func testQwenStopDiscardsAnInFlightPassage() async throws {
        let document = try DocumentImporter.fromText("Une phrase complète.", title: "Annulation")
        let renderer = QwenTestRenderer(delays: [0.5])
        let player = try QwenPassagePlayer(document: document, start: 0, rate: 2, volume: 0) { text in
            try await renderer.render(text)
        }
        var callbacksAfterStop = 0
        player.onPassageChanged = { _ in callbacksAfterStop += 1 }
        player.onFinished = { callbacksAfterStop += 1 }
        player.onError = { _ in callbacksAfterStop += 1 }
        player.play()
        try await Task.sleep(for: .milliseconds(50))
        player.stop()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(player.hasStarted)
        XCTAssertEqual(callbacksAfterStop, 0)
        let files = await renderer.outputFiles
        for file in files { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Discarded audio must be removed") }
    }

    func testQwenBufferAccountsForSlowGenerationButNotColdModelLoading() {
        var warm = QwenBufferPolicy(estimatedSeconds: 40, minimumSeconds: 2)
        var cold = warm
        for index in 0..<5 {
            warm.received(seconds: 1.5, at: Double(index) * 1.5)
            cold.received(seconds: 1.5, at: 60 + Double(index) * 1.5)
        }
        XCTAssertEqual(warm.targetSeconds(rate: 2, played: 0), cold.targetSeconds(rate: 2, played: 0))
        XCTAssertGreaterThan(warm.targetSeconds(rate: 2, played: 0), 20)
        XCTAssertGreaterThan(warm.targetSeconds(rate: 2, played: 0), warm.targetSeconds(rate: 1, played: 0))
        XCTAssertLessThan(warm.targetSeconds(rate: 2, played: 30), warm.targetSeconds(rate: 2, played: 0))
    }

    @MainActor func testQwenBuffersBeforeStartingAndRefillsBeforeResuming() async throws {
        let player = try QwenStreamPlayer(rate: 2, volume: 0, minimumBufferSeconds: 0.3)
        defer { player.stop() }
        var finished = 0
        player.onFinished = { finished += 1 }
        let chunk = QwenAudioChunk(samples: Array(repeating: 0, count: 9_600), sampleRate: 24_000)
        player.play()
        try player.append(chunk)
        XCTAssertFalse(player.hasStarted)
        XCTAssertTrue(player.isBuffering)
        try player.append(chunk)
        XCTAssertTrue(player.isAudible)
        XCTAssertFalse(player.inputEnded)
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(player.isBuffering)
        try player.append(chunk)
        XCTAssertFalse(player.isAudible, "A single short chunk must not trigger another stutter")
        XCTAssertEqual(finished, 0)
        player.finishInput()
        XCTAssertTrue(player.isAudible, "The final tail must play even below the reserve threshold")
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(finished, 1)
        XCTAssertFalse(player.isBuffering, "Completion must not be reported as a final underrun")
    }

    @MainActor func testQwenStreamsBeforeCompletionAndWaitsAcrossUnderruns() async throws {
        let player = try QwenStreamPlayer(rate: 2, volume: 0, minimumBufferSeconds: 0)
        defer { player.stop() }
        var finished = 0
        player.onFinished = { finished += 1 }
        player.play()
        let chunk = QwenAudioChunk(samples: Array(repeating: 0, count: 12_000), sampleRate: 24_000)
        try player.append(chunk)
        XCTAssertTrue(player.hasStarted)
        XCTAssertFalse(player.inputEnded)
        XCTAssertTrue(player.isAudible)
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(player.isBuffering)
        XCTAssertEqual(finished, 0, "An underrun is not the end of the passage")
        let position = player.playedSeconds
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(player.playedSeconds, position, accuracy: 0.01, "Waiting must not advance the text")
        try player.append(chunk)
        XCTAssertTrue(player.isAudible)
        player.finishInput()
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(player.playedSeconds, 1, accuracy: 0.01)
    }

    @MainActor func testQwenPauseRateChangeAndStopKeepQueuedAudioUnderControl() async throws {
        let player = try QwenStreamPlayer(rate: 1, volume: 0, minimumBufferSeconds: 0)
        defer { player.stop() }
        var finished = 0
        player.onFinished = { finished += 1 }
        player.play()
        try player.append(QwenAudioChunk(samples: Array(repeating: 0, count: 24_000), sampleRate: 24_000))
        player.pause()
        player.rate = 2
        let generated = player.generatedSeconds
        player.finishInput()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(player.isAudible)
        XCTAssertEqual(finished, 0)
        XCTAssertEqual(player.generatedSeconds, generated)
        player.play()
        XCTAssertTrue(player.isAudible)
        player.stop()
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(finished, 0, "Cancellation must not advance to another passage")
    }

    @MainActor func testQwenSpeedDefaultsToTwoAndPersistsIndependently() {
        let suite = "qwen-speed-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1.25, forKey: "voice.speed")
        let settings = ReaderSettings(defaults: defaults)
        XCTAssertEqual(settings.qwenSpeed, 2)
        settings.qwenSpeed = 1.75
        let reopened = ReaderSettings(defaults: defaults)
        XCTAssertEqual(reopened.qwenSpeed, 1.75)
        XCTAssertEqual(reopened.speed, 1.25)
    }

    @MainActor func testQwenSpeakerAndStylePersistIndependently() {
        let suite = "qwen-speaker-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderSettings(defaults: defaults)
        XCTAssertEqual(settings.qwenSpeaker, .ryan)
        settings.qwenStyle = .dramatic
        settings.qwenSpeaker = .serena
        let reopened = ReaderSettings(defaults: defaults)
        XCTAssertEqual(reopened.qwenSpeaker, .serena)
        XCTAssertEqual(reopened.qwenStyle, .dramatic)
        defaults.set("unknown-voice", forKey: "voice.qwenSpeaker")
        XCTAssertEqual(ReaderSettings(defaults: defaults).qwenSpeaker, .ryan)
    }

    @MainActor func testAppleFavoritesPersistIndependentlyForEachLanguage() {
        let suite = "apple-voices-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderSettings(defaults: defaults)
        settings.preferSystemVoice("audrey", for: "fr-FR")
        settings.preferSystemVoice("daniel", for: "en-GB")
        settings.preferSystemVoice("monica", for: "es-ES")
        settings.preferSystemVoice("thomas", for: "fr-CA")
        let reopened = ReaderSettings(defaults: defaults)
        let catalog = [SystemVoiceSelection.Voice(id: "audrey", language: "fr-FR", quality: 3),
                       .init(id: "thomas", language: "fr-FR", quality: 1),
                       .init(id: "daniel", language: "en-GB", quality: 1),
                       .init(id: "monica", language: "es-ES", quality: 1)]
        for (language, expected) in [("fr", "thomas"), ("en_US", "daniel"), ("es-MX", "monica")] {
            XCTAssertEqual(SystemVoiceSelection.identifier(for: language, preferred: reopened.systemVoiceID(for: language), voices: catalog), expected)
        }
        XCTAssertEqual(reopened.systemVoiceIDs.count, 3)
        XCTAssertEqual(reopened.systemVoiceID(for: "de"), "")
    }

    @MainActor func testLegacyAppleVoiceMigratesOnceAndAutomaticOnlyResetsItsLanguage() {
        let suite = "apple-voice-migration-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("audrey", forKey: "voice.identifier")
        let settings = ReaderSettings(defaults: defaults, legacyVoiceLanguage: { $0 == "audrey" ? "fr-FR" : nil })
        XCTAssertEqual(settings.systemVoiceID(for: "fr"), "audrey")
        settings.preferSystemVoice("daniel", for: "en-US")
        settings.preferSystemVoice("", for: "fr-CA")
        let reopened = ReaderSettings(defaults: defaults, legacyVoiceLanguage: { _ in
            XCTFail("Do not migrate an old global choice over saved language preferences")
            return "fr"
        })
        XCTAssertEqual(reopened.systemVoiceID(for: "fr"), "")
        XCTAssertEqual(reopened.systemVoiceID(for: "en"), "daniel")
        reopened.preferSystemVoice("", for: "en")
        XCTAssertTrue(ReaderSettings(defaults: defaults).systemVoiceIDs.isEmpty)
    }

    @MainActor func testUnavailableAppleFavoriteFallsBackWithoutForgettingIt() {
        let suite = "apple-voice-unavailable-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderSettings(defaults: defaults)
        settings.preferSystemVoice("audrey", for: "fr")
        var voices = [SystemVoiceSelection.Voice(id: "thomas", language: "fr-FR", quality: 1),
                      .init(id: "daniel", language: "en-GB", quality: 3)]
        XCTAssertEqual(SystemVoiceSelection.identifier(for: "fr", preferred: settings.systemVoiceID(for: "fr"), voices: voices), "thomas")
        voices.append(.init(id: "audrey", language: "fr-FR", quality: 1))
        let reopened = ReaderSettings(defaults: defaults)
        XCTAssertEqual(SystemVoiceSelection.identifier(for: "fr", preferred: reopened.systemVoiceID(for: "fr"), voices: voices), "audrey")
    }

    @MainActor private func translationContext() -> (LibraryStore, URL) {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (LibraryStore(directory: directory), directory)
    }

    @MainActor func testCurrentLanguageKeepsEditionAndReadingPosition() async throws {
        let (library, _) = translationContext()
        let original = try XCTUnwrap(library.documents.first)
        library.updatePosition(id: original.id, position: 2)
        let coordinator = TranslationCoordinator(library: library,
            prepareVoice: { XCTFail("The current edition needs no translation") },
            languageStatus: { _, _ in XCTFail("No language check needed"); return .installed })
        await coordinator.request(original, targetLanguage: "fr-FR")
        XCTAssertEqual(coordinator.readyDocumentID, original.id)
        XCTAssertFalse(coordinator.isTranslating)
        XCTAssertNil(coordinator.configuration)
        XCTAssertEqual(library.document(original.id)?.position, 2)
    }

    @MainActor func testOldTranslationIsReusedAndOriginalCanBeSelected() async throws {
        let (library, _) = translationContext()
        let original = try XCTUnwrap(library.documents.first)
        var spanish = ReadingDocument(title: original.title, author: original.author, source: "TRADUIT · ES", segments: ["Buenos días."])
        spanish.translationOf = original.id
        spanish.languageCode = "es-ES"
        XCTAssertNil(spanish.translationVersion)
        XCTAssertTrue(library.add(spanish))
        let count = library.documents.count
        let coordinator = TranslationCoordinator(library: library,
            prepareVoice: { XCTFail("Saved editions must be reused") })
        await coordinator.request(original, targetLanguage: "es")
        XCTAssertEqual(coordinator.readyDocumentID, spanish.id)
        XCTAssertFalse(coordinator.isTranslating)
        await coordinator.request(spanish, targetLanguage: "es")
        XCTAssertEqual(coordinator.readyDocumentID, spanish.id)
        await coordinator.request(spanish, targetLanguage: "fr")
        XCTAssertEqual(coordinator.readyDocumentID, original.id)
        XCTAssertEqual(library.documents.count, count)
        XCTAssertNil(coordinator.configuration)
    }

    @MainActor func testAnotherLanguageTranslatesFromOriginalNotPreviousTranslation() async throws {
        let (library, _) = translationContext()
        let original = try XCTUnwrap(library.documents.first)
        var english = ReadingDocument(title: original.title, author: "", source: "TRADUIT · EN", segments: ["Good morning."])
        english.translationOf = original.id
        english.languageCode = "en"
        XCTAssertTrue(library.add(english))
        let coordinator = TranslationCoordinator(library: library,
            prepareVoice: {}, languageStatus: { source, target in
                XCTAssertEqual(source, "fr")
                XCTAssertEqual(target, "es")
                return .installed
            })
        await coordinator.request(english, targetLanguage: "es-MX")
        let configuration = try XCTUnwrap(coordinator.configuration)
        XCTAssertEqual(configuration.source?.languageCode?.identifier, "fr")
        XCTAssertEqual(configuration.target?.languageCode?.identifier, "es")
        XCTAssertTrue(coordinator.isTranslating)
        coordinator.cancel()
    }

    @MainActor func testTranslationCanRestartSameLanguagesAfterCancellation() async throws {
        let (library, _) = translationContext()
        let original = try XCTUnwrap(library.documents.first)
        let coordinator = TranslationCoordinator(library: library,
            prepareVoice: {}, languageStatus: { _, _ in .installed })
        await coordinator.request(original, targetLanguage: "es")
        let first = try XCTUnwrap(coordinator.configuration)
        coordinator.cancel()
        XCTAssertNil(coordinator.readyDocumentID)
        await coordinator.request(original, targetLanguage: "es")
        let second = try XCTUnwrap(coordinator.configuration)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.source, second.source)
        XCTAssertEqual(first.target, second.target)
        XCTAssertTrue(coordinator.isTranslating)
        coordinator.cancel()
    }

    @MainActor func testSwitchingAppsDoesNotImmediatelyPauseTranslation() async throws {
        let (library, _) = translationContext()
        let original = try XCTUnwrap(library.documents.first)
        let coordinator = TranslationCoordinator(library: library,
            prepareVoice: {}, languageStatus: { _, _ in .installed })
        await coordinator.request(original, targetLanguage: "es")

        coordinator.applicationDidEnterBackground()

        XCTAssertTrue(coordinator.isTranslating)
        XCTAssertNotNil(coordinator.configuration)
        XCTAssertNil(coordinator.errorMessage)
        coordinator.applicationDidBecomeActive()
        XCTAssertTrue(coordinator.isTranslating)
        coordinator.cancel()
    }

    @MainActor func testRussianTranslationFallsBackToTraditionalAppleModels() async throws {
        let (library, _) = translationContext()
        var russian = try DocumentImporter.fromText("В начале июля, в чрезвычайно жаркое время, молодой человек вышел из своей каморки.", title: "Русский роман")
        russian.languageCode = "ru-RU"
        XCTAssertTrue(library.add(russian))
        var checks: [(String, String)] = []
        let coordinator = TranslationCoordinator(library: library, prepareVoice: {},
            languageStatus: { source, target in checks.append((source, target)); return .unsupported },
            fallbackLanguageStatus: { source, target in checks.append((source, target)); return .installed })
        await coordinator.request(russian, targetLanguage: "fr-FR")
        XCTAssertEqual(checks.map(\.0), ["ru", "ru"])
        XCTAssertEqual(checks.map(\.1), ["fr-FR", "fr-FR"])
        XCTAssertTrue(coordinator.isTranslating)
        let configuration = try XCTUnwrap(coordinator.configuration)
        XCTAssertEqual(configuration.source?.languageCode?.identifier, "ru")
        XCTAssertEqual(configuration.target?.languageCode?.identifier, "fr")
        XCTAssertEqual(configuration.target?.region?.identifier, "FR")
        coordinator.cancel()
    }

    @MainActor func testTranslationPreservesInstalledLanguageVariant() async throws {
        let (library, _) = translationContext()
        let original = try XCTUnwrap(library.documents.first)
        var checkedTargets: [String] = []
        let coordinator = TranslationCoordinator(library: library, prepareVoice: {},
            languageStatus: { _, target in checkedTargets.append(target); return .installed })

        await coordinator.request(original, targetLanguage: "en_US")

        XCTAssertEqual(SystemVoiceSelection.localeIdentifier("en_US"), "en-US")
        XCTAssertEqual(SystemVoiceSelection.localeIdentifier("fr"), "fr")
        XCTAssertEqual(SystemVoiceSelection.localeIdentifier("zh-Hans-CN"), "zh-Hans-CN")
        XCTAssertEqual(SystemVoiceSelection.localeIdentifier("en-US-u-hc-h23"), "en-US")
        XCTAssertEqual(checkedTargets, ["en-US"])
        let configuration = try XCTUnwrap(coordinator.configuration)
        XCTAssertEqual(configuration.target?.languageCode?.identifier, "en")
        XCTAssertEqual(configuration.target?.region?.identifier, "US")
        coordinator.cancel()
    }

    @MainActor func testInstalledLowLatencyModelAvoidsOptionalHighFidelityDownload() async throws {
        let (library, _) = translationContext()
        let original = try XCTUnwrap(library.documents.first)
        var fallbackChecks = 0
        let coordinator = TranslationCoordinator(library: library, prepareVoice: {},
            languageStatus: { _, _ in .supported },
            fallbackLanguageStatus: { _, _ in fallbackChecks += 1; return .installed })

        await coordinator.request(original, targetLanguage: "es")

        if #available(iOS 26.4, *) {
            XCTAssertEqual(fallbackChecks, 1)
            XCTAssertEqual(coordinator.status, String(localized: "Préparation de la traduction…"))
        }
        XCTAssertFalse(coordinator.isInstallingLanguages)
        XCTAssertNotNil(coordinator.configuration)
        XCTAssertTrue(coordinator.isTranslating)
        XCTAssertGreaterThanOrEqual(coordinator.preparationProgress, 0.45)
        coordinator.cancel()
        XCTAssertEqual(coordinator.preparationProgress, 0)
    }

    @MainActor func testMissingLanguageModelIsMarkedAsAnIOSInstallation() async throws {
        let (library, _) = translationContext()
        let original = try XCTUnwrap(library.documents.first)
        let coordinator = TranslationCoordinator(library: library, prepareVoice: {},
            languageStatus: { _, _ in .supported },
            fallbackLanguageStatus: { _, _ in .supported })

        await coordinator.request(original, targetLanguage: "es")

        XCTAssertTrue(coordinator.isInstallingLanguages)
        XCTAssertEqual(coordinator.status, String(localized: "Installation des langues avec iOS…"))
        coordinator.cancel()
        XCTAssertFalse(coordinator.isInstallingLanguages)
    }

    @MainActor func testLanguageInstallationTimesOutWithSettingsInstructions() async throws {
        let (library, _) = translationContext()
        let original = try XCTUnwrap(library.documents.first)
        let coordinator = TranslationCoordinator(
            library: library,
            languageInstallationTimeout: .milliseconds(20),
            prepareVoice: {},
            languageStatus: { _, _ in .supported },
            fallbackLanguageStatus: { _, _ in .supported }
        )

        await coordinator.request(original, targetLanguage: "es")
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertFalse(coordinator.isTranslating)
        XCTAssertFalse(coordinator.isInstallingLanguages)
        XCTAssertTrue(coordinator.errorMessage?.contains("Réglages") == true)
        XCTAssertTrue(coordinator.errorMessage?.contains("Langues téléchargées") == true)
    }

    @MainActor func testStartupTimeoutExitsZeroProgressAndIgnoresLatePreparation() async throws {
        let (library, _) = translationContext()
        let original = try XCTUnwrap(library.documents.first)
        let coordinator = TranslationCoordinator(library: library,
            startupTimeout: .milliseconds(20),
            prepareVoice: { try? await Task.sleep(for: .milliseconds(100)) },
            languageStatus: { _, _ in XCTFail("Expired request must not continue"); return .installed })
        await coordinator.request(original, targetLanguage: "es")
        XCTAssertFalse(coordinator.isTranslating)
        XCTAssertFalse(coordinator.isPreparing)
        XCTAssertNil(coordinator.configuration)
        XCTAssertNil(coordinator.readyDocumentID)
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertEqual(library.document(original.id), original)
    }

    @MainActor func testStartupTaskCancellationDoesNotNavigateOrChangeOriginal() async throws {
        let (library, _) = translationContext()
        let original = try XCTUnwrap(library.documents.first)
        let coordinator = TranslationCoordinator(library: library,
            prepareVoice: { try? await Task.sleep(for: .seconds(10)) },
            languageStatus: { _, _ in XCTFail("Cancelled preparation must stop"); return .installed })
        let task = Task { await coordinator.request(original, targetLanguage: "es") }
        await Task.yield()
        task.cancel()
        await task.value
        XCTAssertFalse(coordinator.isTranslating)
        XCTAssertNil(coordinator.configuration)
        XCTAssertNil(coordinator.readyDocumentID)
        XCTAssertEqual(library.document(original.id), original)
    }

    @MainActor func testLegacyReadingPreferenceDoesNotPreventLoadingOriginal() throws {
        let (library, directory) = translationContext()
        let original = try XCTUnwrap(library.documents.first)
        library.updatePosition(id: original.id, position: 2)
        let url = directory.appending(path: "library.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        json[0]["preferredReadingID"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let reopened = LibraryStore(directory: directory)
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.document(original.id)?.segments, original.segments)
        XCTAssertEqual(reopened.document(original.id)?.position, 2)
    }

    @MainActor func testPhoneLanguagePromptsOnlyForForeignBooksAndRemembersOriginal() throws {
        let (library, directory) = translationContext()
        let original = try XCTUnwrap(library.documents.first)
        XCTAssertFalse(library.readingRoute(for: original, phoneLanguage: "fr").translate)
        XCTAssertTrue(library.readingRoute(for: original, phoneLanguage: "en").translate)
        library.rememberReading(originalID: original.id, readingID: original.id)
        let reopened = LibraryStore(directory: directory)
        XCTAssertFalse(reopened.readingRoute(for: original, phoneLanguage: "en").translate)
        XCTAssertFalse(reopened.readingRoute(for: original, phoneLanguage: "es").translate)
        XCTAssertEqual(reopened.readingRoute(for: original, phoneLanguage: "es").document.id, original.id)
    }

    @MainActor func testSelectingOriginalEPUBKeepsItsTextAndPositionBesideSavedTranslation() throws {
        let (library, directory) = translationContext()
        var original = try DocumentImporter.fromText("The garden was quiet.\n\nShe opened the gate.", title: "The garden", source: "EPUB")
        original.languageCode = "en"
        XCTAssertTrue(library.add(original))
        var french = try DocumentImporter.fromText("Le jardin était calme.\n\nElle ouvrit la grille.", title: original.title, source: "TRADUIT · FR")
        french.languageCode = "fr"
        french.translationOf = original.id
        XCTAssertTrue(library.add(french))
        library.updatePosition(id: original.id, position: 1)
        library.toggleBookmark(id: original.id, position: 1)
        library.rememberReading(originalID: original.id, readingID: french.id)

        let reopened = LibraryStore(directory: directory)
        for language in ["fr", "en", "es"] {
            let route = reopened.readingRoute(for: original, phoneLanguage: language)
            XCTAssertEqual(route.document.id, original.id, "Selecting the EPUB must never substitute another edition")
            XCTAssertEqual(route.document.segments, original.segments)
            XCTAssertEqual(route.document.position, 1)
            XCTAssertEqual(route.document.bookmarks, [1])
            XCTAssertFalse(route.translate)
        }
        let translatedRoute = reopened.readingRoute(for: french, phoneLanguage: "fr")
        XCTAssertEqual(translatedRoute.document.id, french.id)
        XCTAssertEqual(translatedRoute.document.segments, french.segments)
        XCTAssertEqual(translatedRoute.document.position, 0)
        XCTAssertFalse(translatedRoute.translate)
        library.rememberReading(originalID: original.id, readingID: original.id)
        XCTAssertEqual(library.readingRoute(for: french, phoneLanguage: "en").document.id, french.id)
    }

    func testTranslationPublishesContiguousTextBeforeCompletionWithoutChangingOffsets() throws {
        let original = try DocumentImporter.fromText("Premier paragraphe.\n\nDeuxième paragraphe.\n\nDernier paragraphe.", title: "Progressif")
        let work = TranslationWork(document: original, source: "fr", target: "en")
        var draft = work.draft(original: original, language: "en")
        XCTAssertEqual(draft.author, original.author)
        XCTAssertEqual(draft.translationTitleComplete, false)
        XCTAssertEqual(draft.translationAuthorComplete, false)
        XCTAssertFalse(draft.isTranslationMetadataComplete)
        XCTAssertEqual(draft.translationProgress, 0)
        XCTAssertFalse(work.appendAvailable(["", "Second paragraph.", ""], to: &draft))
        XCTAssertTrue(draft.segments.isEmpty)
        XCTAssertTrue(work.appendAvailable(["First paragraph.", "Second paragraph.", ""], to: &draft))
        XCTAssertTrue(draft.isTranslationPending)
        let prefix = draft.segments
        let starts = draft.paragraphStarts
        XCTAssertEqual(draft.translatedBlocks, 2)
        XCTAssertEqual(draft.translationProgress, 2.0 / 3.0, accuracy: 0.001)
        XCTAssertTrue(work.appendAvailable(["First paragraph.", "Second paragraph.", "Last paragraph."], to: &draft))
        XCTAssertEqual(Array(draft.segments.prefix(prefix.count)), prefix)
        XCTAssertEqual(Array(draft.paragraphStarts.prefix(starts.count)), starts)
        XCTAssertFalse(draft.isTranslationPending)
        XCTAssertEqual(draft.translationProgress, 1)
        XCTAssertEqual(draft.paragraphRanges.count, 3)
    }

    @MainActor func testPartialTranslationResumesInSameEditionAndPreservesReadingProgress() async throws {
        let (library, directory) = translationContext()
        let original = try XCTUnwrap(library.documents.first)
        let work = TranslationWork(document: original, source: "fr", target: "en")
        var draft = work.draft(original: original, language: "en")
        var output = Array(repeating: "", count: work.blocks.count)
        output[0] = "First sentence. Second sentence."
        work.appendAvailable(output, to: &draft)
        XCTAssertTrue(library.saveTranslation(draft))
        library.updatePosition(id: draft.id, position: 1)
        library.toggleBookmark(id: draft.id, position: 1)
        let reopened = LibraryStore(directory: directory)
        let originalRoute = reopened.readingRoute(for: original, phoneLanguage: "en")
        XCTAssertEqual(originalRoute.document.id, original.id)
        XCTAssertFalse(originalRoute.translate, "An unfinished translation must not capture the original's entry")
        let route = reopened.readingRoute(for: draft, phoneLanguage: "en")
        XCTAssertEqual(route.document.id, draft.id)
        XCTAssertTrue(route.translate)
        XCTAssertEqual(route.document.position, 1, "Use the current saved position, even if the selected value is stale")
        // Use the real unused Qwen renderer: translating must not initialise Metal.
        let coordinator = TranslationCoordinator(library: reopened, languageStatus: { _, _ in .installed })
        await coordinator.request(route.document, targetLanguage: "en")
        XCTAssertEqual(coordinator.readyDocumentID, draft.id)
        XCTAssertTrue(coordinator.isTranslating)
        XCTAssertNotNil(coordinator.configuration)
        coordinator.cancel()
        output[1] = "A new paragraph."
        work.appendAvailable(output, to: &draft)
        XCTAssertTrue(reopened.saveTranslation(draft))
        XCTAssertEqual(reopened.document(draft.id)?.position, 1)
        XCTAssertEqual(reopened.document(draft.id)?.bookmarks, [1])
        XCTAssertEqual(reopened.document(draft.id)?.isFinished, false)
        XCTAssertEqual(reopened.documents.filter { $0.translationOf == original.id }.count, 1)
    }

    @MainActor func testBackgroundTranslationSavePersistsAndPreservesReaderState() async throws {
        let (library, directory) = translationContext()
        let original = try XCTUnwrap(library.documents.first)
        var draft = TranslationWork(document: original, source: "fr", target: "en-US")
            .draft(original: original, language: "en-US")
        draft.segments = ["Translated passage."]
        draft.paragraphStarts = [0]
        draft.translatedBlocks = 1

        let firstSave = await library.saveTranslationWithoutBlocking(draft)
        XCTAssertTrue(firstSave)
        library.updatePosition(id: draft.id, position: 0)
        library.toggleBookmark(id: draft.id, position: 0)
        draft.segments.append("Next passage.")
        draft.translatedBlocks = 2
        let secondSave = await library.saveTranslationWithoutBlocking(draft)
        XCTAssertTrue(secondSave)

        let reopened = LibraryStore(directory: directory)
        let saved = try XCTUnwrap(reopened.document(draft.id))
        XCTAssertEqual(saved.segments, ["Translated passage.", "Next passage."])
        XCTAssertEqual(saved.bookmarks, [0])
        XCTAssertEqual(saved.languageCode, "en-US")
    }

    func testChangedTranslationPlanReusesExistingEdition() throws {
        let original = try DocumentImporter.fromText("Premier paragraphe.\n\nDeuxième paragraphe.", title: "Original")
        let work = TranslationWork(document: original, source: "fr", target: "en-US")
        var previous = work.draft(original: original, language: "en-US")
        previous.translationFingerprint = "obsolete-plan"
        previous.segments = ["Old translated text."]
        previous.translatedBlocks = 1
        previous.position = 1
        previous.bookmarks = [0]
        previous.title = "Translated title"
        previous.translationTitleComplete = true

        let restarted = work.draft(original: original, language: "en-US", replacing: previous)

        XCTAssertEqual(restarted.id, previous.id)
        XCTAssertEqual(restarted.importedAt, previous.importedAt)
        XCTAssertEqual(restarted.title, "Translated title")
        XCTAssertEqual(restarted.translationTitleComplete, true)
        XCTAssertEqual(restarted.bookmarks, [0])
        XCTAssertTrue(restarted.segments.isEmpty)
        XCTAssertEqual(restarted.translatedBlocks, 0)
        XCTAssertEqual(restarted.translationFingerprint, work.fingerprint)
    }

    @MainActor func testLibraryConsolidatesDuplicateTranslations() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryStore(directory: directory)
        let original = try XCTUnwrap(library.documents.first)
        let work = TranslationWork(document: original, source: "fr", target: "en-US")
        var older = work.draft(original: original, language: "en-US")
        older.segments = ["Older."]
        older.translatedBlocks = 1
        older.bookmarks = [0]
        var advanced = work.draft(original: original, language: "en-GB")
        advanced.segments = ["More advanced.", "Text."]
        advanced.translatedBlocks = 2
        XCTAssertTrue(library.saveTranslation(older))
        XCTAssertTrue(library.saveTranslation(advanced))
        library.rememberReading(originalID: original.id, readingID: older.id)

        let reopened = LibraryStore(directory: directory)
        let translations = reopened.documents.filter { $0.translationOf == original.id }

        XCTAssertEqual(translations.count, 1)
        XCTAssertEqual(translations.first?.id, advanced.id)
        XCTAssertEqual(translations.first?.bookmarks, [0])
        XCTAssertEqual(reopened.document(original.id)?.preferredReadingID, advanced.id)
    }

    @MainActor func testConcurrentTranslationDraftUsesExistingCanonicalEdition() async throws {
        let (library, _) = translationContext()
        let original = try XCTUnwrap(library.documents.first)
        let work = TranslationWork(document: original, source: "fr", target: "en-US")
        var first = work.draft(original: original, language: "en-US")
        first.segments = ["First result."]
        first.translatedBlocks = 1
        let firstSaved = await library.saveTranslationWithoutBlocking(first)
        XCTAssertTrue(firstSaved)

        var concurrent = work.draft(original: original, language: "en-US")
        concurrent.segments = ["Concurrent result."]
        concurrent.translatedBlocks = 1
        concurrent = library.canonicalTranslation(concurrent)

        XCTAssertEqual(concurrent.id, first.id)
        let concurrentSaved = await library.saveTranslationWithoutBlocking(concurrent)
        XCTAssertTrue(concurrentSaved)
        XCTAssertEqual(library.documents.filter { $0.translationOf == original.id }.count, 1)
    }

    func testVoiceAlwaysMatchesTranslationDespiteForeignPreference() {
        let voices = [SystemVoiceSelection.Voice(id: "fr", language: "fr-FR", quality: 3),
                      SystemVoiceSelection.Voice(id: "en", language: "en-GB", quality: 1),
                      SystemVoiceSelection.Voice(id: "es", language: "es-ES", quality: 1)]
        XCTAssertEqual(SystemVoiceSelection.identifier(for: "en", preferred: "fr", voices: voices), "en")
        XCTAssertEqual(SystemVoiceSelection.identifier(for: "es_MX", preferred: "en", voices: voices), "es")
        XCTAssertEqual(SystemVoiceSelection.identifier(for: "fr-CA", preferred: "fr", voices: voices), "fr")
        XCTAssertNil(SystemVoiceSelection.identifier(for: "de", preferred: "fr", voices: voices))
    }

    func testSystemVoiceSpeedDoesNotReachExtremeSynthesizerRates() {
        XCTAssertEqual(SystemVoiceSelection.speechRate(for: 1), AVSpeechUtteranceDefaultSpeechRate)
        let speeds = [0.75, 1, 1.25, 1.5, 1.75, 2]
        let rates = speeds.map(SystemVoiceSelection.speechRate)
        XCTAssertEqual(rates, rates.sorted())
        XCTAssertEqual(Set(rates).count, speeds.count)
        XCTAssertGreaterThan(rates.first!, AVSpeechUtteranceMinimumSpeechRate)
        // Regression: 2× previously saturated at 1.0, making speech unintelligible.
        XCTAssertLessThan(rates.last!, AVSpeechUtteranceDefaultSpeechRate + 0.2)
        XCTAssertEqual(SystemVoiceSelection.speechRate(for: .nan), AVSpeechUtteranceDefaultSpeechRate)
        XCTAssertEqual(SystemVoiceSelection.speechRate(for: 100), rates.last!)
    }

    func testTranslationKeepsContextAndParagraphBoundaries() throws {
        let source = try DocumentImporter.fromText("Elle ouvre la porte. Il fait froid.\n\nElle rentre chez elle.", title: "Contexte")
        let work = TranslationWork(document: source, source: "fr", target: "es")
        XCTAssertEqual(work.blocks.map(\.text), ["Elle ouvre la porte. Il fait froid.", "Elle rentre chez elle."])
        let translated = try work.document(from: ["Abre la puerta. Hace frío.", "Vuelve a casa."], original: source, language: "es")
        XCTAssertEqual(translated.paragraphRanges.count, 2)
        XCTAssertEqual(translated.languageCode, "es")
        XCTAssertEqual(translated.translationOf, source.id)
        XCTAssertThrowsError(try work.document(from: ["Un seul passage"], original: source, language: "es"))
        XCTAssertThrowsError(try work.document(from: ["Un passage", " "], original: source, language: "es"))
    }

    func testTranslationResumeIsIsolatedByContentAndLanguage() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try DocumentImporter.fromText("Le café est prêt.\n\nBonjour !", title: "Reprise")
        let spanish = TranslationWork(document: source, source: "fr", target: "es")
        XCTAssertEqual(spanish.fingerprint, TranslationWork(document: source, source: "fr", target: "es").fingerprint)
        let checkpoint = try TranslationCheckpoint(fingerprint: spanish.fingerprint, root: root)
        try checkpoint.save("El café está listo.", at: 0)
        let reopened = try TranslationCheckpoint(fingerprint: spanish.fingerprint, root: root)
        XCTAssertEqual(reopened.load(count: 2), ["El café está listo.", ""])
        let english = TranslationWork(document: source, source: "fr", target: "en")
        XCTAssertNotEqual(spanish.fingerprint, english.fingerprint)
        var edited = source
        edited.segments[0] = "Le thé est prêt."
        XCTAssertNotEqual(spanish.fingerprint, TranslationWork(document: edited, source: "fr", target: "es").fingerprint)
        checkpoint.remove()
        XCTAssertEqual(reopened.load(count: 2), ["", ""])
    }

    func testTranslationLongParagraphsAreBoundedWithoutLosingText() throws {
        let source = try DocumentImporter.fromText(String(repeating: "Une journée à Paris ☀️. ", count: 200), title: "Long")
        let work = TranslationWork(document: source, source: "fr", target: "en")
        XCTAssertGreaterThan(work.blocks.count, 1)
        XCTAssertTrue(work.blocks.allSatisfy { $0.text.count <= 420 })
        XCTAssertEqual(work.blocks.map(\.text).joined(separator: " "), source.segments.joined(separator: " "))
        let result = try work.document(from: work.blocks.map(\.text), original: source, language: "en")
        XCTAssertEqual(result.paragraphRanges.count, 1)
    }

    @MainActor func testQwenStylePersistsWithoutChangingExistingVoiceChoice() throws {
        let suite = "conteur-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("neural", forKey: "voice.engine")
        let settings = ReaderSettings(defaults: defaults)
        XCTAssertEqual(settings.engine, .system)
        XCTAssertEqual(defaults.string(forKey: "voice.engine"), VoiceEngine.system.rawValue)
        XCTAssertEqual(settings.qwenStyle, .warm)
        settings.engine = .qwen
        settings.qwenStyle = .dramatic
        let reopened = ReaderSettings(defaults: defaults)
        XCTAssertEqual(reopened.engine, .qwen)
        XCTAssertEqual(reopened.qwenStyle, .dramatic)
        XCTAssertEqual(Set(NarrationStyle.allCases.map(\.instruction)).count, 3)
        XCTAssertEqual(NarrationStyle.languageName(for: "fr-CA"), "French")
        XCTAssertNil(NarrationStyle.languageName(for: "nl"))
    }

    func testQwenModelRejectsCorruptionEvenWhenFileSizeIsUnchanged() throws {
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data("verified model".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let file = QwenManifest.File(path: "test.safetensors", bytes: Int64(data.count), sha256: hash)
        try data.write(to: url)
        XCTAssertNoThrow(try QwenManifest.validate(file, at: url))
        try Data(repeating: 0, count: data.count).write(to: url)
        XCTAssertThrowsError(try QwenManifest.validate(file, at: url))
        try Data([0]).write(to: url)
        XCTAssertThrowsError(try QwenManifest.validate(file, at: url))
    }

    func testQwenWindowsDoNotDropTextAcrossBoundedParagraphs() throws {
        let document = try DocumentImporter.fromText(String(repeating: "Une journée à Paris ☀️. ", count: 70) + "\n\nFin du voyage.", title: "Long passage")
        var recovered: [String] = []
        var start = 0
        while start < document.segments.count {
            let window = NarrationWindow(sentenceIn: document, at: start)
            XCTAssertEqual(window.segments.count, 1)
            XCTAssertEqual(window.endPosition, start)
            XCTAssertLessThanOrEqual(window.text.count, 360)
            recovered += window.segments.map { (window.text as NSString).substring(with: $0.range) }
            start = window.endPosition + 1
        }
        XCTAssertEqual(recovered, document.segments)
    }

    func testNarrationKeepsParagraphContextAndUnicodeOffsets() throws {
        let document = try DocumentImporter.fromText("L’été est là. Écoutez !\n\nUn autre paragraphe.", title: "Rythme")
        let window = NarrationWindow(document: document, start: 0)
        XCTAssertEqual(window.text, "L’été est là. Écoutez !")
        XCTAssertEqual(window.endPosition, 1)
        XCTAssertEqual(window.segments.count, 2)
        let ns = window.text as NSString
        for item in window.segments { XCTAssertEqual(ns.substring(with: item.range), document.segments[item.index]) }
    }
    func testEPUBUsesSpineOrderAndPreservesParagraphs() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil))
            .appending(path: "Le-jardin-des-heures.epub")
        let document = try DocumentImporter.fromFile(url)
        XCTAssertEqual(document.title, "Le jardin des heures")
        XCTAssertEqual(document.author, "Atelier Le Conteur")
        XCTAssertEqual(document.languageCode, "fr")
        let text = document.segments.joined(separator: " ")
        XCTAssertFalse(text.contains("hidden-script"))
        XCTAssertFalse(text.contains("hidden-style"))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "Chaque matin")?.lowerBound), try XCTUnwrap(text.range(of: "Prenez le temps")?.lowerBound))
        XCTAssertGreaterThan(document.paragraphRanges.count, 3)
        XCTAssertEqual(document.paragraphRanges.flatMap(Array.init), Array(document.segments.indices))
    }

    @MainActor private func coverEPUB(_ mode: String, corrupt: Bool = false) throws -> (URL, URL) {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "Cover.epub")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 1800), format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1800))
        }
        let cover = corrupt ? Data("not an image".utf8) : try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        let metadata = mode == "legacy" ? "<meta name=\"cover\" content=\"artwork\"/>" : ""
        let properties = ["manifest", "remote"].contains(mode) ? "properties=\"scripted cover-image\"" : ""
        let extra = mode == "svg" ? "<item id=\"wrapper\" href=\"pages/cover.svg\" media-type=\"image/svg+xml\" properties=\"cover-image\"/>" : ""
        let guide = mode == "guide" ? "<guide><reference type=\"cover\" href=\"pages/cover.xhtml#top\"/></guide>" : ""
        let href = mode == "remote" ? "https://example.invalid/cover.jpg" : "images/front%20cover.jpg"
        let entries: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data("<container><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>".utf8)),
            ("OPS/package.opf", Data("<package xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><metadata><dc:title>Avec couverture</dc:title><dc:creator>Auteur</dc:creator>\(metadata)</metadata><manifest><item id=\"artwork\" href=\"\(href)\" media-type=\"image/jpeg\" \(properties)/>\(extra)<item id=\"chapter\" href=\"pages/chapter.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"chapter\"/></spine>\(guide)</package>".utf8)),
            ("OPS/images/front cover.jpg", cover),
            ("OPS/pages/chapter.xhtml", Data("<html><body><p>Bonjour. Voici le premier passage.</p><p>La lecture continue.</p></body></html>".utf8)),
            ("OPS/pages/cover.xhtml", Data("<html><body><img src=\"../images/front%20cover.jpg\"/></body></html>".utf8)),
            ("OPS/pages/cover.svg", Data("<svg xmlns:xlink=\"http://www.w3.org/1999/xlink\"><image xlink:href=\"../images/front%20cover.jpg\"/></svg>".utf8))
        ]
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in entries {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        return (url, root.appending(path: "Covers"))
    }

    private func metadataEPUB(package: Data, chapter: String) throws -> URL {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "Metadata.epub")
        let entries: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data("<container><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>".utf8)),
            ("OPS/package.opf", package),
            ("OPS/chapter.xhtml", Data(chapter.utf8))
        ]
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in entries {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        return url
    }

    func testEPUBRepairsLegacyAndAlreadyLossyTitleCharacters() throws {
        let packageStart = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><package xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><metadata><dc:title>L"
        let packageEnd = "argile des morts</dc:title><dc:creator>Auteur</dc:creator><dc:language>ru</dc:language></metadata><manifest><item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"chapter\"/></spine></package>"
        var legacyPackage = Data(packageStart.utf8)
        legacyPackage.append(0x92) // Windows-1252 right single quotation mark.
        legacyPackage.append(Data(packageEnd.utf8))
        let legacy = try metadataEPUB(package: legacyPackage, chapter: "<html><body><p>Le premier passage continue.</p></body></html>")
        let legacyDocument = try DocumentImporter.fromFile(legacy)
        XCTAssertEqual(legacyDocument.title, "L’argile des morts")
        XCTAssertEqual(legacyDocument.languageCode, "ru", "EPUB metadata must override automatic language detection")

        let lossyPackage = Data((packageStart + "���" + packageEnd).utf8)
        let lossy = try metadataEPUB(package: lossyPackage, chapter: "<html><body><h1>L���argile des morts</h1><p>L’argile des morts</p><p>Le récit commence.</p></body></html>")
        XCTAssertEqual(try DocumentImporter.fromFile(lossy).title, "L’argile des morts")
    }

    func testTranslatedBookExportsAsReimportableEPUBWithLanguageAndMetadata() throws {
        var document = try DocumentImporter.fromText("Premier paragraphe.\n\nDeuxième paragraphe & suite.", title: "Roman <traduit>", source: "TRADUIT · FR", author: "Une autrice")
        document.translationOf = UUID()
        document.languageCode = "fr-FR"
        let url = try EPUBExporter.export(document)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let imported = try DocumentImporter.fromFile(url)
        XCTAssertEqual(imported.title, document.title)
        XCTAssertEqual(imported.author, document.author)
        XCTAssertEqual(imported.languageCode, "fr")
        XCTAssertEqual(imported.segments, document.segments)
    }

    func testDOCXImportsParagraphsAndCoreMetadata() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "Roman.docx")
        let body = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
          <w:p><w:r><w:t>Premier paragraphe.</w:t></w:r></w:p>
          <w:p><w:r><w:t>Deuxième paragraphe en français.</w:t></w:r></w:p>
        </w:body></w:document>
        """.utf8)
        let core = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:title>Le document Word</dc:title><dc:creator>Camille</dc:creator><dc:language>fr-FR</dc:language>
        </cp:coreProperties>
        """.utf8)
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in [("word/document.xml", body), ("docProps/core.xml", core)] {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }

        let document = try DocumentImporter.fromFile(url)
        XCTAssertEqual(document.title, "Le document Word")
        XCTAssertEqual(document.author, "Camille")
        XCTAssertEqual(document.languageCode, "fr")
        XCTAssertEqual(document.source, "DOCX")
        XCTAssertEqual(document.segments, ["Premier paragraphe.", "Deuxième paragraphe en français."])
        XCTAssertEqual(document.paragraphStarts, [0, 1])
    }

    @MainActor func testEPUBCoverMetadataAndPageReferencesPersistBoundedImages() throws {
        for mode in ["manifest", "legacy", "guide", "svg"] {
            let (url, covers) = try coverEPUB(mode)
            let document = try DocumentImporter.fromFile(url, coverDirectory: covers)
            let name = try XCTUnwrap(document.coverFileName, mode)
            let image = try XCTUnwrap(UIImage(contentsOfFile: covers.appending(path: name).path))
            XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 800)
            XCTAssertEqual(image.size.width / image.size.height, 2.0 / 3.0, accuracy: 0.01)
            let second = try DocumentImporter.fromFile(url, coverDirectory: covers)
            XCTAssertEqual(second.coverFileName, name)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: covers.path).count, 1)
            XCTAssertEqual(document.title, "Avec couverture")
            XCTAssertEqual(document.paragraphRanges.count, 2)
        }
    }

    @MainActor func testMissingCorruptAndRemoteCoverNeverBlockEPUBText() throws {
        for (mode, corrupt) in [("none", false), ("manifest", true), ("remote", false)] {
            let (url, covers) = try coverEPUB(mode, corrupt: corrupt)
            let document = try DocumentImporter.fromFile(url, coverDirectory: covers)
            XCTAssertNil(document.coverFileName)
            XCTAssertEqual(document.segments.first, "Bonjour.")
        }
    }

    @MainActor func testReimportAddsCoverToOriginalAndTranslationWithoutLosingProgress() throws {
        let (library, directory) = translationContext()
        let (url, covers) = try coverEPUB("manifest")
        let imported = try DocumentImporter.fromFile(url, coverDirectory: covers)
        var old = imported
        old.coverFileName = nil
        XCTAssertTrue(library.add(old))
        library.updatePosition(id: old.id, position: 1)
        library.toggleBookmark(id: old.id, position: 1)
        let work = TranslationWork(document: old, source: "fr", target: "en")
        let translated = try work.document(from: ["Hello. First paragraph.", "Reading continues."], original: old, language: "en")
        XCTAssertTrue(library.add(translated))
        var reimported = imported
        reimported.id = UUID()
        reimported.title = "Titre réparé"
        reimported.author = "Auteur corrigé"
        reimported.languageCode = "ru"
        let count = library.documents.count
        let refreshed = try XCTUnwrap(library.importDocument(reimported))
        XCTAssertEqual(refreshed.id, old.id)
        XCTAssertEqual(refreshed.title, "Titre réparé")
        XCTAssertEqual(refreshed.author, "Auteur corrigé")
        XCTAssertEqual(refreshed.languageCode, "ru")
        XCTAssertEqual(refreshed.position, 1)
        XCTAssertEqual(refreshed.bookmarks, [1])
        XCTAssertEqual(library.documents.count, count)
        let reopened = LibraryStore(directory: directory)
        XCTAssertEqual(reopened.document(old.id)?.coverFileName, imported.coverFileName)
        XCTAssertEqual(reopened.document(translated.id)?.coverFileName, imported.coverFileName)
        XCTAssertEqual(work.draft(original: imported, language: "es").coverFileName, imported.coverFileName)
    }

    func testTextImportRejectsEmptyAndOversizedText() {
        XCTAssertThrowsError(try DocumentImporter.fromText(" \n\n ", title: "Vide"))
        XCTAssertThrowsError(try DocumentImporter.fromText(String(repeating: "a", count: 2_000_001), title: "Trop long"))
    }

    func testUnicodeAndParagraphBoundariesSurviveSegmentation() throws {
        let document = try DocumentImporter.fromText("Écoutez les oiseaux. L’été arrive !\n\nUn café ☕️ attend François.", title: "Matin")
        XCTAssertEqual(document.paragraphRanges.count, 2)
        XCTAssertTrue(document.segments.joined(separator: " ").contains("☕️"))
        XCTAssertTrue(document.segments.joined(separator: " ").contains("François"))
        XCTAssertTrue(TextSegmenter.split(String(repeating: "é", count: 2000)).allSatisfy { $0.count <= 360 })
    }

    @MainActor func testLibraryPersistsPositionBookmarksAndEmptyState() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        let document = try DocumentImporter.fromText("Bonjour. Comment allez-vous ? Très bien.", title: "Test")
        store.add(document)
        store.updatePosition(id: document.id, position: 1)
        store.toggleBookmark(id: document.id, position: 1)
        let reopened = LibraryStore(directory: directory)
        XCTAssertEqual(reopened.document(document.id)?.position, 1)
        XCTAssertEqual(reopened.document(document.id)?.bookmarks, [1])
        for item in reopened.documents { reopened.delete(item.id) }
        XCTAssertTrue(LibraryStore(directory: directory).documents.isEmpty)
    }

    @MainActor func testCorruptLibraryIsPreserved() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data("corrupt".utf8)
        let url = directory.appending(path: "library.json")
        try data.write(to: url)
        let store = LibraryStore(directory: directory)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    @MainActor func testLegacyWelcomeBookIsRelocalizedWithoutLosingReaderState() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var legacy = ReadingDocument(
            title: "Le goût des mots",
            author: "Bienvenue dans Le Conteur",
            source: "DÉCOUVERTE",
            segments: ["Ancien premier passage.", "Ancien second passage."]
        )
        legacy.position = 1
        legacy.bookmarks = [1]
        try JSONEncoder().encode([legacy]).write(to: directory.appending(path: "library.json"))

        let localized = try XCTUnwrap(LibraryStore(directory: directory).documents.first)
        XCTAssertEqual(localized.id, legacy.id)
        XCTAssertEqual(localized.builtInID, "welcome")
        XCTAssertEqual(localized.title, ReadingDocument.welcome.title)
        XCTAssertEqual(localized.author, ReadingDocument.welcome.author)
        XCTAssertEqual(localized.segments, ReadingDocument.welcome.segments)
        XCTAssertEqual(localized.position, 1)
        XCTAssertEqual(localized.bookmarks, [1])
    }

    func testSharedFileIsCopiedBeforeProviderDisappears() throws {
        guard SharedInbox.directory != nil else { throw XCTSkip("App group unavailable on this test host") }
        let source = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).txt")
        try Data("Une lecture partagée.".utf8).write(to: source)
        try SharedInbox.stage(source)
        try FileManager.default.removeItem(at: source)
        let copy = try XCTUnwrap(SharedInbox.pendingFiles().first { $0.lastPathComponent == source.lastPathComponent })
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "Une lecture partagée.")
    }

}

@MainActor private final class RecordingSpeechSynthesizer: SpeechSynthesizing {
    weak var delegate: AVSpeechSynthesizerDelegate?
    var isPaused = false
    var utterances: [AVSpeechUtterance] = []
    var continuations = 0
    func speak(_ utterance: AVSpeechUtterance) { utterances.append(utterance); isPaused = false }
    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool { isPaused = !utterances.isEmpty; return isPaused }
    func continueSpeaking() -> Bool { continuations += 1; isPaused = false; return true }
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { isPaused = false; return true }
}

private actor RecordingQwenVoiceRenderer {
    struct Request { let text: String; let style: NarrationStyle; let speaker: QwenSpeaker; let language: String }
    private(set) var requests: [Request] = []
    func render(_ text: String, style: NarrationStyle, speaker: QwenSpeaker, language: String = "French") async throws -> QwenRenderedAudio {
        requests.append(Request(text: text, style: style, speaker: speaker, language: language))
        // Hold generation pending so changing the voice exercises cancellation
        // and replacement of the actual Qwen passage queue, without loading MLX.
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
    func waitForRequests(_ count: Int) async throws {
        for _ in 0..<100 {
            if requests.count >= count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Expected \(count) Qwen requests, received \(requests.count)")
    }
}

/// A delayed, local PCM producer exercises the real playback queue without MLX.
private actor QwenTestRenderer {
    let delays: [Double]
    let audioSeconds: [Double]
    private(set) var texts: [String] = []
    private(set) var outputFiles: [URL] = []
    init(delays: [Double], audioSeconds: [Double] = [1]) {
        self.delays = delays
        self.audioSeconds = audioSeconds
    }
    func render(_ text: String) async throws -> QwenRenderedAudio {
        let delay = delays[min(texts.count, delays.count - 1)]
        let duration = audioSeconds[min(texts.count, audioSeconds.count - 1)]
        texts.append(text)
        // Intentionally finish even if cancelled to exercise late-result cleanup.
        try? await Task.sleep(for: .seconds(delay))
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let frames = Int(duration * 24_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<frames { buffer.floatChannelData![0][frame] = sin(Float(frame) * 0.1) * 0.01 }
        let url = URL.temporaryDirectory.appending(path: "qwen-queue-test-\(UUID()).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        file.close()
        outputFiles.append(url)
        return QwenRenderedAudio(url: url, metrics: QwenRenderMetrics(
            generationSeconds: delay, audioSeconds: duration, mlxPeakBytes: 0, observedFootprintBytes: 0))
    }
}

final class LocalizationCatalogTests: XCTestCase {
    func testEverySupportedLanguageCoversActiveStringsAndPreservesFormatSpecifiers() throws {
        for language in ["ar", "de", "en", "es", "it", "ja", "ko", "pt", "ru", "zh-Hans"] {
            try assertCompleteLocalization(language)
        }
    }

    func testAppDisplayNameIsLocalizedForEverySupportedLanguage() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repository.appending(path: "Shared/InfoPlist.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let displayName = try XCTUnwrap(strings["CFBundleDisplayName"] as? [String: Any])
        let localizations = try XCTUnwrap(displayName["localizations"] as? [String: Any])

        for language in ["ar", "de", "en", "es", "it", "ja", "ko", "pt", "ru", "zh-Hans"] {
            let localization = try XCTUnwrap(localizations[language] as? [String: Any], language)
            let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any], language)
            let value = try XCTUnwrap(unit["value"] as? String, language)
            XCTAssertFalse(value.isEmpty, "Missing localized app name for \(language)")
            XCTAssertNotEqual(value, "Le Conteur", "App name still uses French in \(language)")
        }
    }

    private func assertCompleteLocalization(_ language: String) throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repository.appending(path: "Shared/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

        for (source, rawEntry) in strings where !source.isEmpty {
            let entry = try XCTUnwrap(rawEntry as? [String: Any], source)
            guard entry["extractionState"] as? String != "stale" else { continue }
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], source)
            let localization = try XCTUnwrap(localizations[language] as? [String: Any], source)
            let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any], source)
            let translation = try XCTUnwrap(unit["value"] as? String, source)
            XCTAssertFalse(translation.isEmpty, "Missing \(language) translation for: \(source)")
            XCTAssertEqual(formatSpecifiers(in: translation), formatSpecifiers(in: source),
                           "Format specifiers changed in \(language) for: \(source)")
        }
    }

    private func formatSpecifiers(in value: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"%(?:[0-9]+\$)?(?:@|lld|ld|d|f|s|%)"#)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            Range(match.range, in: value).map { String(value[$0]) }
        }.sorted()
    }
}
