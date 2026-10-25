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
    var name: String { seconds.map { String(format: String(localized: "%lld s"), Int64($0)) } ?? String(localized: "Automatique") }
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
        case .ryan: String(localized: "Masculine et dynamique · anglais")
        case .aiden: String(localized: "Masculine, claire et lumineuse · anglais américain")
        case .serena: String(localized: "Féminine, douce et chaleureuse · chinois")
        case .vivian: String(localized: "Féminine, vive et lumineuse · chinois")
        case .uncleFu: String(localized: "Masculine, grave et posée · chinois")
        case .onoAnna: String(localized: "Féminine, légère et enjouée · japonais")
        case .sohee: String(localized: "Féminine, chaleureuse et expressive · coréen")
        case .dylan: String(localized: "Masculine, jeune et naturelle · chinois de Pékin")
        case .eric: String(localized: "Masculine, vive et légèrement rauque · chinois du Sichuan")
        }
    }
}

enum NarrationStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case warm, natural, dramatic
    var id: String { rawValue }
    var name: String {
        switch self {
        case .warm: String(localized: "Chaleureux")
        case .natural: String(localized: "Sobre")
        case .dramatic: String(localized: "Théâtral")
        }
    }
    var subtitle: String {
        switch self {
        case .warm: String(localized: "La douceur d’un livre audio")
        case .natural: String(localized: "Une narration calme et naturelle")
        case .dramatic: String(localized: "Des émotions et des contrastes")
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

    /// Use the language of the edition being read, including a translation's
    /// target language. Keep this identical across all passages of that edition.
    func instruction(language: String) -> String {
        let pronunciation: String
        let styles: (warm: String, natural: String, dramatic: String)
        switch language.lowercased() {
        case "french":
            pronunciation = "Lisez intégralement le texte en français, avec une prononciation française naturelle et un accent constant. Articulez chaque mot et chaque fin de phrase, sans avaler de syllabes. Respectez la ponctuation, sans traduire, résumer ni ajouter de mots."
            styles = (
                "Adoptez une voix de narration chaleureuse et douce, avec des phrases fluides et une émotion discrète.",
                "Adoptez une voix de narration sobre, claire et naturelle, avec une intonation mesurée et un rythme régulier.",
                "Adoptez une voix de narration théâtrale et expressive. Variez l’intonation avec le sens du texte, tout en gardant une articulation nette."
            )
        case "spanish":
            pronunciation = "Lee todo el texto en español, con una pronunciación natural y un acento constante. Articula cada palabra y cada final de frase, sin omitir sílabas. Respeta la puntuación, sin traducir, resumir ni añadir palabras."
            styles = (
                "Narra con una voz cálida y suave, frases fluidas y una emoción sutil.",
                "Narra con una voz sobria, clara y natural, una entonación moderada y un ritmo regular.",
                "Narra con una voz teatral y expresiva. Varía la entonación según el sentido del texto y mantén una articulación clara."
            )
        case "german":
            pronunciation = "Lies den gesamten Text auf Deutsch mit natürlicher Aussprache und gleichbleibendem Akzent vor. Sprich jedes Wort und jedes Satzende deutlich aus, ohne Silben zu verschlucken. Beachte die Satzzeichen, ohne zu übersetzen, zusammenzufassen oder Wörter hinzuzufügen."
            styles = (
                "Erzähle mit warmer, sanfter Stimme, flüssigen Sätzen und dezenten Gefühlen.",
                "Erzähle mit einer ruhigen, klaren und natürlichen Stimme, zurückhaltender Betonung und gleichmäßigem Rhythmus.",
                "Erzähle mit einer ausdrucksstarken, dramatischen Stimme. Passe die Betonung dem Sinn des Textes an und artikuliere weiterhin deutlich."
            )
        case "italian":
            pronunciation = "Leggi tutto il testo in italiano, con una pronuncia naturale e un accento costante. Articola ogni parola e ogni fine di frase, senza saltare sillabe. Rispetta la punteggiatura, senza tradurre, riassumere o aggiungere parole."
            styles = (
                "Narra con una voce calda e dolce, frasi fluide e un’emozione delicata.",
                "Narra con una voce sobria, chiara e naturale, un’intonazione misurata e un ritmo regolare.",
                "Narra con una voce teatrale ed espressiva. Varia l’intonazione secondo il senso del testo, mantenendo un’articolazione chiara."
            )
        case "portuguese":
            pronunciation = "Leia todo o texto em português, com uma pronúncia natural e um sotaque constante. Articule cada palavra e cada final de frase, sem omitir sílabas. Respeite a pontuação, sem traduzir, resumir ou acrescentar palavras."
            styles = (
                "Narre com uma voz calorosa e suave, frases fluidas e uma emoção discreta.",
                "Narre com uma voz sóbria, clara e natural, uma entoação moderada e um ritmo regular.",
                "Narre com uma voz teatral e expressiva. Varie a entoação conforme o sentido do texto, mantendo uma articulação clara."
            )
        case "russian":
            pronunciation = "Прочитайте весь текст по-русски с естественным произношением и неизменным акцентом. Чётко произносите каждое слово и окончания фраз, не проглатывайте слоги. Соблюдайте знаки препинания, не переводите, не сокращайте и не добавляйте слова."
            styles = (
                "Рассказывайте тёплым, мягким голосом, плавно и с лёгкой эмоциональностью.",
                "Рассказывайте сдержанным, ясным и естественным голосом, с умеренной интонацией и ровным ритмом.",
                "Рассказывайте театральным, выразительным голосом. Меняйте интонацию в соответствии со смыслом текста, сохраняя чёткую артикуляцию."
            )
        case "japanese":
            pronunciation = "全文を自然な日本語の発音で読み、アクセントを一貫させてください。言葉や文末を省略せず、一音一音を明瞭に発音してください。句読点を尊重し、翻訳、要約、言葉の追加はしないでください。"
            styles = (
                "温かく柔らかな語り口で、文を滑らかにつなぎ、控えめな感情を込めて読んでください。",
                "落ち着いた明瞭で自然な声で、抑揚は控えめに、一定のリズムで読んでください。",
                "演劇のように表情豊かに読んでください。内容に合わせて抑揚を変えながら、明瞭な発音を保ってください。"
            )
        case "korean":
            pronunciation = "전체 글을 자연스러운 한국어 발음과 일관된 억양으로 읽으세요. 음절을 생략하지 말고 모든 단어와 문장 끝을 또렷하게 발음하세요. 문장 부호를 지키고 번역하거나 요약하거나 단어를 덧붙이지 마세요."
            styles = (
                "따뜻하고 부드러운 목소리로 문장을 자연스럽게 이어 가며 은은한 감정을 담아 읽으세요.",
                "차분하고 명료하며 자연스러운 목소리로, 절제된 억양과 일정한 리듬을 유지하며 읽으세요.",
                "연극처럼 표현력 있는 목소리로 읽으세요. 글의 의미에 맞게 억양을 바꾸되 또렷한 발음을 유지하세요."
            )
        case "chinese":
            pronunciation = "请用自然、标准的普通话完整朗读全文，始终保持一致的口音。每个词和句尾都要发音清晰，不要吞音或漏字。遵循标点，不要翻译、概括或添加文字。"
            styles = (
                "请用温暖柔和的叙述语气朗读，语句流畅，情感细腻而含蓄。",
                "请用平实、清晰、自然的声音朗读，语调适度，节奏均匀。",
                "请用富有戏剧性和表现力的声音朗读，根据文意变化语调，同时保持吐字清晰。"
            )
        default:
            pronunciation = "Read the entire text in English, with natural pronunciation and a consistent accent. Articulate every word and sentence ending without swallowing syllables. Respect punctuation without translating, summarizing or adding words."
            styles = (
                "Use a warm, gentle storytelling voice with fluid phrasing and subtle emotion.",
                "Use a clear, natural, understated voice with measured intonation and an even rhythm.",
                "Use an expressive, theatrical storytelling voice. Vary intonation with the meaning of the text while keeping articulation clear."
            )
        }
        let delivery = switch self {
        case .warm: styles.warm
        case .natural: styles.natural
        case .dramatic: styles.dramatic
        }
        return pronunciation + " " + delivery
    }

    static let auditionText = "La pluie venait de s’arrêter. Camille poussa doucement la porte du jardin. Une silhouette l’attendait près de la fontaine. « Tu es revenu ? » demanda-t-elle, sans oser y croire. L’homme sourit. « Je t’avais promis de retrouver le chemin. » Alors, pour la première fois depuis longtemps, elle se sentit chez elle."

    static func languageName(for code: String?) -> String? {
        let normalized = SystemVoiceSelection.language(code ?? "fr")
        let base = ["fra": "fr", "fre": "fr", "eng": "en", "spa": "es", "deu": "de", "ger": "de",
                    "ita": "it", "por": "pt", "rus": "ru", "jpn": "ja", "kor": "ko", "zho": "zh", "chi": "zh"][normalized] ?? normalized
        return ["fr": "French", "en": "English", "es": "Spanish", "de": "German", "it": "Italian",
                "pt": "Portuguese", "ru": "Russian", "ja": "Japanese", "ko": "Korean", "zh": "Chinese"][base]
    }
}
