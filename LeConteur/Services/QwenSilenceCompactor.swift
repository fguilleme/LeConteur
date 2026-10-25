import Foundation

/// Qwen can generate several seconds of near-silence between words. Shorten
/// only those quiet interiors; leave speech, breaths and ordinary pauses intact.
enum QwenSilenceCompactor {
    struct Result {
        let samples: [Float]
        let removedSeconds: Double
        let shortenedPauses: Int
    }

    static func compact(_ samples: [Float], sampleRate: Int, style: NarrationStyle) -> Result {
        let unchanged = Result(samples: samples, removedSeconds: 0, shortenedPauses: 0)
        guard sampleRate > 0, !samples.isEmpty, samples.allSatisfy(\.isFinite) else { return unchanged }
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        // At most -50 dBFS, also 40 dB below the recording's peak so a quiet
        // voice isn't mistaken for silence. Every sample in the run must qualify.
        let threshold = min(Float(0.0031623), peak * 0.01)
        guard threshold > 0 else { return unchanged }
        let longestPause = Int(Double(sampleRate) * (style == .dramatic ? 2 : 1.25))
        let retainedPause = Int(Double(sampleRate) * (style == .dramatic ? 0.9 : 0.65))
        var output: [Float] = []
        var copyStart = 0
        var index = 0
        var count = 0
        while index < samples.count {
            if abs(samples[index]) >= threshold { index += 1; continue }
            let quietStart = index
            while index < samples.count, abs(samples[index]) < threshold { index += 1 }
            guard index - quietStart > longestPause else { continue }
            // A generated tail can also contain five seconds of silence. Keep
            // short padding at the boundaries so it cannot masquerade as a refill.
            let kept = quietStart == 0 ? min(retainedPause, Int(Double(sampleRate) * 0.15)) :
                index == samples.count ? min(retainedPause, Int(Double(sampleRate) * 0.35)) : retainedPause
            let leftEnd = quietStart + kept / 2
            let rightStart = index - (kept - kept / 2)
            output.append(contentsOf: samples[copyStart..<leftEnd])
            // The splice lies deep inside near-silence. A tiny fade on either
            // side avoids a click without changing any spoken sample.
            let fade = min(sampleRate / 100, kept / 2)
            if fade > 0 {
                for offset in 0..<fade {
                    output[output.count - fade + offset] *= Float(fade - 1 - offset) / Float(fade)
                }
                for offset in 0..<fade {
                    output.append(samples[rightStart + offset] * Float(offset) / Float(fade))
                }
            }
            copyStart = rightStart + fade
            count += 1
        }
        guard count > 0 else { return unchanged }
        output.append(contentsOf: samples[copyStart...])
        return Result(samples: output, removedSeconds: Double(samples.count - output.count) / Double(sampleRate), shortenedPauses: count)
    }
}
