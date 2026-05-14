import Foundation

// MARK: - Local LLM client (OpenAI v1/chat/completions)

/// Errors specific to local chat orchestration
enum LocalChatError: Error, LocalizedError {
    case missingOpenAIAPIKey
    case missingAPIKey(provider: String)
    case missingBaseURL
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingOpenAIAPIKey:
            "No OpenAI API key configured. Add an OpenAI provider account or set OPENAI_API_KEY."
        case let .missingAPIKey(provider):
            "No \(provider) API key configured. Add a \(provider) provider account or set the provider-specific environment variable."
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

    /// Resolve API key from Keychain-backed provider accounts or the
    /// OPENAI_API_KEY environment variable.
    private func apiKey() throws -> String {
        if let key = ProviderAccountService.apiKeyFromKeychain(forProvider: "openai"), !key.isEmpty {
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
            AppErrorReporter.log(message: "OpenAI error: status=\((response as? HTTPURLResponse)?.statusCode ?? -1); response body omitted", context: "LLMClients.OpenAIClient.sendChat")
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
        if let key = ProviderAccountService.apiKeyFromKeychain(forProvider: "anthropic"), !key.isEmpty {
            return key
        }
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty {
            return env
        }
        throw LocalChatError.missingAPIKey(provider: "Anthropic")
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
            AppErrorReporter.log(message: "Anthropic error: status=\((response as? HTTPURLResponse)?.statusCode ?? -1); response body omitted", context: "LLMClients.AnthropicClient.sendChat")
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
        if let key = ProviderAccountService.apiKeyFromKeychain(forProvider: "gemini"), !key.isEmpty {
            return key
        }
        if let env = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !env.isEmpty {
            return env
        }
        throw LocalChatError.missingAPIKey(provider: "Gemini")
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
            AppErrorReporter.log(message: "Gemini error: status=\((response as? HTTPURLResponse)?.statusCode ?? -1); response body omitted", context: "LLMClients.GeminiClient.sendChat")
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
