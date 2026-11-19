@testable import AICoven
internal import Combine
import XCTest

/// The AI connections list and the account store behind it, against the
/// real store with the provider's answers stubbed.
@MainActor
final class AIConnectionsTests: XCTestCase {
    private let accountsKey = UserScope.scopedKey("provider_accounts.v1")
    private let hermesAddressKey = UserScope.scopedKey("hermes_base_url")
    private var savedAccounts: Any?
    private var savedHermesAddress: Any?
    private let service = ProviderAccountService.shared
    private let status = HTTPStatus(200)

    override func setUp() {
        super.setUp()
        savedAccounts = UserDefaults.standard.object(forKey: accountsKey)
        savedHermesAddress = UserDefaults.standard.object(forKey: hermesAddressKey)
        let status = status
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status.value, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"data": [{"id": "gpt-9"}, {"id": "gpt-9-mini"}]}"#.utf8))
        }
    }

    override func tearDown() {
        UserDefaults.standard.set(savedAccounts, forKey: accountsKey)
        UserDefaults.standard.set(savedHermesAddress, forKey: hermesAddressKey)
        KeychainHelper.delete(key: "provider-account-openai-test")
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - The store

    func testTest_failsOnARefusedKeyAndRecordsTheOutcomeAsTheStatus() async throws {
        try store([openAIAccount()], key: "STORED_KEY")

        status.value = 401
        do {
            try await service.testConnection(accountId: "openai-test")
            XCTFail("A refused key must fail the test")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("OpenAI models HTTP 401"))
        }
        let afterRefusal = try await service.loadProviderAccounts().first
        XCTAssertEqual(afterRefusal?.status, "unhealthy")

        status.value = 200
        let models = try await service.testConnection(accountId: "openai-test")
        let afterSuccess = try await service.loadProviderAccounts().first
        XCTAssertEqual(models, 2)
        XCTAssertEqual(afterSuccess?.status, "healthy")
    }

    func testTest_doesNotRecordAnOutcomeForAKeyReplacedWhileTheProviderAnswered() async throws {
        try store([openAIAccount()], key: "STORED_KEY")
        MockURLProtocol.handler = { request in
            // The person saves another key before the old one is refused.
            try KeychainHelper.save(key: "provider-account-openai-test", value: "NEW_KEY")
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }

        _ = try? await service.testConnection(accountId: "openai-test")

        let account = try await service.loadProviderAccounts().first
        XCTAssertEqual(account?.status, "healthy")
    }

    func testEdit_anEmptyAddressClearsTheStoredOne() async throws {
        let hermes = LocalProviderAccount(
            id: "hermes-test",
            provider: "hermes",
            displayName: "Hermes",
            scopes: ["chat"],
            defaultModel: nil,
            baseURL: "http://localhost:8642",
            status: "healthy",
            createdAt: Date()
        )
        try store([hermes])

        try await service.updateProviderAccount(id: "hermes-test", displayName: "Renamed")
        let renamed = try await service.loadProviderAccounts().first
        XCTAssertEqual(renamed?.baseURL, "http://localhost:8642")

        try await service.updateProviderAccount(id: "hermes-test", baseURL: "http://localhost:9000")
        XCTAssertEqual(UserDefaults.standard.string(forKey: hermesAddressKey), "http://localhost:9000")

        try await service.updateProviderAccount(id: "hermes-test", baseURL: "")
        let cleared = try await service.loadProviderAccounts().first
        XCTAssertEqual(cleared?.displayName, "Renamed")
        XCTAssertNil(cleared?.baseURL)
        // The chat client reads the address from here.
        XCTAssertNil(UserDefaults.standard.object(forKey: hermesAddressKey))
    }

    // MARK: - The list

    func testTest_showsTheFailureThenReturnsToRest() async throws {
        try store([openAIAccount()], key: "STORED_KEY")
        status.value = 401
        let viewModel = ProviderKeysViewModel(testResultDisplayDuration: .milliseconds(20))
        await viewModel.loadProviderAccounts()
        let listed = try XCTUnwrap(viewModel.providerAccounts.first)

        await viewModel.testConnection(for: listed)

        guard case let .failure(message) = viewModel.testActionState(for: listed) else {
            return XCTFail("The test must show its failure")
        }
        XCTAssertTrue(message.hasPrefix("OpenAI models HTTP 401"))
        XCTAssertEqual(viewModel.providerAccounts.first?.status, "unhealthy")

        let atRest = expectation(description: "The button reads Test again")
        let watching = viewModel.$testActionStates.sink { states in
            if states[listed.id] == nil { atRest.fulfill() }
        }
        await fulfillment(of: [atRest], timeout: 5)
        watching.cancel()
    }

    func testTest_saysHowManyModelsAndShowsTheStatusItRecorded() async throws {
        try store([openAIAccount(status: "unhealthy")], key: "STORED_KEY")
        let viewModel = ProviderKeysViewModel()
        await viewModel.loadProviderAccounts()
        let listed = try XCTUnwrap(viewModel.providerAccounts.first)

        await viewModel.testConnection(for: listed)

        XCTAssertEqual(viewModel.testActionState(for: listed), .success(message: "Connected. 2 models."))
        XCTAssertEqual(viewModel.providerAccounts.first?.status, "healthy")
    }

    func testDelete_removesTheAccountAndAFailedDeleteSaysWhy() async throws {
        try store([openAIAccount()], key: "STORED_KEY")
        let viewModel = ProviderKeysViewModel()
        await viewModel.loadProviderAccounts()
        let listed = try XCTUnwrap(viewModel.providerAccounts.first)

        await viewModel.deleteAccount(listed)
        XCTAssertTrue(viewModel.providerAccounts.isEmpty)
        XCTAssertNil(viewModel.lastErrorMessage)
        XCTAssertNil(KeychainHelper.load(key: "provider-account-openai-test"))

        // It is gone, so deleting it again fails.
        await viewModel.deleteAccount(listed)
        XCTAssertNotNil(viewModel.lastErrorMessage)
    }

    func testDeleteMessage_saysAnOpenRouterKeyStaysActiveAtOpenRouter() {
        let openAI = ProviderAccount(from: openAIAccount())
        let openRouter = ProviderAccount(from: openAIAccount(provider: "openrouter"))

        XCTAssertFalse(ProviderKeysViewModel.deleteMessage(for: openAI).contains("OpenRouter"))
        XCTAssertTrue(ProviderKeysViewModel.deleteMessage(for: openRouter).contains("stays active in your OpenRouter account"))
    }

    // MARK: - Helpers

    private func openAIAccount(provider: String = "openai", status: String = "healthy") -> LocalProviderAccount {
        LocalProviderAccount(
            id: "openai-test",
            provider: provider,
            displayName: "OpenAI",
            scopes: ["chat"],
            defaultModel: nil,
            baseURL: nil,
            status: status,
            createdAt: Date()
        )
    }

    private func store(_ accounts: [LocalProviderAccount], key: String? = nil) throws {
        try UserDefaults.standard.set(JSONEncoder().encode(accounts), forKey: accountsKey)
        if let key {
            try KeychainHelper.save(key: "provider-account-openai-test", value: key)
        }
    }
}

/// The status the stubbed provider answers with. The URL loading system
/// reads it on its own thread, so every access takes the lock.
private final class HTTPStatus: @unchecked Sendable {
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
