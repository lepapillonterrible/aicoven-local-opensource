import Foundation
import Security

extension Notification.Name {
    static let providerKeysUpdated = Notification.Name("ProviderKeysUpdated")
}

/// Lightweight local representation of a provider account (BYOK).
///
/// This is the persisted form stored on disk/UserDefaults. It deliberately
/// omits the raw API key, which is stored separately in the system Keychain.
struct LocalProviderAccount: Codable {
    let id: String
    let provider: String
    let displayName: String
    let scopes: [String]
    let defaultModel: String?
    let baseURL: String?
    let status: String
    let createdAt: Date
    /// For an OpenClaw connection, the address of its native Gateway, if
    /// the person gave one.
    var gatewayURL: String?
}

extension ProviderAccount {
    /// Initialize a UI-facing ProviderAccount from a locally stored account.
    init(from local: LocalProviderAccount) {
        self.init(
            id: local.id,
            userId: nil,
            provider: local.provider,
            accountName: nil,
            displayName: local.displayName,
            status: local.status,
            scopes: local.scopes,
            defaultModel: local.defaultModel,
            baseURL: local.baseURL,
            isHealthy: local.status == "healthy",
            lastHealthCheck: nil,
            lastHealthCheckAt: nil,
            quotaHint: nil,
            createdAt: local.createdAt
        )
    }
}

enum LocalProviderAccountError: Error {
    case accountNotFound
}

/// Simple Keychain helper for storing provider API keys securely.
enum KeychainHelper {
    /// Base Keychain service; scoped per-user at call sites via UserScope.
    private static var service: String {
        UserScope.scopedKeychainService("AICovenProviderKeys")
    }

    /// The current account's Keychain service, to keep for work that waits:
    /// passed back as `service`, what is saved or deleted afterwards is
    /// that account's, whoever is signed in by then.
    static var currentService: String {
        service
    }

