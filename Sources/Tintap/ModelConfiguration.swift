import Foundation
import Security

enum ModelAPIFormat: String, CaseIterable, Sendable {
    case openAICompatible
    case anthropicMessages

    var displayName: String {
        switch self {
        case .openAICompatible: "OpenAI 兼容（Chat Completions）"
        case .anthropicMessages: "Anthropic（Messages API）"
        }
    }

}

struct ModelConfiguration: Sendable {
    static let defaultSystemPrompt = "You are a precise translation engine. Return only the translation, preserving meaning, formatting, and proper nouns."

    var apiFormat: ModelAPIFormat
    var baseURL: String
    var model: String
    var targetLanguage: String
    var apiKey: String
    var systemPrompt: String

    init(
        apiFormat: ModelAPIFormat,
        baseURL: String,
        model: String,
        targetLanguage: String,
        apiKey: String,
        systemPrompt: String = ModelConfiguration.defaultSystemPrompt
    ) {
        self.apiFormat = apiFormat
        self.baseURL = baseURL
        self.model = model
        self.targetLanguage = targetLanguage
        self.apiKey = apiKey
        self.systemPrompt = systemPrompt
    }

    static let `default` = ModelConfiguration(
        apiFormat: .openAICompatible,
        baseURL: "https://api.openai.com/v1",
        model: "gpt-4.1-mini",
        targetLanguage: "Simplified Chinese",
        apiKey: "",
        systemPrompt: defaultSystemPrompt
    )

    var requestURL: URL? {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false else {
            return nil
        }
        let trimmedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath: String
        switch apiFormat {
        case .openAICompatible:
            endpointPath = trimmedPath.hasSuffix("chat/completions")
                ? trimmedPath
                : [trimmedPath, "chat/completions"].filter { !$0.isEmpty }.joined(separator: "/")
        case .anthropicMessages:
            if trimmedPath.hasSuffix("v1/messages") {
                endpointPath = trimmedPath
            } else if trimmedPath.hasSuffix("v1") {
                endpointPath = [trimmedPath, "messages"].joined(separator: "/")
            } else {
                endpointPath = [trimmedPath, "v1/messages"].filter { !$0.isEmpty }.joined(separator: "/")
            }
        }
        components.path = "/" + endpointPath
        return components.url
    }
}

@MainActor
final class ModelSettingsStore {
    static let shared = ModelSettingsStore()

    private enum Keys {
        static let apiFormat = "model.apiFormat"
        static let baseURL = "model.baseURL"
        static let model = "model.name"
        static let targetLanguage = "model.targetLanguage"
        static let systemPrompt = "model.systemPrompt"
        static let apiKeyAccount = "model.apiKey"
    }

    private let defaults = UserDefaults.standard

    private init() {}

    func load() -> ModelConfiguration {
        ModelConfiguration(
            apiFormat: ModelAPIFormat(rawValue: defaults.string(forKey: Keys.apiFormat) ?? "") ?? .openAICompatible,
            baseURL: defaults.string(forKey: Keys.baseURL) ?? ModelConfiguration.default.baseURL,
            model: defaults.string(forKey: Keys.model) ?? ModelConfiguration.default.model,
            targetLanguage: defaults.string(forKey: Keys.targetLanguage) ?? ModelConfiguration.default.targetLanguage,
            apiKey: (try? KeychainStore.read(account: Keys.apiKeyAccount)) ?? "",
            systemPrompt: defaults.string(forKey: Keys.systemPrompt) ?? ModelConfiguration.default.systemPrompt
        )
    }

    func save(_ configuration: ModelConfiguration) throws {
        defaults.set(configuration.apiFormat.rawValue, forKey: Keys.apiFormat)
        defaults.set(configuration.baseURL, forKey: Keys.baseURL)
        defaults.set(configuration.model, forKey: Keys.model)
        defaults.set(configuration.targetLanguage, forKey: Keys.targetLanguage)
        defaults.set(configuration.systemPrompt, forKey: Keys.systemPrompt)
        try KeychainStore.save(configuration.apiKey, account: Keys.apiKeyAccount)
    }
}

enum KeychainStore {
    private static let service = "com.tintap.app"

    static func read(account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.unreadable(status)
        }
        return value
    }

    static func save(_ value: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            let createStatus = SecItemAdd(item as CFDictionary, nil)
            guard createStatus == errSecSuccess else { throw KeychainError.unreadable(createStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unreadable(updateStatus)
        }
    }

    enum KeychainError: LocalizedError {
        case unreadable(OSStatus)

        var errorDescription: String? {
            "Could not access the API key in Keychain (status \(statusCode))."
        }

        private var statusCode: OSStatus {
            switch self { case let .unreadable(status): status }
        }
    }
}
