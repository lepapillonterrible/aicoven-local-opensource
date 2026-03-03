import Foundation

/// Represents a configured MCP server connection.
/// Stored locally in UserDefaults with authentication tokens in Keychain.
/// Conforms to Sendable since all properties are value types.
struct MCPServerAccount: Identifiable, Codable, Equatable, Sendable {
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
    var cachedTools: [MCPToolDefinition]?

    /// When the tools were last cached
    var toolsCachedAt: Date?

    /// When the connection was created
    let createdAt: Date

    /// When the connection was last updated
    var updatedAt: Date

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
    }
}

/// Supported MCP transport types
enum MCPTransportType: String, Codable, Sendable {
    case sse
    case streamableHttp = "streamable_http"
}

/// Supported MCP authentication types
enum MCPAuthType: String, Codable, Sendable {
    case none
    case bearer
    case apiKey = "api_key"
}
