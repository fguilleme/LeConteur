import Foundation
import NaturalLanguage

/// Estimated word starts in source-audio seconds. Silence does not consume text
/// progress. This is lightweight signal analysis, not speech recognition/alignment.
struct QwenWordTimeline: Sendable {
    struct Word: Sendable, Equatable {
        let range: NSRange
        let start: Double
    }
    let words: [Word]

    init(words: [Word]) { self.words = words }

    init(text: String, samples: [Float], sampleRate: Int) {
        guard sampleRate > 0, !samples.isEmpty else { words = []; return }
        let duration = Double(samples.count) / Double(sampleRate)
        let frameLength = max(1, sampleRate / 100)
        var energy: [Double] = []
        energy.reserveCapacity((samples.count + frameLength - 1) / frameLength)
        for start in stride(from: 0, to: samples.count, by: frameLength) {
            let end = min(samples.count, start + frameLength)
            var sum = 0.0
            for sample in samples[start..<end] {
                guard sample.isFinite else { self = Self.uniform(text: text, duration: duration); return }
                sum += Double(sample) * Double(sample)
            }
            energy.append(sqrt(sum / Double(end - start)))
        }
        guard let peak = energy.max(), peak > 0 else {
            self = Self.uniform(text: text, duration: duration); return
        }
        // Relative threshold also handles quiet voices. Short padding keeps soft
        // consonants and breaths attached to speech; bridge gaps below 160 ms.
        let threshold = min(0.0031623, peak * 0.02)
        let frameSeconds = Double(frameLength) / Double(sampleRate)
        var spans: [Range<Double>] = []
        for index in energy.indices where energy[index] >= threshold {
            let start = max(0, Double(index) * frameSeconds - 0.04)
            let end = min(duration, Double(index + 1) * frameSeconds + 0.04)
            if let previous = spans.last, start - previous.upperBound < 0.08 {
                spans[spans.count - 1] = previous.lowerBound..<end
            } else { spans.append(start..<end) }
        }
        self = Self.distribute(text: text, spans: spans)
    }

    static func uniform(text: String, duration: Double) -> Self {
        guard duration.isFinite, duration > 0 else { return Self(words: []) }
        return distribute(text: text, spans: [0..<duration])
    }

    func range(at seconds: Double) -> NSRange? {
        guard seconds.isFinite, let first = words.first else { return nil }
        // Hold the first word through leading padding, and the last word through
        // trailing padding. Playback pauses supply the same source-audio time.
        var lower = 0, upper = words.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if words[middle].start <= seconds { lower = middle + 1 }
            else { upper = middle }
        }
        return lower == 0 ? first.range : words[lower - 1].range
    }

    func shifted(seconds: Double, utf16: Int) -> [Word] {
        words.map { Word(range: NSRange(location: $0.range.location + utf16, length: $0.range.length),
                         start: $0.start + seconds) }
    }

    private static func distribute(text: String, spans: [Range<Double>]) -> Self {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var tokens: [(range: NSRange, weight: Double)] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            tokens.append((NSRange(range, in: text), Double(max(1, text[range].count))))
            return true
        }
        let totalWeight = tokens.reduce(0.0) { $0 + $1.weight }
        let speechSeconds = spans.reduce(0.0) { $0 + $1.upperBound - $1.lowerBound }
        guard totalWeight > 0, speechSeconds > 0 else { return Self(words: []) }
        var weight = 0.0, elapsed = 0.0, spanIndex = 0
        var words: [Word] = []
        for token in tokens {
            let target = speechSeconds * weight / totalWeight
            while spanIndex + 1 < spans.count,
                  elapsed + spans[spanIndex].upperBound - spans[spanIndex].lowerBound <= target + 1e-9 {
                elapsed += spans[spanIndex].upperBound - spans[spanIndex].lowerBound
                spanIndex += 1
            }
            words.append(Word(range: token.range, start: spans[spanIndex].lowerBound + max(0, target - elapsed)))
            weight += token.weight
        }
        return Self(words: words)
    }
}
