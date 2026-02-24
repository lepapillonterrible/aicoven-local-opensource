import Foundation

/// Anthropic Claude implementation of LLMClient (messages API).
/// Marked @unchecked Sendable because all stored properties are immutable
/// after init and URLSession is thread-safe.
final class AnthropicLLMClient: LLMClient, @unchecked Sendable {
    private let apiKey: String
    private let baseURL: URL
    private let urlSession: URLSession

    /// - Parameters:
    ///   - apiKey: Anthropic API key.
    ///   - baseURL: Base URL for the API (overridable for testing).
    ///   - urlSession: Optional custom URLSession used primarily for tests.
    init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.anthropic.com/v1")!,
        urlSession: URLSession? = nil
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 120
            self.urlSession = URLSession(configuration: config)
        }
    }

    func completeChat(messages: [LLMMessage], model: String, options: ChatOptions) async throws -> LLMChatResponse {
        struct MessageContent: Encodable { let type = "text"
            let text: String
        }
        struct RequestMessage: Encodable { let role: String
            let content: [MessageContent]
        }
        // Native tool calling structures (Anthropic format)
        struct SchemaProperty: Encodable {
            let type: String
            let description: String
        }
        struct InputSchema: Encodable {
            let type: String
            let properties: [String: SchemaProperty]
            let required: [String]
        }
        struct ToolDef: Encodable {
            let name: String
            let description: String
            let input_schema: InputSchema
        }
        struct RequestBody: Encodable {
            let model: String
            let max_tokens: Int
            let system: String?
            let messages: [RequestMessage]
            let temperature: Double
            let tools: [ToolDef]?
        }
        // Response structures — Anthropic returns content blocks that can be
        // "text" or "tool_use"
        struct ContentBlock: Decodable {
            let type: String?
            let text: String?
            // tool_use fields
            let id: String?
            let name: String?
            let input: [String: AnyJSONValue]?
        }
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
        }
        struct ResponseBody: Decodable {
            let content: [ContentBlock]
            let model: String
            let usage: Usage?
            let stop_reason: String?
        }

        let url = baseURL.appendingPathComponent("messages")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let systemContent = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let finalSystem = systemContent.isEmpty ? nil : systemContent

        let reqMessages = messages.filter { $0.role != .system }.map { msg in
            RequestMessage(
                role: msg.role == .user ? "user" : "assistant",
                content: [MessageContent(text: msg.content)]
            )
        }

        // Convert LLMToolDefinition → Anthropic native format
        var anthropicToOriginalName: [String: String] = [:]
        let toolDefs: [ToolDef]? = options.tools?.isEmpty == false ? options.tools!.map { tool in
            var props: [String: SchemaProperty] = [:]
            var requiredParams: [String] = []
            for param in tool.parameters {
                props[param.name] = SchemaProperty(type: param.type, description: param.description)
                if param.required { requiredParams.append(param.name) }
            }

            // Anthropic strictly requires tool names to match ^[a-zA-Z0-9_-]{1,128}$
            let sanitizedName = tool.name.replacingOccurrences(of: ".", with: "_")
            anthropicToOriginalName[sanitizedName] = tool.name

            return ToolDef(
                name: sanitizedName,
                description: tool.description,
                input_schema: InputSchema(type: "object", properties: props, required: requiredParams)
            )
        } : nil

        let body = RequestBody(
            model: model,
            max_tokens: options.maxTokens ?? 4096,
            system: finalSystem,
            messages: reqMessages,
            temperature: options.temperature,
            tools: toolDefs
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            let message = "Anthropic HTTP \(http.statusCode): \(bodyText)"
            throw NSError(
                domain: "AnthropicLLMClient",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        guard !data.isEmpty else {
            throw NSError(
                domain: "AnthropicLLMClient",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Anthropic returned an empty response body."]
            )
        }
        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)

        // Extract text content
        let text = decoded.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined(separator: "\n")
        let msg = LLMMessage(role: .assistant, content: text)

        let usage = decoded.usage.map { u in
            LLMTokenUsage(
                promptTokens: u.input_tokens ?? 0,
                completionTokens: u.output_tokens ?? 0
            )
        }

        // Parse native tool calls from tool_use content blocks
        let toolUseBlocks = decoded.content.filter { $0.type == "tool_use" }
        var toolCalls: [LLMToolCall]? = nil
        if !toolUseBlocks.isEmpty {
            toolCalls = toolUseBlocks.compactMap { block in
                guard let name = block.name else { return nil }
                let originalName = anthropicToOriginalName[name] ?? name
                return LLMToolCall(name: originalName, arguments: block.input ?? [:])
            }
        }

        return LLMChatResponse(
            message: msg,
            providerID: "anthropic",
            modelID: decoded.model,
            usage: usage,
            toolCalls: toolCalls
        )
    }

    func embed(texts: [String], model: String) async throws -> [[Float]] {
        // Anthropic does not currently expose a general-purpose embeddings API
        // in the same way; for now this is unsupported.
        throw NSError(domain: "AnthropicLLMClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Embeddings are not supported for Anthropic in this client."])
    }
}
