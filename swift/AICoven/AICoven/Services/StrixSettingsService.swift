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

    /// Who is signed in, asked each time it matters.
    private let signedIn: @Sendable () async -> String
    /// The first of the person's connections, for what Strix runs on
    /// where nothing is stored yet.
    private let firstConnection: @Sendable () async -> (provider: String, defaultModel: String?)?

    /// The key each account's Strix settings are kept under.
    private static func storageKey(for account: String) -> String {
        UserScope.scopedKey("strix_settings.v1", for: account)
    }

    /// The service as the app uses it; tests give it who is signed in and
    /// the first connection.
    init(
        signedIn: @escaping @Sendable () async -> String = { await MainActor.run { UserScope.currentUserID } },
        firstConnection: (@Sendable () async -> (provider: String, defaultModel: String?)?)? = nil
    ) {
        self.signedIn = signedIn
        self.firstConnection = firstConnection ?? {
            do {
                guard let first = try await ProviderAccountService.shared.loadProviderAccounts().first else { return nil }
                return (provider: first.provider, defaultModel: first.defaultModel)
            } catch {
                AppErrorReporter.log(error: error, context: "StrixSettingsService.firstConnection")
                return nil
            }
        }
    }

    /// Load the current personal Strix config, creating a default if needed.
    /// Returns the settings as the agent form and Strix's Agents page show them.
    /// Note: Does NOT set hardcoded defaults - provider/model are derived from
    /// configured provider accounts or left nil if none are configured.
    ///
    /// They are the settings of the account signed in when this is asked,
    /// read and kept under that account's own key: if another is signed in
    /// by the time the connections have been looked up, nothing is kept
    /// and nothing is given (`RepositoryError.accountChanged`).
    func loadPersonalStrix() async throws -> LocalStrixSettings {
        let account = await signedIn()
        var settings = loadLocalSettings(of: account)

        // Only apply defaults if provider/model are not set AND user has
        // configured provider accounts. This avoids showing "gpt-4o" when
        // the user only has a Gemini key configured.
        // Hermes, and a model on this device, name no model here: there
        // is none to look up for them.
        let namesNoModel = ["hermes", "mlx"].contains(settings.provider?.lowercased() ?? "")
        if settings.provider == nil || (settings.model == nil && !namesNoModel) {
            let defaultProvider = await firstConnection()
            // The connections looked up are those of whoever is signed in
            // now: they are not one account's to keep for another.
            guard await signedIn() == account else { throw RepositoryError.accountChanged }
            if let defaultProvider {
                if settings.provider == nil {
                    settings.provider = defaultProvider.provider
                }
                // A model is taken only from a connection of the provider
                // Strix runs on: another provider's model is not its model.
                if settings.model == nil, defaultProvider.provider.lowercased() == settings.provider?.lowercased() {
                    settings.model = defaultProvider.defaultModel
                }
                // Persist any backfilled defaults
                saveLocalSettings(settings, for: account)
            }
        }

        // Keep ChatService in sync with current settings
        updateLLMDefaults(from: settings, for: account)

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
        guard let data = UserDefaults.standard.data(forKey: storageKey(for: account)) else { return nil }
        return try? JSONDecoder().decode(LocalStrixSettings.self, from: data)
    }

    /// Saves Strix as the agent form shows it, as the account that pressed
    /// Save: its instructions (emptied ones are cleared), what it runs
    /// on, and of the settings under Advanced those the form showed (nil
    /// leaves what is stored). Nothing is saved if another account is
    /// signed in by now, or for what is not something to save.
    func save(_ strix: AgentSaving, as account: String) async throws -> LocalStrixSettings {
        guard let strix = strix.storable else { throw CovenRepositoryError.agentIncomplete }
        guard await signedIn() == account else { throw RepositoryError.accountChanged }
        var settings = loadLocalSettings(of: account)
        // Instructions that say nothing are none.
        settings.systemPrompt = strix.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : strix.instructions
        if !strix.provider.isEmpty {
            settings.provider = strix.provider
            settings.model = strix.model.isEmpty ? nil : strix.model
            settings.providerAccountId = strix.providerAccountId
        }
        if let temperature = strix.temperature { settings.temperature = temperature }
        if let maxTokens = strix.maxTokens { settings.maxTokens = maxTokens }
        if let mostSteps = strix.mostSteps { settings.autonomousMaxSteps = mostSteps }
        // Asked again, with nothing waited for until the write, which is
        // under that account's own key.
        guard await signedIn() == account else { throw RepositoryError.accountChanged }
        saveLocalSettings(settings, for: account)
        updateLLMDefaults(from: settings, for: account)
        return settings
    }

    /// Update the current personal Strix configuration and return the
    /// settings as they are then stored.
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
        let account = await signedIn()
        var settings = loadLocalSettings(of: account)
        settings.systemPrompt = systemPrompt
        settings.model = model
        settings.provider = provider
        settings.providerAccountId = providerAccountId
        settings.autonomousMode = autonomousMode
        settings.autonomousMaxSteps = autonomousMaxSteps
        settings.plannerMaxTasks = plannerMaxTasks
        settings.plannerMaxSeconds = plannerMaxSeconds

        saveLocalSettings(settings, for: account)
        updateLLMDefaults(from: settings, for: account)

        return settings
    }

    // MARK: - Private helpers

    private func loadLocalSettings(of account: String) -> LocalStrixSettings {
        // The settings can still name Hermes for what is now a server: read
        // after that is put right, or a load in flight would save it back.
        ProviderAccountService.convertHermesModelConnectionsIfNeeded()
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: Self.storageKey(for: account)) else {
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

    private func saveLocalSettings(_ settings: LocalStrixSettings, for account: String) {
        do {
            let data = try JSONEncoder().encode(settings)
            UserDefaults.standard.set(data, forKey: Self.storageKey(for: account))
        } catch {
            AppErrorReporter.log(error: error, context: "StrixSettingsService.saveLocalSettings.encode")
        }
    }

    /// Keep ChatService's simple provider/model shims in sync so that
    /// `resolveProviderAndModel()` respects the Strix configuration.
    private func updateLLMDefaults(from settings: LocalStrixSettings, for account: String) {
        let defaults = UserDefaults.standard
        if let provider = settings.provider?.lowercased() {
            defaults.set(provider, forKey: UserScope.scopedKey("llm_provider", for: account))
            if let model = settings.model {
                // Each under the key `ChatService.resolveProviderAndModel`
                // reads that provider's model from.
                switch provider {
                case "google", "gemini":
                    defaults.set(model, forKey: UserScope.scopedKey("gemini_model", for: account))
                case "hermes", "mlx":
                    // Hermes uses the model it is set up with, and a model
                    // on this device is the one made active in its own
                    // settings: there is none to keep here.
                    break
                default:
                    defaults.set(model, forKey: UserScope.scopedKey("\(provider)_model", for: account))
                }
            }
        }
    }

}
