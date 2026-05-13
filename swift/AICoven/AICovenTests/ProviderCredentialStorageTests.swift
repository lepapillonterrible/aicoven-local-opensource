import XCTest
@testable import AICoven

final class ProviderCredentialStorageTests: XCTestCase {
    override func tearDown() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: UserScope.scopedKey("provider_accounts.v1"))
        for key in ["openai_api_key", "anthropic_api_key", "gemini_api_key", "openclaw_api_key", "hermes_api_key", "together_api_key"] {
            defaults.removeObject(forKey: UserScope.scopedKey(key))
        }
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
}
