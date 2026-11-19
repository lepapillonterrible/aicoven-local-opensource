import Foundation

/// Local representation of the personal Strix configuration stored on this
/// device. This mirrors only the fields the Swift client actually uses.
struct LocalStrixSettings: Codable {
    var systemPrompt: String?
    var model: String?
    var provider: String?
    var providerAccountId: String?
    var autonomousMode: Bool?
    var autonomousMaxSteps: Int?
    var plannerMaxTasks: Int?
    var plannerMaxSeconds: Double?
}

/// Service for managing the personal Strix assistant configuration in the
/// local-first client. Settings are stored in UserDefaults, and we also mirror
/// provider/model into simple keys that ChatService already understands
/// (llm_provider + per-provider model keys).
actor StrixSettingsService {
    static let shared = StrixSettingsService()

    /// User-scoped storage key so each Firebase user gets their own Strix config.
    private var storageKey: String {
        UserScope.scopedKey("strix_settings.v1")
    }

    private init() {}

    /// Load the current personal Strix config, creating a default if needed.
    /// Returns the normalized local settings used by StrixSettingsView.
    /// Note: Does NOT set hardcoded defaults - provider/model are derived from
    /// configured provider accounts or left nil if none are configured.
    func loadPersonalStrix() async throws -> LocalStrixSettings {
        var settings = loadLocalSettings()

        // Only apply defaults if provider/model are not set AND user has
        // configured provider accounts. This avoids showing "gpt-4o" when
        // the user only has a Gemini key configured.
        if settings.provider == nil || settings.model == nil {
            if let defaultProvider = await getFirstConfiguredProvider() {
                if settings.provider == nil {
                    settings.provider = defaultProvider.provider
                }
                if settings.model == nil {
                    settings.model = defaultProvider.defaultModel
                }
                // Persist any backfilled defaults
                saveLocalSettings(settings)
            }
        }

        // Keep ChatService in sync with current settings
        updateLLMDefaults(from: settings)

        return settings
    }

    /// Returns the first configured provider account (if any) to use as default.
    private func getFirstConfiguredProvider() async -> (provider: String, defaultModel: String?)? {
        do {
            let accounts = try await ProviderAccountService.shared.loadProviderAccounts()
            guard let first = accounts.first else { return nil }
            return (provider: first.provider, defaultModel: first.defaultModel)
        } catch {
            AppErrorReporter.log(error: error, context: "StrixSettingsService.getFirstConfiguredProvider")
            return nil
        }
    }

    /// Update the current personal Strix configuration and return the
    /// normalized local settings used by StrixSettingsView.
    func updatePersonalStrix(
        systemPrompt: String?,
        model: String?,
        provider: String?,
        providerAccountId: String?,
        autonomousMode: Bool?,
        autonomousMaxSteps: Int?,
        plannerMaxTasks: Int?,
        plannerMaxSeconds: Double?
    ) async throws -> LocalStrixSettings {
        var settings = loadLocalSettings()
        settings.systemPrompt = systemPrompt
        settings.model = model
        settings.provider = provider
        settings.providerAccountId = providerAccountId
        settings.autonomousMode = autonomousMode
        settings.autonomousMaxSteps = autonomousMaxSteps
        settings.plannerMaxTasks = plannerMaxTasks
        settings.plannerMaxSeconds = plannerMaxSeconds

        saveLocalSettings(settings)
        updateLLMDefaults(from: settings)

        return settings
    }

    // MARK: - Private helpers

    private func loadLocalSettings() -> LocalStrixSettings {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: storageKey) else {
            return LocalStrixSettings(
                systemPrompt: nil,
                model: nil,
                provider: nil,
                providerAccountId: nil,
                autonomousMode: nil,
                autonomousMaxSteps: nil,
                plannerMaxTasks: nil,
                plannerMaxSeconds: nil
            )
        }
        do {
            return try JSONDecoder().decode(LocalStrixSettings.self, from: data)
        } catch {
            AppErrorReporter.log(error: error, context: "StrixSettingsService.loadLocalSettings.decode")
            return LocalStrixSettings(
                systemPrompt: nil,
                model: nil,
                provider: nil,
                providerAccountId: nil,
                autonomousMode: nil,
                autonomousMaxSteps: nil,
                plannerMaxTasks: nil,
                plannerMaxSeconds: nil
            )
        }
    }

    private func saveLocalSettings(_ settings: LocalStrixSettings) {
        do {
            let data = try JSONEncoder().encode(settings)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            AppErrorReporter.log(error: error, context: "StrixSettingsService.saveLocalSettings.encode")
        }
    }

    /// Keep ChatService's simple provider/model shims in sync so that
    /// `resolveProviderAndModel()` respects the Strix configuration.
    private func updateLLMDefaults(from settings: LocalStrixSettings) {
        let defaults = UserDefaults.standard
        if let provider = settings.provider?.lowercased() {
            defaults.set(provider, forKey: UserScope.scopedKey("llm_provider"))
            if let model = settings.model {
                switch provider {
                case "anthropic":
                    defaults.set(model, forKey: UserScope.scopedKey("anthropic_model"))
                case "google", "gemini":
                    defaults.set(model, forKey: UserScope.scopedKey("gemini_model"))
                case "openrouter", "openai_compatible":
                    defaults.set(model, forKey: UserScope.scopedKey("\(provider)_model"))
                default:
                    defaults.set(model, forKey: UserScope.scopedKey("openai_model"))
                }
            }
        }
    }

}
