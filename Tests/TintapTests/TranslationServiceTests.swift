import Foundation
import Testing
@testable import Tintap

struct TranslationServiceTests {
    @Test
    func translateOpenAICompatibleParsesSuccessfulResponse() async throws {
        defer { URLProtocolStub.requestHandler = nil }
        URLProtocolStub.requestHandler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            guard let url = request.url else { throw URLError(.badURL) }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = """
            {
              "choices": [
                {
                  "message": {
                    "role": "assistant",
                    "content": "你好，世界"
                  }
                }
              ]
            }
            """.data(using: .utf8)!
            return (response, data)
        }

        let translated = try await makeService().translate("Hello, world", using: makeConfiguration())

        #expect(translated == "你好，世界")
    }

    @Test
    func translateUsesConfiguredSystemPromptAndRecordsTokenUsage() async throws {
        defer { URLProtocolStub.requestHandler = nil }
        URLProtocolStub.requestHandler = { request in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            #expect(body.contains("Translate like a pirate."))
            guard let url = request.url else { throw URLError(.badURL) }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = """
            {
              "choices": [{"message": {"role": "assistant", "content": "Ahoy"}}],
              "usage": {"prompt_tokens": 12, "completion_tokens": 3, "total_tokens": 15}
            }
            """.data(using: .utf8)!
            return (response, data)
        }

        let suiteName = "TintapTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let statistics = UsageStatisticsStore(defaults: defaults)
        let service = makeService(statistics: statistics)
        var configuration = makeConfiguration()
        configuration.systemPrompt = "Translate like a pirate."

        _ = try await service.translate("Hello", using: configuration)
        let snapshot = await statistics.current()

        #expect(snapshot.requestCount == 1)
        #expect(snapshot.successCount == 1)
        #expect(snapshot.inputTokens == 12)
        #expect(snapshot.outputTokens == 3)
        #expect(snapshot.totalTokens == 15)
    }

    @Test
    func translateAnthropicParsesSuccessfulResponse() async throws {
        defer { URLProtocolStub.requestHandler = nil }
        URLProtocolStub.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            guard let url = request.url else { throw URLError(.badURL) }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = """
            {
              "content": [
                { "type": "text", "text": "测试结果" }
              ]
            }
            """.data(using: .utf8)!
            return (response, data)
        }

        let translated = try await makeService().translate(
            "test",
            using: makeConfiguration(apiFormat: .anthropicMessages, baseURL: "https://api.deepseek.com/anthropic")
        )

        #expect(translated == "测试结果")
    }

    @Test
    func translateRejectsHTMLResponse() async {
        defer { URLProtocolStub.requestHandler = nil }
        URLProtocolStub.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (response, Data("<html></html>".utf8))
        }

        do {
            _ = try await makeService().translate("test", using: makeConfiguration())
            Issue.record("Expected webPageResponse error")
        } catch let error as TranslationError {
            guard case let .webPageResponse(url) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(url == "https://api.openai.com/v1/chat/completions")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func translateMapsAPIErrorMessage() async {
        defer { URLProtocolStub.requestHandler = nil }
        URLProtocolStub.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = """
            {
              "error": {
                "message": "invalid api key"
              }
            }
            """.data(using: .utf8)!
            return (response, data)
        }

        do {
            _ = try await makeService().translate("test", using: makeConfiguration())
            Issue.record("Expected requestFailed error")
        } catch let error as TranslationError {
            guard case let .requestFailed(message) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(message == "invalid api key")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func translateRejectsMissingAPIKeyBeforeRequest() async {
        do {
            _ = try await makeService().translate(
                "test",
                using: makeConfiguration(apiKey: "   ")
            )
            Issue.record("Expected missingAPIKey error")
        } catch let error as TranslationError {
            guard case .missingAPIKey = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func translateRejectsInvalidResponsePayload() async {
        defer { URLProtocolStub.requestHandler = nil }
        URLProtocolStub.requestHandler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = #"{"choices":[]}"#.data(using: .utf8)!
            return (response, data)
        }

        do {
            _ = try await makeService().translate("test", using: makeConfiguration())
            Issue.record("Expected invalidResponse error")
        } catch let error as TranslationError {
            guard case .invalidResponse = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func translateCachesRepeatedRequestsWithSameConfiguration() async throws {
        defer { URLProtocolStub.requestHandler = nil }
        let counter = RequestCounter()
        URLProtocolStub.requestHandler = { request in
            counter.increment()
            guard let url = request.url else { throw URLError(.badURL) }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = """
            {
              "choices": [
                {
                  "message": {
                    "role": "assistant",
                    "content": "缓存结果"
                  }
                }
              ]
            }
            """.data(using: .utf8)!
            return (response, data)
        }

        let cache = TranslationCacheStore()
        let service = makeService(cache: cache)
        let configuration = makeConfiguration()
        let first = try await service.translate("cache me", using: configuration)
        let second = try await service.translate("cache me", using: configuration)

        #expect(first == "缓存结果")
        #expect(second == "缓存结果")
        #expect(counter.currentValue() == 1)
    }

    @Test
    func translateCacheSeparatesDifferentTargetLanguages() async throws {
        defer { URLProtocolStub.requestHandler = nil }
        let counter = RequestCounter()
        URLProtocolStub.requestHandler = { request in
            counter.increment()
            guard let url = request.url else { throw URLError(.badURL) }
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            let translated = body.contains("Japanese") ? "こんにちは" : "你好"
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = """
            {
              "choices": [
                {
                  "message": {
                    "role": "assistant",
                    "content": "\(translated)"
                  }
                }
              ]
            }
            """.data(using: .utf8)!
            return (response, data)
        }

        let cache = TranslationCacheStore()
        let service = makeService(cache: cache)
        let chineseConfiguration = makeConfiguration(targetLanguage: "Simplified Chinese")
        let japaneseConfiguration = makeConfiguration(targetLanguage: "Japanese")

        let chinese = try await service.translate("hello", using: chineseConfiguration)
        let japanese = try await service.translate("hello", using: japaneseConfiguration)

        #expect(chinese == "你好")
        #expect(japanese == "こんにちは")
        #expect(counter.currentValue() == 2)
    }

    private func makeService(
        cache: TranslationCacheStore = TranslationCacheStore(),
        statistics: UsageStatisticsStore = UsageStatisticsStore()
    ) -> TranslationService {
        TranslationService(session: makeStubbedSession(), cache: cache, statistics: statistics)
    }

    private func makeStubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private func makeConfiguration(
        apiFormat: ModelAPIFormat = .openAICompatible,
        baseURL: String = "https://api.openai.com/v1",
        model: String = "gpt-4.1-mini",
        apiKey: String = "test-key",
        targetLanguage: String = "Simplified Chinese"
    ) -> ModelConfiguration {
        ModelConfiguration(
            apiFormat: apiFormat,
            baseURL: baseURL,
            model: model,
            targetLanguage: targetLanguage,
            apiKey: apiKey
        )
    }
}
