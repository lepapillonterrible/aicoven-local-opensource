import XCTest
@testable import AICoven

final class ProviderCredentialStorageTests: XCTestCase {
    override func tearDown() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: UserScope.scopedKey("provider_accounts.v1"))
        for key in ["openai_api_key", "anthropic_api_key", "gemini_api_key", "openclaw_api_key", "hermes_api_key", "together_api_key"] {
            defaults.removeObject(forKey: UserScope.scopedKey(key))
        }
        KeychainHelper.delete(key: "provider-account-hermes-test")
        KeychainHelper.delete(key: "provider-account-together-test")
        super.tearDown()
    }

    func testLLMConfigurationIgnoresLegacyUserDefaultsAPIKeyMirrors() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: UserScope.scopedKey("provider_accounts.v1"))
        defaults.set("PLAINTEXT_LEGACY_KEY", forKey: UserScope.scopedKey("openai_api_key"))

        let clients = LLMConfiguration.makeDefaultClients()

        XCTAssertNil(clients["openai"], "Raw API keys in UserDefaults must not configure LLM clients")
    }

    func testClearLegacyAPIKeyCacheRemovesKnownSecretMirrors() {
        let defaults = UserDefaults.standard
        defaults.set("OPENAI", forKey: UserScope.scopedKey("openai_api_key"))
        defaults.set("ANTHROPIC", forKey: UserScope.scopedKey("anthropic_api_key"))
        defaults.set("GEMINI", forKey: UserScope.scopedKey("gemini_api_key"))
        defaults.set("OPENCLAW", forKey: UserScope.scopedKey("openclaw_api_key"))
        defaults.set("HERMES", forKey: UserScope.scopedKey("hermes_api_key"))
        defaults.set("TOGETHER", forKey: UserScope.scopedKey("together_api_key"))

        for provider in ["openai", "anthropic", "gemini", "openclaw", "hermes"] {
            ProviderAccountService.clearLegacyAPIKeyCache(provider: provider)
        }

        XCTAssertNil(defaults.string(forKey: UserScope.scopedKey("openai_api_key")))
        XCTAssertNil(defaults.string(forKey: UserScope.scopedKey("anthropic_api_key")))
        XCTAssertNil(defaults.string(forKey: UserScope.scopedKey("gemini_api_key")))
        XCTAssertNil(defaults.string(forKey: UserScope.scopedKey("openclaw_api_key")))
        XCTAssertNil(defaults.string(forKey: UserScope.scopedKey("hermes_api_key")))
        XCTAssertNil(defaults.string(forKey: UserScope.scopedKey("together_api_key")))
    }

    func testHermesTogetherProviderAliasesResolveBidirectionallyFromKeychain() throws {
        let defaults = UserDefaults.standard
        let now = Date()
        let hermesAccount = LocalProviderAccount(
            id: "hermes-test",
            provider: "hermes",
            displayName: "Hermes",
            scopes: ["chat"],
            defaultModel: nil,
            baseURL: nil,
            status: "healthy",
            createdAt: now
        )
        let togetherAccount = LocalProviderAccount(
            id: "together-test",
            provider: "together",
            displayName: "Together",
            scopes: ["chat"],
            defaultModel: nil,
            baseURL: nil,
            status: "healthy",
            createdAt: now
        )

        try KeychainHelper.save(key: "provider-account-hermes-test", value: "HERMES_KEY")
        try KeychainHelper.save(key: "provider-account-together-test", value: "TOGETHER_KEY")

        defaults.set(try JSONEncoder().encode([hermesAccount]), forKey: UserScope.scopedKey("provider_accounts.v1"))
        XCTAssertEqual(ProviderAccountService.apiKeyFromKeychain(forProvider: "together"), "HERMES_KEY")

        defaults.set(try JSONEncoder().encode([togetherAccount]), forKey: UserScope.scopedKey("provider_accounts.v1"))
        XCTAssertEqual(ProviderAccountService.apiKeyFromKeychain(forProvider: "hermes"), "TOGETHER_KEY")
    }

    func testProviderSpecificMissingKeyErrorDescriptionsAreNotOpenAISpecific() {
        let anthropicDescription = LocalChatError.missingAPIKey(provider: "Anthropic").localizedDescription
        let geminiDescription = LocalChatError.missingAPIKey(provider: "Gemini").localizedDescription

        XCTAssertTrue(anthropicDescription.contains("Anthropic"))
        XCTAssertTrue(geminiDescription.contains("Gemini"))
        XCTAssertFalse(anthropicDescription.contains("OpenAI"))
        XCTAssertFalse(geminiDescription.contains("OpenAI"))
    }
}
