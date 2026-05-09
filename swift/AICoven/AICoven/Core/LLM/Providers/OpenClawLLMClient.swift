import Foundation

/// OpenClaw client implementation of LLMClient.
///
/// OpenClaw is a self-hosted LLM proxy/gateway that presents an OpenAI-compatible API.
/// This client connects to user-configurable base URLs for local or private deployments.
///
/// Configuration keys (via UserDefaults):
/// - openclaw_base_url: The base URL of your OpenClaw instance (default: http://localhost:3000)
/// - openclaw_api_key: Optional API key (many local deployments don't require auth)
/// - openclaw_model: Default model ID to use (optional)
/// - openclaw_context_tokens: Context window size (default: 4096)
///
/// Environment variables:
/// - OPENCLAW_BASE_URL
/// - OPENCLAW_API_KEY
///
/// Marked @unchecked Sendable because all stored properties are immutable
/// after init and URLSession is thread-safe.
final class OpenClawLLMClient: LLMClient, @unchecked Sendable {
    private let apiKey: String?
    private let baseURL: URL
    private let urlSession: URLSession

    /// Default base URL for local OpenClaw instances.
    static let defaultBaseURL = URL(string: "http://localhost:3000")!

    /// - Parameters:
    ///   - baseURL: Base URL for OpenClaw API (overridable for self-hosted).
    ///   - apiKey: Optional API key (many local deployments don't require auth).
    ///   - urlSession: Optional custom URLSession used primarily for tests.
    init(
        baseURL: URL? = nil,
        apiKey: String? = nil,
        urlSession: URLSession? = nil
    ) {
        // Resolve base URL
        if let providedURL = baseURL {
            self.baseURL = providedURL
        } else if let envURL = ProcessInfo.processInfo.environment["OPENCLAW_BASE_URL"],
                  let url = URL(string: envURL) {
            self.baseURL = url
        } else {
            self.baseURL = OpenClawLLMClient.defaultBaseURL
        }

        // Resolve API key
        if let providedKey = apiKey {
            self.apiKey = providedKey
        } else if let envKey = ProcessInfo.processInfo.environment["OPENCLAW_API_KEY"], !envKey.isEmpty {
            self.apiKey = envKey
        } else {
            self.apiKey = nil
        }

        // Configure URLSession
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 120 // Longer timeout for local models
            config.timeoutIntervalForResource = 300
            self.urlSession = URLSession(configuration: config)
        }
    }

    /// Creates a shared instance configured from UserDefaults.
    /// Used by LLMConfiguration.makeDefaultClients().
    convenience init?() {
        let defaults = UserDefaults.standard

        // Base URL is required
        let baseURLString: String
        if let url = defaults.string(forKey: UserScope.scopedKey("openclaw_base_url")), !url.isEmpty {
            baseURLString = url
        } else if let envURL = ProcessInfo.processInfo.environment["OPENCLAW_BASE_URL"], !envURL.isEmpty {
            baseURLString = envURL
        } else {
            return nil // No base URL configured
        }

        guard let baseURL = URL(string: baseURLString) else {
            return nil
        }

        // API key is optional
        let apiKey: String?
        if let key = defaults.string(forKey: UserScope.scopedKey("openclaw_api_key")), !key.isEmpty {
            apiKey = key
        } else if let envKey = ProcessInfo.processInfo.environment["OPENCLAW_API_KEY"], !envKey.isEmpty {
            apiKey = envKey
        } else {
            apiKey = nil
        }

        self.init(baseURL: baseURL, apiKey: apiKey)
    }

    // MARK: - LLMClient

    func completeChat(messages: [LLMMessage], model: String, options: ChatOptions) async throws -> LLMChatResponse {
        struct RequestMessage: Encodable {
            let role: String
            let content: String
        }

        // Tool calling structures (OpenAI-compatible)
        struct FunctionProperty: Encodable {
            let type: String
            let description: String
        }
        struct FunctionParameters: Encodable {
            let type: String
            let properties: [String: FunctionProperty]
            let required: [String]
        }
        struct FunctionDef: Encodable {
            let name: String
            let description: String
            let parameters: FunctionParameters
        }
        struct ToolDef: Encodable {
            let type: String
            let function: FunctionDef
        }
        struct RequestBody: Encodable {
            let model: String
            let messages: [RequestMessage]
            let temperature: Double?
            let max_tokens: Int?
            let tools: [ToolDef]?
        }

        // Response structures
        struct ToolCallResponse: Decodable {
            struct FunctionCall: Decodable {
                let name: String
                let arguments: String // JSON string
            }
            let id: String?
            let type: String?
            let function: FunctionCall
        }
        struct ResponseBody: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let role: String?
                    let content: String?
                    let tool_calls: [ToolCallResponse]?
                }
                let message: Message
                let finish_reason: String?
            }
            struct UsageBody: Decodable {
                let prompt_tokens: Int?
                let completion_tokens: Int?
                let total_tokens: Int?
            }
            let choices: [Choice]
            let usage: UsageBody?
            let model: String?
        }

        let url = baseURL.appendingPathComponent("/v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let reqMessages = messages.map { msg in
            RequestMessage(role: msg.role.rawValue, content: msg.content)
        }

        // Convert LLMToolDefinition → OpenAI-compatible format
        let toolDefs: [ToolDef]? = options.tools?.isEmpty == false ? options.tools!.map { tool in
            var props: [String: FunctionProperty] = [:]
            var requiredParams: [String] = []
            for param in tool.parameters {
                props[param.name] = FunctionProperty(type: param.type, description: param.description)
                if param.required { requiredParams.append(param.name) }
            }
            return ToolDef(
                type: "function",
                function: FunctionDef(
                    name: tool.name,
                    description: tool.description,
                    parameters: FunctionParameters(type: "object", properties: props, required: requiredParams)
                )
            )
        } : nil

        let body = RequestBody(
            model: model,
            messages: reqMessages,
            temperature: options.temperature,
            max_tokens: options.maxTokens,
            tools: toolDefs
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            let message = "OpenClaw HTTP \(http.statusCode): \(bodyText)"
            throw NSError(
                domain: "OpenClawLLMClient",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        guard !data.isEmpty else {
            throw NSError(
                domain: "OpenClawLLMClient",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "OpenClaw returned an empty response body."]
            )
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(ResponseBody.self, from: data)
        guard let first = decoded.choices.first else {
            throw NSError(domain: "OpenClawLLMClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "No choices in response"])
        }

        let msg = LLMMessage(role: .assistant, content: first.message.content ?? "")
        let usage: LLMTokenUsage?
        if let u = decoded.usage {
            usage = LLMTokenUsage(
                promptTokens: u.prompt_tokens ?? 0,
                completionTokens: u.completion_tokens ?? 0
            )
        } else {
            usage = nil
        }

        // Parse tool calls
        var toolCalls: [LLMToolCall]? = nil
        if let nativeCalls = first.message.tool_calls, !nativeCalls.isEmpty {
            toolCalls = nativeCalls.compactMap { tc in
                guard let argsData = tc.function.arguments.data(using: .utf8),
                      let argsDict = try? JSONDecoder().decode([String: AnyJSONValue].self, from: argsData) else {
                    return LLMToolCall(name: tc.function.name, arguments: [:])
                }
                return LLMToolCall(name: tc.function.name, arguments: argsDict)
            }
        }

        return LLMChatResponse(
            message: msg,
            providerID: "openclaw",
            modelID: decoded.model ?? model,
            usage: usage,
            toolCalls: toolCalls
        )
    }

    func embed(texts: [String], model: String) async throws -> [[Float]] {
        struct EmbeddingRequest: Encodable {
            let model: String
            let input: [String]
        }
        struct EmbeddingResponse: Decodable {
            struct Item: Decodable {
                let embedding: [Float]
            }
            let data: [Item]
        }

        let url = baseURL.appendingPathComponent("/v1/embeddings")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body = EmbeddingRequest(model: model, input: texts)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            let message = "OpenClaw embeddings HTTP \(http.statusCode): \(bodyText)"
            throw NSError(
                domain: "OpenClawLLMClient",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        guard !data.isEmpty else {
            throw NSError(
                domain: "OpenClawLLMClient",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "OpenClaw returned an empty embeddings response body."]
            )
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(EmbeddingResponse.self, from: data)
        return decoded.data.map(\.embedding)
    }
}
