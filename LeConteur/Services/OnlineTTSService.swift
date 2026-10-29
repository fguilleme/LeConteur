import AVFoundation
import Foundation
import Security

enum OnlineVoiceProvider: String, CaseIterable, Identifiable, Sendable {
    case elevenLabs
    case fishAudio

    var id: String { rawValue }
    var name: String {
        switch self {
        case .elevenLabs: "ElevenLabs"
        case .fishAudio: "Fish Audio"
        }
    }
    var engine: VoiceEngine {
        switch self {
        case .elevenLabs: .elevenLabs
        case .fishAudio: .fishAudio
        }
    }
    var keyURL: URL {
        switch self {
        case .elevenLabs: URL(string: "https://elevenlabs.io/app/developers/api-keys")!
        case .fishAudio: URL(string: "https://fish.audio/app/api-keys")!
        }
    }
}

extension VoiceEngine {
    var onlineProvider: OnlineVoiceProvider? {
        switch self {
        case .elevenLabs: .elevenLabs
        case .fishAudio: .fishAudio
        case .system, .supertonic, .qwen: nil
        }
    }
}

struct OnlineVoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let details: String
    let languages: [String]
    let provider: OnlineVoiceProvider
}

enum OnlineTTSAPIError: LocalizedError, Equatable {
    case missingKey
    case missingVoice
    case invalidResponse
    case server(status: Int, message: String)
    case unusableAudio

    var errorDescription: String? {
        switch self {
        case .missingKey: String(localized: "Ajoutez d’abord une clé API.")
        case .missingVoice: String(localized: "Choisissez d’abord une voix.")
        case .invalidResponse: String(localized: "Le fournisseur a renvoyé une réponse illisible.")
        case .server(let status, let message):
            message.isEmpty
                ? String(format: String(localized: "Le service vocal a répondu avec l’erreur %lld."), Int64(status))
                : message
        case .unusableAudio: String(localized: "Le fournisseur n’a pas produit d’audio utilisable.")
        }
    }
}

enum OnlineAPIKeyStore {
    private static let service = "com.fguilleme.conteur.online-tts"

    static func contains(_ provider: OnlineVoiceProvider) -> Bool {
        (try? load(provider)) != nil
    }

    static func load(_ provider: OnlineVoiceProvider) throws -> String {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw OnlineTTSAPIError.missingKey }
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw OnlineTTSAPIError.missingKey
        }
        return key
    }

    static func save(_ key: String, for provider: OnlineVoiceProvider) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OnlineTTSAPIError.missingKey }
        let data = Data(trimmed.utf8)
        let query = baseQuery(provider)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw keychainError(addStatus) }
        } else if status != errSecSuccess {
            throw keychainError(status)
        }
    }

    static func remove(_ provider: OnlineVoiceProvider) throws {
        let status = SecItemDelete(baseQuery(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }

    private static func baseQuery(_ provider: OnlineVoiceProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider.rawValue]
    }

    private static func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? String(localized: "Impossible d’accéder au trousseau.")])
    }
}

