@testable import AICoven
import XCTest

@MainActor
final class OpenRouterProviderTests: XCTestCase {
    private let savedKeys = ["strix_settings.v1", "llm_provider", "openrouter_model", "openai_model", "provider_accounts.v1"]
    private var savedValues: [String: Any] = [:]

    private let catalog = """
    {"data": [
      {"id": "vendor/no-tools", "name": "No Tools", "context_length": 4096,
       "supported_parameters": ["temperature"]},
      {"id": "google/gemini-9", "name": "Gemini 9", "context_length": 1000000,
       "supported_parameters": ["tools"]},
      {"id": "anthropic/claude-sonnet-9:free", "name": "Sonnet 9 (free)", "context_length": 200000,
       "supported_parameters": ["tools"]},
      {"id": "anthropic/claude-sonnet-9", "name": "Sonnet 9", "context_length": 200000,
       "supported_parameters": ["tools", "temperature"]}
    ]}
    """.data(using: .utf8)!

    override func setUp() {
        super.setUp()
        for key in savedKeys {
            savedValues[key] = UserDefaults.standard.object(forKey: UserScope.scopedKey(key))
        }
    }

    override func tearDown() {
        for key in savedKeys {
            UserDefaults.standard.set(savedValues[key], forKey: UserScope.scopedKey(key))
        }
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testToolModels_dropModelsWithoutToolsAndPutTheDefaultFirst() throws {
        let models = try ProviderAccountService.openRouterToolModels(from: catalog)

        XCTAssertEqual(
            models.map(\.id),
            ["anthropic/claude-sonnet-9", "google/gemini-9", "anthropic/claude-sonnet-9:free"]
        )
        XCTAssertEqual(models.first?.contextLength, 200_000)
        XCTAssertEqual(models.first?.provider, "openrouter")
    }

    func testRouting_seesOnlyTheChosenOpenRouterModelAndDownloadsTheCatalogOnce() async throws {
        let account = LocalProviderAccount(
            id: "openrouter-test",
            provider: "openrouter",
            displayName: "OpenRouter",
            scopes: ["chat"],
            defaultModel: nil,
            baseURL: nil,
            status: "healthy",
            createdAt: Date()
        )
        let defaults = UserDefaults.standard
        try defaults.set(JSONEncoder().encode([account]), forKey: UserScope.scopedKey("provider_accounts.v1"))
        defaults.removeObject(forKey: UserScope.scopedKey("openrouter_model"))

        let downloads = DownloadCounter()
        let catalog = catalog
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/models")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            downloads.increment()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, catalog)
        }

        let withoutAChoice = try await ProviderAccountService.shared.loadAllModelDescriptors()
        defaults.set("google/gemini-9", forKey: UserScope.scopedKey("openrouter_model"))
        let withAChoice = try await ProviderAccountService.shared.loadAllModelDescriptors()

        XCTAssertEqual(withoutAChoice.map(\.modelID), ["anthropic/claude-sonnet-9"])
        XCTAssertEqual(withoutAChoice.first?.maxContextTokens, 200_000)
        XCTAssertEqual(withAChoice.map(\.modelID), ["google/gemini-9"])
        XCTAssertEqual(downloads.count, 1)
    }

    func testCompleteChat_sendsTheKeyToOpenRouterAndReportsItAsTheProvider() async throws {
        let body = """
        {"choices": [{"message": {"role": "assistant", "content": "Hello"}}],
         "usage": {"prompt_tokens": 3, "completion_tokens": 1},
         "model": "anthropic/claude-sonnet-9"}
        """.data(using: .utf8)!
        let client = makeClient(statusCode: 200, body: body)

        let response = try await client.completeChat(
            messages: [LLMMessage(role: .user, content: "Hi")],
            model: "anthropic/claude-sonnet-9",
            options: ChatOptions()
        )

        XCTAssertEqual(response.providerID, "openrouter")
        XCTAssertEqual(response.message.content, "Hello")
    }

    func testCompleteChat_namesOpenRouterWhenTheKeyIsRefused() async {
        let client = makeClient(statusCode: 401, body: Data("{}".utf8))

        do {
            _ = try await client.completeChat(
                messages: [LLMMessage(role: .user, content: "Hi")],
                model: "anthropic/claude-sonnet-9",
                options: ChatOptions()
            )
            XCTFail("A refused key must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("OpenRouter HTTP 401"))
        }
    }

    func testStrixModelChoice_isSavedWhereAnOpenRouterTurnReadsIt() async throws {
        UserDefaults.standard.set("gpt-4o", forKey: UserScope.scopedKey("openai_model"))

        _ = try await StrixSettingsService.shared.updatePersonalStrix(
            systemPrompt: nil,
            model: "anthropic/claude-sonnet-9",
            provider: "openrouter",
            providerAccountId: nil,
            autonomousMode: nil,
            autonomousMaxSteps: nil,
            plannerMaxTasks: nil,
            plannerMaxSeconds: nil
        )

        let defaults = UserDefaults.standard
        XCTAssertEqual(defaults.string(forKey: UserScope.scopedKey("openrouter_model")), "anthropic/claude-sonnet-9")
        XCTAssertEqual(defaults.string(forKey: UserScope.scopedKey("openai_model")), "gpt-4o")
    }

    private func makeClient(statusCode: Int, body: Data) -> OpenAILLMClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer TEST_KEY")
            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        return OpenAILLMClient(
            apiKey: "TEST_KEY",
            baseURL: OpenAILLMClient.openRouterBaseURL,
            providerID: "openrouter",
            providerName: "OpenRouter",
            urlSession: URLSession(configuration: config)
        )
    }
}

private final class DownloadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func increment() {
        lock.withLock { value += 1 }
    }
}
