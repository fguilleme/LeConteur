import Foundation

enum QwenBufferPreset: String, CaseIterable, Identifiable, Sendable {
    case automatic, seconds10, seconds30, seconds60
    var id: String { rawValue }
    var seconds: Double? {
        switch self {
        case .automatic: nil
        case .seconds10: 10
        case .seconds30: 30
        case .seconds60: 60
        }
    }
    var name: String { seconds.map { "\(Int($0)) s" } ?? "Automatique" }
}

enum QwenSpeaker: String, CaseIterable, Identifiable, Sendable {
    case ryan, aiden, serena, vivian, uncleFu = "uncle_fu", onoAnna = "ono_anna", sohee, dylan, eric
    var id: String { rawValue }
    var name: String {
        switch self {
        case .ryan: "Ryan"
        case .aiden: "Aiden"
        case .serena: "Serena"
        case .vivian: "Vivian"
        case .uncleFu: "Uncle Fu"
        case .onoAnna: "Ono Anna"
        case .sohee: "Sohee"
        case .dylan: "Dylan"
        case .eric: "Eric"
        }
    }
    var description: String {
        switch self {
        case .ryan: "Masculine et dynamique · anglais"
        case .aiden: "Masculine, claire et lumineuse · anglais américain"
        case .serena: "Féminine, douce et chaleureuse · chinois"
        case .vivian: "Féminine, vive et lumineuse · chinois"
        case .uncleFu: "Masculine, grave et posée · chinois"
        case .onoAnna: "Féminine, légère et enjouée · japonais"
        case .sohee: "Féminine, chaleureuse et expressive · coréen"
        case .dylan: "Masculine, jeune et naturelle · chinois de Pékin"
        case .eric: "Masculine, vive et légèrement rauque · chinois du Sichuan"
        }
    }
}

enum NarrationStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case warm, natural, dramatic
    var id: String { rawValue }
    var name: String {
        switch self {
        case .warm: "Chaleureux"
        case .natural: "Sobre"
        case .dramatic: "Théâtral"
        }
    }
    var subtitle: String {
        switch self {
        case .warm: "La douceur d’un livre audio"
        case .natural: "Une narration calme et naturelle"
        case .dramatic: "Des émotions et des contrastes"
        }
    }
    var icon: String {
        switch self {
        case .warm: "sun.max"
        case .natural: "leaf"
        case .dramatic: "theatermasks"
        }
    }
    var instruction: String {
        switch self {
        case .warm:
            "Read as a warm, intimate audiobook narrator. Gentle emotional depth, fluid phrasing, unhurried natural pauses. Convey quiet wonder in questions, a reassuring smile in replies, and warmth. Subtle acting, never exaggerated."
        case .natural:
            "Read with a natural, clear, understated delivery. Calm and conversational, neutral but alive. Respect punctuation and questions with subtle pitch variation. No theatrical acting, no exaggerated emotion, no sing-song delivery."
        case .dramatic:
            "Perform as an expressive dramatic storyteller. Build suspense, give questions genuine surprised disbelief, replies a warm reassuring smile, and endings a feeling of relief. Vary rhythm, pitch and intensity, with deliberate dramatic pauses. Speak clearly without shouting."
        }
    }

    static let auditionText = "La pluie venait de s’arrêter. Camille poussa doucement la porte du jardin. Une silhouette l’attendait près de la fontaine. « Tu es revenu ? » demanda-t-elle, sans oser y croire. L’homme sourit. « Je t’avais promis de retrouver le chemin. » Alors, pour la première fois depuis longtemps, elle se sentit chez elle."

    static func languageName(for code: String?) -> String? {
        let base = (code ?? "fr").split(separator: "-").first.map(String.init) ?? "fr"
        return ["fr": "French", "en": "English", "es": "Spanish", "de": "German", "it": "Italian",
                "pt": "Portuguese", "ru": "Russian", "ja": "Japanese", "ko": "Korean", "zh": "Chinese"][base]
    }
}
