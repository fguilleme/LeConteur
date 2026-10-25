import AVFoundation

enum SystemVoiceSelection {
    static func installedVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted {
            if $0.language.hasPrefix("fr") != $1.language.hasPrefix("fr") { return $0.language.hasPrefix("fr") }
            return ($0.language, $0.name) < ($1.language, $1.name)
        }
    }

    static func speechRate(for speed: Double) -> Float {
        // The synthesizer's rate is not a playback multiplier: default * 2
        // reaches its extreme maximum. Keep 1× at the native natural pace and
        // use a gentle logarithmic curve for the reader's approximate speeds.
        let multiplier = speed.isFinite ? min(2, max(0.75, speed)) : 1
        return AVSpeechUtteranceDefaultSpeechRate + Float(log2(multiplier)) * 0.1
    }

    struct Voice {
        let id: String
        let language: String
        let quality: Int
    }

    static func language(_ value: String) -> String {
        Locale.Language(identifier: value.replacingOccurrences(of: "_", with: "-")).languageCode?.identifier ?? value.lowercased()
    }

    /// Preserve a BCP-47 language variant for APIs such as Translation while
    /// removing unrelated locale extensions (calendar, numbering system, etc.).
    static func localeIdentifier(_ value: String) -> String {
        let raw = value.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").map(String.init)
        guard let first = raw.first, !first.isEmpty else { return value.lowercased() }
        var result = [first.lowercased()]
        var index = 1
        if raw.indices.contains(index), raw[index].count == 4, raw[index].allSatisfy(\.isLetter) {
            result.append(raw[index].prefix(1).uppercased() + raw[index].dropFirst().lowercased())
            index += 1
        }
        if raw.indices.contains(index) {
            let region = raw[index]
            if (region.count == 2 && region.allSatisfy(\.isLetter)) || (region.count == 3 && region.allSatisfy(\.isNumber)) {
                result.append(region.uppercased())
            }
        }
        return result.joined(separator: "-")
    }

    static func identifier(for textLanguage: String, preferred: String, voices: [Voice]) -> String? {
        let matches = voices.filter { language($0.language) == language(textLanguage) }
        if matches.contains(where: { $0.id == preferred }) { return preferred }
        return matches.sorted {
            if $0.quality != $1.quality { return $0.quality > $1.quality }
            if ($0.language == textLanguage) != ($1.language == textLanguage) { return $0.language == textLanguage }
            return $0.id < $1.id
        }.first?.id
    }

    static func resolve(language: String, preferred: String) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let id = identifier(for: language, preferred: preferred, voices: voices.map {
            Voice(id: $0.identifier, language: $0.language, quality: $0.quality.rawValue)
        })
        // Choose an installed voice even when iOS only offers the default quality.
        return id.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? AVSpeechSynthesisVoice(language: language)
    }
}
