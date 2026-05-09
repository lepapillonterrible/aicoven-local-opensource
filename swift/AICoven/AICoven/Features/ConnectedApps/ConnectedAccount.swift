import Foundation

/// Represents a connected third-party app account (GitHub, Google Drive, etc.)
/// Stored locally in the database with tokens in Keychain.
/// Conforms to Sendable since all properties are value types.
struct ConnectedAccount: Identifiable, Codable, Equatable {
    /// Unique identifier for this connection
    let id: String

    /// Provider identifier (e.g., "github", "google_drive")
    let provider: ConnectedAppProvider

    /// Display name for the account (e.g., username or email)
    var displayName: String

    /// Current connection status
    var status: ConnectionStatus

    /// OAuth scopes granted by the user
    var scopes: [String]

    /// Provider-specific metadata (e.g., GitHub login, avatar URL)
    var metadata: [String: String]

    /// When the connection was created
    let createdAt: Date

    /// When the connection was last updated
    var updatedAt: Date

    /// When tokens were last refreshed
    var lastRefreshAt: Date?

    // MARK: - Coding Keys

    enum CodingKeys: String, CodingKey {
        case id
        case provider
        case displayName = "display_name"
        case status
        case scopes
        case metadata
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastRefreshAt = "last_refresh_at"
    }
}

/// Supported connected app providers
/// Conforms to Sendable since it's a simple enum.
enum ConnectedAppProvider: String, Codable, CaseIterable {
    case github
    case googleDrive = "google_drive"

    /// Human-readable display name
    var displayName: String {
        switch self {
        case .github: "GitHub"
        case .googleDrive: "Google Drive"
        }
    }

    /// SF Symbol icon name
    var iconName: String {
        switch self {
        case .github: "link.circle.fill"
        case .googleDrive: "folder.fill"
        }
    }

    /// Default OAuth scopes to request
    var defaultScopes: [String] {
        switch self {
        case .github:
            ["repo", "read:user", "user:email"]
        case .googleDrive:
            [
                "https://www.googleapis.com/auth/drive.file",
                "https://www.googleapis.com/auth/documents",
                "https://www.googleapis.com/auth/spreadsheets"
            ]
        }
    }
}

/// Connection status for a connected account
/// Conforms to Sendable since it's a simple enum.
enum ConnectionStatus: String, Codable {
    case connected
    case pending
    case error
    case revoked
    case disconnected
}

/// OAuth token bundle stored in Keychain.
/// Conforms to Sendable since all properties are value types.
struct OAuthTokenBundle: Codable {
    /// The access token for API calls
    var accessToken: String

    /// The refresh token (if provided by the provider)
    var refreshToken: String?

    /// Token type (usually "Bearer")
    var tokenType: String

    /// When the access token expires (if known)
    var expiresAt: Date?

    /// OAuth scopes associated with this token
    var scopes: [String]

    // MARK: - Coding Keys

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresAt = "expires_at"
        case scopes
    }

    /// Check if the token is expired or about to expire (within 5 minutes)
    var isExpired: Bool {
        guard let expiresAt else {
            // If no expiry, assume it's valid (GitHub tokens don't expire)
            return false
        }
        // Add 5-minute buffer
        return expiresAt.addingTimeInterval(-300) <= Date()
    }
}

/// Configuration for OAuth providers
struct OAuthConfig {
    let clientId: String
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let redirectUri: String?
    let scopes: [String]

    /// GitHub OAuth configuration using Device Flow
    /// Note: Client ID should be configured in app settings
    /// No client secret needed - uses Device Flow which is safe for open-source apps
    static func github(clientId: String) -> OAuthConfig {
        OAuthConfig(
            clientId: clientId,
            authorizationEndpoint: "https://github.com/login/device/code",
            tokenEndpoint: "https://github.com/login/oauth/access_token",
            redirectUri: nil, // Device Flow doesn't use redirect URIs
            scopes: ConnectedAppProvider.github.defaultScopes
        )
    }

    /// Google OAuth configuration using PKCE
    /// Note: Client ID should be configured in app settings
    /// No client secret needed - uses PKCE which is safe for native apps
    static func google(clientId: String) -> OAuthConfig {
        OAuthConfig(
            clientId: clientId,
            authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
            tokenEndpoint: "https://oauth2.googleapis.com/token",
            redirectUri: "aicoven://oauth/google/callback",
            scopes: ConnectedAppProvider.googleDrive.defaultScopes
        )
    }
}
