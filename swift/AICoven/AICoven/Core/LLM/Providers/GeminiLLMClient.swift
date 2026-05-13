import Foundation

/// Google Gemini implementation of LLMClient.
///
/// Uses the public Generative Language API with API key passed as a
/// query parameter. Supports native function calling when tools are provided.
/// Marked @unchecked Sendable because all stored properties are immutable
/// after init and URLSession is thread-safe.
final class GeminiLLMClient: LLMClient, @unchecked Sendable {
    private let apiKey: String
    private let baseURL: URL
    private let urlSession: URLSession

    /// - Parameters:
    ///   - apiKey: Google Generative Language (Gemini) API key.
    ///   - baseURL: Base URL for the API (overridable for testing).
    ///   - urlSession: Optional custom URLSession used primarily for tests.
    init(
        apiKey: String,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
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
        // ── Request types ──────────────────────────────────────────────────
        struct ReqPart: Encodable { let text: String }
        struct ReqContent: Encodable { let role: String
            let parts: [ReqPart]
        }
        struct GenerationConfig: Encodable {
            let temperature: Double
        }
        // Native tool calling structures (Gemini format)
        struct ItemsSchema: Encodable {
            let type: String
        }
        struct ParamProperty: Encodable {
            let type: String
            let description: String
            let items: ItemsSchema?
        }
        struct ParametersSchema: Encodable {
            let type: String
            let properties: [String: ParamProperty]
            let required: [String]
        }
        struct FunctionDeclaration: Encodable {
            let name: String
            let description: String
            let parameters: ParametersSchema
        }
        struct ToolsBlock: Encodable {
            let functionDeclarations: [FunctionDeclaration]
        }
        struct RequestBody: Encodable {
            let contents: [ReqContent]
            let generationConfig: GenerationConfig
            let tools: [ToolsBlock]?
        }

        // ── Response types ─────────────────────────────────────────────────
        struct FunctionCallPart: Decodable {
            let name: String
            let args: [String: AnyJSONValue]?
        }
        struct ResponsePart: Decodable {
            let text: String?
            let functionCall: FunctionCallPart?
        }
        struct ResponseContent: Decodable {
            let parts: [ResponsePart]?
        }
        struct ResponseCandidate: Decodable {
            let content: ResponseContent?
            let finishReason: String?
        }
        struct UsageMetadata: Decodable {
            let promptTokenCount: Int?
            let candidatesTokenCount: Int?
            let totalTokenCount: Int?
        }
        struct GeminiError: Decodable {
            let message: String?
            let code: Int?
        }
        struct ResponseBody: Decodable {
            let candidates: [ResponseCandidate]?
            let modelVersion: String?
            let usageMetadata: UsageMetadata?
            let error: GeminiError?
        }

        // ── Build request ──────────────────────────────────────────────────
        let path = "\(model):generateContent"
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        let url = components.url!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let contents = messages.map { msg in
            ReqContent(
                role: msg.role == .user ? "user" : "model",
                parts: [ReqPart(text: msg.content)]
            )
        }

        // Convert LLMToolDefinition → Gemini native format (functionDeclarations).
        // Gemini doesn't allow dots in function names, so we convert
        // "file.write" → "file_write" for outbound, and reverse on decode.
        let toolsBlock: [ToolsBlock]? = {
            guard let tools = options.tools, !tools.isEmpty else { return nil }
            let declarations = tools.map { tool in
                let geminiName = tool.name.replacingOccurrences(of: ".", with: "_")
                var props: [String: ParamProperty] = [:]
                var requiredParams: [String] = []
                for param in tool.parameters {
                    // Map generic types to Gemini schema types:
                    // https://ai.google.dev/api/caching#Type
                    let geminiType = switch param.type.lowercased() {
                    case "string": "STRING"
                    case "integer", "int", "number", "float", "double": "NUMBER"
                    case "boolean", "bool": "BOOLEAN"
                    case "array": "ARRAY"
                    case "object": "OBJECT"
                    default: "STRING" // safe fallback
                    }
                    // Gemini requires ARRAY types to have an `items` field
                    let items: ItemsSchema? = geminiType == "ARRAY" ? ItemsSchema(type: "STRING") : nil
                    props[param.name] = ParamProperty(type: geminiType, description: param.description, items: items)
                    if param.required { requiredParams.append(param.name) }
                }
                return FunctionDeclaration(
                    name: geminiName,
                    description: tool.description,
                    parameters: ParametersSchema(type: "OBJECT", properties: props, required: requiredParams)
                )
            }
            return [ToolsBlock(functionDeclarations: declarations)]
        }()

        let body = RequestBody(
            contents: contents,
            generationConfig: GenerationConfig(temperature: options.temperature),
            tools: toolsBlock
        )
        request.httpBody = try JSONEncoder().encode(body)

        // ── Execute request ────────────────────────────────────────────────
        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            let message = "Gemini HTTP \(http.statusCode). Response body omitted to avoid leaking provider/account metadata."
            throw NSError(
                domain: "GeminiLLMClient",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        guard !data.isEmpty else {
            throw NSError(
                domain: "GeminiLLMClient",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Gemini returned an empty response body."]
            )
        }

        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            #if DEBUG
            AppErrorReporter.log(message: "Gemini decode failed: \(error.localizedDescription); response body omitted", context: "GeminiLLMClient.completeChat")
            #endif
            throw error
        }

        // Handle API-level errors returned in the response body.
        if let apiError = decoded.error {
            let message = "Gemini API error \(apiError.code ?? -1): \(apiError.message ?? "unknown")"
            throw NSError(
                domain: "GeminiLLMClient",
                code: apiError.code ?? -1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        guard let first = decoded.candidates?.first else {
            throw NSError(
                domain: "GeminiLLMClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No candidates in response"]
            )
        }

        // ── Extract text + native tool calls ──────────────────────────────
        let parts = first.content?.parts ?? []
        var textPieces: [String] = []
        var toolCalls: [LLMToolCall] = []

        for part in parts {
            if let t = part.text, !t.isEmpty {
                textPieces.append(t)
            }
            if let fc = part.functionCall {
                // Convert underscores back to dots for our tool naming convention
                let toolName = fc.name.replacingOccurrences(of: "_", with: ".")
                let args = fc.args ?? [:]
                #if DEBUG
                AppErrorReporter.log(
                    message: "Native Gemini function call: \(fc.name) → \(toolName)",
                    context: "GeminiLLMClient.completeChat"
                )
                #endif
                toolCalls.append(LLMToolCall(name: toolName, arguments: args))
            }
        }

        let text = textPieces.joined(separator: "\n")

        if text.isEmpty, toolCalls.isEmpty {
            let reason = first.finishReason ?? "unknown"
            #if DEBUG
            AppErrorReporter.log(
                message: "Gemini response empty (finishReason: \(reason)); returning empty text.",
                context: "GeminiLLMClient.completeChat"
            )
            #endif
        }

        let msg = LLMMessage(role: .assistant, content: text)
        let modelVersion = decoded.modelVersion ?? model

        let usage = decoded.usageMetadata.map { meta in
            LLMTokenUsage(
                promptTokens: meta.promptTokenCount ?? 0,
                completionTokens: meta.candidatesTokenCount ?? 0
            )
        }

        return LLMChatResponse(
            message: msg,
            providerID: "google",
            modelID: modelVersion,
            usage: usage,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls
        )
    }

    func embed(texts: [String], model: String) async throws -> [[Float]] {
        // For now, embeddings via Gemini are not implemented.
        throw NSError(domain: "GeminiLLMClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Embeddings are not supported for Gemini in this client."])
    }
}