    static func save(key: String, value: String, service: String? = nil) throws {
        let service = service ?? self.service
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        // Remove any existing item
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func load(key: String, service: String? = nil) -> String? {
        let service = service ?? self.service
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String, service: String? = nil) {
        let service = service ?? self.service
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Service for managing provider accounts (BYOK - Bring Your Own Key)
/// in the local-only client.
///
/// Accounts are stored as JSON in UserDefaults (without secrets). Raw API
/// keys are stored in the system Keychain, keyed by provider-account ID.
/// UserDefaults may hold non-secret provider configuration such as base URLs
/// and model preferences, but it must never mirror raw API keys.
actor ProviderAccountService {
    static let shared = ProviderAccountService()

    /// User-scoped storage key so each Firebase user gets their own provider accounts.
    private var storageKey: String {
        UserScope.scopedKey("provider_accounts.v1")
    }

    /// OpenRouter's model list is public and about 1 MB, and every chat turn
    /// rebuilds the model list, so one download is reused for 15 minutes from
    /// its start, by callers that arrive while it runs too. A failed download
    /// is not kept.
    private var openRouterCatalog: (startedAt: Date, download: Task<[ProviderInitializationStatus.ModelMetadata], Error>)?

    #if DEBUG
    /// Drops the kept catalog, so a test downloads the one it scripts.
    func forgetOpenRouterCatalog() {
        openRouterCatalog = nil
    }
    #endif

    /// Asks a Gateway what it offers; stood in for by tests.
    private var gatewayHello: @Sendable (URL, String?) async throws -> OpenClawGatewayHello = { address, token in
        try await OpenClawGateway.hello(at: address, token: token)
    }

    func askGateways(with hello: @escaping @Sendable (URL, String?) async throws -> OpenClawGatewayHello) {
        gatewayHello = hello
    }

    private init() {}

    // MARK: - Public API

    /// Load all provider accounts for the current user (local-only).
    func loadProviderAccounts() async throws -> [ProviderAccount] {
        let locals = try loadLocalAccounts()
        return locals.map(ProviderAccount.init(from:))
    }

    /// Create a new local provider account and persist its API key.
    @discardableResult
    func createProviderAccount(
        provider: String,
        displayName: String,
        apiKey: String,
        scopes: [String] = ["chat"],
        defaultModel: String? = nil
    ) async throws -> ProviderAccount {
        var locals = try loadLocalAccounts()
        let now = Date()
        let id = UUID().uuidString
        let local = LocalProviderAccount(
            id: id,
            provider: provider.lowercased(),
            displayName: displayName,
            scopes: scopes,
            defaultModel: defaultModel,
            baseURL: nil,
            status: "healthy",
            createdAt: now
        )
        locals.append(local)
        try saveLocalAccounts(locals)

        // Store the API key in the Keychain only. Never mirror raw provider
        // credentials into UserDefaults; LLMConfiguration resolves them from
        // Keychain using the stored account metadata.
        try KeychainHelper.save(key: keychainKey(for: id), value: apiKey)
        clearLegacyAPIKeyCache(provider: provider)

        await MainActor.run { NotificationCenter.default.post(name: .providerKeysUpdated, object: nil) }

        return ProviderAccount(from: local)
    }

    /// Create a local Ollama provider account. No API key is needed;
    /// we store the base URL and default model instead.
    @discardableResult
    func createOllamaAccount(
        displayName: String,
        baseURL: String,
        defaultModel: String?
    ) async throws -> ProviderAccount {
        var locals = try loadLocalAccounts()
        let now = Date()
        let id = UUID().uuidString
        let local = LocalProviderAccount(
            id: id,
            provider: "ollama",
            displayName: displayName,
            scopes: ["chat"],
            defaultModel: defaultModel,
            baseURL: baseURL,
            status: "healthy",
            createdAt: now
        )
        locals.append(local)
        try saveLocalAccounts(locals)

        // Cache non-secret base URL so LLMConfiguration can build the OllamaLLMClient.
        updateProviderConfigCache(provider: "ollama", baseURL: baseURL)

        await MainActor.run { NotificationCenter.default.post(name: .providerKeysUpdated, object: nil) }

        return ProviderAccount(from: local)
    }

    /// Create a local MLX provider account. No API key or server needed;
    /// we store the Hugging Face model ID.
    @discardableResult
    func createMLXAccount(
        displayName: String,
        modelID: String
    ) async throws -> ProviderAccount {
        var locals = try loadLocalAccounts()
        let now = Date()
        let id = UUID().uuidString
        let local = LocalProviderAccount(
            id: id,
            provider: "mlx",
            displayName: displayName,
            scopes: ["chat"],
            defaultModel: modelID,
            baseURL: nil,
            status: "healthy",
            createdAt: now
        )
        locals.append(local)
        try saveLocalAccounts(locals)

        // Set the active MLX model so LLMConfiguration picks it up.
        // This is just a preference — the actual model download happens lazily
        // on first chat via MLXLLMClient.ensureModelLoaded().
        await MLXModelManager.shared.setActiveModel(modelID)

        await MainActor.run { NotificationCenter.default.post(name: .providerKeysUpdated, object: nil) }

        return ProviderAccount(from: local)
    }

    /// Create a local OpenClaw provider account.
    @discardableResult
    func createOpenClawAccount(
        displayName: String,
        baseURL: String,
        apiKey: String?,
        defaultModel: String?,
        gatewayURL: String? = nil
    ) async throws -> ProviderAccount {
        var locals = try loadLocalAccounts()
        let now = Date()
        let id = UUID().uuidString
        let local = LocalProviderAccount(
            id: id,
            provider: "openclaw",
            displayName: displayName,
            scopes: ["chat"],
            defaultModel: defaultModel,
            baseURL: baseURL,
            status: "healthy",
            createdAt: now,
            gatewayURL: gatewayURL.flatMap { $0.isEmpty ? nil : $0 }
        )
        locals.append(local)
        try saveLocalAccounts(locals)

        if let apiKey, !apiKey.isEmpty {
            try KeychainHelper.save(key: keychainKey(for: id), value: apiKey)
        }

        updateProviderConfigCache(provider: "openclaw", baseURL: baseURL)
        clearLegacyAPIKeyCache(provider: "openclaw")

        await MainActor.run { NotificationCenter.default.post(name: .providerKeysUpdated, object: nil) }

        return ProviderAccount(from: local)
    }

    /// A token a Gateway issued this device goes with the connection that
    /// named the Gateway, unless another connection still names it.
    private func forgetIssuedToken(for gateway: String?, unlessStillNamedIn accounts: [LocalProviderAccount]) {
        guard let gateway, !accounts.contains(where: { $0.gatewayURL == gateway }) else { return }
        OpenClawGateway.forgetIssuedToken(for: gateway)
    }

    /// The Gateway address stored with a connection, if it has one.
    func gatewayAddress(forAccount id: String) throws -> String? {
        try loadLocalAccounts().first { $0.id == id }?.gatewayURL
    }

    /// Create a connection to a Hermes agent: the address of its API server,
    /// and the key that server was started with, if it was started with one.
    @discardableResult
    func createHermesAgentAccount(displayName: String, baseURL: String, apiKey: String?) async throws -> ProviderAccount {
        var locals = try loadLocalAccounts()
        let id = UUID().uuidString
        let local = LocalProviderAccount(
            id: id,
            provider: "hermes",
            displayName: displayName,
            scopes: ["chat"],
            defaultModel: nil,
            baseURL: baseURL,
            status: "healthy",
            createdAt: Date()
        )
        locals.append(local)
        // The key first, as for a server: a failed key save leaves no
        // connection behind, and a failed account save takes its key back out.
        if let apiKey, !apiKey.isEmpty {
            try KeychainHelper.save(key: keychainKey(for: id), value: apiKey)
        }
        do {
            try saveLocalAccounts(locals)
        } catch {
            KeychainHelper.delete(key: keychainKey(for: id))
            throw error
        }

        await MainActor.run { NotificationCenter.default.post(name: .providerKeysUpdated, object: nil) }

        return ProviderAccount(from: local)
    }

    /// Create a connection to a server that speaks the OpenAI chat API. The
    /// key is optional: many servers on a person's own machine ask for none.
    @discardableResult
    func createOpenAICompatibleAccount(
        displayName: String,
        baseURL: String,
        apiKey: String?,
        defaultModel: String?
    ) async throws -> ProviderAccount {
        var locals = try loadLocalAccounts()
        let id = UUID().uuidString
        let local = LocalProviderAccount(
            id: id,
            provider: "openai_compatible",
            displayName: displayName,
            scopes: ["chat"],
            defaultModel: defaultModel,
            baseURL: baseURL,
            status: "healthy",
            createdAt: Date()
        )
        locals.append(local)
        // The key first: a failed key save then leaves no connection behind,
        // and a failed account save takes its key back out.
        if let apiKey, !apiKey.isEmpty {
            try KeychainHelper.save(key: keychainKey(for: id), value: apiKey)
        }
        do {
            try saveLocalAccounts(locals)
        } catch {
            KeychainHelper.delete(key: keychainKey(for: id))
            throw error
        }

        await MainActor.run { NotificationCenter.default.post(name: .providerKeysUpdated, object: nil) }

        return ProviderAccount(from: local)
    }

    /// Update an existing provider account's display name and/or API key.
    func updateProviderAccount(
        id: String,
        displayName: String? = nil,
        apiKey: String? = nil,
        baseURL: String? = nil,
        defaultModel: String? = nil,
        gatewayURL: String? = nil
    ) async throws {
        var locals = try loadLocalAccounts()
        guard let index = locals.firstIndex(where: { $0.id == id }) else {
            throw LocalProviderAccountError.accountNotFound
        }
        let old = locals[index]
        let updated = LocalProviderAccount(
            id: old.id,
            provider: old.provider,
            displayName: displayName ?? old.displayName,
            scopes: old.scopes,
            defaultModel: defaultModel ?? old.defaultModel,
            // An empty address clears it, and the provider's own applies again.
            baseURL: baseURL.map { $0.isEmpty ? nil : $0 } ?? old.baseURL,
            status: old.status,
            createdAt: old.createdAt,
            // As for the address: not given leaves it, empty clears it.
            gatewayURL: gatewayURL.map { $0.isEmpty ? nil : $0 } ?? old.gatewayURL
        )
        locals[index] = updated
        try saveLocalAccounts(locals)
        if old.gatewayURL != updated.gatewayURL {
            forgetIssuedToken(for: old.gatewayURL, unlessStillNamedIn: locals)
        }

        // Update Keychain if API key changed. Do not mirror secrets into UserDefaults.
        if let apiKey, !apiKey.isEmpty {
            try KeychainHelper.save(key: keychainKey(for: id), value: apiKey)
            clearLegacyAPIKeyCache(provider: old.provider)
        }

        // Update non-secret base URL cache if changed.
        if let baseURL {
            updateProviderConfigCache(provider: old.provider, baseURL: baseURL)
        }

        await MainActor.run { NotificationCenter.default.post(name: .providerKeysUpdated, object: nil) }
    }

    /// Delete a local provider account and its associated API key.
    func deleteProviderAccount(id: String) async throws {
        var locals = try loadLocalAccounts()
        guard let index = locals.firstIndex(where: { $0.id == id }) else {
            throw LocalProviderAccountError.accountNotFound
        }
        let removed = locals.remove(at: index)
        try saveLocalAccounts(locals)

        // Remove Keychain entry
        KeychainHelper.delete(key: keychainKey(for: id))
        forgetIssuedToken(for: removed.gatewayURL, unlessStillNamedIn: locals)

        // If this was the last account for its provider, clear the global
        // UserDefaults API key hint so the UI can surface a proper error.
        let remainingForProvider = locals.contains { $0.provider == removed.provider }
        if !remainingForProvider {
            clearProviderConfigCache(provider: removed.provider)
        }

        await MainActor.run { NotificationCenter.default.post(name: .providerKeysUpdated, object: nil) }
    }

    /// Get initialization status for a provider account, including a list of
    /// models that this provider supports for the *specific key*.
    ///
    /// In the local-only client we prefer the provider's live models API. If
    /// that fails, we currently return an empty list rather than guessing.
    func getInitializationStatus(accountId: String) async throws -> ProviderInitializationStatus {
        let locals = try loadLocalAccounts()
        guard let account = locals.first(where: { $0.id == accountId }) else {
            throw LocalProviderAccountError.accountNotFound
        }
        let models: [ProviderInitializationStatus.ModelMetadata]
        if account.provider.lowercased() == "hermes" {
            // A Hermes agent has no models to choose among, so the screens
            // that list a connection's models do not ask it: only Test does.
            models = []
        } else {
            do {
                models = try await fetchRemoteModels(for: account)
            } catch {
                AppErrorReporter.log(error: error, context: "ProviderAccountService.getInitializationStatus.fetchRemoteModels")
                models = []
            }
        }
        return ProviderInitializationStatus(
            providerAccountId: account.id,
            status: "initialized",
            modelMetadata: models
        )
    }

    /// Ask OpenRouter whether it accepts an account's stored key, without
    /// running a model. OpenRouter's model list is public, so listing models
    /// cannot tell a refused key from a working one.
    func checkOpenRouterKey(accountId: String) async throws {
        guard let apiKey = KeychainHelper.load(key: keychainKey(for: accountId)) else {
            throw NSError(domain: "ProviderAccountService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing OpenRouter API key for account \(accountId)"])
        }
        var request = URLRequest(url: OpenAILLMClient.openRouterBaseURL.appendingPathComponent("key"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw NSError(
                domain: "ProviderAccountService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "OpenRouter key check HTTP \(http.statusCode). Response body omitted to avoid leaking provider/account metadata."]
            )
        }
    }

    /// Tests an account against its provider and records the outcome as the
    /// account's status. It reads the models the account can use; for
    /// OpenRouter, whose model list is public, it first asks whether the key
    /// is accepted. Returns the number of models, and throws what failed.
    @discardableResult
    func testConnection(accountId: String) async throws -> Int {
        guard let account = try loadLocalAccounts().first(where: { $0.id == accountId }) else {
            throw LocalProviderAccountError.accountNotFound
        }
        let testedKey = KeychainHelper.load(key: keychainKey(for: accountId))
        let outcome: Result<Int, Error>
        do {
            if account.provider.lowercased() == "openrouter" {
                try await checkOpenRouterKey(accountId: accountId)
            }
            if let gateway = account.gatewayURL {
                // A connection with a Gateway is tested at its Gateway,
                // where its turns run: that it answers as one, takes this
                // device and the token, and offers what a turn needs.
                guard let address = OpenClawGatewayConnection.address(gateway) else { throw OpenClawGatewayError.invalidAddress }
                let hello = try await gatewayHello(address, testedKey)
                if let missing = hello.missing { throw OpenClawGatewayError.notSupported(missing) }
                // The models are asked of the server address with the key
                // as it is stored now. If either was edited while the
                // Gateway answered, the new key is not sent to the old
                // address: the models are not asked.
                let current = try loadLocalAccounts().first { $0.id == accountId }
                let unchanged = current?.baseURL == account.baseURL && KeychainHelper.load(key: keychainKey(for: accountId)) == testedKey
                outcome = unchanged ? await .success((try? fetchRemoteModels(for: account).count) ?? 0) : .success(0)
            } else {
                outcome = try await .success(fetchRemoteModels(for: account).count)
            }
        } catch {
            outcome = .failure(error)
        }
        // Read again: the account may have been edited or deleted while the
        // provider answered. The outcome is about the address and key that
        // were tested, so it is recorded only if they are still the ones
        // stored.
        var locals = try loadLocalAccounts()
        if let index = locals.firstIndex(where: { $0.id == accountId }),
           locals[index].baseURL == account.baseURL,
           locals[index].gatewayURL == account.gatewayURL,
           KeychainHelper.load(key: keychainKey(for: accountId)) == testedKey {
            let current = locals[index]
            locals[index] = LocalProviderAccount(
                id: current.id,
                provider: current.provider,
                displayName: current.displayName,
                scopes: current.scopes,
                defaultModel: current.defaultModel,
                baseURL: current.baseURL,
                status: (try? outcome.get()) == nil ? "unhealthy" : "healthy",
                createdAt: current.createdAt,
                gatewayURL: current.gatewayURL
            )
            try saveLocalAccounts(locals)
        }
        return try outcome.get()
    }

    /// Run initialization for a provider account. In the local-only client we
    /// simply return static model metadata without performing network calls.
    @discardableResult
    func initializeProviderAccount(accountId: String) async throws -> ProviderInitializationStatus {
        try await getInitializationStatus(accountId: accountId)
    }

    /// Lightweight model info used by refreshProviderModels.
    struct ProviderModel: Decodable {
        let id: String
        let name: String
        let provider: String?
    }

    /// Refresh model metadata for a provider account.
    /// Prefer the provider's live model list when available. If it fails we
    /// return an empty list rather than using hardcoded models.
    @discardableResult
    func refreshProviderModels(accountId: String) async throws -> [ProviderModel] {
        let locals = try loadLocalAccounts()
        guard let account = locals.first(where: { $0.id == accountId }) else {
            throw LocalProviderAccountError.accountNotFound
        }
        let metadata: [ProviderInitializationStatus.ModelMetadata]
        do {
            metadata = try await fetchRemoteModels(for: account)
        } catch {
            AppErrorReporter.log(error: error, context: "ProviderAccountService.refreshProviderModels.fetchRemoteModels")
            metadata = []
        }
        return metadata.map { modelMeta in
            ProviderModel(id: modelMeta.id, name: modelMeta.name ?? modelMeta.id, provider: modelMeta.provider)
        }
    }

    /// What chat chooses a model from: the models the router picks among,
    /// and, by provider, every model the provider's own list says takes
    /// pictures (OpenRouter's whole catalog, of which the router is given
    /// one model).
    struct ModelCatalog {
        var routed: [ModelDescriptor] = []
        var imageModels: [String: Set<String>] = [:]
    }

    /// Build dynamic ModelDescriptors for all configured provider accounts
    /// using live ListModels responses. Only chat-capable models are included.
    func loadAllModelDescriptors() async throws -> [ModelDescriptor] {
        try await loadModelCatalog().routed
    }

    /// The same, with the models listed as taking pictures.
    func loadModelCatalog() async throws -> ModelCatalog {
        let locals = try loadLocalAccounts()
        var descriptors: [ModelDescriptor] = []
        var imageModels: [String: Set<String>] = [:]

        // Chat reaches one OpenAI-compatible server, the first connected, so
        // only its models are offered.
        let compatibleServerID = locals.first { $0.provider.lowercased() == "openai_compatible" }?.id

        for account in locals {
            let providerID = account.provider.lowercased()
            if providerID == "openai_compatible", account.id != compatibleServerID { continue }
            // A Hermes agent has no models for the router to choose among,
            // and is not asked for any here: this runs before every turn,
            // and an agent that is switched off would hold each one up.
            if providerID == "hermes" { continue }
            let metadata: [ProviderInitializationStatus.ModelMetadata]
            do {
                metadata = try await fetchRemoteModels(for: account)
            } catch {
                AppErrorReporter.log(error: error, context: "ProviderAccountService.loadAllModelDescriptors.fetchRemoteModels.\(providerID)")
                // A server's model list can fail while it still answers
                // chat, so its chosen model stays on offer below.
                guard providerID == "openai_compatible" else { continue }
                metadata = []
            }

            let seeing = metadata.filter { $0.takesImages == true }.map(\.id)
            if !seeing.isEmpty {
                imageModels[providerID, default: []].formUnion(seeing)
            }

            // The router picks by a coarse cost class, which cannot rank
            // OpenRouter's whole catalog, so it sees one OpenRouter model: the
            // one chosen in Strix settings, whether or not the catalog still
            // lists it, or the catalog's default when none is chosen.
            var routed = metadata
            if providerID == "openrouter" {
                if let chosen = UserDefaults.standard.string(forKey: UserScope.scopedKey("openrouter_model")) {
                    routed = [metadata.first { $0.id == chosen } ?? ProviderInitializationStatus.ModelMetadata(
                        id: chosen,
                        name: chosen,
                        provider: "openrouter",
                        contextLength: nil
                    )]
                } else {
                    routed = Array(metadata.prefix(1))
                }
            }
            // A server's models cannot be ranked by cost class either, so the
            // router sees one: the model chosen in Strix settings, else the
            // one chosen when the server was connected, else the first listed.
            if providerID == "openai_compatible" {
                let chosen = UserDefaults.standard.string(forKey: UserScope.scopedKey("openai_compatible_model"))
                    ?? account.defaultModel
                if let chosen {
                    routed = [metadata.first { $0.id == chosen } ?? ProviderInitializationStatus.ModelMetadata(
                        id: chosen,
                        name: chosen,
                        provider: "openai_compatible",
                        contextLength: nil
                    )]
                } else {
                    routed = Array(metadata.prefix(1))
                }
            }

            for modelMeta in routed {
                let context = modelMeta.contextLength ?? 128_000
                let cost: ModelDescriptor.CostClass
                let lowerID = modelMeta.id.lowercased()
                if lowerID.contains("mini") || lowerID.contains("flash") {
                    cost = .cheap
                } else if lowerID.contains("haiku") {
                    cost = .medium
                } else {
                    cost = .expensive
                }

                let provider = modelMeta.provider?.lowercased() ?? providerID
                descriptors.append(
                    ModelDescriptor(
                        providerID: provider,
                        modelID: modelMeta.id,
                        maxContextTokens: context,
                        supportsTools: true,
                        supportsEmbeddings: false,
                        costClass: cost,
                        takesImages: ModelDescriptor.takesImages(providerID: provider, modelID: modelMeta.id, listed: modelMeta.takesImages)
                    )
                )
            }
        }

        // ── MLX local models ─────────────────────────────────────────────
        // MLX models don't come from a remote API, so inject descriptors
        // for any active/downloaded model directly—but ONLY if the user
        // actually has an MLX provider account configured.
        let hasMLXAccount = locals.contains { $0.provider.lowercased() == "mlx" }
        if hasMLXAccount,
           let activeMLX = UserDefaults.standard.string(forKey: "MLXModelManager.activeModelID"), !activeMLX.isEmpty {
            descriptors.append(
                ModelDescriptor(
                    providerID: "mlx",
                    modelID: activeMLX,
                    // Most MLX catalog models (Qwen3-4B, Mistral-7B, etc.)
                    // support 32K+ context; 8K was far too small for system
                    // prompt + MCP catalog + memories + recent turns.
                    maxContextTokens: 32_768,
                    supportsTools: true,
                    supportsEmbeddings: false,
                    costClass: .free
                )
            )
        }

        return ModelCatalog(routed: descriptors, imageModels: imageModels)
    }

    /// Helper to refresh all provider accounts for the current user in parallel.
    /// Failures for individual accounts are logged but don't throw.
    func refreshAllProviderModels() async {
        do {
            let accounts = try loadLocalAccounts()

            await withTaskGroup(of: Void.self) { group in
                for account in accounts {
                    group.addTask {
                        do {
                            _ = try await self.refreshProviderModels(accountId: account.id)
                            AppErrorReporter.log(message: "Refreshed models for account \(account.id)", context: "ProviderAccountService.refreshAllProviderModels.account")
                        } catch {
                            AppErrorReporter.log(error: error, context: "ProviderAccountService.refreshAllProviderModels.account.\(account.id)")
                        }
                    }
                }
            }
        } catch {
            AppErrorReporter.log(error: error, context: "ProviderAccountService.refreshAllProviderModels.loadLocalAccounts")
        }
    }

    // MARK: - Private helpers

}

// MARK: - ProviderAccountService Private Helpers

extension ProviderAccountService {
    /// The Hermes agent the app runs Hermes turns with: the first one
    /// connected.
    static func hermesAgent() -> HermesAgentClient? {
        guard let account = loadLocalAccountsFromDefaults().first(where: { $0.provider.lowercased() == "hermes" }),
              let baseURL = account.baseURL.flatMap(LocalProviderDiscoveryService.serverBaseURL(from:)) else {
            return nil
        }
        let key = KeychainHelper.load(key: keychainKey(forAccountId: account.id))
        return HermesAgentClient(baseURL: baseURL, apiKey: key?.isEmpty == false ? key : nil)
    }

    /// The OpenClaw Gateway the app runs OpenClaw turns through: that of
    /// the first OpenClaw connection, if it names one, with that
    /// connection's token.
    static func openClawGateway() -> (address: URL, token: String?)? {
        guard let (account, address) = openClawConnectionWithGateway() else { return nil }
        let token = KeychainHelper.load(key: keychainKey(forAccountId: account.id))
        return (address, token?.isEmpty == false ? token : nil)
    }

    /// Whether OpenClaw runs its turns itself: its connection names its
    /// Gateway. Reads no secret.
    static var openClawRunsItsTurns: Bool {
        openClawConnectionWithGateway() != nil
    }

    private static func openClawConnectionWithGateway() -> (account: LocalProviderAccount, address: URL)? {
        guard let account = loadLocalAccountsFromDefaults().first(where: { $0.provider.lowercased() == "openclaw" }),
              let address = account.gatewayURL.flatMap(OpenClawGatewayConnection.address) else {
            return nil
        }
        return (account, address)
    }

    /// The OpenAI-compatible server chat reaches: the first connected, with
    /// its own key. Both come from the same connection, so one server's key
    /// is never sent to another.
    static func openAICompatibleServer() -> (baseURL: URL, apiKey: String?)? {
        guard let account = loadLocalAccountsFromDefaults().first(where: { $0.provider.lowercased() == "openai_compatible" }),
              let baseURL = account.baseURL.flatMap(URL.init(string:)), baseURL.host != nil else {
            return nil
        }
        let key = KeychainHelper.load(key: keychainKey(forAccountId: account.id))
        return (baseURL, key?.isEmpty == false ? key : nil)
    }

    /// Resolve the first configured API key for a provider from Keychain using
    /// user-scoped account metadata. This intentionally bypasses UserDefaults
    /// secret mirrors; UserDefaults may only contain non-secret metadata.
    static func apiKeyFromKeychain(forProvider provider: String) -> String? {
        let normalized = provider.lowercased()
        let providerMatches: (String) -> Bool = { candidate in
            let lower = candidate.lowercased()
            if normalized == "google" || normalized == "gemini" {
                return lower == "google" || lower == "gemini"
            }
            return lower == normalized
        }

        let accounts = loadLocalAccountsFromDefaults().filter { providerMatches($0.provider) }
        guard let account = accounts.first else {
            return nil
        }
        return KeychainHelper.load(key: keychainKey(forAccountId: account.id))
    }

    static func clearLegacyAPIKeyCache(provider: String) {
        let defaults = UserDefaults.standard
        let keys: [String] = switch provider.lowercased() {
        case "openai":
            ["openai_api_key"]
        case "anthropic":
            ["anthropic_api_key"]
        case "google", "gemini":
            ["gemini_api_key"]
        case "openclaw":
            ["openclaw_api_key"]
        case "hermes", "together":
            ["hermes_api_key", "together_api_key"]
        default:
            []
        }
        for key in keys {
            defaults.removeObject(forKey: UserScope.scopedKey(key))
        }
    }

    private static func loadLocalAccountsFromDefaults() -> [LocalProviderAccount] {
        convertHermesModelConnectionsIfNeeded()
        let storageKey = UserScope.scopedKey("provider_accounts.v1")
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return []
        }
        do {
            return try JSONDecoder().decode([LocalProviderAccount].self, from: data)
        } catch {
            AppErrorReporter.log(error: error, context: "ProviderAccountService.loadLocalAccountsFromDefaults.decodeAccounts")
            return []
        }
    }

    private static func keychainKey(forAccountId accountId: String) -> String {
        "provider-account-\(accountId)"
    }

    // MARK: - Hermes model connections

    static let togetherAddress = "https://api.together.xyz"

    /// "Hermes" used to mean Nous Research's Hermes models, served by
    /// Together AI or by a server of the person's own, over the OpenAI chat
    /// API. Such a connection becomes what it is: an OpenAI-compatible
    /// server, at Together AI's address when it named none, with the model
    /// it was using. Its id stays, and so its key stays where it is in the
    /// Keychain. Done once for each account on this device, before anything
    /// reads the connections or the provider chosen for replies: "hermes"
    /// is to mean the Hermes agent, whose connections must not be taken for
    /// these.
    static func convertHermesModelConnectionsIfNeeded() {
        // One at a time: the connections are read from the chat's own
        // actor and from this service's, and a second conversion begun
        // before the first had finished would work from what the first
        // was in the middle of changing.
        hermesConversion.withLock {
            let defaults = UserDefaults.standard
            let doneKey = UserScope.scopedKey("hermes_model_connections_converted.v1")
            guard !defaults.bool(forKey: doneKey) else { return }
            let storageKey = UserScope.scopedKey("provider_accounts.v1")
            do {
                // No connections stored is none to convert; a choice of
                // Hermes can still have been left behind.
                let accounts = try defaults.data(forKey: storageKey).map {
                    try JSONDecoder().decode([LocalProviderAccount].self, from: $0)
                } ?? []
                let alias = defaults.string(forKey: UserScope.scopedKey("hermes_model"))
                let isHermes: (LocalProviderAccount) -> Bool = { ["hermes", "together"].contains($0.provider.lowercased()) }
                let existingServer = accounts.first { $0.provider.lowercased() == "openai_compatible" }
                var convertedIDs: Set<String> = []
                var converted = accounts.map { account -> LocalProviderAccount in
                    guard isHermes(account) else { return account }
                    convertedIDs.insert(account.id)
                    let ownAddress = account.baseURL.flatMap { $0.isEmpty ? nil : $0 }
                    let address = ownAddress ?? togetherAddress
                    let named = account.defaultModel ?? alias ?? "hermes-3"
                    // Together AI is sent the name it knows; a server of the
                    // person's own, the name as they gave it.
                    let isTogether = URL(string: address)?.host?.lowercased() == URL(string: togetherAddress)?.host
                    return LocalProviderAccount(
                        id: account.id,
                        provider: "openai_compatible",
                        displayName: account.displayName,
                        scopes: account.scopes,
                        defaultModel: isTogether ? togetherModelID(for: named) : named,
                        baseURL: address,
                        status: account.status,
                        createdAt: account.createdAt
                    )
                }
                // The model in use is the server in use's: the earlier
                // server's own where there is one, else the converted
                // connection's.
                let modelKey = UserScope.scopedKey("openai_compatible_model")
                let inUse = existingServer ?? converted.first { convertedIDs.contains($0.id) }
                let model = (existingServer == nil ? nil : defaults.string(forKey: modelKey)) ?? inUse?.defaultModel
                // First, so that a failure after it leaves the connections
                // to be converted again, to the same end.
                try moveChosenProviderOffHermes(toServerWith: convertedIDs.isEmpty ? nil : model, isConverted: !convertedIDs.isEmpty)
                if !convertedIDs.isEmpty {
                    // Each stays where it was listed, so what comes first
                    // among the other providers does not change. The server
                    // in use is the first one listed, though, so a converted
                    // connection listed before a server connected earlier
                    // goes just after it: that server keeps its place.
                    if let existingServer, let place = converted.firstIndex(where: { $0.id == existingServer.id }) {
                        let ahead = converted[..<place].filter { convertedIDs.contains($0.id) }
                        converted.removeAll { account in ahead.contains { $0.id == account.id } }
                        let after = converted.firstIndex { $0.id == existingServer.id }.map { $0 + 1 } ?? converted.endIndex
                        converted.insert(contentsOf: ahead, at: after)
                    }
                    try defaults.set(JSONEncoder().encode(converted), forKey: storageKey)
                    if existingServer == nil, let model {
                        defaults.set(model, forKey: modelKey)
                    }
                }
                defaults.removeObject(forKey: UserScope.scopedKey("hermes_base_url"))
                defaults.removeObject(forKey: UserScope.scopedKey("hermes_model"))
                defaults.set(true, forKey: doneKey)
            } catch {
                // Left to be tried again: nothing has been changed.
                AppErrorReporter.log(error: error, context: "ProviderAccountService.convertHermesModelConnections")
            }
        }
    }

    private static let hermesConversion = NSLock()

    /// The name Together AI knows a Hermes model by, for the short names
    /// this app used.
    static func togetherModelID(for alias: String) -> String {
        let known = [
            "hermes-3": "NousResearch/Hermes-3-Llama-3.1-405B-Turbo",
            "hermes-3-405b": "NousResearch/Hermes-3-Llama-3.1-405B-Turbo",
            "hermes-3-70b": "NousResearch/Hermes-3-Llama-3.1-70B",
            "hermes-3-8b": "NousResearch/Hermes-3-Llama-3.1-8B",
            "hermes-2": "NousResearch/Nous-Hermes-2-Mixtral-8x7B-DPO",
            "hermes-2-mixtral": "NousResearch/Nous-Hermes-2-Mixtral-8x7B-DPO",
            "hermes-2-mistral": "NousResearch/Nous-Hermes-2-Mistral-7B-DPO",
            "hermes-2-vision": "NousResearch/Nous-Hermes-2-Vision-Alpha",
        ]
        return known[alias.lowercased()] ?? alias
    }

    /// Hermes stops being the provider chosen for replies, wherever that
    /// is stored. Where a connection was converted, the server is chosen in
    /// its place, with the model of the server in use. Where none was (the
    /// Hermes connection had been removed and the choice left behind),
    /// nothing is chosen, and the app falls back as it does for any
    /// provider that is not connected: left as it was, the choice would
    /// come to mean the Hermes agent.
    private static func moveChosenProviderOffHermes(toServerWith model: String?, isConverted: Bool) throws {
        let defaults = UserDefaults.standard
        let providerKey = UserScope.scopedKey("llm_provider")
        if defaults.string(forKey: providerKey)?.lowercased() == "hermes" {
            if isConverted {
                defaults.set("openai_compatible", forKey: providerKey)
            } else {
                defaults.removeObject(forKey: providerKey)
            }
        }
        let settingsKey = UserScope.scopedKey("strix_settings.v1")
        // Settings that cannot be read name no provider to anything that
        // reads them, and are replaced the next time they are saved.
        guard let data = defaults.data(forKey: settingsKey),
              var settings = try? JSONDecoder().decode(LocalStrixSettings.self, from: data),
              settings.provider?.lowercased() == "hermes" else { return }
        settings.provider = isConverted ? "openai_compatible" : nil
        settings.model = isConverted ? model : nil
        if !isConverted {
            settings.providerAccountId = nil
        }
        try defaults.set(JSONEncoder().encode(settings), forKey: settingsKey)
    }

    private static func sanitizedHTTPError(provider: String, statusCode: Int) -> NSError {
        NSError(
            domain: "ProviderAccountService",
            code: statusCode,
            userInfo: [NSLocalizedDescriptionKey: "\(provider) models HTTP \(statusCode). Response body omitted to avoid leaking provider/account metadata."]
        )
    }

    private func loadLocalAccounts() throws -> [LocalProviderAccount] {
        Self.convertHermesModelConnectionsIfNeeded()
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: storageKey) else {
            return []
        }
        do {
            return try JSONDecoder().decode([LocalProviderAccount].self, from: data)
        } catch {
            AppErrorReporter.log(error: error, context: "ProviderAccountService.loadLocalAccounts.decodeAccounts")
            return []
        }
    }

    private func saveLocalAccounts(_ accounts: [LocalProviderAccount]) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(accounts)
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func keychainKey(for accountId: String) -> String {
        "provider-account-\(accountId)"
    }

    private func updateProviderConfigCache(provider: String, baseURL: String? = nil) {
        let defaults = UserDefaults.standard
        clearLegacyAPIKeyCache(provider: provider)
        guard let baseURL, ["ollama", "openclaw"].contains(provider.lowercased()) else { return }
        let key = UserScope.scopedKey("\(provider.lowercased())_base_url")
        // An empty address is no address, as it is in the stored account.
        if baseURL.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(baseURL, forKey: key)
        }
    }

