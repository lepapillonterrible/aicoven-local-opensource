@testable import AICoven
import XCTest

/// A connection made for Hermes models becomes an OpenAI-compatible server,
/// once, and keeps its key and its model.
final class HermesModelConnectionsTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private let keys = [
        "provider_accounts.v1", "hermes_model_connections_converted.v1", "hermes_model", "hermes_base_url",
        "openai_compatible_model", "llm_provider", "strix_settings.v1",
    ]

    override func setUp() {
        super.setUp()
        clear()
    }

    override func tearDown() {
        clear()
        KeychainHelper.delete(key: "provider-account-hermes-test")
        super.tearDown()
    }

    private func clear() {
        for key in keys {
            defaults.removeObject(forKey: UserScope.scopedKey(key))
        }
    }

    private func account(_ id: String, provider: String, baseURL: String? = nil, model: String? = nil) -> LocalProviderAccount {
        LocalProviderAccount(
            id: id, provider: provider, displayName: "Mine", scopes: ["chat"],
            defaultModel: model, baseURL: baseURL, status: "healthy", createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func store(_ accounts: [LocalProviderAccount]) throws {
        try defaults.set(JSONEncoder().encode(accounts), forKey: UserScope.scopedKey("provider_accounts.v1"))
    }

    private func stored() throws -> [LocalProviderAccount] {
        let data = try XCTUnwrap(defaults.data(forKey: UserScope.scopedKey("provider_accounts.v1")))
        return try JSONDecoder().decode([LocalProviderAccount].self, from: data)
    }

    func testATogetherConnection_becomesAServerAtTogetherWithItsKeyAndTheModelTogetherKnows() throws {
        try store([account("hermes-test", provider: "hermes")])
        try KeychainHelper.save(key: "provider-account-hermes-test", value: "TOGETHER_KEY")
        defaults.set("hermes-3-70b", forKey: UserScope.scopedKey("hermes_model"))
        defaults.set("hermes", forKey: UserScope.scopedKey("llm_provider"))
        try defaults.set(
            JSONEncoder().encode(LocalStrixSettings(model: "hermes-3-70b", provider: "hermes")),
            forKey: UserScope.scopedKey("strix_settings.v1")
        )

        ProviderAccountService.convertHermesModelConnectionsIfNeeded()

        let converted = try XCTUnwrap(stored().first)
        XCTAssertEqual(converted.id, "hermes-test")
        XCTAssertEqual(converted.provider, "openai_compatible")
        XCTAssertEqual(converted.baseURL, "https://api.together.xyz")
        XCTAssertEqual(converted.defaultModel, "NousResearch/Hermes-3-Llama-3.1-70B")
        XCTAssertEqual(converted.displayName, "Mine")
        // The server the app now uses, with the key the connection had.
        let server = try XCTUnwrap(ProviderAccountService.openAICompatibleServer())
        XCTAssertEqual(server.baseURL.absoluteString, "https://api.together.xyz")
        XCTAssertEqual(server.apiKey, "TOGETHER_KEY")
        XCTAssertEqual(defaults.string(forKey: UserScope.scopedKey("openai_compatible_model")), "NousResearch/Hermes-3-Llama-3.1-70B")
        XCTAssertEqual(defaults.string(forKey: UserScope.scopedKey("llm_provider")), "openai_compatible")
        let settingsData = try XCTUnwrap(defaults.data(forKey: UserScope.scopedKey("strix_settings.v1")))
        let settings = try JSONDecoder().decode(LocalStrixSettings.self, from: settingsData)
        XCTAssertEqual(settings.provider, "openai_compatible")
        XCTAssertEqual(settings.model, "NousResearch/Hermes-3-Llama-3.1-70B")
        XCTAssertNil(defaults.string(forKey: UserScope.scopedKey("hermes_model")))
    }

    func testAConnectionToTheirOwnServer_keepsItsAddressAndTheModelAsTheyNamedIt() throws {
        try store([account("hermes-test", provider: "hermes", baseURL: "http://127.0.0.1:8080", model: "hermes-3")])

        ProviderAccountService.convertHermesModelConnectionsIfNeeded()

        let converted = try XCTUnwrap(stored().first)
        XCTAssertEqual(converted.provider, "openai_compatible")
        XCTAssertEqual(converted.baseURL, "http://127.0.0.1:8080")
        XCTAssertEqual(converted.defaultModel, "hermes-3")
    }

    func testAServerConnectedBefore_keepsItsPlaceAndItsModelWhereverItWasListed() throws {
        try store([
            account("hermes-test", provider: "together"),
            account("server", provider: "openai_compatible", baseURL: "http://127.0.0.1:1234", model: "qwen"),
            account("claude", provider: "anthropic"),
        ])
        defaults.set("qwen", forKey: UserScope.scopedKey("openai_compatible_model"))
        defaults.set("hermes", forKey: UserScope.scopedKey("llm_provider"))

        ProviderAccountService.convertHermesModelConnectionsIfNeeded()

        let accounts = try stored()
        XCTAssertEqual(accounts.map(\.id), ["server", "hermes-test", "claude"], "The converted connection goes just after the earlier server")
        XCTAssertEqual(ProviderAccountService.openAICompatibleServer()?.baseURL.absoluteString, "http://127.0.0.1:1234")
        XCTAssertEqual(defaults.string(forKey: UserScope.scopedKey("openai_compatible_model")), "qwen")
        XCTAssertEqual(defaults.string(forKey: UserScope.scopedKey("llm_provider")), "openai_compatible")
    }

    func testAConvertedConnection_staysWhereItWasListedAmongTheOtherProviders() throws {
        try store([
            account("hermes-test", provider: "hermes", baseURL: "http://127.0.0.1:8080", model: "local-hermes"),
            account("ollama", provider: "ollama", model: "qwen"),
        ])

        ProviderAccountService.convertHermesModelConnectionsIfNeeded()

        XCTAssertEqual(try stored().map(\.id), ["hermes-test", "ollama"], "What comes first among the providers does not change")
    }

    func testWhereHermesWasChosenAndAServerWasConnectedBefore_thatServersOwnModelIsChosen() async throws {
        try store([
            account("hermes-test", provider: "hermes"),
            account("ollama", provider: "ollama", model: "qwen"),
            account("server", provider: "openai_compatible", baseURL: "http://127.0.0.1:1234", model: "llama"),
        ])
        try defaults.set(JSONEncoder().encode(LocalStrixSettings(provider: "hermes")), forKey: UserScope.scopedKey("strix_settings.v1"))

        let settings = try await StrixSettingsService.shared.loadPersonalStrix()

        XCTAssertEqual(try stored().map(\.id), ["ollama", "server", "hermes-test"])
        XCTAssertEqual(settings.provider, "openai_compatible")
        XCTAssertEqual(settings.model, "llama", "Not the first connection's model, and not the converted one's")
        XCTAssertEqual(defaults.string(forKey: UserScope.scopedKey("openai_compatible_model")), "llama")
    }

    func testATogetherAddressGivenInFull_stillGetsTheModelNameTogetherKnows() throws {
        try store([account("hermes-test", provider: "hermes", baseURL: "https://api.together.xyz", model: "hermes-3-70b")])

        ProviderAccountService.convertHermesModelConnectionsIfNeeded()

        XCTAssertEqual(try stored().first?.defaultModel, "NousResearch/Hermes-3-Llama-3.1-70B")
    }

    func testSettingsLoadedWhileHermesIsStillChosen_comeBackWithTheServerChosen() async throws {
        try store([account("hermes-test", provider: "hermes", baseURL: "http://127.0.0.1:8080", model: "local-hermes")])
        try defaults.set(JSONEncoder().encode(LocalStrixSettings(provider: "hermes")), forKey: UserScope.scopedKey("strix_settings.v1"))
        defaults.set("hermes", forKey: UserScope.scopedKey("llm_provider"))

        let settings = try await StrixSettingsService.shared.loadPersonalStrix()

        XCTAssertEqual(settings.provider, "openai_compatible")
        XCTAssertEqual(settings.model, "local-hermes")
        XCTAssertEqual(defaults.string(forKey: UserScope.scopedKey("llm_provider")), "openai_compatible")
    }

    func testReadersThatConvertAtTheSameTime_leaveOneConversion() throws {
        try store([account("hermes-test", provider: "hermes")])
        defaults.set("hermes-3-8b", forKey: UserScope.scopedKey("hermes_model"))

        DispatchQueue.concurrentPerform(iterations: 40) { _ in
            _ = ProviderAccountService.openAICompatibleServer()
        }

        let accounts = try stored()
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.defaultModel, "NousResearch/Hermes-3-Llama-3.1-8B", "A second reader did not convert again from half-changed state")
    }

    func testTheConversion_happensOnceSoALaterHermesConnectionIsLeftAsItIs() throws {
        try store([account("claude", provider: "anthropic")])
        ProviderAccountService.convertHermesModelConnectionsIfNeeded()

        // Connected after: a Hermes agent, not Hermes models.
        try store([account("agent", provider: "hermes", baseURL: "http://127.0.0.1:8642")])
        ProviderAccountService.convertHermesModelConnectionsIfNeeded()
        _ = ProviderAccountService.openAICompatibleServer()

        XCTAssertEqual(try stored().map(\.provider), ["hermes"])
    }

    func testReadingTheConnections_convertsFirst() throws {
        try store([account("hermes-test", provider: "hermes", baseURL: "http://127.0.0.1:8080")])

        let server = ProviderAccountService.openAICompatibleServer()

        XCTAssertEqual(server?.baseURL.absoluteString, "http://127.0.0.1:8080")
    }
}
