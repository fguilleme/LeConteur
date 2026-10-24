import XCTest
import AVFoundation
import CryptoKit
import Translation
import UIKit
import ZIPFoundation
@testable import LeConteur

final class LeConteurTests: XCTestCase {
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
        XCTAssertFalse(work.appendAvailable(["", "Second paragraph.", ""], to: &draft))
        XCTAssertTrue(draft.segments.isEmpty)
        XCTAssertTrue(work.appendAvailable(["First paragraph.", "Second paragraph.", ""], to: &draft))
        XCTAssertTrue(draft.isTranslationPending)
        let prefix = draft.segments
        let starts = draft.paragraphStarts
        XCTAssertEqual(draft.translatedBlocks, 2)
        XCTAssertTrue(work.appendAvailable(["First paragraph.", "Second paragraph.", "Last paragraph."], to: &draft))
        XCTAssertEqual(Array(draft.segments.prefix(prefix.count)), prefix)
        XCTAssertEqual(Array(draft.paragraphStarts.prefix(starts.count)), starts)
        XCTAssertFalse(draft.isTranslationPending)
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
        XCTAssertTrue(work.blocks.allSatisfy { $0.text.count <= 900 })
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
        XCTAssertEqual(settings.engine, .neural)
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
            let window = NarrationWindow(document: document, start: start, characterLimit: 360)
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
        let count = library.documents.count
        let refreshed = try XCTUnwrap(library.importDocument(reimported))
        XCTAssertEqual(refreshed.id, old.id)
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

    func testNeuralVoiceProducesRealFrenchAudio() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil)).appending(path: "VoiceModel.onnx")
        guard FileManager.default.fileExists(atPath: fixture.path) else { throw XCTSkip("Optional voice model fixture not downloaded") }
        try NeuralModel.validate(fixture)
        let renderer = NeuralVoiceRenderer(modelURL: fixture)
        let output = try await renderer.render("Bonjour, ceci est une lecture entièrement locale.", speed: 1)
        defer { try? FileManager.default.removeItem(at: output) }
        let audio = try AVAudioFile(forReading: output)
        XCTAssertGreaterThan(audio.length, 22_050)
        XCTAssertEqual(audio.fileFormat.sampleRate, 22_050)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)))
        try audio.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        XCTAssertGreaterThan(samples.reduce(Float(0)) { max($0, abs($1)) }, 0.01)
    }
}

/// A delayed, local PCM producer exercises the real playback queue without MLX.
private actor QwenTestRenderer {
    let delays: [Double]
    private(set) var texts: [String] = []
    private(set) var outputFiles: [URL] = []
    init(delays: [Double]) { self.delays = delays }
    func render(_ text: String) async throws -> QwenRenderedAudio {
        let delay = delays[min(texts.count, delays.count - 1)]
        texts.append(text)
        // Intentionally finish even if cancelled to exercise late-result cleanup.
        try? await Task.sleep(for: .seconds(delay))
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000)!
        buffer.frameLength = 24_000
        for frame in 0..<24_000 { buffer.floatChannelData![0][frame] = sin(Float(frame) * 0.1) * 0.01 }
        let url = URL.temporaryDirectory.appending(path: "qwen-queue-test-\(UUID()).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        file.close()
        outputFiles.append(url)
        return QwenRenderedAudio(url: url, metrics: QwenRenderMetrics(
            generationSeconds: delay, audioSeconds: 1, mlxPeakBytes: 0, observedFootprintBytes: 0))
    }
}
