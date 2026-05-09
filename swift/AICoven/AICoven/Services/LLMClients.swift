import Foundation

// MARK: - Local LLM client (OpenAI v1/chat/completions)

/// Errors specific to local chat orchestration
enum LocalChatError: Error, LocalizedError {
    case missingOpenAIAPIKey
    case missingBaseURL
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingOpenAIAPIKey:
            "No API key configured. Set the appropriate environment variable or store the key in UserDefaults."
        case .missingBaseURL:
            "No base URL configured. Set the appropriate base URL in UserDefaults."
        case .invalidResponse:
            "Received an invalid response from the API."
        }
    }
}

/// Lightweight wire representation of a chat message we send over HTTP to
/// provider REST APIs. This is intentionally separate from the core `LLMMessage`
/// type used by `LLMClient` to avoid name collisions.
private struct WireLLMMessage: Encodable {
    enum Role: String, Encodable {
        case user
        case assistant
        case system
    }

    let role: Role
    let content: String
}

/// Minimal OpenAI Chat Completions client (non-streaming).
///
/// This talks directly to https://api.openai.com/v1/chat/completions and
/// returns the full assistant message content plus token usage.
private actor OpenAIClient {
    private let apiURL = URL(string: "https://api.openai.com/v1/chat/completions")!

    /// Resolve API key from either UserDefaults ("openai_api_key") or the
    /// OPENAI_API_KEY environment variable.
    private func apiKey() throws -> String {
        if let key = UserDefaults.standard.string(forKey: UserScope.scopedKey("openai_api_key")), !key.isEmpty {
            return key
        }
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty {
            return env
        }
        throw LocalChatError.missingOpenAIAPIKey
    }

    /// Non-streaming chat completion call.
    func sendChat(
        messages: [WireLLMMessage],
        model: String
    ) async throws -> (content: String, usage: TokenUsage?) {
        struct RequestBody: Encodable {
            let model: String
            let messages: [WireLLMMessage]
        }
        struct ResponseBody: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let role: String
                    let content: String
                }

                let index: Int?
                let message: Message
            }

            struct Usage: Decodable {
                let promptTokens: Int?
                let completionTokens: Int?
                let totalTokens: Int?

                enum CodingKeys: String, CodingKey {
                    case promptTokens = "prompt_tokens"
                    case completionTokens = "completion_tokens"
                    case totalTokens = "total_tokens"
                }
            }

            let choices: [Choice]
            let usage: Usage?
        }

        let body = RequestBody(model: model, messages: messages)
        let encoder = JSONEncoder()
        let data = try encoder.encode(body)

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = try apiKey()
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let bodyText = String(data: responseData, encoding: .utf8) ?? "<non-utf8>"
            AppErrorReporter.log(message: "OpenAI error: status=\((response as? HTTPURLResponse)?.statusCode ?? -1) body=\(bodyText)", context: "LLMClients.OpenAIClient.sendChat")
            throw LocalChatError.invalidResponse
        }

        let decoder = JSONDecoder()
        let res = try decoder.decode(ResponseBody.self, from: responseData)
        guard let first = res.choices.first else {
            throw LocalChatError.invalidResponse
        }
        let content = first.message.content
        let usage: TokenUsage? = if let usageData = res.usage {
            TokenUsage(
                promptTokens: usageData.promptTokens,
                completionTokens: usageData.completionTokens,
                totalTokens: usageData.totalTokens
            )
        } else {
            nil
        }
        return (content, usage)
    }
}

