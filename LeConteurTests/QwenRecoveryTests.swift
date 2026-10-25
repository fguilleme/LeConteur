import XCTest
import AVFoundation
@testable import LeConteur

final class QwenRecoveryTests: XCTestCase {
    func testLimitRecoveryPreservesTextAndEveryAudioFrame() async throws {
        let text = "Élodie observe l’océan 👩🏽‍🔬.\nPuis elle reprend son récit, doucement."
        let renderer = RecoveryRenderer([.limit, .audio(3_901, 0.1), .audio(5_813, 0.2)])
        let result = try await QwenRenderRecovery.render(text) { try await renderer.render($0) }
        defer { try? FileManager.default.removeItem(at: result.url) }
        let requests = await renderer.texts
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.dropFirst().joined(), text, "Recovery must not add, omit or reorder any text")
        XCTAssertEqual(requests[1].trimmingCharacters(in: .whitespacesAndNewlines), "Élodie observe l’océan 👩🏽‍🔬.", "Prefer complete sentences")
        let file = try AVAudioFile(forReading: result.url)
        XCTAssertEqual(file.length, 9_714)
        XCTAssertEqual(result.metrics.audioSeconds, 9_714.0 / 24_000, accuracy: 0.00001)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        XCTAssertEqual(buffer.frameLength, 9_714)
        let samples = buffer.floatChannelData![0]
        XCTAssertEqual(samples[0], 0.1)
        XCTAssertEqual(samples[3_900], 0.1)
        XCTAssertEqual(samples[3_901], 0.2)
        XCTAssertEqual(samples[9_713], 0.2)
        let timeline = try XCTUnwrap(result.wordTimeline)
        let secondStart = requests[1].utf16.count
        let firstWordOfSecondPiece = try XCTUnwrap(timeline.words.first { $0.range.location >= secondStart })
        XCTAssertEqual(firstWordOfSecondPiece.start, 3_901.0 / 24_000, accuracy: 0.00001)
        XCTAssertEqual((text as NSString).substring(with: firstWordOfSecondPiece.range), "Puis")
        let files = await renderer.files
        XCTAssertTrue(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testRecoverySplitPreservesUnicodeAndDoesNotSplitWords() throws {
        for text in ["Une phrase unique assez longue pour garder tous les mots 👨‍👩‍👧‍👦 et les accents e\u{301}.",
                     "Une phrase unique suivie d’espaces. \n ",
                     "Première phrase.\n\nUne deuxième phrase qui contient davantage de mots."] {
            let pieces = try XCTUnwrap(QwenRenderRecovery.split(text))
            XCTAssertEqual(pieces.count, 2)
            XCTAssertEqual(pieces.joined(), text)
            XCTAssertTrue(pieces[0].last?.isWhitespace == true || pieces[1].first?.isWhitespace == true)
        }
        XCTAssertNil(QwenRenderRecovery.split("anticonstitutionnellement"))
        XCTAssertNil(QwenRenderRecovery.split("  seul  "))
        XCTAssertNil(QwenRenderRecovery.split(""))
    }

    func testRecoveryDoesNotRetryOtherErrorsOrRecurseAfterASecondLimit() async throws {
        for outcome in [RecoveryRenderer.Outcome.missing, .limit] {
            let renderer = RecoveryRenderer([outcome, .limit, .limit])
            do {
                _ = try await QwenRenderRecovery.render("Le début du récit. La suite du récit.") { try await renderer.render($0) }
                XCTFail("The render must fail")
            } catch {
                switch outcome {
                case .missing: guard case QwenError.missing = error else { return XCTFail("Wrong error: \(error)") }
                case .limit: guard case QwenError.generationLimitReached = error else { return XCTFail("Wrong error: \(error)") }
                default: XCTFail("Unexpected fixture")
                }
            }
            let texts = await renderer.texts
            XCTAssertEqual(texts.count, outcome == .missing ? 1 : 2)
        }
    }

    func testRecoveryDiscardsFirstPieceIfSecondPieceFails() async throws {
        let renderer = RecoveryRenderer([.limit, .audio(4_800, 0.1), .limit])
        do {
            _ = try await QwenRenderRecovery.render("La première phrase. Puis la deuxième phrase.") { try await renderer.render($0) }
            XCTFail("An incomplete passage must never enter the playback queue")
        } catch QwenError.generationLimitReached { }
        let files = await renderer.files
        XCTAssertEqual(files.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[0].path))
    }

