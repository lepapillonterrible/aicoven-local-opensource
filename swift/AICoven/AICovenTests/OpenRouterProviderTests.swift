@testable import AICoven
import XCTest

@MainActor
final class OpenRouterProviderTests: XCTestCase {
    private let savedKeys = ["strix_settings.v1", "llm_provider", "openrouter_model", "openai_model", "provider_accounts.v1"]
    private var savedValues: [String: Any] = [:]

    private let catalog = """
    {"data": [
      {"id": "vendor/no-tools", "name": "No Tools", "context_length": 4096,
       "supported_parameters": ["temperature"], "endpoints": ["/api/v1/chat/completions"]},
      {"id": "google/gemini-9", "name": "Gemini 9", "context_length": 1000000,
       "supported_parameters": ["tools"], "endpoints": ["/api/v1/chat/completions"]},
      {"id": "google/gemini-9:batch", "name": "Gemini 9 (batch)", "context_length": 1000000,
       "supported_parameters": ["tools"], "endpoints": ["/api/v1/batches"]},
      {"id": "anthropic/claude-sonnet-9:free", "name": "Sonnet 9 (free)", "context_length": 200000,
       "supported_parameters": ["tools"], "endpoints": ["/api/v1/chat/completions"]},
      {"id": "anthropic/claude-sonnet-9", "name": "Sonnet 9", "context_length": 200000,
       "supported_parameters": ["tools", "temperature"], "endpoints": ["/api/v1/chat/completions"]}
    ]}
    """.data(using: .utf8)!

    private let account = LocalProviderAccount(
        id: "openrouter-test",
        provider: "openrouter",
        displayName: "OpenRouter",
        scopes: ["chat"],
        defaultModel: nil,
        baseURL: nil,
        status: "healthy",
        createdAt: Date()
    )

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
        KeychainHelper.delete(key: "provider-account-openrouter-test")
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testChatModels_dropModelsAChatTurnCannotUseAndPutTheDefaultFirst() throws {
        let models = try ProviderAccountService.openRouterToolModels(from: catalog)

        XCTAssertEqual(
            models.map(\.id),
            ["anthropic/claude-sonnet-9", "google/gemini-9", "anthropic/claude-sonnet-9:free"]
        )
        XCTAssertEqual(models.first?.contextLength, 200_000)
        XCTAssertEqual(models.first?.provider, "openrouter")
    }

    func testRouting_seesOnlyTheChosenOpenRouterModelAndDownloadsTheCatalogOnce() async throws {
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

        async let first = ProviderAccountService.shared.loadAllModelDescriptors()
        async let overlapping = ProviderAccountService.shared.loadAllModelDescriptors()
        let withoutAChoice = try await [first, overlapping]
        defaults.set("google/gemini-9", forKey: UserScope.scopedKey("openrouter_model"))
        let withAChoice = try await ProviderAccountService.shared.loadAllModelDescriptors()
        defaults.set("vendor/retired", forKey: UserScope.scopedKey("openrouter_model"))
        let withARetiredChoice = try await ProviderAccountService.shared.loadAllModelDescriptors()

        XCTAssertEqual(withoutAChoice.map { $0.map(\.modelID) }, [["anthropic/claude-sonnet-9"], ["anthropic/claude-sonnet-9"]])
        XCTAssertEqual(withoutAChoice[0].first?.maxContextTokens, 200_000)
        XCTAssertEqual(withAChoice.map(\.modelID), ["google/gemini-9"])
        XCTAssertEqual(withARetiredChoice.map(\.modelID), ["vendor/retired"])
        XCTAssertEqual(downloads.count, 1)
    }