/// Minimal Anthropic messages client (non-streaming).
///
/// Uses the Messages API at https://api.anthropic.com/v1/messages.
private actor AnthropicClient {
    private let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!

    private func apiKey() throws -> String {
        if let key = UserDefaults.standard.string(forKey: UserScope.scopedKey("anthropic_api_key")), !key.isEmpty {
            return key
        }
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty {
            return env
        }
        throw LocalChatError.missingOpenAIAPIKey
    }

    func sendChat(
        messages: [WireLLMMessage],
        model: String
    ) async throws -> (content: String, usage: TokenUsage?) {
        struct ContentBlock: Encodable {
            let type: String
            let text: String
        }
        struct MessageRequest: Encodable {
            let model: String
            let maxTokens: Int
            let messages: [AnthropicMessage]

            enum CodingKeys: String, CodingKey {
                case model
                case maxTokens = "max_tokens"
                case messages
            }
        }
        struct AnthropicMessage: Encodable {
            let role: String
            let content: [ContentBlock]
        }
        struct ResponseBody: Decodable {
            struct Content: Decodable {
                let type: String?
                let text: String?
            }

            struct Usage: Decodable {
                let inputTokens: Int?
                let outputTokens: Int?

                enum CodingKeys: String, CodingKey {
                    case inputTokens = "input_tokens"
                    case outputTokens = "output_tokens"
                }
            }

            let content: [Content]
            let usage: Usage?
        }

        // Collapse incoming messages into a single user turn for now.
        let userText = messages.map(\.content).joined(separator: "\n\n")
        let requestBody = MessageRequest(
            model: model,
            maxTokens: 1024,
            messages: [
                AnthropicMessage(
                    role: "user",
                    content: [ContentBlock(type: "text", text: userText)]
                )
            ]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(requestBody)

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let key = try apiKey()
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let bodyText = String(data: responseData, encoding: .utf8) ?? "<non-utf8>"
            AppErrorReporter.log(message: "Anthropic error: status=\((response as? HTTPURLResponse)?.statusCode ?? -1) body=\(bodyText)", context: "LLMClients.AnthropicClient.sendChat")
            throw LocalChatError.invalidResponse
        }

        let decoder = JSONDecoder()
        let res = try decoder.decode(ResponseBody.self, from: responseData)
        let contentText = res.content.compactMap(\.text).joined(separator: "\n\n")
        let usage: TokenUsage? = if let usageData = res.usage {
            TokenUsage(
                promptTokens: usageData.inputTokens,
                completionTokens: usageData.outputTokens,
                totalTokens: nil
            )
        } else {
            nil
        }
        return (contentText, usage)
    }
}

/// Minimal Gemini (Google AI) client using generateContent (non-streaming).
private actor GeminiClient {
    private let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/")!

    private func apiKey() throws -> String {
        if let key = UserDefaults.standard.string(forKey: UserScope.scopedKey("gemini_api_key")), !key.isEmpty {
            return key
        }
        if let env = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !env.isEmpty {
            return env
        }
        throw LocalChatError.missingOpenAIAPIKey
    }

    func sendChat(
        messages: [WireLLMMessage],
        model: String
    ) async throws -> (content: String, usage: TokenUsage?) {
        struct Part: Encodable { let text: String }
        struct Content: Encodable { let parts: [Part] }
        struct RequestBody: Encodable { let contents: [Content] }

        struct ResponseBody: Decodable {
            struct Candidate: Decodable {
                struct CandidateContent: Decodable {
                    struct CandidatePart: Decodable { let text: String? }
                    let parts: [CandidatePart]
                }

                let content: CandidateContent?
            }

            struct Usage: Decodable {
                let promptTokenCount: Int?
                let candidatesTokenCount: Int?
                let totalTokenCount: Int?
            }

            let candidates: [Candidate]?
            let usageMetadata: Usage?
        }

        let userText = messages.map(\.content).joined(separator: "\n\n")
        let body = RequestBody(contents: [Content(parts: [Part(text: userText)])])
        let encoder = JSONEncoder()
        let data = try encoder.encode(body)

        let key = try apiKey()
        var url = baseURL.appendingPathComponent(model)
        url.appendPathComponent(":generateContent")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        guard let finalURL = components.url else {
            throw LocalChatError.invalidResponse
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let bodyText = String(data: responseData, encoding: .utf8) ?? "<non-utf8>"
            AppErrorReporter.log(message: "Gemini error: status=\((response as? HTTPURLResponse)?.statusCode ?? -1) body=\(bodyText)", context: "LLMClients.GeminiClient.sendChat")
            throw LocalChatError.invalidResponse
        }

        let decoder = JSONDecoder()
        let res = try decoder.decode(ResponseBody.self, from: responseData)
        let text = res.candidates?.first?.content?.parts.compactMap(\.text).joined(separator: "\n\n") ?? ""
        let usage: TokenUsage? = if let usageData = res.usageMetadata {
            TokenUsage(
                promptTokens: usageData.promptTokenCount,
                completionTokens: usageData.candidatesTokenCount,
                totalTokens: usageData.totalTokenCount
            )
        } else {
            nil
        }
        return (text, usage)
    }
}

// MARK: - OpenClaw Client

