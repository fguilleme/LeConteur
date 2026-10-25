import XCTest
@testable import LeConteur

final class QwenSilenceCompactorTests: XCTestCase {
    func testMultiSecondGapsAreShortenedWithoutChangingSpeechSamples() {
        let rate = 24_000
        let speech = (0..<4_800).map { Float(0.1) + Float($0 % 100) / 1000 }
        let longGap = [Float](repeating: 0.0002, count: Int(4.7 * Double(rate)))
        let source = speech + longGap + speech + longGap + speech
        let result = QwenSilenceCompactor.compact(source, sampleRate: rate, style: .warm)
        XCTAssertEqual(result.shortenedPauses, 2)
        XCTAssertEqual(result.removedSeconds, 8.1, accuracy: 0.001)
        XCTAssertEqual(result.samples.filter { abs($0) >= 0.001 }, speech + speech + speech,
                       "Keep every speech sample in order; only the middle of long quiet runs may change")
        XCTAssertEqual(result.samples.count, 3 * speech.count + 2 * Int(0.65 * Double(rate)))
    }

    func testOrdinaryPausesAndBreathsStayUnchanged() {
        let rate = 24_000
        var source: [Float] = [0.2]
        for seconds in [0.1, 0.3, 0.65, 0.9, 1.2] {
            source += [Float](repeating: 0.0001, count: Int(seconds * Double(rate))) + [0.2]
        }
        let result = QwenSilenceCompactor.compact(source, sampleRate: rate, style: .natural)
        XCTAssertEqual(result.samples, source)
        XCTAssertEqual(result.shortenedPauses, 0)
    }

    func testQuietVoiceIsNotClassifiedAsSilence() {
        let source: [Float] = [0.0007] + [Float](repeating: 0.0003, count: 100_000) + [0.0007]
        let result = QwenSilenceCompactor.compact(source, sampleRate: 24_000, style: .warm)
        XCTAssertEqual(result.samples, source)
        XCTAssertEqual(result.shortenedPauses, 0)
    }

    func testDramaticStyleKeepsLongerIntentionalPauses() {
        let source: [Float] = [0.2] + [Float](repeating: 0, count: 36_000) + [0.2]
        XCTAssertEqual(QwenSilenceCompactor.compact(source, sampleRate: 24_000, style: .dramatic).samples, source)
        XCTAssertEqual(QwenSilenceCompactor.compact(source, sampleRate: 24_000, style: .warm).shortenedPauses, 1)
        let longer: [Float] = [0.2] + [Float](repeating: 0, count: 72_000) + [0.2]
        let result = QwenSilenceCompactor.compact(longer, sampleRate: 24_000, style: .dramatic)
        XCTAssertEqual(result.samples.count, 21_602)
    }

    func testLongLeadingAndTrailingSilencesKeepShortPaddingWhileOrdinaryGapsRemain() {
        var source = [Float](repeating: 0, count: 72_000)
        for _ in 0..<5 { source += [0.2] + [Float](repeating: 0, count: 12_000) }
        source += [Float](repeating: 0, count: 72_000)
        let result = QwenSilenceCompactor.compact(source, sampleRate: 24_000, style: .warm)
        XCTAssertEqual(result.shortenedPauses, 2)
        XCTAssertEqual(result.removedSeconds, 6, accuracy: 0.001)
        XCTAssertEqual(result.samples.filter { $0 == 0.2 }.count, 5)
        XCTAssertEqual(result.samples.count, 60_005)
        let shortPadding = [Float](repeating: 0, count: 12_000) + [Float(0.2)] + [Float](repeating: 0, count: 12_000)
        XCTAssertEqual(QwenSilenceCompactor.compact(shortPadding, sampleRate: 24_000, style: .warm).samples, shortPadding)
        let silence = [Float](repeating: 0, count: 72_000)
        XCTAssertEqual(QwenSilenceCompactor.compact(silence, sampleRate: 24_000, style: .warm).samples, silence)
    }
}
