@testable import AICoven
import XCTest

@MainActor
final class AIConnectionsTests: XCTestCase {
    private let accountsKey = "provider_accounts.v1"
    private var savedAccounts: Any?

    override func setUp() {
        super.setUp()
        savedAccounts = UserDefaults.standard.object(forKey: UserScope.scopedKey(accountsKey))
    }

    override func tearDown() {
        UserDefaults.standard.set(savedAccounts, forKey: UserScope.scopedKey(accountsKey))
        KeychainHelper.delete(key: "provider-account-openai-test")
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - The service's Test

    func testTest_failsOnARefusedKeyAndRecordsTheOutcomeAsTheStatus() async throws {
        let stored = LocalProviderAccount(
            id: "openai-test",
            provider: "openai",
            displayName: "OpenAI",
            scopes: ["chat"],
            defaultModel: nil,
            baseURL: nil,
            status: "healthy",
            createdAt: Date()
        )
        try UserDefaults.standard.set(JSONEncoder().encode([stored]), forKey: UserScope.scopedKey(accountsKey))
        try KeychainHelper.save(key: "provider-account-openai-test", value: "STORED_KEY")
        let status = HTTPStatus(401)
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status.value, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"data": [{"id": "gpt-9"}, {"id": "gpt-9-mini"}]}"#.utf8))
        }
        let service = ProviderAccountService.shared

        do {
            try await service.testConnection(accountId: "openai-test")
            XCTFail("A refused key must fail the test")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("OpenAI models HTTP 401"))
        }
        let afterRefusal = try await service.loadProviderAccounts().first { $0.id == "openai-test" }
        XCTAssertEqual(afterRefusal?.status, "unhealthy")

        status.value = 200
        let models = try await service.testConnection(accountId: "openai-test")
        let afterSuccess = try await service.loadProviderAccounts().first { $0.id == "openai-test" }
        XCTAssertEqual(models, 2)
        XCTAssertEqual(afterSuccess?.status, "healthy")
    }

    // MARK: - The list

    func testTest_showsTheFailureThenReturnsToRest() async {
        let store = FakeAccounts(accounts: [account("a")])
        await store.failTests(with: "The key was refused")
        let viewModel = ProviderKeysViewModel(service: store, testResultDisplayDuration: .milliseconds(20))
        await viewModel.loadProviderAccounts()
        let listed = viewModel.providerAccounts[0]

        await viewModel.testConnection(for: listed)

        XCTAssertEqual(viewModel.testActionState(for: listed), .failure(message: "The key was refused"))
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(viewModel.testActionState(for: listed), .idle)
    }

    func testTest_saysHowManyModelsAndReloadsTheStatusItRecorded() async {
        let store = FakeAccounts(accounts: [account("a", status: "unhealthy")])
        let viewModel = ProviderKeysViewModel(service: store)
        await viewModel.loadProviderAccounts()

        await viewModel.testConnection(for: viewModel.providerAccounts[0])

        XCTAssertEqual(viewModel.testActionState(for: viewModel.providerAccounts[0]), .success(message: "Connected. 3 models."))
        XCTAssertEqual(viewModel.providerAccounts[0].status, "healthy")
    }

    func testDelete_removesTheAccountAndAFailedDeleteKeepsItAndSaysWhy() async {
        let store = FakeAccounts(accounts: [account("a"), account("b")])
        let viewModel = ProviderKeysViewModel(service: store)
        await viewModel.loadProviderAccounts()

        await viewModel.deleteAccount(viewModel.providerAccounts[0])
        XCTAssertEqual(viewModel.providerAccounts.map(\.id), ["b"])
        XCTAssertNil(viewModel.lastErrorMessage)

        await store.failDeletes(with: "The disk is full")
        await viewModel.deleteAccount(viewModel.providerAccounts[0])
        XCTAssertEqual(viewModel.providerAccounts.map(\.id), ["b"])
        XCTAssertEqual(viewModel.lastErrorMessage, "The disk is full")
    }

    func testDeleteMessage_saysAnOpenRouterKeyStaysActiveAtOpenRouter() {
        XCTAssertFalse(ProviderKeysViewModel.deleteMessage(for: account("a")).contains("OpenRouter"))
        XCTAssertTrue(
            ProviderKeysViewModel.deleteMessage(for: account("b", provider: "openrouter"))
                .contains("stays active in your OpenRouter account")
        )
    }

    private func account(_ id: String, provider: String = "openai", status: String = "healthy") -> ProviderAccount {
        ProviderAccount(from: LocalProviderAccount(
            id: id,
            provider: provider,
            displayName: id,
            scopes: ["chat"],
            defaultModel: nil,
            baseURL: nil,
            status: status,
            createdAt: Date(timeIntervalSince1970: 0)
        ))
    }
}

/// An account store in memory. A test that passes records "healthy", as the
/// real one does.
private actor FakeAccounts: ProviderAccountManaging {
    private var accounts: [ProviderAccount]
    private var testFailure: String?
    private var deleteFailure: String?

    init(accounts: [ProviderAccount]) {
        self.accounts = accounts
    }

    func failTests(with message: String) {
        testFailure = message
    }

    func failDeletes(with message: String) {
        deleteFailure = message
    }

    func loadProviderAccounts() async throws -> [ProviderAccount] {
        accounts
    }

    func deleteProviderAccount(id: String) async throws {
        if let deleteFailure { throw Failure(message: deleteFailure) }
        accounts.removeAll { $0.id == id }
    }

    func testConnection(accountId: String) async throws -> Int {
        if let testFailure { throw Failure(message: testFailure) }
        accounts = accounts.map { account in
            guard account.id == accountId else { return account }
            return ProviderAccount(from: LocalProviderAccount(
                id: account.id,
                provider: account.provider,
                displayName: account.displayName,
                scopes: account.scopes,
                defaultModel: account.defaultModel,
                baseURL: account.baseURL,
                status: "healthy",
                createdAt: Date(timeIntervalSince1970: 0)
            ))
        }
        return 3
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? {
            message
        }
    }
}

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
