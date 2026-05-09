import Foundation

/// Hermes client implementation of LLMClient for Nous Research Hermes models.
///
/// Hermes is a family of models fine-tuned for agentic capabilities and tool use.
/// This client supports both Together AI cloud hosting and self-hosted deployments.
///
/// Configuration keys (via UserDefaults):
/// - hermes_api_key: API key for Together AI or your self-hosted instance
///   (Alternatively, use together_api_key for Together AI)
/// - hermes_base_url: For self-hosted instances (default: Together AI)
/// - hermes_model: Model alias or full model ID (default: "hermes-3")
///
/// Environment variables:
/// - HERMES_API_KEY or TOGETHER_API_KEY
/// - HERMES_BASE_URL
///
/// Supported model aliases (mapped to Together AI full IDs):
/// - "hermes-3" or "hermes-3-405b" → NousResearch/Hermes-3-Llama-3.1-405B-Turbo
/// - "hermes-3-70b" → NousResearch/Hermes-3-Llama-3.1-70B
/// - "hermes-3-8b" → NousResearch/Hermes-3-Llama-3.1-8B
/// - "hermes-2" → NousResearch/Nous-Hermes-2-Mixtral-8x7B-DPO
/// - "hermes-2-mistral" → NousResearch/Nous-Hermes-2-Mistral-7B-DPO
/// - "hermes-2-vision" → NousResearch/Nous-Hermes-2-Vision-Alpha
///
/// Marked @unchecked Sendable because all stored properties are immutable
/// after init and URLSession is thread-safe.
final class HermesLLMClient: LLMClient, @unchecked Sendable {
    private let apiKey: String?
    private let baseURL: URL
    private let urlSession: URLSession

    /// Default Together AI base URL for Hermes models.
    static let defaultBaseURL = URL(string: "https://api.together.xyz")!

    /// Default model alias.
    static let defaultModelAlias = "hermes-3"

