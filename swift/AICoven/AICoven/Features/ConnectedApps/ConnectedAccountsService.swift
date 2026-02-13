import Foundation

/// Service for managing connected app accounts and OAuth tokens locally.
/// Tokens are stored securely in Keychain; account metadata is stored in UserDefaults.
actor ConnectedAccountsService {

    /// Shared singleton instance
    static let shared = ConnectedAccountsService()

    /// Keychain key prefix for OAuth tokens
    private let keychainPrefix = "connected_account_token_"

    /// UserDefaults key for accounts list
    private let accountsKey = "connected_accounts"

    /// In-memory cache of accounts (nil means not yet loaded)
    private var accountsCache: [ConnectedAccount]?

    /// Flag to ensure we only load once
    private var hasLoadedAccounts = false

    private init() {
        // Note: We cannot call actor-isolated methods from init.
        // Loading is done lazily on first access.
    }

    /// Ensure accounts are loaded from storage (called by public methods)
    private func ensureAccountsLoaded() {
        guard !hasLoadedAccounts else { return }
        hasLoadedAccounts = true
        loadAccountsFromStorage()
    }

    // MARK: - Account Management

    /// Get all connected accounts
    func getAllAccounts() -> [ConnectedAccount] {
        ensureAccountsLoaded()
        return accountsCache ?? []
    }

    /// Get accounts for a specific provider
    func getAccounts(for provider: ConnectedAppProvider) -> [ConnectedAccount] {
        ensureAccountsLoaded()
        return (accountsCache ?? []).filter { $0.provider == provider }
    }

    /// Get a specific account by ID
    func getAccount(id: String) -> ConnectedAccount? {
        ensureAccountsLoaded()
        return accountsCache?.first { $0.id == id }
    }

    /// Get the first connected account for a provider (convenience for single-account providers)
    func getConnectedAccount(for provider: ConnectedAppProvider) -> ConnectedAccount? {
        ensureAccountsLoaded()
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
        try storeTokenBundle(tokenBundle, forAccountId: id)

        // Add to cache and persist
        ensureAccountsLoaded()
        if accountsCache == nil {
            accountsCache = []
        }
        accountsCache?.append(account)
        saveAccountsToStorage()

        return account
    }

    /// Update an existing account
    func updateAccount(_ account: ConnectedAccount) {
        ensureAccountsLoaded()
        if let index = accountsCache?.firstIndex(where: { $0.id == account.id }) {
            var updated = account
            updated.updatedAt = Date()
            accountsCache?[index] = updated
            saveAccountsToStorage()
        }
    }

    /// Delete a connected account and its tokens
    func deleteAccount(id: String) throws {
        // Remove token from Keychain
        deleteTokenBundle(forAccountId: id)

        // Remove from cache
        ensureAccountsLoaded()
        accountsCache?.removeAll { $0.id == id }
        saveAccountsToStorage()
    }

    /// Disconnect an account (mark as disconnected, optionally keep for reconnect)
    func disconnectAccount(id: String) {
        ensureAccountsLoaded()
        if let index = accountsCache?.firstIndex(where: { $0.id == id }) {
            accountsCache?[index].status = .disconnected
            accountsCache?[index].updatedAt = Date()
            saveAccountsToStorage()

            // Also delete the tokens
            deleteTokenBundle(forAccountId: id)
        }
    }

    // MARK: - Token Management

    /// Get the OAuth token bundle for an account
    func getTokenBundle(forAccountId id: String) throws -> OAuthTokenBundle {
        let key = keychainPrefix + id

        // Use KeychainHelper to read the token data
        guard let jsonString = KeychainHelper.load(key: key),
              let data = jsonString.data(using: .utf8) else {
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

    /// Store an OAuth token bundle for an account
    func storeTokenBundle(_ bundle: OAuthTokenBundle, forAccountId id: String) throws {
        let key = keychainPrefix + id

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(bundle)

        // Convert to string and store via KeychainHelper
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw ConnectedAccountError.tokenStorageFailed(underlying: NSError(domain: "ConnectedAccounts", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode token data"]))
        }

        do {
            try KeychainHelper.save(key: key, value: jsonString)
        } catch {
            throw ConnectedAccountError.tokenStorageFailed(underlying: error)
        }
    }

    /// Delete token bundle from Keychain
    private func deleteTokenBundle(forAccountId id: String) {
        let key = keychainPrefix + id
        KeychainHelper.delete(key: key)
    }

    /// Get the access token for API calls, refreshing if necessary
    func getAccessToken(forAccountId id: String) async throws -> String {
        var bundle = try getTokenBundle(forAccountId: id)

        // Check if token needs refresh
        if bundle.isExpired {
            guard let account = getAccount(id: id) else {
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
            updateAccount(updated)
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
        try storeTokenBundle(newBundle, forAccountId: account.id)

        // Update account metadata
        var updated = account
        updated.lastRefreshAt = Date()
        updated.status = .connected
        updateAccount(updated)

        return newBundle
    }

    /// Refresh a Google OAuth token
    private func refreshGoogleToken(refreshToken: String, currentScopes: [String]) async throws -> OAuthTokenBundle {
        // Get client ID from Info.plist (set via xcconfig)
        let clientId = Bundle.main.infoDictionary?["GOOGLE_OAUTH_CLIENT_ID"] as? String
            ?? "870439799161-1c7u8utd0t0kh3ote5kugh8cj9961ugb.apps.googleusercontent.com"
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
        guard let data = UserDefaults.standard.data(forKey: accountsKey) else {
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

        do {
            let data = try encoder.encode(accountsCache)
            UserDefaults.standard.set(data, forKey: accountsKey)
        } catch {
            AppErrorReporter.log(error: error, context: "ConnectedAccountsService.saveAccountsToStorage")
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
        }
    }
}
