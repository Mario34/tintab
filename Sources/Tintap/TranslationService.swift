import Foundation

struct TranslationService {
    private let session: URLSession
    private let cache: TranslationCacheStore
    private let statistics: UsageStatisticsStore

    init(
        session: URLSession = .shared,
        cache: TranslationCacheStore = .shared,
        statistics: UsageStatisticsStore = .shared
    ) {
        self.session = session
        self.cache = cache
        self.statistics = statistics
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
            systemPrompt: configuration.systemPrompt,
            sourceText: text
        )
        if let cachedTranslation = await cache.value(for: cacheKey) {
            DebugLogger.log("Returning cached translation.")
            await statistics.recordCacheHit()
            return cachedTranslation
        }

        let systemPrompt = configuration.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ModelConfiguration.defaultSystemPrompt
            : configuration.systemPrompt
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

        await statistics.recordRequestStarted()
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { throw TranslationError.invalidResponse }
            if httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/html") == true {
                throw TranslationError.webPageResponse(endpoint.absoluteString)
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw TranslationError.requestFailed(errorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)")
            }

            let translated: String?
            let inputTokens: Int?
            let outputTokens: Int?
            switch configuration.apiFormat {
            case .openAICompatible:
                let response = try? JSONDecoder().decode(OpenAIResponse.self, from: data)
                translated = response?.choices.first?.message.content
                inputTokens = response?.usage?.promptTokens
                outputTokens = response?.usage?.completionTokens
            case .anthropicMessages:
                let response = try? JSONDecoder().decode(AnthropicResponse.self, from: data)
                translated = response?.content.first(where: { $0.type == "text" })?.text
                inputTokens = response?.usage?.inputTokens
                outputTokens = response?.usage?.outputTokens
            }
            guard let translated = translated?.trimmingCharacters(in: .whitespacesAndNewlines), !translated.isEmpty else {
                throw TranslationError.invalidResponse
            }
            await cache.set(translated, for: cacheKey)
            await statistics.recordRequestSucceeded(inputTokens: inputTokens, outputTokens: outputTokens)
            return translated
        } catch {
            await statistics.recordRequestFailed()
            throw error
        }
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
    let systemPrompt: String
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
    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }
    let choices: [Choice]
    let usage: Usage?
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
    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }
    let content: [ContentBlock]
    let usage: Usage?
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