    /// - Parameters:
    ///   - apiKey: API key for Together AI or self-hosted instance (optional for some self-hosted).
    ///   - baseURL: Optional base URL override for self-hosted instances (uses Together AI if nil).
    ///   - urlSession: Optional custom URLSession used primarily for tests.
    init(
        apiKey: String? = nil,
        baseURL: URL? = nil,
        urlSession: URLSession? = nil
    ) {
        self.apiKey = apiKey

        // Resolve base URL
        if let providedURL = baseURL {
            self.baseURL = providedURL
        } else if let envURL = ProcessInfo.processInfo.environment["HERMES_BASE_URL"],
                  let url = URL(string: envURL) {
            self.baseURL = url
        } else {
            self.baseURL = HermesLLMClient.defaultBaseURL
        }

        // Configure URLSession
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 120
            self.urlSession = URLSession(configuration: config)
        }
    }

    /// Creates a shared instance configured from UserDefaults.
    /// Used by LLMConfiguration.makeDefaultClients().
    convenience init?() {
        let defaults = UserDefaults.standard

        // Base URL is optional (defaults to Together AI)
        let rawBaseURL = defaults.string(forKey: UserScope.scopedKey("hermes_base_url"))
            ?? ProcessInfo.processInfo.environment["HERMES_BASE_URL"]
        let baseURL = rawBaseURL.flatMap { $0.isEmpty ? nil : URL(string: $0) }

        // Resolve API key (hermes_api_key preferred, fallback to together_api_key)
        let apiKey = [
            defaults.string(forKey: UserScope.scopedKey("hermes_api_key")),
            defaults.string(forKey: UserScope.scopedKey("together_api_key")),
            ProcessInfo.processInfo.environment["HERMES_API_KEY"],
            ProcessInfo.processInfo.environment["TOGETHER_API_KEY"]
        ].compactMap { $0 }.first { !$0.isEmpty }

        // If no API key and no custom base URL, we can't do anything (Together AI requires an API key)
        if apiKey == nil, baseURL == nil {
            return nil
        }

        self.init(apiKey: apiKey, baseURL: baseURL)
    }

    // MARK: - Model Name Mapping

    /// Maps friendly model aliases to Together AI model IDs.
    /// For self-hosted instances, returns the alias as-is (assuming user provided full ID).
    private func resolveModelID(_ alias: String, isSelfHosted: Bool) -> String {
        guard !isSelfHosted else {
            return alias // Self-hosted: user provides the full model identifier
        }

        // Together AI model mappings
        let modelMap: [String: String] = [
            "hermes-3": "NousResearch/Hermes-3-Llama-3.1-405B-Turbo",
            "hermes-3-405b": "NousResearch/Hermes-3-Llama-3.1-405B-Turbo",
            "hermes-3-70b": "NousResearch/Hermes-3-Llama-3.1-70B",
            "hermes-3-8b": "NousResearch/Hermes-3-Llama-3.1-8B",
            "hermes-2": "NousResearch/Nous-Hermes-2-Mixtral-8x7B-DPO",
            "hermes-2-mixtral": "NousResearch/Nous-Hermes-2-Mixtral-8x7B-DPO",
            "hermes-2-mistral": "NousResearch/Nous-Hermes-2-Mistral-7B-DPO",
            "hermes-2-vision": "NousResearch/Nous-Hermes-2-Vision-Alpha",
        ]

        return modelMap[alias.lowercased()] ?? alias
    }

    /// Returns the effective context window for a model.
    static func contextWindow(for modelID: String) -> Int {
        if modelID.contains("405") {
            128_000
        } else if modelID.contains("70") {
            128_000
        } else if modelID.contains("mixtral") {
            32_768
        } else {
            32_768
        }
    }

    // MARK: - LLMClient

    func completeChat(messages: [LLMMessage], model: String, options: ChatOptions) async throws -> LLMChatResponse {
        struct RequestMessage: Encodable {
            let role: String
            let content: String
        }

        // Tool calling structures (OpenAI-compatible format)
        struct FunctionProperty: Encodable {
            let type: String
            let description: String
        }
        struct FunctionParameters: Encodable {
            let type: String
            let properties: [String: FunctionProperty]
            let required: [String]
            enum CodingKeys: String, CodingKey {
                case type
                case properties
                case required
            }
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

        let isSelfHosted = baseURL != HermesLLMClient.defaultBaseURL
        let resolvedModel = resolveModelID(model, isSelfHosted: isSelfHosted)

        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let apiKey {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

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
            model: resolvedModel,
            messages: reqMessages,
            temperature: options.temperature,
            max_tokens: options.maxTokens,
            tools: toolDefs
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            let message = "Hermes HTTP \(http.statusCode): \(bodyText)"
            throw NSError(
                domain: "HermesLLMClient",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        guard !data.isEmpty else {
            throw NSError(
                domain: "HermesLLMClient",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Hermes returned an empty response body."]
            )
        }

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ResponseBody.self, from: data)
        guard let first = decoded.choices.first else {
            throw NSError(domain: "HermesLLMClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "No choices in response"])
        }

        let msg = LLMMessage(role: .assistant, content: first.message.content ?? "")
        let usage: LLMTokenUsage? = if let u = decoded.usage {
            LLMTokenUsage(
                promptTokens: u.prompt_tokens ?? 0,
                completionTokens: u.completion_tokens ?? 0
            )
        } else {
            nil
        }

        // Parse tool calls (Hermes excels at function calling)
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
            providerID: "hermes",
            modelID: decoded.model ?? resolvedModel,
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

        let url = baseURL.appendingPathComponent("v1/embeddings")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let apiKey {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        // Together AI uses model aliases for embeddings; Hermes doesn't have a native embedding model
        // Use Together's embedding model or delegate to the provided model param
        let embeddingModel = model.contains("together") ? model : "togethercomputer/m2-bert-80M-2k-retrieval"
        let body = EmbeddingRequest(model: embeddingModel, input: texts)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            let message = "Hermes embeddings HTTP \(http.statusCode): \(bodyText)"
            throw NSError(
                domain: "HermesLLMClient",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        guard !data.isEmpty else {
            throw NSError(
                domain: "HermesLLMClient",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Hermes returned an empty embeddings response body."]
            )
        }

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(EmbeddingResponse.self, from: data)
        return decoded.data.map(\.embedding)
    }
}