/// OpenClaw client for self-hosted OpenAI-compatible LLM endpoints.
///
/// OpenClaw is a local LLM proxy/gateway that presents an OpenAI-compatible API.
/// This client connects to user-configurable base URLs for local or private deployments.
private actor OpenClawClient {
    
    /// Resolve the base URL from UserDefaults ("openclaw_base_url") or
    /// OPENCLAW_BASE_URL environment variable.
    /// Default: http://localhost:3000
    private func baseURL() throws -> String {
        if let url = UserDefaults.standard.string(forKey: UserScope.scopedKey("openclaw_base_url")), !url.isEmpty {
            return url
        }
        if let env = ProcessInfo.processInfo.environment["OPENCLAW_BASE_URL"], !env.isEmpty {
            return env
        }
        return "http://localhost:3000"
    }
    
    /// Resolve API key from UserDefaults ("openclaw_api_key") or
    /// OPENCLAW_API_KEY environment variable.
    /// Many local deployments don't require auth, so this is optional.
    private func apiKey() -> String? {
        if let key = UserDefaults.standard.string(forKey: UserScope.scopedKey("openclaw_api_key")), !key.isEmpty {
            return key
        }
        if let env = ProcessInfo.processInfo.environment["OPENCLAW_API_KEY"], !env.isEmpty {
            return env
        }
        return nil
    }

    /// Non-streaming chat completion call compatible with OpenAI API format.
    func sendChat(
        messages: [WireLLMMessage],
        model: String
    ) async throws -> (content: String, usage: TokenUsage?) {
        struct RequestBody: Encodable {
            let model: String
            let messages: [WireLLMMessage]
            let temperature: Double?
            let maxTokens: Int?
            
            enum CodingKeys: String, CodingKey {
                case model
                case messages
                case temperature
                case maxTokens = "max_tokens"
            }
        }
        
        struct ResponseBody: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let role: String?
                    let content: String?
                }
                let index: Int?
                let message: Message
                let finishReason: String?
                
                enum CodingKeys: String, CodingKey {
                    case index
                    case message
                    case finishReason = "finish_reason"
                }
            }

            struct Usage: Decodable {
                let promptTokens: Int?
                let completionTokens: Int?
                let totalTokens: Int?

                enum CodingKeys: String, CodingKey {
                    case promptTokens = "prompt_tokens"
                    case completionTokens = "completion_tokens"
                    case totalTokens = "total_tokens"
                }
            }

            let id: String?
            let object: String?
            let created: Int?
            let model: String?
            let choices: [Choice]
            let usage: Usage?
        }

        let baseURLString = try baseURL()
        guard let apiURL = URL(string: baseURLString)?.appendingPathComponent("/v1/chat/completions") else {
            throw LocalChatError.missingBaseURL
        }

        let body = RequestBody(
            model: model,
            messages: messages,
            temperature: 0.7,
            maxTokens: nil // Let the endpoint decide
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(body)

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Optional API key (many local deployments don't require auth)
        if let key = apiKey() {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let bodyText = String(data: responseData, encoding: .utf8) ?? "<non-utf8>"
            AppErrorReporter.log(message: "OpenClaw error: status=\((response as? HTTPURLResponse)?.statusCode ?? -1) body=\(bodyText)", context: "LLMClients.OpenClawClient.sendChat")
            throw LocalChatError.invalidResponse
        }

        let decoder = JSONDecoder()
        let res = try decoder.decode(ResponseBody.self, from: responseData)
        guard let first = res.choices.first else {
            throw LocalChatError.invalidResponse
        }
        let content = first.message.content ?? ""
        let usage: TokenUsage? = if let usageData = res.usage {
            TokenUsage(
                promptTokens: usageData.promptTokens,
                completionTokens: usageData.completionTokens,
                totalTokens: usageData.totalTokens
            )
        } else {
            nil
        }
        return (content, usage)
    }
}

// MARK: - Hermes Client

