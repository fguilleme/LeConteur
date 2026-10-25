import AVFoundation
import NaturalLanguage

/// Retry only unfinished synthesis, once as two shorter phrases. Commit nothing
/// until both are complete: the original reader window and its offsets stay intact.
enum QwenRenderRecovery {
    static func render(_ text: String, using renderer: @Sendable (String) async throws -> QwenRenderedAudio) async throws -> QwenRenderedAudio {
        let started = Date()
        do {
            let result = try await renderer(text)
            do { try Task.checkCancellation() }
            catch { try? FileManager.default.removeItem(at: result.url); throw error }
            return result
        } catch QwenError.generationLimitReached {
            try Task.checkCancellation()
            guard let pieces = split(text) else { throw QwenError.generationLimitReached }
            var rendered: [QwenRenderedAudio] = []
            defer { for part in rendered { try? FileManager.default.removeItem(at: part.url) } }
            // No recursive retries: at most three model calls for a passage.
            for piece in pieces {
                try Task.checkCancellation()
                rendered.append(try await renderer(piece))
                try Task.checkCancellation()
            }
            return try join(rendered, texts: pieces, elapsed: Date().timeIntervalSince(started))
        }
    }

    static func split(_ text: String) -> [String]? {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var boundaries: [String.Index] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if range.upperBound < text.endIndex { boundaries.append(range.upperBound) }
            return true
        }
        func hasTextOnBothSides(_ index: String.Index) -> Bool {
            !text[..<index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !text[index...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        boundaries = boundaries.filter(hasTextOnBothSides)
        // Prefer a sentence boundary. A single long sentence can be divided at
        // whitespace, never inside a word or a composed Unicode character.
        if boundaries.isEmpty {
            boundaries = text.indices.filter { text[$0].isWhitespace && hasTextOnBothSides($0) }
        }
        let midpoint = text.count / 2
        let boundary = boundaries.min { abs(text.distance(from: text.startIndex, to: $0) - midpoint) <
            abs(text.distance(from: text.startIndex, to: $1) - midpoint) }
        guard let boundary else { return nil }
        // Preserve punctuation, whitespace and order exactly. Nothing is spoken
        // as a preamble or removed afterwards using guessed audio durations.
        return [String(text[..<boundary]), String(text[boundary...])]
    }

    private static func join(_ parts: [QwenRenderedAudio], texts: [String], elapsed: Double) throws -> QwenRenderedAudio {
        let url = URL.temporaryDirectory.appending(path: "conteur-qwen-recovered-\(UUID().uuidString).wav")
        do {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192) else { throw QwenError.emptyAudio }
            let output = try AVAudioFile(forWriting: url, settings: format.settings)
            defer { output.close() }
            var frames: AVAudioFramePosition = 0
            var utf16Offset = 0
            var words: [QwenWordTimeline.Word] = []
            for (part, text) in zip(parts, texts) {
                let input = try AVAudioFile(forReading: part.url)
                guard input.processingFormat == format, input.length > 0 else { throw QwenError.emptyAudio }
                // Keep the playback queue's 120-second per-passage safety limit.
                guard frames + input.length <= 120 * 24_000 else { throw QwenError.generationLimitReached }
                let timeline = part.wordTimeline ?? .uniform(text: text, duration: Double(input.length) / 24_000)
                words.append(contentsOf: timeline.shifted(seconds: Double(frames) / 24_000, utf16: utf16Offset))
                utf16Offset += text.utf16.count
                while input.framePosition < input.length {
                    try Task.checkCancellation()
                    try input.read(into: buffer, frameCount: AVAudioFrameCount(min(8_192, input.length - input.framePosition)))
                    guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0],
                          UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)).allSatisfy(\.isFinite) else {
                        throw QwenError.emptyAudio
                    }
                    try output.write(from: buffer)
                    frames += AVAudioFramePosition(buffer.frameLength)
                }
            }
            output.close()
            try Task.checkCancellation()
            return QwenRenderedAudio(url: url, metrics: QwenRenderMetrics(
                generationSeconds: max(elapsed, parts.reduce(0) { $0 + $1.metrics.generationSeconds }),
                audioSeconds: Double(frames) / 24_000,
                mlxPeakBytes: parts.map(\.metrics.mlxPeakBytes).max() ?? 0,
                observedFootprintBytes: parts.map(\.metrics.observedFootprintBytes).max() ?? 0,
                modelLoads: parts.reduce(0) { $0 + $1.metrics.modelLoads }),
                wordTimeline: QwenWordTimeline(words: words))
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
