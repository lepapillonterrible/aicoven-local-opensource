import Foundation

/// Google Gemini implementation of LLMClient.
///
/// Uses the public Generative Language API with API key passed as a
/// query parameter.
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
    init(apiKey: String,
         baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
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

    func completeChat(messages: [LLMMessage], model: String, options: ChatOptions) async throws -> LLMChatResponse {
        struct Part: Encodable { let text: String }
        struct Content: Encodable { let role: String; let parts: [Part] }
        struct FunctionCallingConfig: Encodable { let mode: String }
        struct ToolConfig: Encodable {
            let functionCallingConfig: FunctionCallingConfig
            enum CodingKeys: String, CodingKey {
                case functionCallingConfig = "function_calling_config"
            }
        }
        struct RequestBody: Encodable {
            let contents: [Content]
            let generationConfig: GenerationConfig
            let toolConfig: ToolConfig
            enum CodingKeys: String, CodingKey {
                case contents
                case generationConfig
                case toolConfig = "tool_config"
            }
        }
        struct GenerationConfig: Encodable {
            let temperature: Double
        }
        struct ResponseBody: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String? }
                    let parts: [Part]?
                }
                let content: Content?
                let finishReason: String?
            }
            struct UsageMetadata: Decodable {
                let promptTokenCount: Int?
                let candidatesTokenCount: Int?
                let totalTokenCount: Int?
            }
            let candidates: [Candidate]?
            let modelVersion: String?
            let usageMetadata: UsageMetadata?
            // Gemini may return an error object instead of candidates.
            let error: GeminiError?
            struct GeminiError: Decodable {
                let message: String?
                let code: Int?
            }
        }

        // Gemini's REST API expects paths like
        //   https://generativelanguage.googleapis.com/v1/models/gemini-2.0-flash:generateContent
        // The ListModels API returns fully-qualified names of the form
        //   "models/gemini-2.0-flash".
        // To avoid double-prefix or stripping mistakes, we treat the `model`
        // argument as the full resource name and append ":generateContent"
        // directly.
        let path = "\(model):generateContent"
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        let url = components.url!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let contents = messages.map { msg in
            Content(role: msg.role == .user ? "user" : "model",
                    parts: [Part(text: msg.content)])
        }
        // Disable native function calling so Gemini responds with plain text.
        // Our tool protocol uses text-based JSON; native function calls conflict
        // (causing MALFORMED_FUNCTION_CALL errors).
        let body = RequestBody(
            contents: contents,
            generationConfig: GenerationConfig(temperature: options.temperature),
            toolConfig: ToolConfig(functionCallingConfig: FunctionCallingConfig(mode: "NONE"))
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            let message = "Gemini HTTP \(http.statusCode): \(bodyText)"
            throw NSError(domain: "GeminiLLMClient", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard !data.isEmpty else {
            throw NSError(domain: "GeminiLLMClient", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Gemini returned an empty response body."])
        }
        
        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            #if DEBUG
            let bodySnippet = String(data: data.prefix(500), encoding: .utf8) ?? "<non-utf8>"
            AppErrorReporter.log(message: "Gemini decode failed: \(error.localizedDescription)\nResponse: \(bodySnippet)", context: "GeminiLLMClient.completeChat")
            #endif
            throw error
        }
        
        // Handle API-level errors returned in the response body.
        if let apiError = decoded.error {
            let message = "Gemini API error \(apiError.code ?? -1): \(apiError.message ?? "unknown")"
            throw NSError(domain: "GeminiLLMClient", code: apiError.code ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        
        guard let first = decoded.candidates?.first else {
            throw NSError(domain: "GeminiLLMClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "No candidates in response"])
        }
        
        // Handle safety-filtered or empty responses.
        guard let parts = first.content?.parts else {
            let reason = first.finishReason ?? "unknown"
            throw NSError(domain: "GeminiLLMClient", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Gemini response had no content (finishReason: \(reason))"])
        }
        
        let text = parts.compactMap { $0.text }.joined(separator: "\n")
        let msg = LLMMessage(role: .assistant, content: text)
        let modelVersion = decoded.modelVersion ?? model
        
        let usage = decoded.usageMetadata.map { meta in
            LLMTokenUsage(
                promptTokens: meta.promptTokenCount ?? 0,
                completionTokens: meta.candidatesTokenCount ?? 0
            )
        }
        
        return LLMChatResponse(message: msg, providerID: "google", modelID: modelVersion, usage: usage)
    }

    func embed(texts: [String], model: String) async throws -> [[Float]] {
        // For now, embeddings via Gemini are not implemented.
        throw NSError(domain: "GeminiLLMClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Embeddings are not supported for Gemini in this client."])
    }
}