/// Hermes client for Nous Research Hermes models via OpenAI-compatible API.
///
/// Hermes (especially Hermes 3) is a family of advanced LLMs fine-tuned for
/// agentic and tool use capabilities. This client supports:
/// - Together AI API (cloud)
/// - Self-hosted/local instances (via configurable base URL)
/// - Any OpenAI-compatible endpoint hosting Hermes models
private actor HermesClient {
    
    /// Default Together AI base URL for Hermes
    private let togetherAIBaseURL = "https://api.together.xyz"
    
    /// Resolve the base URL from:
    /// 1. UserDefaults ("hermes_base_url") - for local/self-hosted
    /// 2. HERMES_BASE_URL environment variable
    /// 3. Default to Together AI
    private func baseURL() -> String {
        if let url = UserDefaults.standard.string(forKey: UserScope.scopedKey("hermes_base_url")), !url.isEmpty {
            return url
        }
        if let env = ProcessInfo.processInfo.environment["HERMES_BASE_URL"], !env.isEmpty {
            return env
        }
        return togetherAIBaseURL
    }
    
    /// Resolve API key from:
    /// 1. UserDefaults ("hermes_api_key")
    /// 2. HERMES_API_KEY or TOGETHER_API_KEY environment variable
    private func apiKey() throws -> String {
        if let key = UserDefaults.standard.string(forKey: UserScope.scopedKey("hermes_api_key")), !key.isEmpty {
            return key
        }
        if let env = ProcessInfo.processInfo.environment["HERMES_API_KEY"], !env.isEmpty {
            return env
        }
        if let env = ProcessInfo.processInfo.environment["TOGETHER_API_KEY"], !env.isEmpty {
            return env
        }
        throw LocalChatError.missingOpenAIAPIKey
    }

    /// Non-streaming chat completion call compatible with OpenAI API format.
    func sendChat(
        messages: [WireLLMMessage],
        model: String
    ) async throws -> (content: String, usage: TokenUsage?) {
        struct RequestBody: Encodable {
            let model: String
            let messages: [WireLLMMessage]
            let temperature: Double?
            let maxTokens: Int?
            
            enum CodingKeys: String, CodingKey {
                case model
                case messages
                case temperature
                case maxTokens = "max_tokens"
            }
        }
        
        struct ResponseBody: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let role: String?
                    let content: String?
                    // Some Hermes deployments may return tool_calls
                    let toolCalls: [ToolCall]?
                    
                    enum CodingKeys: String, CodingKey {
                        case role
                        case content
                        case toolCalls = "tool_calls"
                    }
                }
                
                struct ToolCall: Decodable {
                    let id: String?
                    let type: String?
                    let function: FunctionCall?
                }
                
                struct FunctionCall: Decodable {
                    let name: String?
                    let arguments: String?
                }
                
                let index: Int?
                let message: Message
                let finishReason: String?
                
                enum CodingKeys: String, CodingKey {
                    case index
                    case message
                    case finishReason = "finish_reason"
                }
            }

            struct Usage: Decodable {
                let promptTokens: Int?
                let completionTokens: Int?
                let totalTokens: Int?

                enum CodingKeys: String, CodingKey {
                    case promptTokens = "prompt_tokens"
                    case completionTokens = "completion_tokens"
                    case totalTokens = "total_tokens"
                }
            }

            let id: String?
            let object: String?
            let created: Int?
            let model: String?
            let choices: [Choice]
            let usage: Usage?
        }

        let baseURLString = baseURL()
        guard let apiURL = URL(string: baseURLString)?.appendingPathComponent("/v1/chat/completions") else {
            throw LocalChatError.missingBaseURL
        }

        let body = RequestBody(
            model: mapModelName(model),
            messages: messages,
            temperature: 0.7,
            maxTokens: nil
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(body)

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = try apiKey()
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let bodyText = String(data: responseData, encoding: .utf8) ?? "<non-utf8>"
            AppErrorReporter.log(message: "Hermes error: status=\((response as? HTTPURLResponse)?.statusCode ?? -1) body=\(bodyText)", context: "LLMClients.HermesClient.sendChat")
            throw LocalChatError.invalidResponse
        }

        let decoder = JSONDecoder()
        let res = try decoder.decode(ResponseBody.self, from: responseData)
        guard let first = res.choices.first else {
            throw LocalChatError.invalidResponse
        }
        
        // Handle potential tool calls (Hermes is strong at function calling)
        let content = first.message.content ?? ""
        
        // If there are tool calls, append them to content for visibility
        let toolCallContent: String
        if let toolCalls = first.message.toolCalls, !toolCalls.isEmpty {
            let toolCallDescriptions = toolCalls.compactMap { tc -> String? in
                guard let name = tc.function?.name else { return nil }
                let args = tc.function?.arguments ?? "{}"
                return "[Tool Call: \(name)(\(args))]"
            }
            toolCallContent = toolCallDescriptions.joined(separator: "\n")
        } else {
            toolCallContent = ""
        }
        
        let finalContent = toolCallContent.isEmpty ? content : content + "\n" + toolCallContent
        
        let usage: TokenUsage? = if let usageData = res.usage {
            TokenUsage(
                promptTokens: usageData.promptTokens,
                completionTokens: usageData.completionTokens,
                totalTokens: usageData.totalTokens
            )
        } else {
            nil
        }
        return (finalContent, usage)
    }
    
    /// Maps friendly model names to Together AI model IDs.
    /// Users can also pass the full model ID directly.
    private func mapModelName(_ model: String) -> String {
        let modelMap: [String: String] = [
            "hermes-3": "NousResearch/Hermes-3-Llama-3.1-405B-Turbo",
            "hermes-3-405b": "NousResearch/Hermes-3-Llama-3.1-405B-Turbo",
            "hermes-3-70b": "NousResearch/Hermes-3-Llama-3.1-70B",
            "hermes-3-8b": "NousResearch/Hermes-3-Llama-3.1-8B",
            "hermes-2": "NousResearch/Nous-Hermes-2-Mixtral-8x7B-DPO",
            "hermes-2-mistral": "NousResearch/Nous-Hermes-2-Mistral-7B-DPO",
            "hermes-2-vision": "NousResearch/Nous-Hermes-2-Vision-Alpha",
        ]
        
        // Return the mapped ID or the original if not found
        // This allows users to pass full model IDs directly
        return modelMap[model.lowercased()] ?? model
    }
}
