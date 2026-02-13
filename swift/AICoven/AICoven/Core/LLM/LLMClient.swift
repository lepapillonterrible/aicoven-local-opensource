import Foundation

/// Represents a single chat message in the core LLM interface.
/// Conforms to Sendable since all properties are value types.
public struct LLMMessage: Sendable {
    public enum Role: String, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    public let id: UUID
    public let role: Role
    public let content: String

    public init(id: UUID = UUID(), role: Role, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

// MARK: - Native Tool Calling Types

/// Tool definition for native function calling.
/// Providers convert this to their native format (OpenAI tools, Anthropic tools,
/// Gemini functionDeclarations). Local models (MLX/Ollama) ignore these and
/// rely on text-based tool instructions in the system prompt.
public struct LLMToolDefinition: Sendable {
    public let name: String
    public let description: String
    public let parameters: [LLMToolParameter]

    public init(name: String, description: String, parameters: [LLMToolParameter]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// Parameter definition for a tool.
public struct LLMToolParameter: Sendable {
    public let name: String
    public let type: String
    public let description: String
    public let required: Bool

    public init(name: String, type: String, description: String, required: Bool) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
    }
}

/// A structured tool call returned by native function calling.
/// ChatService converts these into `ChatToolInvocation` objects for execution.
public struct LLMToolCall: Sendable {
    public let name: String
    public let arguments: [String: AnyJSONValue]

    public init(name: String, arguments: [String: AnyJSONValue]) {
        self.name = name
        self.arguments = arguments
    }
}

// MARK: - Response

/// High-level result of a chat completion.
/// Conforms to Sendable since all properties are Sendable.
public struct LLMChatResponse: Sendable {
    public let message: LLMMessage
    public let providerID: String
    public let modelID: String
    public let usage: LLMTokenUsage?
    /// Structured tool calls from native function calling (OpenAI, Anthropic, Gemini).
    /// `nil` when the provider doesn't support native tool calling or the model
    /// chose not to call any tools.
    public let toolCalls: [LLMToolCall]?

    public init(
        message: LLMMessage,
        providerID: String,
        modelID: String,
        usage: LLMTokenUsage?,
        toolCalls: [LLMToolCall]? = nil
    ) {
        self.message = message
        self.providerID = providerID
        self.modelID = modelID
        self.usage = usage
        self.toolCalls = toolCalls
    }
}

/// Simple token usage accounting for routing and UX.
/// Conforms to Sendable since all properties are value types.
public struct LLMTokenUsage: Sendable {
    public let promptTokens: Int
    public let completionTokens: Int

    public var totalTokens: Int {
        promptTokens + completionTokens
    }

    public init(promptTokens: Int, completionTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

/// Options for chat completion requests.
/// Conforms to Sendable since all properties are Sendable.
public struct ChatOptions: Sendable {
    public let temperature: Double
    public let maxTokens: Int?
    public let stream: Bool
    /// Tool definitions for native function calling. When non-nil, API clients
    /// (OpenAI, Anthropic, Gemini) send these as native function declarations.
    /// Local clients (MLX, Ollama) ignore this — they rely on text-based
    /// tool instructions in the system prompt.
    public let tools: [LLMToolDefinition]?

    public init(
        temperature: Double = 0.7,
        maxTokens: Int? = nil,
        stream: Bool = false,
        tools: [LLMToolDefinition]? = nil
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stream = stream
        self.tools = tools
    }
}

/// Protocol for LLM clients that can perform chat completions and embeddings.
/// Marked as Sendable to allow safe use across actor boundaries.
public protocol LLMClient: Sendable {
    /// Performs a chat completion for the given messages and model identifier.
    func completeChat(messages: [LLMMessage], model: String, options: ChatOptions) async throws -> LLMChatResponse

    /// Computes embeddings for one or more texts using the specified embedding model.
    func embed(texts: [String], model: String) async throws -> [[Float]]
}

// MARK: - Streaming

/// A single delta in a streaming chat completion.
public struct LLMStreamDelta: Sendable {
    /// Incremental text content (may be a single token).
    public let text: String
    /// `true` when this is the final delta (stream is about to end).
    public let isFinished: Bool
    /// Token usage, provided on the final delta when available.
    public let usage: LLMTokenUsage?

    public init(text: String, isFinished: Bool = false, usage: LLMTokenUsage? = nil) {
        self.text = text
        self.isFinished = isFinished
        self.usage = usage
    }
}

/// Protocol for LLM clients that support true token-by-token streaming.
/// Clients that don't implement this will fall back to the default
/// implementation which wraps `completeChat()`.
public protocol StreamingLLMClient: LLMClient {
    /// Streams chat completion token-by-token.
    func streamChat(messages: [LLMMessage], model: String, options: ChatOptions) -> AsyncThrowingStream<LLMStreamDelta, Error>
}

/// Default streaming implementation: wraps `completeChat()` and emits the
/// full response as a single delta. Clients that natively stream should
/// override this with a real implementation.
public extension StreamingLLMClient {
    func streamChat(messages: [LLMMessage], model: String, options: ChatOptions) -> AsyncThrowingStream<LLMStreamDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await completeChat(messages: messages, model: model, options: options)
                    continuation.yield(LLMStreamDelta(
                        text: response.message.content,
                        isFinished: true,
                        usage: response.usage
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