    func testTheCatalog_saysWhichOpenRouterModelsTakePictures_alsoOfThoseTheRouterIsNotGiven() async throws {
        let defaults = UserDefaults.standard
        try defaults.set(JSONEncoder().encode([account]), forKey: UserScope.scopedKey("provider_accounts.v1"))
        defaults.set("vendor/reads", forKey: UserScope.scopedKey("openrouter_model"))
        let listed = Data("""
        {"data": [
          {"id": "vendor/sees", "name": "Sees", "context_length": 1000, "supported_parameters": ["tools"],
           "endpoints": ["/api/v1/chat/completions"], "architecture": {"input_modalities": ["text", "image"]}},
          {"id": "vendor/reads", "name": "Reads", "context_length": 1000, "supported_parameters": ["tools"],
           "endpoints": ["/api/v1/chat/completions"], "architecture": {"input_modalities": ["text"]}},
          {"id": "vendor/sees-without-tools", "name": "Sees, no tools", "context_length": 1000, "supported_parameters": ["temperature"],
           "endpoints": ["/api/v1/chat/completions"], "architecture": {"input_modalities": ["image", "text"]}}
        ]}
        """.utf8)
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, listed)
        }
        await ProviderAccountService.shared.forgetOpenRouterCatalog()

        let reading = try await ProviderAccountService.shared.loadModelCatalog()
        XCTAssertEqual(reading.routed.map(\.modelID), ["vendor/reads"])
        XCTAssertEqual(reading.routed.first?.takesImages, false)
        XCTAssertEqual(
            reading.imageModels, ["openrouter": ["vendor/sees", "vendor/sees-without-tools"]],
            "Known though the router is not given them, one that a chat turn is not offered included"
        )
        XCTAssertEqual(try ProviderAccountService.openRouterToolModels(from: listed).map(\.id), ["vendor/sees", "vendor/reads"])

        defaults.set("vendor/sees", forKey: UserScope.scopedKey("openrouter_model"))
        let seeing = try await ProviderAccountService.shared.loadModelCatalog()
        XCTAssertEqual(seeing.routed.map(\.modelID), ["vendor/sees"])
        XCTAssertEqual(seeing.routed.first?.takesImages, true)

        // One chosen that chat is not offered is still known by the catalog.
        defaults.set("vendor/sees-without-tools", forKey: UserScope.scopedKey("openrouter_model"))
        let unoffered = try await ProviderAccountService.shared.loadModelCatalog()
        XCTAssertEqual(unoffered.routed.map(\.modelID), ["vendor/sees-without-tools"])
        XCTAssertEqual(unoffered.routed.first?.takesImages, true)
        await ProviderAccountService.shared.forgetOpenRouterCatalog()
    }

    func testKeyCheck_asksOpenRouterAboutTheStoredKeyAndFailsWhenItIsRefused() async throws {
        try KeychainHelper.save(key: "provider-account-openrouter-test", value: "STORED_KEY")
        let status = StatusCode(200)
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer STORED_KEY")
            let response = HTTPURLResponse(url: request.url!, statusCode: status.value, httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }

        try await ProviderAccountService.shared.checkOpenRouterKey(accountId: "openrouter-test")

        status.value = 401
        do {
            try await ProviderAccountService.shared.checkOpenRouterKey(accountId: "openrouter-test")
            XCTFail("A refused key must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("OpenRouter key check HTTP 401"))
        }
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

    func testCompleteChat_sendsDottedToolNamesInFunctionNameFormAndMapsEachCallBack() async throws {
        let body = """
        {"choices": [{"message": {"role": "assistant", "content": null, "tool_calls": [
            {"id": "call_1", "type": "function", "function": {"name": "file_read_", "arguments": "{\\"path\\": \\"a.txt\\"}"}},
            {"id": "call_2", "type": "function", "function": {"name": "file_read", "arguments": "{\\"path\\": \\"b.txt\\"}"}}
         ]}}],
         "model": "anthropic/claude-sonnet-9"}
        """.data(using: .utf8)!
        let sentBody = SentBody()
        let client = makeClient(statusCode: 200, body: body, sentBody: sentBody)

        let response = try await client.completeChat(
            messages: [LLMMessage(role: .user, content: "Read a.txt")],
            model: "anthropic/claude-sonnet-9",
            options: ChatOptions(tools: ["file.read", "file_read"].map { name in
                LLMToolDefinition(
                    name: name,
                    description: "Read a file",
                    parameters: [LLMToolParameter(name: "path", type: "string", description: "Path", required: true)]
                )
            })
        )

        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: sentBody.value) as? [String: Any])
        let tools = try XCTUnwrap(sent["tools"] as? [[String: Any]])
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(names, ["file_read", "file_read_"])
        XCTAssertEqual(response.toolCalls?.map(\.name), ["file_read", "file.read"])
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
        // Strix's settings are saved with the account's key in memory.
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        addTeardownBlock { await DataEncryptionService.shared.lock() }
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

    private func makeClient(statusCode: Int, body: Data, sentBody: SentBody? = nil) -> OpenAILLMClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer TEST_KEY")
            // URLProtocol hands a request's body over as a stream.
            if let sentBody, let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                stream.close()
                sentBody.value = data
            }
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

// The three boxes below cross from a URL loading thread to the test. Each is
// @unchecked Sendable because every read and write of its value holds its lock.

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

private final class StatusCode: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int

    init(_ value: Int) {
        stored = value
    }

    var value: Int {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class SentBody: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()

    var value: Data {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