actor OnlineTTSClient {
    static let shared = OnlineTTSClient()
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func voices(for provider: OnlineVoiceProvider) async throws -> [OnlineVoice] {
        let key = try OnlineAPIKeyStore.load(provider)
        switch provider {
        case .elevenLabs: return try await elevenLabsVoices(key: key)
        case .fishAudio: return try await fishAudioVoices(key: key)
        }
    }

    func synthesize(_ text: String, provider: OnlineVoiceProvider, voiceID: String) async throws -> QwenRenderedAudio {
        let key = try OnlineAPIKeyStore.load(provider)
        guard !voiceID.isEmpty else { throw OnlineTTSAPIError.missingVoice }
        let started = Date()
        let data: Data
        switch provider {
        case .elevenLabs:
            data = try await synthesizeElevenLabs(text, voiceID: voiceID, key: key)
        case .fishAudio:
            data = try await synthesizeFishAudio(text, voiceID: voiceID, key: key)
        }
        try Task.checkCancellation()
        let url = FileManager.default.temporaryDirectory
            .appending(path: "conteur-online-\(UUID().uuidString).mp3")
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let audio = try AVAudioFile(forReading: url)
            let duration = Double(audio.length) / audio.processingFormat.sampleRate
            guard duration.isFinite, duration > 0.05 else { throw OnlineTTSAPIError.unusableAudio }
            return QwenRenderedAudio(url: url,
                metrics: .init(generationSeconds: Date().timeIntervalSince(started), audioSeconds: duration,
                               mlxPeakBytes: 0, observedFootprintBytes: 0),
                wordTimeline: .uniform(text: text, duration: duration))
        } catch {
            try? FileManager.default.removeItem(at: url)
            if error is OnlineTTSAPIError { throw error }
            throw OnlineTTSAPIError.unusableAudio
        }
    }

    private func elevenLabsVoices(key: String) async throws -> [OnlineVoice] {
        var result: [OnlineVoice] = []
        var token: String?
        repeat {
            var components = URLComponents(string: "https://api.elevenlabs.io/v2/voices")!
            components.queryItems = [URLQueryItem(name: "page_size", value: "100"),
                                     URLQueryItem(name: "include_total_count", value: "false"),
                                     URLQueryItem(name: "sort", value: "name"),
                                     URLQueryItem(name: "sort_direction", value: "asc")]
            if let token { components.queryItems?.append(URLQueryItem(name: "next_page_token", value: token)) }
            var request = URLRequest(url: components.url!)
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
            let (data, response) = try await session.data(for: request)
            try validate(response, data: data)
            let page = try JSONDecoder().decode(ElevenVoicesPage.self, from: data)
            result += page.voices.map {
                let labels = [$0.labels?["language"], $0.labels?["accent"], $0.labels?["gender"]]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                return OnlineVoice(id: $0.voiceID, name: $0.name,
                                   details: labels.isEmpty ? ($0.description ?? $0.category ?? "") : labels,
                                   languages: $0.verifiedLanguages?.map(\.language) ?? [], provider: .elevenLabs)
            }
            token = page.hasMore ? page.nextPageToken : nil
        } while token != nil && result.count < 1_000
        return unique(result)
    }

    private func fishAudioVoices(key: String) async throws -> [OnlineVoice] {
        // Personal voices first, followed by the most-used public voices. Fish
        // Audio's public catalogue is unbounded, so the app keeps this picker
        // responsive by loading a generous, useful first page.
        let personal = try await fishAudioVoicePage(key: key, personal: true, pageSize: 100)
        let popular = try await fishAudioVoicePage(key: key, personal: false, pageSize: 100)
        return unique(personal + popular)
    }

    private func fishAudioVoicePage(key: String, personal: Bool, pageSize: Int) async throws -> [OnlineVoice] {
        var components = URLComponents(string: "https://api.fish.audio/model")!
        components.queryItems = [URLQueryItem(name: "page_size", value: String(pageSize)),
                                 URLQueryItem(name: "page_number", value: "1"),
                                 URLQueryItem(name: "self", value: personal ? "true" : "false"),
                                 URLQueryItem(name: "sort_by", value: personal ? "created_at" : "task_count")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        let page = try JSONDecoder().decode(FishVoicesPage.self, from: data)
        return page.items.filter { $0.type == "tts" && $0.state == "trained" }.map {
            let languages = $0.languages ?? []
            return OnlineVoice(id: $0.id, name: $0.title,
                               details: languages.isEmpty ? ($0.description ?? "") : languages.joined(separator: " · "),
                               languages: languages, provider: .fishAudio)
        }
    }

    private func synthesizeElevenLabs(_ text: String, voiceID: String, key: String) async throws -> Data {
        let escaped = voiceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? voiceID
        let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(escaped)?output_format=mp3_44100_128")!
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ElevenSpeechRequest(text: text, modelID: "eleven_multilingual_v2"))
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return data
    }

    private func synthesizeFishAudio(_ text: String, voiceID: String, key: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.fish.audio/v1/tts")!, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("s2.1-pro", forHTTPHeaderField: "model")
        request.httpBody = try JSONEncoder().encode(FishSpeechRequest(text: text, referenceID: voiceID))
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return data
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw OnlineTTSAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let api = try? JSONDecoder().decode(APIErrorMessage.self, from: data)
            throw OnlineTTSAPIError.server(status: http.statusCode,
                message: api?.detail ?? api?.message ?? String(data: data.prefix(500), encoding: .utf8) ?? "")
        }
    }

    private func unique(_ voices: [OnlineVoice]) -> [OnlineVoice] {
        var ids = Set<String>()
        return voices.filter { ids.insert($0.id).inserted }
    }
}

private struct ElevenVoicesPage: Decodable {
    let voices: [ElevenVoice]
    let hasMore: Bool
    let nextPageToken: String?
    enum CodingKeys: String, CodingKey { case voices, hasMore = "has_more", nextPageToken = "next_page_token" }
}

private struct ElevenVoice: Decodable {
    struct VerifiedLanguage: Decodable { let language: String }
    let voiceID: String
    let name: String
    let category: String?
    let description: String?
    let labels: [String: String]?
    let verifiedLanguages: [VerifiedLanguage]?
    enum CodingKeys: String, CodingKey { case voiceID = "voice_id", name, category, description, labels, verifiedLanguages = "verified_languages" }
}

private struct FishVoicesPage: Decodable {
    let items: [FishVoice]
}

private struct FishVoice: Decodable {
    let id: String
    let type: String
    let title: String
    let description: String?
    let state: String
    let languages: [String]?
    enum CodingKeys: String, CodingKey { case id = "_id", type, title, description, state, languages }
}

private struct ElevenSpeechRequest: Encodable {
    let text: String
    let modelID: String
    enum CodingKeys: String, CodingKey { case text, modelID = "model_id" }
}

private struct FishSpeechRequest: Encodable {
    let text: String
    let referenceID: String
    let format = "mp3"
    let sampleRate = 44_100
    let mp3Bitrate = 128
    enum CodingKeys: String, CodingKey {
        case text, referenceID = "reference_id", format, sampleRate = "sample_rate", mp3Bitrate = "mp3_bitrate"
    }
}

private struct APIErrorMessage: Decodable {
    let message: String?
    let detail: String?
}
