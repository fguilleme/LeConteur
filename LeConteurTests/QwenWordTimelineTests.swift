import XCTest
import AVFoundation
@testable import LeConteur

final class QwenWordTimelineTests: XCTestCase {
    func testTrailingSilenceDoesNotLeaveTheHighlightTenWordsBehind() throws {
        let text = Array(repeating: "mot", count: 20).joined(separator: " ")
        let timeline = QwenWordTimeline(text: text, samples: tone(6) + silence(6), sampleRate: 1_000)
        let last = try XCTUnwrap(timeline.words.last)
        XCTAssertEqual(timeline.words.count, 20)
        XCTAssertEqual(timeline.range(at: 6), last.range, "All words are finished before the six-second silent tail")
        XCTAssertEqual(timeline.range(at: 11), last.range)
        let legacyOffset = Int(6.0 / 12.0 * Double(text.utf16.count))
        XCTAssertLessThan(legacyOffset, last.range.location - 32, "The old whole-file interpolation was about ten words late")
    }

    func testHighlightHoldsAcrossAnInternalPauseAndWaitsThroughLeadingSilence() throws {
        let samples = silence(2) + tone(1) + silence(4) + tone(1) + silence(2)
        let timeline = QwenWordTimeline(text: "mot mot mot mot", samples: samples, sampleRate: 1_000)
        XCTAssertEqual(timeline.words.count, 4)
        XCTAssertGreaterThan(try XCTUnwrap(timeline.words.first).start, 1.9)
        XCTAssertEqual(timeline.range(at: 3.5), timeline.words[1].range)
        XCTAssertEqual(timeline.range(at: 6.5), timeline.words[1].range, "The cursor must not travel through text during a four-second silence")
        XCTAssertEqual(timeline.range(at: 7.1), timeline.words[2].range)
        XCTAssertEqual(timeline.range(at: 8), timeline.words[3].range)
    }

    func testQuietSpeechKeepsTheSameTimingAndShortGapsAreBridged() {
        let samples = tone(1) + silence(0.1) + tone(1)
        let quiet = samples.map { $0 * 0.001 }
        let normalTimeline = QwenWordTimeline(text: "Une voix douce", samples: samples, sampleRate: 1_000)
        let quietTimeline = QwenWordTimeline(text: "Une voix douce", samples: quiet, sampleRate: 1_000)
        XCTAssertEqual(normalTimeline.words, quietTimeline.words)
        XCTAssertEqual(normalTimeline.words, QwenWordTimeline.uniform(text: "Une voix douce", duration: 2.1).words)
    }

    func testUnicodeOffsetsAndRecoveredPieceOffsetsStayInUTF16() throws {
        let prefix = "Élodie 👩🏽‍🔬 dit : "
        let text = "l’océan est bleu."
        let timeline = QwenWordTimeline.uniform(text: text, duration: 3)
        let shifted = timeline.shifted(seconds: 4.5, utf16: prefix.utf16.count)
        for (original, joined) in zip(timeline.words, shifted) {
            XCTAssertEqual(((prefix + text) as NSString).substring(with: joined.range), (text as NSString).substring(with: original.range))
            XCTAssertEqual(joined.start, original.start + 4.5, accuracy: 0.00001)
        }
        let last = try XCTUnwrap(shifted.last)
        XCTAssertEqual(((prefix + text) as NSString).substring(with: last.range), "bleu")
    }

    func testSilentOrInvalidSignalUsesBoundedFallback() {
        let uniform = QwenWordTimeline.uniform(text: "Une voix", duration: 1)
        XCTAssertEqual(QwenWordTimeline(text: "Une voix", samples: silence(1), sampleRate: 1_000).words, uniform.words)
        var invalid = silence(1); invalid[10] = .nan
        XCTAssertEqual(QwenWordTimeline(text: "Une voix", samples: invalid, sampleRate: 1_000).words, uniform.words)
        XCTAssertNil(uniform.range(at: .nan))
        XCTAssertTrue(QwenWordTimeline(text: "", samples: tone(1), sampleRate: 1_000).words.isEmpty)
        XCTAssertTrue(QwenWordTimeline.uniform(text: "Une voix", duration: .infinity).words.isEmpty)
    }

    func testHighlightRetainsOriginalDecomposedAccentOffsets() throws {
        let text = "L’e\u{301}te\u{301} est la\u{300}."
        let timeline = QwenWordTimeline.uniform(text: text, duration: 3)
        let last = try XCTUnwrap(timeline.words.last)
        XCTAssertEqual(last.range, NSRange(location: 12, length: 3))
        XCTAssertEqual((text as NSString).substring(with: last.range), "la\u{300}")
        XCTAssertNotEqual(text.utf16.count, text.precomposedStringWithCanonicalMapping.utf16.count,
            "Normalizing model input must not change the original reader's offsets")
    }

    @MainActor func testPassagePlayerUsesSpeechTimelineAtChangedSpeedAndKeepsItOnPause() async throws {
        let text = Array(repeating: "mot", count: 20).joined(separator: " ")
        let document = try DocumentImporter.fromText(text, title: "Surlignage")
        let expected = (text as NSString).range(of: "mot", options: .backwards)
        let player = try QwenPassagePlayer(document: document, start: 0, rate: 1.25, volume: 0) { text in
            let samples = Array(repeating: Float(0.1), count: 14_400) + Array(repeating: Float(0), count: 57_600)
            let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            pcm.frameLength = pcm.frameCapacity
            samples.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            let url = URL.temporaryDirectory.appending(path: "word-timeline-\(UUID()).wav")
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: pcm); file.close()
            return QwenRenderedAudio(url: url, metrics: .init(generationSeconds: 0.01, audioSeconds: 3,
                mlxPeakBytes: 0, observedFootprintBytes: 0),
                wordTimeline: QwenWordTimeline(text: text, samples: samples, sampleRate: 24_000))
        }
        defer { player.stop() }
        var current: NSRange?
        player.onWord = { current = $0 }
        player.onError = { XCTFail("Unexpected error: \($0)") }
        player.play()
        let deadline = Date().addingTimeInterval(4)
        while player.playedSeconds < 0.8, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(current, expected, "The highlight must reach the last word while its silent tail is still playing")
        XCTAssertEqual(player.completedPassages, 0)
        player.pause()
        let position = player.playedSeconds
        player.rate = 2
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(player.playedSeconds, position, accuracy: 0.01)
        XCTAssertEqual(current, expected)
        player.play()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertGreaterThan(player.playedSeconds, position + 0.2)
        XCTAssertEqual(current, expected, "A speed change must not reinterpret source-audio timestamps")
    }

    private func tone(_ seconds: Double) -> [Float] { Array(repeating: 0.1, count: Int(seconds * 1_000)) }
    private func silence(_ seconds: Double) -> [Float] { Array(repeating: 0, count: Int(seconds * 1_000)) }
}
