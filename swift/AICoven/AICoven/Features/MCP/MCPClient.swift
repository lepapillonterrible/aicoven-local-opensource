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
            return try await discoverTools()
        }

        // Send tools/list JSON-RPC request
        let response: MCPListToolsResponse = try await sendRpcRequest(method: "tools/list", params: [String: String]?.none)
        return response.tools
    }

    /// Execute a tool on the server
    func callTool(name: String, arguments: [String: AnyJSONValue]) async throws -> [MCPContentItem] {
        guard isConnected else {
            try await connect()
            return try await callTool(name: name, arguments: arguments)
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
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")

        if let token, server.authType == .bearer {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if let token, server.authType == .apiKey {
            request.setValue(token, forHTTPHeaderField: "X-Api-Key")
        }

        var dict: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": method
        ]

        if let params {
            let paramsData = try JSONEncoder().encode(params)
            let paramsObj = try JSONSerialization.jsonObject(with: paramsData)
            dict["params"] = paramsObj
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: dict)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPClientError.invalidResponse("Not an HTTP response")
        }

        if !(200 ... 299).contains(httpResponse.statusCode) {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw MCPClientError.serverError("HTTP \(httpResponse.statusCode): \(errorBody)")
        }

        // The server may respond with plain JSON or an SSE stream.
        // Detect the Content-Type and extract the JSON-RPC payload accordingly.
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
        let jsonData: Data

        if contentType.contains("text/event-stream") {
            // SSE response: extract JSON from `data:` lines
            guard let body = String(data: data, encoding: .utf8) else {
                throw MCPClientError.invalidResponse("Could not decode SSE body as UTF-8")
            }
            // Collect all `data:` payloads and concatenate (some servers split across lines)
            let dataLines = body.components(separatedBy: "\n")
                .filter { $0.hasPrefix("data:") }
                .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            guard !dataLines.isEmpty else {
                throw MCPClientError.invalidResponse("SSE stream contained no data lines")
            }

            // Use the last non-empty data payload (the JSON-RPC result)
            guard let payloadData = dataLines.last?.data(using: .utf8) else {
                throw MCPClientError.invalidResponse("Could not encode SSE data as UTF-8")
            }
            jsonData = payloadData
        } else {
            // Plain JSON response
            jsonData = data
        }

        let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        guard let dict = json else {
            throw MCPClientError.invalidResponse("Invalid JSON format")
        }

        let decoder = JSONDecoder()

        if let rawError = dict["error"] {
            let errorData = try JSONSerialization.data(withJSONObject: rawError)
            let parsedError = try decoder.decode(JsonRpcError.self, from: errorData)
            throw MCPClientError.serverError(parsedError.message)
        }

        guard let rawResult = dict["result"] else {
            throw MCPClientError.invalidResponse("Missing result in JSON-RPC response")
        }

        let resultData = try JSONSerialization.data(withJSONObject: rawResult)
        return try decoder.decode(T.self, from: resultData)
    }
}

// MARK: - JSON-RPC Models

private struct JsonRpcError: Decodable {
    let code: Int
    let message: String

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
    }

    enum CodingKeys: String, CodingKey {
        case code, message
    }
}

// MARK: - MCP Models

struct MCPToolDefinition: Codable, Equatable, Identifiable {
    let name: String
    let description: String?
    let inputSchema: [String: AnyJSONValue]

    var id: String {
        name
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        inputSchema = try container.decode([String: AnyJSONValue].self, forKey: .inputSchema)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(inputSchema, forKey: .inputSchema)
    }

    enum CodingKeys: String, CodingKey {
        case name, description, inputSchema
    }
}

struct MCPListToolsResponse: Decodable {
    let tools: [MCPToolDefinition]

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tools = try container.decode([MCPToolDefinition].self, forKey: .tools)
    }

    enum CodingKeys: String, CodingKey {
        case tools
    }
}

struct CallToolParams: Encodable {
    let name: String
    let arguments: [String: AnyJSONValue]

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(arguments, forKey: .arguments)
    }

    enum CodingKeys: String, CodingKey {
        case name, arguments
    }
}

struct MCPContentItem: Decodable {
    let type: String
    let text: String?
    // other data like 'data' for base64 resources can be added here

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        text = try container.decodeIfPresent(String.self, forKey: .text)
    }

    enum CodingKeys: String, CodingKey {
        case type, text
    }
}

struct MCPCallToolResponse: Decodable {
    let content: [MCPContentItem]
    let isError: Bool?

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decode([MCPContentItem].self, forKey: .content)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError)
    }

    enum CodingKeys: String, CodingKey {
        case content, isError
    }
}