    func testCancellationDiscardsRecoveredAndLateAudio() async throws {
        let renderer = RecoveryRenderer([.limit, .audio(4_800, 0.1), .audio(4_800, 0.2)], delays: [0, 0, 0.3])
        let task = Task {
            try await QwenRenderRecovery.render("Une phrase complète. Une autre phrase complète.") { try await renderer.render($0) }
        }
        let deadline = Date().addingTimeInterval(3)
        while await renderer.texts.count < 3 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let requests = await renderer.texts
        XCTAssertEqual(requests.count, 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must win over late audio") }
        catch is CancellationError { }
        let files = await renderer.files
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @MainActor func testRecoveredPassagePlaysAndKeepsOriginalReaderWindow() async throws {
        let document = try DocumentImporter.fromText("Une phrase complète avec de nombreux mots à prononcer sans perdre la suite du récit.\n\nLe dernier passage.", title: "Reprise")
        let renderer = RecoveryRenderer([.limit, .audio(6_000, 0.1), .audio(6_000, 0.2), .audio(6_000, 0.3)])
        let player = try QwenPassagePlayer(document: document, start: 0, rate: 1, volume: 0,
                                           buffering: .init(preset: .seconds10)) { try await renderer.render($0) }
        defer { player.stop() }
        var windows: [String] = []
        var finished = false
        player.onPassageChanged = { windows.append($0.text) }
        player.onFinished = { finished = true }
        player.onError = { XCTFail("Unexpected error: \($0)") }
        player.play()
        try await wait { finished }
        XCTAssertTrue(finished)
        XCTAssertEqual(player.completedPassages, 2)
        XCTAssertEqual(windows, document.segments)
        XCTAssertNil(player.failedPosition)
    }

    @MainActor func testFailureKeepsPausedReserveAndReportsOnlyAfterItPlays() async throws {
        let document = try DocumentImporter.fromText("Le premier passage.\n\nLa suite difficile. Encore une phrase.", title: "Réserve conservée")
        let renderer = RecoveryRenderer([.audio(12_000, 0.1), .limit, .limit], delays: [0, 0.2, 0])
        let player = try QwenPassagePlayer(document: document, start: 0, rate: 1, volume: 0,
                                           buffering: .init(preset: .seconds10)) { try await renderer.render($0) }
        defer { player.stop() }
        var errors = 0
        var reserve: QwenReserveProgress?
        player.onError = { _ in errors += 1 }
        player.onFinished = { XCTFail("A failure must not finish the book") }
        player.onReserveChanged = { reserve = $0 }
        player.play()
        try await wait { player.bufferedPassages == 1 }
        player.pause()
        try await wait { player.failedPosition != nil }
        XCTAssertEqual(player.failedPosition, 1)
        XCTAssertEqual(errors, 0)
        XCTAssertFalse(player.isAudible)
        XCTAssertEqual(player.completedPassages, 0)
        XCTAssertEqual(reserve?.isComplete, false)
        XCTAssertEqual(reserve?.hasGenerationError, true)
        player.play()
        XCTAssertTrue(player.isAudible, "Valid audio below the target must be released after a generation failure")
        XCTAssertEqual(errors, 0)
        try await wait { errors > 0 }
        XCTAssertEqual(errors, 1)
        XCTAssertEqual(player.completedPassages, 1)
    }

    @MainActor func testControllerRetryStartsAtFailedTextWithoutSwitchingToApple() async throws {
        let root = URL.temporaryDirectory.appending(path: "qwen-recovery-library-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(directory: root)
        let suite = "qwen-recovery-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderSettings(defaults: defaults)
        settings.engine = .qwen
        settings.qwenSpeed = 1
        let speech = RecoverySpeechSynthesizer()
        let renderer = RecoveryRenderer([.audio(6_000, 0.1), .limit, .limit, .audio(6_000, 0.2)])
        let playback = PlaybackController(library: library, settings: settings, speech: speech,
                                          renderQwen: { text, _, _, _, _ in try await renderer.render(text) })
        defer { playback.stop() }
        var document = try DocumentImporter.fromText("Le passage déjà lu.\n\nLa suite difficile. Une dernière phrase.", title: "Position de reprise")
        document.languageCode = "fr"
        library.add(document)
        playback.open(document, autoplay: true)
        try await wait { playback.errorMessage != nil }
        XCTAssertNotNil(playback.errorMessage)
        XCTAssertEqual(playback.position, 1)
        XCTAssertEqual(library.document(document.id)?.position, 1)
        XCTAssertEqual(library.document(document.id)?.isFinished, false)
        playback.handleRemoteCommand(.play)
        try await wait { library.document(document.id)?.isFinished == true }
        let texts = await renderer.texts
        XCTAssertEqual(texts.count, 4)
        XCTAssertEqual(texts.last, document.segments.suffix(2).joined(separator: " "),
                       "Retry the same coherent window without dropping its last sentence")
        XCTAssertEqual(library.document(document.id)?.isFinished, true)
        XCTAssertEqual(playback.effectiveEngine, .qwen)
        XCTAssertEqual(speech.calls, 0)
    }

    @MainActor private func wait(until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }
}

private actor RecoveryRenderer {
    enum Outcome: Equatable { case limit, missing, audio(Int, Float) }
    let outcomes: [Outcome]
    let delays: [Double]
    private(set) var texts: [String] = []
    private(set) var files: [URL] = []
    init(_ outcomes: [Outcome], delays: [Double] = [0]) { self.outcomes = outcomes; self.delays = delays }
    func render(_ text: String) async throws -> QwenRenderedAudio {
        let index = texts.count
        texts.append(text)
        // Simulate a non-cooperative generator to check cleanup of late results.
        try? await Task.sleep(for: .seconds(delays[min(index, delays.count - 1)]))
        switch outcomes[min(index, outcomes.count - 1)] {
        case .limit: throw QwenError.generationLimitReached
        case .missing: throw QwenError.missing
        case .audio(let frames, let value):
            let url = URL.temporaryDirectory.appending(path: "qwen-recovery-test-\(UUID()).wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = buffer.frameCapacity
            for index in 0..<frames { buffer.floatChannelData![0][index] = value }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            file.close()
            files.append(url)
            return QwenRenderedAudio(url: url, metrics: .init(generationSeconds: 0.01,
                audioSeconds: Double(frames) / 24_000, mlxPeakBytes: 0, observedFootprintBytes: 0))
        }
    }
}

@MainActor private final class RecoverySpeechSynthesizer: SpeechSynthesizing {
    weak var delegate: AVSpeechSynthesizerDelegate?
    var isPaused = false
    var calls = 0
    func speak(_ utterance: AVSpeechUtterance) { calls += 1 }
    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool { isPaused = true; return true }
    func continueSpeaking() -> Bool { isPaused = false; return true }
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { isPaused = false; return true }
}
