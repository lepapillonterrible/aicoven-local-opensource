import Foundation

/// Local representation of the personal Strix configuration stored on this
/// device. This mirrors only the fields the Swift client actually uses.
struct LocalStrixSettings: Codable {
    var systemPrompt: String?
    var model: String?
    var provider: String?
    var providerAccountId: String?
    var autonomousMode: Bool?
    /// The most tool steps of one of Strix's turns ("Most steps" in its
    /// form), under the name the cloud app keeps an agent's under.
    var autonomousMaxSteps: Int?
    var plannerMaxTasks: Int?
    var plannerMaxSeconds: Double?
    /// How freely Strix answers, and the longest its answer may be, as
    /// an agent's: none stored where the person has set none.
    var temperature: Double?
    var maxTokens: Int?
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

    /// The instructions `account` wrote for Strix, exactly as they are
    /// stored (an empty text is returned as it is); nil where none are
    /// stored or the settings cannot be read. Only read: nothing is
    /// converted, defaulted or saved by asking.
    func instructions(of account: String) -> String? {
        Self.stored(of: account)?.systemPrompt
    }

    /// Strix's settings exactly as `account` has them stored; nil where
    /// none are stored or they cannot be read. Only read: nothing is
    /// converted, defaulted or saved by asking.
    nonisolated static func stored(of account: String) -> LocalStrixSettings? {
        guard let data = UserDefaults.standard.data(forKey: UserScope.scopedKey("strix_settings.v1", for: account)) else { return nil }
        return try? JSONDecoder().decode(LocalStrixSettings.self, from: data)
    }

    /// Saves Strix as the agent form shows it, as the account that pressed
    /// Save: its instructions (emptied ones are cleared), what it runs
    /// on, and of the settings under Advanced those the form showed (nil
    /// leaves what is stored). Nothing is saved if another account is
    /// signed in by now, or for what is not something to save.
    func save(_ strix: AgentSaving, as account: String) async throws -> LocalStrixSettings {
        guard let strix = strix.storable else { throw CovenRepositoryError.agentIncomplete }
        guard await MainActor.run(body: { UserScope.currentUserID }) == account else { throw RepositoryError.accountChanged }
        var settings = loadLocalSettings()
        settings.systemPrompt = strix.instructions.isEmpty ? nil : strix.instructions
        if !strix.provider.isEmpty {
            settings.provider = strix.provider
            settings.model = strix.model.isEmpty ? nil : strix.model
            settings.providerAccountId = strix.providerAccountId
        }
        if let temperature = strix.temperature { settings.temperature = temperature }
        if let maxTokens = strix.maxTokens { settings.maxTokens = maxTokens }
        if let mostSteps = strix.mostSteps { settings.autonomousMaxSteps = mostSteps }
        // Asked again, with nothing waited for until the write.
        guard await MainActor.run(body: { UserScope.currentUserID }) == account else { throw RepositoryError.accountChanged }
        saveLocalSettings(settings)
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
        // The settings can still name Hermes for what is now a server: read
        // after that is put right, or a load in flight would save it back.
        ProviderAccountService.convertHermesModelConnectionsIfNeeded()
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
                // Each under the key `ChatService.resolveProviderAndModel`
                // reads that provider's model from.
                switch provider {
                case "google", "gemini":
                    defaults.set(model, forKey: UserScope.scopedKey("gemini_model"))
                case "hermes", "mlx":
                    // Hermes uses the model it is set up with, and a model
                    // on this device is the one made active in its own
                    // settings: there is none to keep here.
                    break
                default:
                    defaults.set(model, forKey: UserScope.scopedKey("\(provider)_model"))
                }
            }
        }
    }

}
