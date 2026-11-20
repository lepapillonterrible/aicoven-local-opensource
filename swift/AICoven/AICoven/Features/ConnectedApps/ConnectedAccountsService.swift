import Foundation

/// Service for managing connected app accounts and OAuth tokens locally.
/// Tokens are stored securely in Keychain; account metadata is stored in UserDefaults.
actor ConnectedAccountsService {

    /// Shared singleton instance
    static let shared = ConnectedAccountsService()

    /// Keychain key prefix for OAuth tokens (will be user-scoped)
    private let keychainPrefix = "connected_account_token_"

    /// Keychain key prefix for MCP tokens (will be user-scoped)
    private let mcpKeychainPrefix = "mcp_server_token_"

    /// The signed-in account: connections are kept apart by account.
    private let currentUser: @Sendable () async -> String

    /// Where the lists of accounts and MCP servers are kept.
    private let defaults: UserDefaults

    /// Where tokens are kept: the Keychain, or a test's stand-in.
    nonisolated struct TokenStore {
        var save: @Sendable (_ key: String, _ value: String, _ service: String) throws -> Void
        var load: @Sendable (_ key: String, _ service: String) -> String?
        var delete: @Sendable (_ key: String, _ service: String) -> Void

        static let keychain = TokenStore(
            save: { try KeychainHelper.save(key: $0, value: $1, in: $2) },
            load: { KeychainHelper.load(key: $0, in: $1) },
            delete: { KeychainHelper.delete(key: $0, in: $1) }
        )
    }

    private let tokens: TokenStore

    /// Asks Figma who a token belongs to; a test answers in Figma's place.
    private let figmaIdentity: @Sendable (_ token: String) async throws -> FigmaToolService.Identity

    /// The account whose connections are in memory, or nil before any are.
    private var loadedFor: String?

    /// In-memory cache of accounts (nil means not yet loaded)
    private var accountsCache: [ConnectedAccount]?

    /// In-memory cache of MCP servers (nil means not yet loaded)
    private var mcpServersCache: [MCPServerAccount]?

    init(
        currentUser: @escaping @Sendable () async -> String = { await MainActor.run { UserScope.currentUserID } },
        defaults: UserDefaults = .standard,
        tokens: TokenStore = .keychain,
        figmaIdentity: @escaping @Sendable (_ token: String) async throws -> FigmaToolService.Identity = { try await FigmaToolService.identity(token: $0) }
    ) {
        self.currentUser = currentUser
        self.defaults = defaults
        self.tokens = tokens
        self.figmaIdentity = figmaIdentity
    }

    /// Makes what is in memory the signed-in account's, and says whose it
    /// is (called first by every public method). After another account
    /// signs in, the one before's connections are put down and this one's
    /// read: they are never shown or used as another account's.
    ///
    /// A method that changes something waits for nothing after this: the
    /// lists and tokens it reads and writes are all this one account's,
    /// under names spelled from it, whoever signs in meanwhile. The two
    /// that must wait (`refreshAccessToken` and `connectFigma`, each for
    /// its provider) ask again afterwards and keep nothing if the account
    /// is another by then.
    @discardableResult
    private func ensureAccountsLoaded() async -> String {
        let user = await currentUser()
        // Nothing waits from here on: what is in memory is one account's whole.
        if loadedFor != user {
            loadedFor = user
            loadAccountsFromStorage()
            loadMCPServersFromStorage()
        }
        return user
    }

    /// The key a list is kept under: the account's in memory.
    private func storageKey(_ base: String) -> String? {
        loadedFor.map { UserScope.scopedKey(base, for: $0) }
    }

    /// The Keychain names of an account's token, as they have always been
    /// spelled: the key and the service both carry the account.
    private func tokenName(_ base: String, of owner: String) -> (key: String, service: String) {
        (UserScope.scopedKeychainService(base, for: owner), KeychainHelper.service(for: owner))
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

        // The token and the account are kept for the account signed in
        // now, with nothing waited for between them.
        let owner = await ensureAccountsLoaded()
        try storeTokenBundle(tokenBundle, forAccountId: id, of: owner)

        if accountsCache == nil {
            accountsCache = []
        }
        accountsCache?.append(account)
        saveAccountsToStorage()

        return account
    }

    /// Update an existing account
    func updateAccount(_ account: ConnectedAccount) async {
        await ensureAccountsLoaded()
        if let index = accountsCache?.firstIndex(where: { $0.id == account.id }) {
            var updated = account
            updated.updatedAt = Date()
            accountsCache?[index] = updated
            saveAccountsToStorage()
        }
    }

    /// Delete a connected account and its tokens
    func deleteAccount(id: String) async throws {
        let owner = await ensureAccountsLoaded()
        if accountsCache?.contains(where: { $0.id == id && $0.provider == .figma }) == true { figmaChanges += 1 }
        deleteTokenBundle(forAccountId: id, of: owner)
        accountsCache?.removeAll { $0.id == id }
        saveAccountsToStorage()
    }

    /// Disconnect an account (mark as disconnected, optionally keep for reconnect)
    func disconnectAccount(id: String) async {
        let owner = await ensureAccountsLoaded()
        if let index = accountsCache?.firstIndex(where: { $0.id == id }) {
            if accountsCache?[index].provider == .figma { figmaChanges += 1 }
            accountsCache?[index].status = .disconnected
            accountsCache?[index].updatedAt = Date()
            saveAccountsToStorage()

            // Also delete the tokens
            deleteTokenBundle(forAccountId: id, of: owner)
        }
    }

    // MARK: - Figma, connected with a token

    /// Why a Figma token was not taken.
    enum FigmaTokenRefusal: Error, Equatable {
        /// It says nothing, or is longer than a token is.
        case notAToken
        /// Figma did not accept it.
        case refused
        /// It is of another Figma account than the one whose token is
        /// being replaced.
        case otherAccount
        /// The connection being given a new token is no longer there, or
        /// another account signed in to the app while Figma was asked.
        case changed
    }

    /// The Figma metadata key that holds Figma's id of the user.
    static let figmaUserKey = "figma_user_id"

    /// Counts what is done to the Figma connection (a token given, the
    /// connection disconnected or deleted). A token whose check with
    /// Figma was overtaken by any of these is not kept.
    private var figmaChanges = 0

    /// Connects Figma with a personal access token, or gives the
    /// connection `replacing` a new one. The token is checked with Figma
    /// first (who it belongs to); nothing is kept of a token Figma does
    /// not accept. A new token for a connection must be of the same Figma
    /// account. The token is kept in the Keychain and is never returned.
    func connectFigma(token given: String, replacing accountID: String? = nil) async throws -> ConnectedAccount {
        let token = given.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.count <= FigmaToolService.longestToken else { throw FigmaTokenRefusal.notAToken }

        let owner = await ensureAccountsLoaded()
        figmaChanges += 1
        let attempt = figmaChanges
        let who: FigmaToolService.Identity
        do {
            who = try await figmaIdentity(token)
        } catch FigmaError.tokenRefused {
            throw FigmaTokenRefusal.refused
        }
        // Figma was waited for. What follows is for the account that
        // asked, with nothing more waited for; and only if the person has
        // not called it off (the sheet was closed), given another token,
        // or disconnected Figma meanwhile.
        let sameOwner = await ensureAccountsLoaded() == owner
        // Nothing waits from here to the end.
        try Task.checkCancellation()
        guard sameOwner, attempt == figmaChanges else { throw FigmaTokenRefusal.changed }

        let bundle = OAuthTokenBundle(accessToken: token, refreshToken: nil, tokenType: "X-Figma-Token", expiresAt: nil, scopes: [])
        let now = Date()

        if let accountID {
            // A connection that was disconnected is not brought back by
            // a token given before that.
            guard let index = accountsCache?.firstIndex(where: { $0.id == accountID && $0.provider == .figma }), var account = accountsCache?[index],
                  account.status == .connected || account.status == .error else {
                throw FigmaTokenRefusal.changed
            }
            guard account.metadata[Self.figmaUserKey] == who.id else { throw FigmaTokenRefusal.otherAccount }
            try storeTokenBundle(bundle, forAccountId: accountID, of: owner)
            account.displayName = who.label
            account.status = .connected
            account.updatedAt = now
            account.lastRefreshAt = now
            accountsCache?[index] = account
            saveAccountsToStorage()
            return account
        }

        let account = ConnectedAccount(
            id: UUID().uuidString,
            provider: .figma,
            displayName: who.label,
            status: .connected,
            scopes: [],
            metadata: [Self.figmaUserKey: who.id, "source": "personal_access_token"],
            createdAt: now,
            updatedAt: now,
            lastRefreshAt: now
        )
        try storeTokenBundle(bundle, forAccountId: account.id, of: owner)
        // One Figma connection is used: an earlier one is put down, with
        // its token.
        for earlier in accountsCache ?? [] where earlier.provider == .figma {
            deleteTokenBundle(forAccountId: earlier.id, of: owner)
        }
        accountsCache?.removeAll { $0.provider == .figma }
        accountsCache = (accountsCache ?? []) + [account]
        saveAccountsToStorage()
        return account
    }

    /// Marks a Figma connection as one whose token Figma has refused: it
    /// is not used again until the person gives it a new token. Only if
    /// `token` is still the one it keeps: a refusal of a token that has
    /// since been replaced says nothing of the new one.
    func markFigmaTokenRefused(accountID: String, token: String) async {
        let owner = await ensureAccountsLoaded()
        guard let index = accountsCache?.firstIndex(where: { $0.id == accountID && $0.provider == .figma && $0.status == .connected }),
              (try? tokenBundle(forAccountId: accountID, of: owner))?.accessToken == token else { return }
        accountsCache?[index].status = .error
        accountsCache?[index].updatedAt = Date()
        saveAccountsToStorage()
    }

    /// The Figma connection whose token Figma has refused, which waits
    /// for a new one; nil if there is none.
    func figmaAccountNeedingAToken() async -> ConnectedAccount? {
        await ensureAccountsLoaded()
        return ConnectedAppProvider.figma.accountWaitingForAToken(in: accountsCache ?? [])
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

        // The token and the server are kept for the account signed in now,
        // with nothing waited for between them.
        let owner = await ensureAccountsLoaded()
        if authType != .none, let token {
            try storeMCPToken(token, forServerId: id, of: owner)
        }

        if mcpServersCache == nil {
            mcpServersCache = []
        }
        mcpServersCache?.append(server)
        saveMCPServersToStorage()

        return server
    }

    /// Update an existing MCP server
    func updateMCPServer(_ server: MCPServerAccount, token: String? = nil) async throws {
        let owner = await ensureAccountsLoaded()
        if let index = mcpServersCache?.firstIndex(where: { $0.id == server.id }) {
            var updated = server
            updated.updatedAt = Date()
            mcpServersCache?[index] = updated

            if let token {
                try storeMCPToken(token, forServerId: server.id, of: owner)
            }

            saveMCPServersToStorage()
        }
    }

    /// Keeps a server's freshly listed tools on the server as it is stored
    /// now, in one step: what is checked is what is written. With
    /// `unlessListedSince`, nothing is kept if its tools have been listed
    /// already (a listing that started earlier does not replace a later
    /// one's). False if the server is gone or was left as it is.
    @discardableResult
    func cacheMCPTools(_ tools: [MCPToolDefinition], forServerId id: String, unlessListedSince: Bool = false) async -> Bool {
        await ensureAccountsLoaded()
        // Nothing waits between here and the write.
        guard let index = mcpServersCache?.firstIndex(where: { $0.id == id }), var server = mcpServersCache?[index] else { return false }
        if unlessListedSince, server.toolsCachedAt != nil { return false }
        let now = Date()
        server.cachedTools = tools
        server.toolsCachedAt = now
        server.status = .connected
        server.updatedAt = now
        mcpServersCache?[index] = server
        saveMCPServersToStorage()
        return true
    }

    /// Delete an MCP server
    func deleteMCPServer(id: String) async throws {
        let owner = await ensureAccountsLoaded()
        deleteMCPToken(forServerId: id, of: owner)
        mcpServersCache?.removeAll { $0.id == id }
        saveMCPServersToStorage()
    }

    /// Get the authentication token for an MCP server
    func getMCPToken(forServerId id: String) async throws -> String? {
        let owner = await ensureAccountsLoaded()
        // If the server doesn't exist, we can't get its token
        guard let server = mcpServersCache?.first(where: { $0.id == id }), server.authType != .none else {
            return nil
        }

        let name = tokenName(mcpKeychainPrefix + id, of: owner)
        guard let tokenString = tokens.load(name.key, name.service) else {
            throw ConnectedAccountError.mcpTokenNotFound(serverId: id)
        }

        return tokenString
    }

    /// Store the authentication token for an MCP server of `owner`.
    private func storeMCPToken(_ token: String, forServerId id: String, of owner: String) throws {
        let name = tokenName(mcpKeychainPrefix + id, of: owner)
        do {
            try tokens.save(name.key, token, name.service)
        } catch {
            throw ConnectedAccountError.mcpTokenStorageFailed(underlying: error)
        }
    }

    /// Delete the authentication token for an MCP server of `owner`.
    private func deleteMCPToken(forServerId id: String, of owner: String) {
        let name = tokenName(mcpKeychainPrefix + id, of: owner)
        tokens.delete(name.key, name.service)
    }

    // MARK: - Token Management

    /// Get the OAuth token bundle for an account
    func getTokenBundle(forAccountId id: String) async throws -> OAuthTokenBundle {
        let owner = await ensureAccountsLoaded()
        return try tokenBundle(forAccountId: id, of: owner)
    }

    private func tokenBundle(forAccountId id: String, of owner: String) throws -> OAuthTokenBundle {
        let name = tokenName(keychainPrefix + id, of: owner)
        guard let jsonString = tokens.load(name.key, name.service), let data = jsonString.data(using: .utf8) else {
            throw ConnectedAccountError.tokenNotFound(accountId: id)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            return try decoder.decode(OAuthTokenBundle.self, from: data)
        } catch {
            throw ConnectedAccountError.tokenDecodingFailed(underlying: error)
        }
    }

    /// Store an OAuth token bundle for an account of `owner`.
    private func storeTokenBundle(_ bundle: OAuthTokenBundle, forAccountId id: String, of owner: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(bundle)

        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw ConnectedAccountError.tokenStorageFailed(underlying: NSError(domain: "ConnectedAccounts", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode token data"]))
        }

        let name = tokenName(keychainPrefix + id, of: owner)
        do {
            try tokens.save(name.key, jsonString, name.service)
        } catch {
            throw ConnectedAccountError.tokenStorageFailed(underlying: error)
        }
    }

    /// Delete the token bundle of an account of `owner`.
    private func deleteTokenBundle(forAccountId id: String, of owner: String) {
        let name = tokenName(keychainPrefix + id, of: owner)
        tokens.delete(name.key, name.service)
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
        // A token the person pasted is not refreshed: it works until the
        // expiry set where it was made, and is then replaced by them. Its
        // connection is left as it is.
        if account.provider.connectsWithToken {
            throw ConnectedAccountError.refreshNotSupported(provider: account.provider)
        }
        let owner = await ensureAccountsLoaded()
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

        case .figma:
            // Not reached: a pasted token is turned away above.
            throw ConnectedAccountError.refreshNotSupported(provider: account.provider)
        }

        // The provider was waited for. The new token is kept only if the
        // account it was asked for is still the one signed in and still has
        // this connection, and then with nothing more waited for.
        guard await ensureAccountsLoaded() == owner, let index = accountsCache?.firstIndex(where: { $0.id == account.id }) else {
            throw ConnectedAccountError.accountNotFound(accountId: account.id)
        }
        try storeTokenBundle(newBundle, forAccountId: account.id, of: owner)

        // Update account metadata
        var updated = account
        updated.lastRefreshAt = Date()
        updated.status = .connected
        updated.updatedAt = Date()
        accountsCache?[index] = updated
        saveAccountsToStorage()

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
    private func loadAccountsFromStorage() {
        guard let key = storageKey("connected_accounts"), let data = defaults.data(forKey: key) else {
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
    private func saveAccountsToStorage() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let key = storageKey("connected_accounts") else { return }

        do {
            let data = try encoder.encode(accountsCache)
            defaults.set(data, forKey: key)
        } catch {
            AppErrorReporter.log(error: error, context: "ConnectedAccountsService.saveAccountsToStorage")
        }
    }

    /// Load MCP servers from UserDefaults
    private func loadMCPServersFromStorage() {
        guard let key = storageKey("mcp_servers"), let data = defaults.data(forKey: key) else {
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
    private func saveMCPServersToStorage() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let key = storageKey("mcp_servers") else { return }

        do {
            let data = try encoder.encode(mcpServersCache)
            defaults.set(data, forKey: key)
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
