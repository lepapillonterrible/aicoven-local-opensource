@testable import AICoven
import XCTest

/// OpenAI-compatible servers: finding them, connecting one, and reaching it
/// in a chat turn.
@MainActor
final class OpenAICompatibleServerTests: XCTestCase {
    private let accountsKey = UserScope.scopedKey("provider_accounts.v1")
    private let modelKey = UserScope.scopedKey("openai_compatible_model")
    private var savedAccounts: Any?
    private var savedModel: Any?
    private let service = ProviderAccountService.shared
    private let modelList = Data(#"{"data": [{"id": "qwen-9"}, {"id": "phi-9"}]}"#.utf8)

    override func setUp() {
        super.setUp()
        savedAccounts = UserDefaults.standard.object(forKey: accountsKey)
        savedModel = UserDefaults.standard.object(forKey: modelKey)
        UserDefaults.standard.removeObject(forKey: accountsKey)
        UserDefaults.standard.removeObject(forKey: modelKey)
    }

    override func tearDown() {
        for account in (try? JSONDecoder().decode([LocalProviderAccount].self, from: UserDefaults.standard.data(forKey: accountsKey) ?? Data())) ?? [] {
            KeychainHelper.delete(key: "provider-account-\(account.id)")
        }
        UserDefaults.standard.set(savedAccounts, forKey: accountsKey)
        UserDefaults.standard.set(savedModel, forKey: modelKey)
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Finding servers

    func testDetect_listsServersThatAnswerAndMarksOneThatAsksForAKey() async {
        let transport = FakeTransport(answers: [
            "http://127.0.0.1:1234/v1/models": .success(modelList),
            "http://127.0.0.1:11434/v1/models": .unauthorized,
        ])

        let found = await LocalProviderDiscoveryService(transport: transport).discover()

        XCTAssertEqual(found.map(\.provider), ["openai_compatible", "ollama"])
        XCTAssertEqual(found.map(\.displayName), ["LM Studio", "Ollama"])
        XCTAssertEqual(found.map(\.baseURL), ["http://127.0.0.1:1234", "http://127.0.0.1:11434"])
        XCTAssertEqual(found.map(\.models), [["qwen-9", "phi-9"], []])
        XCTAssertEqual(found.map(\.requiresKey), [false, true])
    }

    func testDetect_findsNothingWhenNoPortAnswers() async {
        let found = await LocalProviderDiscoveryService(transport: FakeTransport(answers: [:])).discover()

        XCTAssertTrue(found.isEmpty)
    }

    func testTypedAddress_readsPortsHostsAndURLsAndRefusesWhatHasNoPort() {
        typealias Endpoint = LocalProviderDiscoveryService.ManualEndpoint
        let parse = LocalProviderDiscoveryService.parseManualEndpoint

        XCTAssertEqual(parse(" 8080 "), Endpoint(scheme: "http", host: "127.0.0.1", port: 8080))
        XCTAssertEqual(parse("192.168.1.20:1234"), Endpoint(scheme: "http", host: "192.168.1.20", port: 1234))
        XCTAssertEqual(parse("https://box.local:8443/v1/models"), Endpoint(scheme: "https", host: "box.local", port: 8443))
        XCTAssertEqual(parse("[::1]:1234")?.baseURL, "http://[::1]:1234")
        XCTAssertNil(parse("box.local"))
        XCTAssertNil(parse("70000"))
        XCTAssertNil(parse("not a port"))
    }

    func testServerAddress_isWhereRequestsGoWhateverWasTyped() {
        let address = { LocalProviderDiscoveryService.serverBaseURL(from: $0)?.absoluteString }

        XCTAssertEqual(address("1234"), "http://127.0.0.1:1234")
        XCTAssertEqual(address("http://127.0.0.1:1234/v1/"), "http://127.0.0.1:1234")
        XCTAssertEqual(address("https://models.example.com/v1"), "https://models.example.com")
        XCTAssertEqual(address("https://example.com/llm/v1?x=1"), "https://example.com/llm")
        XCTAssertNil(address("https://"))
        XCTAssertNil(address("somewhere"))
    }

    // MARK: - A connected server

    func testTest_asksTheServerForItsModelsWithItsKey() async throws {
        let account = try await service.createOpenAICompatibleAccount(
            displayName: "LM Studio",
            baseURL: "http://127.0.0.1:1234",
            apiKey: "SERVER_KEY",
            defaultModel: "qwen-9"
        )
        let modelList = modelList
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:1234/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer SERVER_KEY")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, modelList)
        }

        let models = try await service.testConnection(accountId: account.id)

        XCTAssertEqual(models, 2)
    }

    func testChat_reachesTheFirstServerWithItsOwnKeyAndNeverAnothers() async throws {
        _ = try await service.createOpenAICompatibleAccount(
            displayName: "No key", baseURL: "http://127.0.0.1:1234", apiKey: nil, defaultModel: "qwen-9"
        )
        _ = try await service.createOpenAICompatibleAccount(
            displayName: "Keyed", baseURL: "https://models.example.com", apiKey: "OTHER_SERVERS_KEY", defaultModel: "big-9"
        )

        let server = try XCTUnwrap(ProviderAccountService.openAICompatibleServer())

        XCTAssertEqual(server.baseURL.absoluteString, "http://127.0.0.1:1234")
        XCTAssertNil(server.apiKey)
        XCTAssertNotNil(LLMConfiguration.makeDefaultClients()["openai_compatible"])
    }

    func testRouting_seesTheModelChosenForTheFirstServerOnly() async throws {
        _ = try await service.createOpenAICompatibleAccount(
            displayName: "First", baseURL: "http://127.0.0.1:1234", apiKey: nil, defaultModel: "phi-9"
        )
        _ = try await service.createOpenAICompatibleAccount(
            displayName: "Second", baseURL: "http://127.0.0.1:8080", apiKey: nil, defaultModel: "other-9"
        )
        let modelList = modelList
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:1234/v1/models")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, modelList)
        }

        let connected = try await service.loadAllModelDescriptors().filter { $0.providerID == "openai_compatible" }
        UserDefaults.standard.set("qwen-9", forKey: modelKey)
        let chosenInSettings = try await service.loadAllModelDescriptors().filter { $0.providerID == "openai_compatible" }

        XCTAssertEqual(connected.map(\.modelID), ["phi-9"])
        XCTAssertEqual(chosenInSettings.map(\.modelID), ["qwen-9"])
    }

    func testReply_isReportedAsTheServersNotOpenClaws() async throws {
        let body = Data(#"{"choices": [{"message": {"role": "assistant", "content": "Hi"}}], "model": "qwen-9"}"#.utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:1234/v1/chat/completions")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
        let client = try OpenClawLLMClient(
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:1234")),
            providerID: "openai_compatible",
            providerName: "OpenAI-compatible server",
            urlSession: URLSession(configuration: config)
        )

        let reply = try await client.completeChat(
            messages: [LLMMessage(role: .user, content: "Hi")],
            model: "qwen-9",
            options: ChatOptions(temperature: 0.3, maxTokens: nil, stream: false)
        )

        XCTAssertEqual(reply.providerID, "openai_compatible")
        XCTAssertEqual(reply.message.content, "Hi")
    }
}

/// Answers each address with what the test gave it, and nothing else.
private struct FakeTransport: LocalProviderProbeTransport {
    let answers: [String: LocalProviderProbeOutcome]

    func probe(url: URL, bearerToken _: String?, timeout _: TimeInterval) async -> LocalProviderProbeOutcome {
        answers[url.absoluteString] ?? .unavailable
    }
}
