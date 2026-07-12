import Foundation

struct TranslationService {
    private let session: URLSession
    private let cache: TranslationCacheStore

    init(session: URLSession = .shared, cache: TranslationCacheStore = .shared) {
        self.session = session
        self.cache = cache
    }

    func translate(_ text: String, using configuration: ModelConfiguration) async throws -> String {
        guard !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.missingAPIKey
        }
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.missingModel
        }
        guard let endpoint = configuration.requestURL else {
            throw TranslationError.invalidBaseURL
        }
        let cacheKey = TranslationCacheKey(
            endpoint: endpoint.absoluteString,
            apiFormat: configuration.apiFormat,
            model: configuration.model,
            targetLanguage: configuration.targetLanguage,
            sourceText: text
        )
        if let cachedTranslation = await cache.value(for: cacheKey) {
            DebugLogger.log("Returning cached translation.")
            return cachedTranslation
        }

        let systemPrompt = "You are a precise translation engine. Return only the translation, preserving meaning, formatting, and proper nouns."
        let userPrompt = "Translate the following text into \(configuration.targetLanguage):\n\n\(text)"

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        switch configuration.apiFormat {
        case .openAICompatible:
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(OpenAIRequest(
                model: configuration.model,
                messages: [
                    Message(role: "system", content: systemPrompt),
                    Message(role: "user", content: userPrompt)
                ]
            ))
        case .anthropicMessages:
            request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try JSONEncoder().encode(AnthropicRequest(
                model: configuration.model,
                maxTokens: 1_024,
                system: systemPrompt,
                messages: [Message(role: "user", content: userPrompt)]
            ))
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw TranslationError.invalidResponse }
        if httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/html") == true {
            throw TranslationError.webPageResponse(endpoint.absoluteString)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TranslationError.requestFailed(errorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)")
        }

        let translated: String?
        switch configuration.apiFormat {
        case .openAICompatible:
            translated = try? JSONDecoder().decode(OpenAIResponse.self, from: data).choices.first?.message.content
        case .anthropicMessages:
            translated = try? JSONDecoder().decode(AnthropicResponse.self, from: data).content
                .first(where: { $0.type == "text" })?.text
        }
        guard let translated = translated?.trimmingCharacters(in: .whitespacesAndNewlines), !translated.isEmpty else {
            throw TranslationError.invalidResponse
        }
        await cache.set(translated, for: cacheKey)
        return translated
    }

    private func errorMessage(from data: Data) -> String? {
        try? JSONDecoder().decode(APIErrorResponse.self, from: data).error.message
    }
}

actor TranslationCacheStore {
    static let shared = TranslationCacheStore()

    private var storage: [TranslationCacheKey: String] = [:]

    func value(for key: TranslationCacheKey) -> String? {
        storage[key]
    }

    func set(_ value: String, for key: TranslationCacheKey) {
        storage[key] = value
    }

    func clear() {
        storage.removeAll()
    }
}

struct TranslationCacheKey: Hashable {
    let endpoint: String
    let apiFormat: ModelAPIFormat
    let model: String
    let targetLanguage: String
    let sourceText: String
}

private struct Message: Codable {
    let role: String
    let content: String
}

private struct OpenAIRequest: Encodable {
    let model: String
    let messages: [Message]
}

private struct OpenAIResponse: Decodable {
    struct Choice: Decodable { let message: Message }
    let choices: [Choice]
}

private struct AnthropicRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model, system, messages
        case maxTokens = "max_tokens"
    }
}

private struct AnthropicResponse: Decodable {
    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }
    let content: [ContentBlock]
}

private struct APIErrorResponse: Decodable {
    struct Details: Decodable { let message: String }
    let error: Details
}

enum TranslationError: LocalizedError {
    case missingAPIKey, missingModel, invalidBaseURL, invalidResponse, webPageResponse(String), requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "请先在 Tintap 菜单栏中配置 API Key。"
        case .missingModel: "请先在 Tintap 菜单栏中配置模型名称。"
        case .invalidBaseURL: "模型服务地址无效。"
        case .invalidResponse: "模型服务返回了无法识别的数据格式；请检查接口格式设置。"
        case let .webPageResponse(url): "模型服务返回了网页而不是 API JSON。请检查服务地址：\(url)。New API/Anthropic 网关通常应填写 https://域名/v1。"
        case let .requestFailed(message): "翻译请求失败：\(message)"
        }
    }
}
