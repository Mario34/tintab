import Testing
@testable import Tintap

struct ModelConfigurationTests {
    @Test
    func openAICompatibleAppendsChatCompletionsToBaseV1URL() {
        let configuration = ModelConfiguration(
            apiFormat: .openAICompatible,
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4.1-mini",
            targetLanguage: "Simplified Chinese",
            apiKey: "test-key"
        )

        #expect(configuration.requestURL?.absoluteString == "https://api.openai.com/v1/chat/completions")
    }

    @Test
    func openAICompatibleKeepsExistingChatCompletionsEndpoint() {
        let configuration = ModelConfiguration(
            apiFormat: .openAICompatible,
            baseURL: " https://example.com/custom/chat/completions ",
            model: "test-model",
            targetLanguage: "Simplified Chinese",
            apiKey: "test-key"
        )

        #expect(configuration.requestURL?.absoluteString == "https://example.com/custom/chat/completions")
    }

    @Test
    func anthropicAppendsV1MessagesWhenMissing() {
        let configuration = ModelConfiguration(
            apiFormat: .anthropicMessages,
            baseURL: "https://api.deepseek.com/anthropic",
            model: "deepseek-v4-flash",
            targetLanguage: "Simplified Chinese",
            apiKey: "test-key"
        )

        #expect(configuration.requestURL?.absoluteString == "https://api.deepseek.com/anthropic/v1/messages")
    }

    @Test
    func anthropicKeepsExistingMessagesEndpoint() {
        let configuration = ModelConfiguration(
            apiFormat: .anthropicMessages,
            baseURL: "https://api.deepseek.com/anthropic/v1/messages",
            model: "deepseek-v4-flash",
            targetLanguage: "Simplified Chinese",
            apiKey: "test-key"
        )

        #expect(configuration.requestURL?.absoluteString == "https://api.deepseek.com/anthropic/v1/messages")
    }

    @Test
    func invalidBaseURLReturnsNil() {
        let configuration = ModelConfiguration(
            apiFormat: .openAICompatible,
            baseURL: "not a url",
            model: "test-model",
            targetLanguage: "Simplified Chinese",
            apiKey: "test-key"
        )

        #expect(configuration.requestURL == nil)
    }
}
