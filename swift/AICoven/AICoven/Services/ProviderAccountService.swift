import Foundation
import Security

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

    static func save(key: String, value: String) throws {
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
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func load(key: String) -> String? {
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

    static func delete(key: String) {
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
/// keys are stored in the system Keychain, keyed by provider-account ID. For
/// compatibility with the existing ChatService, we also mirror the most
/// recent key per provider into UserDefaults (e.g. "openai_api_key").
actor ProviderAccountService {
    static let shared = ProviderAccountService()

    /// User-scoped storage key so each Firebase user gets their own provider accounts.
    private var storageKey: String {
        UserScope.scopedKey("provider_accounts.v1")
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

        // Store the API key in the Keychain, and mirror to UserDefaults so the
        // existing ChatService clients (OpenAI/Anthropic/Gemini) can read it.
        try KeychainHelper.save(key: keychainKey(for: id), value: apiKey)
        updateGlobalAPIKeyCache(provider: provider, apiKey: apiKey)

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

        // Cache base URL so LLMConfiguration can build the OllamaLLMClient.
        updateGlobalAPIKeyCache(provider: "ollama", apiKey: baseURL)

        return ProviderAccount(from: local)
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

        // If this was the last account for its provider, clear the global
        // UserDefaults API key hint so the UI can surface a proper error.
        let remainingForProvider = locals.contains { $0.provider == removed.provider }
        if !remainingForProvider {
            clearGlobalAPIKeyCache(provider: removed.provider)
        }
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
        do {
            models = try await fetchRemoteModels(for: account)
        } catch {
            AppErrorReporter.log(error: error, context: "ProviderAccountService.getInitializationStatus.fetchRemoteModels")
            models = []
        }
        return ProviderInitializationStatus(
            providerAccountId: account.id,
            status: "initialized",
            modelMetadata: models
        )
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

    /// Build dynamic ModelDescriptors for all configured provider accounts
    /// using live ListModels responses. Only chat-capable models are included.
    func loadAllModelDescriptors() async throws -> [ModelDescriptor] {
        let locals = try loadLocalAccounts()
        var descriptors: [ModelDescriptor] = []

        for account in locals {
            let providerID = account.provider.lowercased()
            let metadata: [ProviderInitializationStatus.ModelMetadata]
            do {
                metadata = try await fetchRemoteModels(for: account)
            } catch {
                AppErrorReporter.log(error: error, context: "ProviderAccountService.loadAllModelDescriptors.fetchRemoteModels.\(providerID)")
                continue
            }

            for modelMeta in metadata {
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

                descriptors.append(
                    ModelDescriptor(
                        providerID: modelMeta.provider?.lowercased() ?? providerID,
                        modelID: modelMeta.id,
                        maxContextTokens: context,
                        supportsTools: true,
                        supportsEmbeddings: false,
                        costClass: cost
                    )
                )
            }
        }

        return descriptors
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
    private func loadLocalAccounts() throws -> [LocalProviderAccount] {
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

    private func updateGlobalAPIKeyCache(provider: String, apiKey: String) {
        let defaults = UserDefaults.standard
        switch provider.lowercased() {
        case "openai":
            defaults.set(apiKey, forKey: UserScope.scopedKey("openai_api_key"))
        case "anthropic":
            defaults.set(apiKey, forKey: UserScope.scopedKey("anthropic_api_key"))
        case "google", "gemini":
            defaults.set(apiKey, forKey: UserScope.scopedKey("gemini_api_key"))
        case "ollama":
            // For Ollama we cache the base URL rather than an API key.
            defaults.set(apiKey, forKey: UserScope.scopedKey("ollama_base_url"))
        default:
            break
        }
    }

    private func clearGlobalAPIKeyCache(provider: String) {
        let defaults = UserDefaults.standard
        switch provider.lowercased() {
        case "openai":
            defaults.removeObject(forKey: UserScope.scopedKey("openai_api_key"))
        case "anthropic":
            defaults.removeObject(forKey: UserScope.scopedKey("anthropic_api_key"))
        case "google", "gemini":
            defaults.removeObject(forKey: UserScope.scopedKey("gemini_api_key"))
        case "ollama":
            defaults.removeObject(forKey: UserScope.scopedKey("ollama_base_url"))
        default:
            break
        }
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
            struct OpenAIListResponse: Decodable { struct Item: Decodable { let id: String } ; let data: [Item] }
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.httpMethod = "GET"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                throw NSError(domain: "ProviderAccountService", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "OpenAI models HTTP \(http.statusCode): \(body)"])
            }
            let decoded = try JSONDecoder().decode(OpenAIListResponse.self, from: data)
            let chatOnly = decoded.data
                .map { $0.id }
                .filter { isChatModel(provider: "openai", id: $0) }
            let models = chatOnly.isEmpty ? decoded.data.map { $0.id } : chatOnly
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
            guard let apiKey = KeychainHelper.load(key: keychainKey(for: account.id)) ?? UserDefaults.standard.string(forKey: UserScope.scopedKey("gemini_api_key")) else {
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
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                    throw NSError(domain: "ProviderAccountService", code: http.statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: "Gemini models HTTP \(http.statusCode): \(body)"])
                }
                let decoded = try JSONDecoder().decode(GeminiListResponse.self, from: data)
                allModelNames.append(contentsOf: (decoded.models ?? []).map { $0.name })
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
                    contextLength: 128_000  // Ollama doesn't report context length via tags
                )
            }
        default:
            // Other providers: fall back to static metadata for now.
            throw NSError(domain: "ProviderAccountService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No remote model fetch implemented for provider \(provider)"])
        }
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
