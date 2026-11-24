import Foundation

/// Represents a configured MCP server connection.
/// Stored locally in UserDefaults with its whole address and its token in
/// the Keychain (an address can carry a key, in its path or its query):
/// the preferences keep only `shownAddress`.
/// Conforms to Sendable since all properties are value types.
struct MCPServerAccount: Identifiable, Codable, Equatable {
    /// Unique identifier for this connection
    let id: String

    /// Display name for the server (e.g., "Zapier MCP")
    var name: String

    /// Server endpoint URL
    var serverUrl: String

    /// Transport type (e.g., "sse" or "stdio", though "sse" and "streamable_http" are more common for remote)
    var transport: MCPTransportType

    /// Authentication type
    var authType: MCPAuthType

    /// Current connection status
    var status: ConnectionStatus

    /// Cached list of tools provided by this server
    var cachedTools: [MCPToolDefinition]? = nil

    /// When the tools were last cached
    var toolsCachedAt: Date? = nil

    /// When the connection was created
    let createdAt: Date

    /// When the connection was last updated
    var updatedAt: Date

    /// On disk only: the whole address is in the Keychain, and
    /// `serverUrl` in the preferences is `shownAddress`.
    var addressInKeychain: Bool? = nil

    /// The address as it is shown and kept outside the Keychain: its
    /// scheme, host and port, with "/…" where it goes on (a path, a query
    /// or a fragment can carry a key, and a user and password always do).
    var shownAddress: String {
        Self.shown(serverUrl)
    }

    static func shown(_ address: String) -> String {
        guard let parts = URLComponents(string: address), let scheme = parts.scheme, let host = parts.host, !host.isEmpty else {
            return "an address that cannot be read"
        }
        let port = parts.port.map { ":\($0)" } ?? ""
        let goesOn = !(parts.path.isEmpty || parts.path == "/") || parts.query != nil || parts.fragment != nil
        return "\(scheme)://\(host)\(port)" + (goesOn ? "/…" : "")
    }

    // MARK: - Coding Keys

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case serverUrl = "server_url"
        case transport
        case authType = "auth_type"
        case status
        case cachedTools = "cached_tools"
        case toolsCachedAt = "tools_cached_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case addressInKeychain = "address_in_keychain"
    }
}

/// Supported MCP transport types
enum MCPTransportType: String, Codable {
    case sse
    case streamableHttp = "streamable_http"
}

/// Supported MCP authentication types
enum MCPAuthType: String, Codable {
    case none
    case bearer
    case apiKey = "api_key"
}
