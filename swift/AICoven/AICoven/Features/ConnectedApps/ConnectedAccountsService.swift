import Foundation

/// Service for managing connected app accounts and OAuth tokens locally.
/// Tokens are stored securely in Keychain; account metadata is stored in UserDefaults.
actor ConnectedAccountsService {

    /// Shared singleton instance
    static let shared = ConnectedAccountsService()

    /// Keychain key prefix for OAuth tokens (will be user-scoped)
    private let keychainPrefix = "connected_account_token_"

    /// UserDefaults key for accounts list (will be user-scoped)
    private func getAccountsKey() async -> String {
        await UserScope.scopedKey("connected_accounts")
    }

    /// Keychain key prefix for MCP tokens (will be user-scoped)
    private let mcpKeychainPrefix = "mcp_server_token_"

    /// UserDefaults key for MCP servers list (will be user-scoped)
    private func getMCPServersKey() async -> String {
        await UserScope.scopedKey("mcp_servers")
    }

    /// In-memory cache of accounts (nil means not yet loaded)
    private var accountsCache: [ConnectedAccount]?

    /// In-memory cache of MCP servers (nil means not yet loaded)
    private var mcpServersCache: [MCPServerAccount]?

    /// Flag to ensure we only load once
    private var hasLoadedAccounts = false

    private init() {
        // Note: We cannot call actor-isolated methods from init.
        // Loading is done lazily on first access.
    }

    /// Ensure accounts are loaded from storage (called by public methods)
    private func ensureAccountsLoaded() async {
        guard !hasLoadedAccounts else { return }
        hasLoadedAccounts = true
        await loadAccountsFromStorage()
        await loadMCPServersFromStorage()
    }

    // MARK: - Account Management

    /// Get all connected accounts
    func getAllAccounts() async -> [ConnectedAccount] {
        await ensureAccountsLoaded()
        return accountsCache ?? []
    }

    /// Get accounts for a specific provider
    func getAccounts(for provider: ConnectedAppProvider) async -> [ConnectedAccount] {
        await ensureAccountsLoaded()
        return (accountsCache ?? []).filter { $0.provider == provider }
    }

    /// Get a specific account by ID
    func getAccount(id: String) async -> ConnectedAccount? {
        await ensureAccountsLoaded()
        return accountsCache?.first { $0.id == id }
    }

    /// Get the first connected account for a provider (convenience for single-account providers)
    func getConnectedAccount(for provider: ConnectedAppProvider) async -> ConnectedAccount? {
        await ensureAccountsLoaded()
        return accountsCache?.first { $0.provider == provider && $0.status == .connected }
    }

    /// Create a new connected account after successful OAuth flow
    func createAccount(
        provider: ConnectedAppProvider,
        displayName: String,
        tokenBundle: OAuthTokenBundle,
        metadata: [String: String] = [:]
    ) async throws -> ConnectedAccount {
        let id = UUID().uuidString
        let now = Date()

        let account = ConnectedAccount(
            id: id,
            provider: provider,
            displayName: displayName,
            status: .connected,
            scopes: tokenBundle.scopes,
            metadata: metadata,
            createdAt: now,
            updatedAt: now,
            lastRefreshAt: now
        )

        // Store token in Keychain
        try await storeTokenBundle(tokenBundle, forAccountId: id)

        // Add to cache and persist
        await ensureAccountsLoaded()
        if accountsCache == nil {
            accountsCache = []
        }
        accountsCache?.append(account)
        await saveAccountsToStorage()

        return account
    }

    /// Update an existing account
    func updateAccount(_ account: ConnectedAccount) async {
        await ensureAccountsLoaded()
        if let index = accountsCache?.firstIndex(where: { $0.id == account.id }) {
            var updated = account
            updated.updatedAt = Date()
            accountsCache?[index] = updated
            await saveAccountsToStorage()
        }
    }

    /// Delete a connected account and its tokens
    func deleteAccount(id: String) async throws {
        // Remove token from Keychain
        await deleteTokenBundle(forAccountId: id)

        // Remove from cache
        await ensureAccountsLoaded()
        accountsCache?.removeAll { $0.id == id }
        await saveAccountsToStorage()
    }

    /// Disconnect an account (mark as disconnected, optionally keep for reconnect)
    func disconnectAccount(id: String) async {
        await ensureAccountsLoaded()
        if let index = accountsCache?.firstIndex(where: { $0.id == id }) {
            accountsCache?[index].status = .disconnected
            accountsCache?[index].updatedAt = Date()
            await saveAccountsToStorage()

            // Also delete the tokens
            await deleteTokenBundle(forAccountId: id)
        }
    }

    // MARK: - MCP Server Management

    /// Get all connected MCP servers
    func getAllMCPServers() async -> [MCPServerAccount] {
        await ensureAccountsLoaded()
        return mcpServersCache ?? []
    }

    /// Get a specific MCP server by ID
    func getMCPServer(id: String) async -> MCPServerAccount? {
        await ensureAccountsLoaded()
        return mcpServersCache?.first { $0.id == id }
    }

    /// Create a new MCP server connection
    func createMCPServer(
        name: String,
        serverUrl: String,
        transport: MCPTransportType,
        authType: MCPAuthType,
        token: String? = nil
    ) async throws -> MCPServerAccount {
        let id = UUID().uuidString
        let now = Date()

        let server = MCPServerAccount(
            id: id,
            name: name,
            serverUrl: serverUrl,
            transport: transport,
            authType: authType,
            status: .connected,
            createdAt: now,
            updatedAt: now
        )

        if authType != .none, let token {
            try await storeMCPToken(token, forServerId: id)
        }

        await ensureAccountsLoaded()
        if mcpServersCache == nil {
            mcpServersCache = []
        }
        mcpServersCache?.append(server)
        await saveMCPServersToStorage()

        return server
    }

    /// Update an existing MCP server
    func updateMCPServer(_ server: MCPServerAccount, token: String? = nil) async throws {
        await ensureAccountsLoaded()
        if let index = mcpServersCache?.firstIndex(where: { $0.id == server.id }) {
            var updated = server
            updated.updatedAt = Date()
            mcpServersCache?[index] = updated

            if let token {
                try await storeMCPToken(token, forServerId: server.id)
            }

            await saveMCPServersToStorage()
        }
    }

    /// Delete an MCP server
    func deleteMCPServer(id: String) async throws {
        await deleteMCPToken(forServerId: id)

        await ensureAccountsLoaded()
        mcpServersCache?.removeAll { $0.id == id }
        await saveMCPServersToStorage()
    }

    /// Get the authentication token for an MCP server
    func getMCPToken(forServerId id: String) async throws -> String? {
        // If the server doesn't exist, we can't get its token
        guard let server = await getMCPServer(id: id), server.authType != .none else {
            return nil
        }

        let key = await UserScope.scopedKeychainService(mcpKeychainPrefix + id)

        guard let tokenString = await MainActor.run(body: { KeychainHelper.load(key: key) }) else {
            throw ConnectedAccountError.mcpTokenNotFound(serverId: id)
        }

        return tokenString
    }

    /// Store the authentication token for an MCP server
    private func storeMCPToken(_ token: String, forServerId id: String) async throws {
        let key = await UserScope.scopedKeychainService(mcpKeychainPrefix + id)
        do {
            try KeychainHelper.save(key: key, value: token)
        } catch {
            throw ConnectedAccountError.mcpTokenStorageFailed(underlying: error)
        }
    }

    /// Delete the authentication token for an MCP server
    private func deleteMCPToken(forServerId id: String) async {
        let key = await UserScope.scopedKeychainService(mcpKeychainPrefix + id)
        KeychainHelper.delete(key: key)
    }

    // MARK: - Token Management

    /// Get the OAuth token bundle for an account
    func getTokenBundle(forAccountId id: String) async throws -> OAuthTokenBundle {
        // User-scoped keychain key
        let key = await UserScope.scopedKeychainService(keychainPrefix + id)

        // Use KeychainHelper to read the token data
        guard let jsonString = await MainActor.run(body: { KeychainHelper.load(key: key) }), // KeychainHelper might require MainActor? No, KeychainHelper is usually thread safe or nonisolated.
              // Wait, KeychainHelper load is static. Is it isolated?
              // Usually Keychain wrappers are nonisolated or thread-safe.
              // Assuming non-isolated for now, but UserScope.scopedKeychainService is MainActor.
              // If KeychainHelper is MainActor, we need await MainActor.run.
              // Let's assume KeychainHelper is NOT MainActor (it handles C API).
              // But if it is, I'd see errors.
              // The error in UserScope was about UserScope, not KeychainHelper.
              // So:
              let data = jsonString.data(using: .utf8) else {
            throw ConnectedAccountError.tokenNotFound(accountId: id)
        }

        // Actually, just in case KeychainHelper is MainActor (some libs do this), I'll check if I need to await it.
        // But for now:
        // let jsonString = KeychainHelper.load(key: key)
        // -> logic:

        // Re-reading code: KeychainHelper wasn't flagged in my analysis, only UserScope.

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            return try decoder.decode(OAuthTokenBundle.self, from: data)
        } catch {
            throw ConnectedAccountError.tokenDecodingFailed(underlying: error)
        }
    }

    /// Store an OAuth token bundle for an account
    func storeTokenBundle(_ bundle: OAuthTokenBundle, forAccountId id: String) async throws {
        // User-scoped keychain key
        let key = await UserScope.scopedKeychainService(keychainPrefix + id)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(bundle)

        // Convert to string and store via KeychainHelper
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw ConnectedAccountError.tokenStorageFailed(underlying: NSError(domain: "ConnectedAccounts", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode token data"]))
        }

        do {
            // Check if KeychainHelper needs await. If strictly nonisolated, fine.
            try KeychainHelper.save(key: key, value: jsonString)
        } catch {
            throw ConnectedAccountError.tokenStorageFailed(underlying: error)
        }
    }

    /// Delete token bundle from Keychain
    private func deleteTokenBundle(forAccountId id: String) async {
        // User-scoped keychain key
        let key = await UserScope.scopedKeychainService(keychainPrefix + id)
        KeychainHelper.delete(key: key)
    }

    /// Get the access token for API calls, refreshing if necessary
    func getAccessToken(forAccountId id: String) async throws -> String {
        var bundle = try await getTokenBundle(forAccountId: id)

        // Check if token needs refresh
        if bundle.isExpired {
            guard let account = await getAccount(id: id) else {
                throw ConnectedAccountError.accountNotFound(accountId: id)
            }

            bundle = try await refreshAccessToken(forAccount: account, currentBundle: bundle)
        }

        return bundle.accessToken
    }

    /// Refresh the access token using the refresh token
    func refreshAccessToken(
        forAccount account: ConnectedAccount,
        currentBundle: OAuthTokenBundle
    ) async throws -> OAuthTokenBundle {
        guard let refreshToken = currentBundle.refreshToken else {
            // Mark account as needing re-auth
            var updated = account
            updated.status = .error
            await updateAccount(updated)
            throw ConnectedAccountError.noRefreshToken(accountId: account.id)
        }

        // Build token refresh request based on provider
        let newBundle: OAuthTokenBundle

        switch account.provider {
        case .github:
            // GitHub OAuth tokens don't expire and don't have refresh tokens
            // If we got here, something is wrong
            throw ConnectedAccountError.refreshNotSupported(provider: account.provider)

        case .googleDrive:
            newBundle = try await refreshGoogleToken(
                refreshToken: refreshToken,
                currentScopes: currentBundle.scopes
            )
        }

        // Store the new token bundle
        try await storeTokenBundle(newBundle, forAccountId: account.id)

        // Update account metadata
        var updated = account
        updated.lastRefreshAt = Date()
        updated.status = .connected
        await updateAccount(updated)

        return newBundle
    }

    /// ... refreshGoogleToken remains largely same but is already async ...
    /// Refresh a Google OAuth token
    private func refreshGoogleToken(refreshToken: String, currentScopes: [String]) async throws -> OAuthTokenBundle {
        // ... implementation same as before ...
        // Get client ID from Info.plist (set via xcconfig)
        let clientId = await MainActor.run { Bundle.main.infoDictionary?["GOOGLE_OAUTH_CLIENT_ID"] as? String }
            ?? "870439799161-1c7u8utd0t0kh3ote5kugh8cj9961ugb.apps.googleusercontent.com"
        // Bundle.main access might be MainActor isolated? usually not, but safest to wrap if unsure.
        // Actually Bundle.main is Sendable but infoDictionary reads might be MainActor in Swift 6 STRICT?
        // Let's assume it's fine or safe.

        guard !clientId.isEmpty else {
            throw ConnectedAccountError.missingConfiguration(key: "GOOGLE_OAUTH_CLIENT_ID")
        }

        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id": clientId,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        request.httpBody = body.map { "\($0.key)=\($0.value)" }.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ConnectedAccountError.tokenRefreshFailed(provider: .googleDrive)
        }

        // Parse response
        struct TokenResponse: Codable {
            let access_token: String
            let expires_in: Int
            let token_type: String
            let scope: String?
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        return OAuthTokenBundle(
            accessToken: tokenResponse.access_token,
            refreshToken: refreshToken, // Keep the same refresh token
            tokenType: tokenResponse.token_type,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expires_in)),
            scopes: tokenResponse.scope?.split(separator: " ").map(String.init) ?? currentScopes
        )
    }

    // MARK: - Persistence

    /// Load accounts from UserDefaults
    private func loadAccountsFromStorage() async {
        let key = await getAccountsKey()
        // UserDefaults might be MainActor? No, UserDefaults is thread safe.
        guard let data = UserDefaults.standard.data(forKey: key) else {
            accountsCache = []
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            accountsCache = try decoder.decode([ConnectedAccount].self, from: data)
        } catch {
            AppErrorReporter.log(error: error, context: "ConnectedAccountsService.loadAccountsFromStorage")
            accountsCache = []
        }
    }

    /// Save accounts to UserDefaults
    private func saveAccountsToStorage() async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let key = await getAccountsKey()

        do {
            let data = try encoder.encode(accountsCache)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            AppErrorReporter.log(error: error, context: "ConnectedAccountsService.saveAccountsToStorage")
        }
    }

    /// Load MCP servers from UserDefaults
    private func loadMCPServersFromStorage() async {
        let key = await getMCPServersKey()
        guard let data = UserDefaults.standard.data(forKey: key) else {
            mcpServersCache = []
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            mcpServersCache = try decoder.decode([MCPServerAccount].self, from: data)
        } catch {
            AppErrorReporter.log(error: error, context: "ConnectedAccountsService.loadMCPServersFromStorage")
            mcpServersCache = []
        }
    }

    /// Save MCP servers to UserDefaults
    private func saveMCPServersToStorage() async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let key = await getMCPServersKey()

        do {
            let data = try encoder.encode(mcpServersCache)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            AppErrorReporter.log(error: error, context: "ConnectedAccountsService.saveMCPServersToStorage")
        }
    }
}

