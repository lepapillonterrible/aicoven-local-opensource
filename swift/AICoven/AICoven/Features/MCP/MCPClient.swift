import Foundation

/// Errors that can occur during MCP operations
enum MCPClientError: LocalizedError {
    case invalidURL
    case connectionFailed(Error)
    case invalidResponse(String)
    case serverError(String)
    case timeout
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid MCP server URL"
        case let .connectionFailed(err): "Connection failed: \(err.localizedDescription)"
        case let .invalidResponse(msg): "Invalid response from server: \(msg)"
        case let .serverError(msg): "MCP Server error: \(msg)"
        case .timeout: "Request timed out"
        case .notConnected: "Not connected to the MCP server"
        }
    }
}

/// A minimal MCP (Model Context Protocol) client for Swift.
/// Implements tool discovery and execution over HTTP/SSE.
actor MCPClient {
    let server: MCPServerAccount
    let token: String?

    private var session: URLSession

    // For SSE, we would normally hold onto the connection and POST endpoint.
    // For this minimal implementation, we abstract the transport layer.
    private var postEndpoint: URL?
    private var isConnected = false

    init(server: MCPServerAccount, token: String?) {
        self.server = server
        self.token = token

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        session = URLSession(configuration: config)
    }

    /// Connect to the server and establish the session (e.g., SSE stream)
    func connect() async throws {
        guard let url = URL(string: server.serverUrl) else {
            throw MCPClientError.invalidURL
        }

        // In a full implementation, we would open the SSE connection here,
        // listen for the 'endpoint' event, and store it in `postEndpoint`.
        // For streamable_http or simple REST adaptations, the URL might just be the base.
        postEndpoint = url // Fallback for simple HTTP implementations
        isConnected = true
    }

    /// Disconnect from the server
    func disconnect() {
        isConnected = false
        // Close SSE streams if any
    }

    /// Fetch available tools from the server
    func discoverTools() async throws -> [MCPToolDefinition] {
        guard isConnected else {
            try await connect()
        }

        // Send tools/list JSON-RPC request
        let response: MCPListToolsResponse = try await sendRpcRequest(method: "tools/list", params: nil)
        return response.tools
    }

    /// Execute a tool on the server
    func callTool(name: String, arguments: [String: AnyJSONValue]) async throws -> [MCPContentItem] {
        guard isConnected else {
            try await connect()
        }

        let params = CallToolParams(name: name, arguments: arguments)
        let response: MCPCallToolResponse = try await sendRpcRequest(method: "tools/call", params: params)

        if response.isError == true {
            let errorText = response.content.first(where: { $0.type == "text" })?.text ?? "Unknown tool error"
            throw MCPClientError.serverError(errorText)
        }

        return response.content
    }

    // MARK: - Internal RPC Helpers

    private func sendRpcRequest<T: Decodable>(method: String, params: (some Encodable)?) async throws -> T {
        guard let endpoint = postEndpoint else {
            throw MCPClientError.notConnected
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let token, server.authType == .bearer {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if let token, server.authType == .apiKey {
            request.setValue(token, forHTTPHeaderField: "X-Api-Key")
        }

        let rpcReq = JsonRpcRequest(id: UUID().uuidString, method: method, params: params)
        request.httpBody = try JSONEncoder().encode(rpcReq)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPClientError.invalidResponse("Not an HTTP response")
        }

        if !(200 ... 299).contains(httpResponse.statusCode) {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw MCPClientError.serverError("HTTP \(httpResponse.statusCode): \(errorBody)")
        }

        let rpcRes = try JSONDecoder().decode(JsonRpcResponse<T>.self, from: data)

        if let error = rpcRes.error {
            throw MCPClientError.serverError(error.message)
        }

        guard let result = rpcRes.result else {
            throw MCPClientError.invalidResponse("Missing result in JSON-RPC response")
        }

        return result
    }
}

// MARK: - JSON-RPC Models

private struct JsonRpcRequest<P: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: String
    let method: String
    let params: P?
}

private struct JsonRpcResponse<T: Decodable>: Decodable {
    let jsonrpc: String
    let id: String?
    let result: T?
    let error: JsonRpcError?
}

private struct JsonRpcError: Decodable {
    let code: Int
    let message: String
}

// MARK: - MCP Models

struct MCPToolDefinition: Codable, Identifiable, Sendable {
    let name: String
    let description: String?
    let inputSchema: [String: AnyJSONValue]

    var id: String {
        name
    }
}

struct MCPListToolsResponse: Decodable {
    let tools: [MCPToolDefinition]
}

struct CallToolParams: Encodable {
    let name: String
    let arguments: [String: AnyJSONValue]
}

struct MCPContentItem: Decodable {
    let type: String
    let text: String?
    // other data like 'data' for base64 resources can be added here
}

struct MCPCallToolResponse: Decodable {
    let content: [MCPContentItem]
    let isError: Bool?
}