    private func clearProviderConfigCache(provider: String) {
        let defaults = UserDefaults.standard
        clearLegacyAPIKeyCache(provider: provider)
        switch provider.lowercased() {
        case "ollama":
            defaults.removeObject(forKey: UserScope.scopedKey("ollama_base_url"))
        case "mlx":
            defaults.removeObject(forKey: "MLXModelManager.activeModelID")
            defaults.removeObject(forKey: "MLXModelManager.downloadedModelIDs")
        case "openclaw":
            defaults.removeObject(forKey: UserScope.scopedKey("openclaw_base_url"))
        case "openai_compatible":
            defaults.removeObject(forKey: UserScope.scopedKey("openai_compatible_model"))
        default:
            break
        }
    }

    private func clearLegacyAPIKeyCache(provider: String) {
        ProviderAccountService.clearLegacyAPIKeyCache(provider: provider)
    }

    /// Try to fetch live model metadata for a specific provider account using
    /// its API key. This keeps model pickers aligned with what that key can
    /// actually access. Errors are propagated to callers, who may decide to
    /// fall back to `defaultModelMetadata`.
    /// Fetch live model metadata for a specific provider account using its API
    /// key. All routing and model pickers should be based on this response.
    private func fetchRemoteModels(for account: LocalProviderAccount) async throws -> [ProviderInitializationStatus.ModelMetadata] {
        let provider = account.provider.lowercased()
        switch provider {
        case "openai":
            guard let apiKey = KeychainHelper.load(key: keychainKey(for: account.id)) else {
                throw NSError(domain: "ProviderAccountService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing OpenAI API key for account \(account.id)"])
            }
            struct OpenAIListResponse: Decodable { struct Item: Decodable { let id: String }
                let data: [Item]
            }
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.httpMethod = "GET"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                throw Self.sanitizedHTTPError(provider: "OpenAI", statusCode: http.statusCode)
            }
            let decoded = try JSONDecoder().decode(OpenAIListResponse.self, from: data)
            let chatOnly = decoded.data
                .map(\.id)
                .filter { isChatModel(provider: "openai", id: $0) }
            let models = chatOnly.isEmpty ? decoded.data.map(\.id) : chatOnly
            return models.map { id in
                ProviderInitializationStatus.ModelMetadata(
                    id: id,
                    name: id,
                    provider: "openai",
                    contextLength: nil
                )
            }
        case "google", "gemini":
            // Gemini / Google AI
            guard let apiKey = KeychainHelper.load(key: keychainKey(for: account.id)) else {
                throw NSError(domain: "ProviderAccountService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing Gemini API key for account \(account.id)"])
            }
            struct GeminiListResponse: Decodable {
                struct Model: Decodable { let name: String }
                let models: [Model]?
                let nextPageToken: String?
            }

            // Fetch all pages from the Gemini list-models endpoint.
            var allModelNames: [String] = []
            var pageToken: String? = nil
            repeat {
                var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
                var queryItems = [URLQueryItem(name: "key", value: apiKey)]
                if let token = pageToken {
                    queryItems.append(URLQueryItem(name: "pageToken", value: token))
                }
                components.queryItems = queryItems
                let url = components.url!
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                    throw Self.sanitizedHTTPError(provider: "Gemini", statusCode: http.statusCode)
                }
                let decoded = try JSONDecoder().decode(GeminiListResponse.self, from: data)
                allModelNames.append(contentsOf: (decoded.models ?? []).map(\.name))
                pageToken = decoded.nextPageToken
            } while pageToken != nil

            // Merge in static preview models that may not appear in the API yet.
            let previewModels = [
                "models/gemini-3-pro-preview",
                "models/gemini-3-flash-preview",
                "models/gemini-3-pro-image-preview"
            ]
            let existingSet = Set(allModelNames.map { $0.lowercased() })
            for preview in previewModels where !existingSet.contains(preview.lowercased()) {
                allModelNames.append(preview)
            }

            let chatOnly = allModelNames.filter { isChatModel(provider: "google", id: $0) }
            let models = chatOnly.isEmpty ? allModelNames : chatOnly
            return models.map { name in
                ProviderInitializationStatus.ModelMetadata(
                    id: name, // e.g. "models/gemini-2.0-flash"
                    name: name,
                    provider: "google",
                    contextLength: nil
                )
            }
        case "ollama":
            // Ollama model discovery via /api/tags
            let urlStr = account.baseURL ?? "http://localhost:11434"
            let client = OllamaLLMClient(baseURL: URL(string: urlStr) ?? OllamaLLMClient.defaultBaseURL)
            let models = try await client.discoverModels()
            return models.map { model in
                ProviderInitializationStatus.ModelMetadata(
                    id: model.name,
                    name: model.name,
                    provider: "ollama",
                    contextLength: 128_000 // Ollama doesn't report context length via tags
                )
            }
        case "mlx":
            // MLX: return curated catalog models as static metadata.
            return MLXModelManager.defaultCatalog.map { info in
                ProviderInitializationStatus.ModelMetadata(
                    id: info.id,
                    name: info.displayName,
                    provider: "mlx",
                    contextLength: 128_000
                )
            }
        case "openclaw", "openai_compatible", "hermes":
            let apiKey = KeychainHelper.load(key: keychainKey(for: account.id)) ?? ""
            let defaultBaseURL = switch provider {
            case "openclaw": "http://localhost:3000"
            default: ""
            }
            guard let url = URL(string: account.baseURL ?? defaultBaseURL)?.appendingPathComponent("v1/models"), url.host != nil else {
                throw NSError(domain: "ProviderAccountService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid base URL for \(provider)"])
            }
            struct OpenAIListResponse: Decodable { struct Item: Decodable { let id: String }
                let data: [Item]
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                throw Self.sanitizedHTTPError(provider: provider == "openai_compatible" ? "Server" : provider, statusCode: http.statusCode)
            }
            let decoded = try JSONDecoder().decode(OpenAIListResponse.self, from: data)
            let chatOnly = decoded.data
                .map(\.id)
                .filter { isChatModel(provider: provider, id: $0) }
            let models = chatOnly.isEmpty ? decoded.data.map(\.id) : chatOnly
            return models.map { id in
                ProviderInitializationStatus.ModelMetadata(
                    id: id,
                    name: id,
                    provider: provider,
                    contextLength: nil
                )
            }
        case "openrouter":
            if let cached = openRouterCatalog, Date().timeIntervalSince(cached.startedAt) < 15 * 60 {
                return try await cached.download.value
            }
            let download = Task {
                var request = URLRequest(url: OpenAILLMClient.openRouterBaseURL.appendingPathComponent("models"))
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                    throw Self.sanitizedHTTPError(provider: "OpenRouter", statusCode: http.statusCode)
                }
                return try Self.openRouterToolModels(from: data)
            }
            openRouterCatalog = (Date(), download)
            do {
                return try await download.value
            } catch {
                if openRouterCatalog?.download == download {
                    openRouterCatalog = nil
                }
                throw error
            }
        case "anthropic":
            guard let apiKey = KeychainHelper.load(key: keychainKey(for: account.id)) else {
                throw NSError(domain: "ProviderAccountService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing Anthropic API key for account \(account.id)"])
            }
            struct AnthropicListResponse: Decodable {
                struct Item: Decodable { let id: String
                    let display_name: String?
                }

                let data: [Item]?
            }
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
            request.httpMethod = "GET"
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                throw Self.sanitizedHTTPError(provider: "Anthropic", statusCode: http.statusCode)
            }
            let decoded = try JSONDecoder().decode(AnthropicListResponse.self, from: data)
            let modelsData = decoded.data ?? []
            let chatOnly = modelsData
                .map(\.id)
                .filter { isChatModel(provider: "anthropic", id: $0) }
            let models = chatOnly.isEmpty ? modelsData.map(\.id) : chatOnly
            return models.map { id in
                ProviderInitializationStatus.ModelMetadata(
                    id: id,
                    name: modelsData.first(where: { $0.id == id })?.display_name ?? id,
                    provider: "anthropic",
                    contextLength: nil
                )
            }
        default:
            // Other providers: fall back to static metadata for now.
            throw NSError(domain: "ProviderAccountService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No remote model fetch implemented for provider \(provider)"])
        }
    }

    /// The models in OpenRouter's catalog that a chat turn can use, default
    /// model first: those served at the chat completions endpoint (a `:batch`
    /// variant is served only at the batch endpoint) that support tool
    /// calling. A chat turn may carry tools, and OpenRouter refuses a request
    /// with tools for a model that does not support them.
    ///
    /// The default is the first Claude Sonnet, else GPT, else Gemini model in
    /// the catalog. An id with a `:` suffix is a variant of a model (`:free`,
    /// `:batch`) with its own limits, so it is never the default.
    static func openRouterToolModels(from data: Data) throws -> [ProviderInitializationStatus.ModelMetadata] {
        struct Catalog: Decodable {
            struct Model: Decodable {
                let id: String
                let name: String?
                let context_length: Int?
                let supported_parameters: [String]?
                let endpoints: [String]?
                let architecture: Architecture?
            }

            struct Architecture: Decodable {
                let input_modalities: [String]?
            }

            let data: [Model]
        }
        var models = try JSONDecoder().decode(Catalog.self, from: data).data
            .filter { $0.supported_parameters?.contains("tools") == true }
            .filter { $0.endpoints?.contains("/api/v1/chat/completions") == true }
            .map { model in
                ProviderInitializationStatus.ModelMetadata(
                    id: model.id,
                    name: model.name ?? model.id,
                    provider: "openrouter",
                    contextLength: model.context_length,
                    takesImages: model.architecture?.input_modalities?.contains("image") == true
                )
            }
        for prefix in ["anthropic/claude-sonnet", "openai/gpt-", "google/gemini-"] {
            if let index = models.firstIndex(where: { $0.id.hasPrefix(prefix) && !$0.id.contains(":") }) {
                models.insert(models.remove(at: index), at: 0)
                break
            }
        }
        return models
    }

    /// Heuristic filter to decide whether a model ID represents a chat model
    /// (vs embeddings, audio, moderation, tools, etc.). This keeps the edit
    /// agent / Strix model picker focused on chat-capable models only.
    private func isChatModel(provider: String, id: String) -> Bool {
        let lower = id.lowercased()
        switch provider.lowercased() {
        case "openai":
            // Exclude obvious non-chat families.
            if lower.contains("embedding") { return false }
            if lower.contains("-embed-") { return false }
            if lower.contains("whisper") { return false }
            if lower.contains("tts-") || lower.contains("audio-") { return false }
            if lower.contains("omni-moderation") { return false }
            // Keep GPT / o* reasoning style models.
            return lower.hasPrefix("gpt-") || lower.hasPrefix("o1") || lower.hasPrefix("o3")
        case "google", "gemini":
            // Gemini models endpoint returns names like "models/gemini-2.0-flash".
            let trimmed = lower.replacingOccurrences(of: "models/", with: "")
            if trimmed.contains("embed") || trimmed.contains("embedding") { return false }
            if trimmed.contains("vision-") { return false }
            // Treat anything with "gemini" that isn't obviously an embedding as chat.
            return trimmed.contains("gemini")
        default:
            return true
        }
    }

    // NOTE: Previously we had a `defaultModelMetadata` helper here with
    // hardcoded model IDs per provider. This has been removed so that all
    // routing goes through live `fetchRemoteModels` results.
}
