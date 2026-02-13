import Foundation

/// OpenAI-compatible implementation of LLMClient.
/// Marked @unchecked Sendable because all stored properties are immutable
/// after init and URLSession is thread-safe.
final class OpenAILLMClient: LLMClient, @unchecked Sendable {
    private let apiKey: String
    private let baseURL: URL
    private let urlSession: URLSession

    /// - Parameters:
    ///   - apiKey: OpenAI API key.
    ///   - baseURL: Base URL for the API (overridable for testing).
    ///   - urlSession: Optional custom URLSession used primarily for tests.
    init(apiKey: String,
         baseURL: URL = URL(string: "https://api.openai.com/v1")!,
         urlSession: URLSession? = nil) {
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

    // MARK: - LLMClient

    func completeChat(messages: [LLMMessage], model: String, options: ChatOptions) async throws -> LLMChatResponse {
        struct RequestMessage: Encodable {
            let role: String
            let content: String
        }
        // Native tool calling structures (OpenAI format)
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
            let temperature: Double
            let tools: [ToolDef]?
        }
        // Response structures
        struct ToolCallResponse: Decodable {
            struct FunctionCall: Decodable {
                let name: String
                let arguments: String  // JSON string
            }
            let id: String?
            let type: String?
            let function: FunctionCall
        }
        struct ResponseBody: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let role: String
                    let content: String?
                    let tool_calls: [ToolCallResponse]?
                }
                let message: Message
                let finish_reason: String?
            }
            struct UsageBody: Decodable {
                let prompt_tokens: Int?
                let completion_tokens: Int?
            }
            let choices: [Choice]
            let usage: UsageBody?
            let model: String
        }

        let url = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let reqMessages = messages.map { msg in
            RequestMessage(role: msg.role.rawValue, content: msg.content)
        }

        // Convert LLMToolDefinition → OpenAI native format
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

        let body = RequestBody(model: model, messages: reqMessages,
                               temperature: options.temperature, tools: toolDefs)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            let message = "OpenAI HTTP \(http.statusCode): \(bodyText)"
            throw NSError(domain: "OpenAILLMClient", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard !data.isEmpty else {
            throw NSError(domain: "OpenAILLMClient", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "OpenAI returned an empty response body."])
        }
        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard let first = decoded.choices.first else {
            throw NSError(domain: "OpenAILLMClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "No choices in response"])
        }

        let msg = LLMMessage(role: .assistant, content: first.message.content ?? "")
        let usage: LLMTokenUsage?
        if let u = decoded.usage {
            usage = LLMTokenUsage(promptTokens: u.prompt_tokens ?? 0, completionTokens: u.completion_tokens ?? 0)
        } else {
            usage = nil
        }

        // Parse native tool calls
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

        return LLMChatResponse(message: msg, providerID: "openai", modelID: decoded.model,
                               usage: usage, toolCalls: toolCalls)
    }

    func embed(texts: [String], model: String) async throws -> [[Float]] {
        struct EmbeddingRequest: Encodable {
            let model: String
            let input: [String]
        }
        struct EmbeddingResponse: Decodable {
            struct Item: Decodable { let embedding: [Float] }
            let data: [Item]
        }

        let url = baseURL.appendingPathComponent("embeddings")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = EmbeddingRequest(model: model, input: texts)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            let message = "OpenAI embeddings HTTP \(http.statusCode): \(bodyText)"
            throw NSError(domain: "OpenAILLMClient", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard !data.isEmpty else {
            throw NSError(domain: "OpenAILLMClient", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "OpenAI returned an empty embeddings response body."])
        }
        let decoded = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
        return decoded.data.map { $0.embedding }
    }
}