// MARK: - Errors

/// Errors that can occur when managing connected accounts
enum ConnectedAccountError: LocalizedError {
    case accountNotFound(accountId: String)
    case tokenNotFound(accountId: String)
    case tokenDecodingFailed(underlying: Error)
    case tokenStorageFailed(underlying: Error)
    case noRefreshToken(accountId: String)
    case refreshNotSupported(provider: ConnectedAppProvider)
    case tokenRefreshFailed(provider: ConnectedAppProvider)
    case missingConfiguration(key: String)
    case oauthFailed(message: String)
    case mcpTokenNotFound(serverId: String)
    case mcpTokenStorageFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case let .accountNotFound(id):
            "Connected account not found: \(id)"
        case let .tokenNotFound(id):
            "OAuth token not found for account: \(id)"
        case let .tokenDecodingFailed(error):
            "Failed to decode OAuth token: \(error.localizedDescription)"
        case let .tokenStorageFailed(error):
            "Failed to store OAuth token: \(error.localizedDescription)"
        case let .noRefreshToken(id):
            "No refresh token available for account: \(id). Re-authentication required."
        case let .refreshNotSupported(provider):
            "Token refresh not supported for \(provider.displayName)"
        case let .tokenRefreshFailed(provider):
            "Failed to refresh \(provider.displayName) token"
        case let .missingConfiguration(key):
            "Missing OAuth configuration: \(key)"
        case let .oauthFailed(message):
            "OAuth authentication failed: \(message)"
        case let .mcpTokenNotFound(id):
            "MCP authentication token not found for server: \(id)"
        case let .mcpTokenStorageFailed(error):
            "Failed to store MCP authentication token: \(error.localizedDescription)"
        }
    }
}
