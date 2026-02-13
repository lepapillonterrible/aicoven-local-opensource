import Foundation

/// Ollama-compatible implementation of LLMClient.
///
/// Ollama exposes an OpenAI-compatible `/v1/chat/completions` endpoint, so this
/// client reuses the same JSON schema as OpenAILLMClient but targets a local
/// server (default `http://localhost:11434`). No API key is required.
///
/// Additionally provides helpers for model discovery (`/api/tags`) and
/// connection testing used by the provider-keys UI.
// Safety: @unchecked Sendable is safe because both `baseURL` and `urlSession`
// are immutable after init, and URLSession is documented as thread-safe.
final class OllamaLLMClient: LLMClient, @unchecked Sendable {
    let baseURL: URL
    private let urlSession: URLSession

    /// Default Ollama base URL.
    static let defaultBaseURL = URL(string: "http://localhost:11434")!

    init(
        baseURL: URL = OllamaLLMClient.defaultBaseURL,
        urlSession: URLSession? = nil
    ) {
        self.baseURL = baseURL
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 120 // local models can be slow on first load
            config.timeoutIntervalForResource = 300
            self.urlSession = URLSession(configuration: config)
        }
    }

    // MARK: - LLMClient

    func completeChat(messages: [LLMMessage], model: String, options: ChatOptions) async throws -> LLMChatResponse {
        struct RequestMessage: Encodable {
            let role: String
            let content: String
        }
        struct RequestBody: Encodable {
            let model: String
            let messages: [RequestMessage]
            let temperature: Double
            let stream: Bool
        }
        struct ResponseBody: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let role: String
                    let content: String
                }

                let message: Message
            }

            struct UsageBody: Decodable {
                let prompt_tokens: Int?
                let completion_tokens: Int?
            }

            let choices: [Choice]
            let usage: UsageBody?
            let model: String
        }

        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let reqMessages = messages.map { msg in
            RequestMessage(role: msg.role.rawValue, content: msg.content)
        }
        let body = RequestBody(
            model: model,
            messages: reqMessages,
            temperature: options.temperature,
            stream: false
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            let message = "Ollama HTTP \(http.statusCode): \(bodyText)"
            throw NSError(
                domain: "OllamaLLMClient",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        guard !data.isEmpty else {
            throw NSError(
                domain: "OllamaLLMClient",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Ollama returned an empty response body."]
            )
        }
        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard let first = decoded.choices.first else {
            throw NSError(
                domain: "OllamaLLMClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No choices in Ollama response"]
            )
        }

        let msg = LLMMessage(role: .assistant, content: first.message.content)
        let usage: LLMTokenUsage? = if let u = decoded.usage {
            LLMTokenUsage(
                promptTokens: u.prompt_tokens ?? 0,
                completionTokens: u.completion_tokens ?? 0
            )
        } else {
            nil
        }

        return LLMChatResponse(
            message: msg,
            providerID: "ollama",
            modelID: decoded.model,
            usage: usage
        )
    }

    func embed(texts: [String], model: String) async throws -> [[Float]] {
        // Ollama supports embeddings via /api/embeddings but the schema is
        // different from OpenAI; for now we throw unsupported.
        throw NSError(
            domain: "OllamaLLMClient",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Embeddings not yet supported for Ollama."]
        )
    }

    // MARK: - Ollama-specific helpers

    /// Model information returned by Ollama's `/api/tags` endpoint.
    struct OllamaModel: Decodable, Identifiable {
        let name: String
        let size: Int64?
        let modifiedAt: String?

        var id: String {
            name
        }

        /// Human-readable file size (e.g. "3.8 GB").
        var formattedSize: String? {
            guard let bytes = size else { return nil }
            let gb = Double(bytes) / 1_073_741_824
            if gb >= 1.0 {
                return String(format: "%.1f GB", gb)
            }
            let mb = Double(bytes) / 1_048_576
            return String(format: "%.0f MB", mb)
        }

        enum CodingKeys: String, CodingKey {
            case name, size
            case modifiedAt = "modified_at"
        }
    }

    /// Discover available models from the Ollama server.
    func discoverModels() async throws -> [OllamaModel] {
        struct TagsResponse: Decodable {
            let models: [OllamaModel]?
        }

        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "OllamaLLMClient",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Ollama /api/tags HTTP \(http.statusCode): \(bodyText)"]
            )
        }
        let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
        return decoded.models ?? []
    }

    /// Quick connectivity check. Returns `true` if the server responds.
    func testConnection() async -> Bool {
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        do {
            let (_, response) = try await urlSession.data(for: request)
            if let http = response as? HTTPURLResponse {
                return (200 ..< 300).contains(http.statusCode)
            }
            return false
        } catch {
            return false
        }
    }
}
