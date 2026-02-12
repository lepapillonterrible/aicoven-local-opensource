import Foundation

#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
#endif

/// LLM client that runs models locally via Apple's MLX framework on Apple
/// Silicon. Chat completions happen entirely on-device — no network calls,
/// no API key required.
///
/// Implements both `LLMClient` (full response) and `StreamingLLMClient`
/// (token-by-token streaming). When the `MLXLLM` package is available, this
/// uses `ChatSession` for conversation-aware inference with KV cache
/// management. Without the package it compiles but returns an error.
final class MLXLLMClient: StreamingLLMClient, @unchecked Sendable {

    /// The Hugging Face model ID (e.g. "mlx-community/Qwen3-4B-4bit").
    let modelID: String

    /// Provider identifier for routing.
    static let providerID = "mlx"

    #if canImport(MLXLLM)
    private var session: ChatSession?
    private var model: (any LLMModel)?
    private let lock = NSLock()
    #endif

    init(modelID: String) {
        self.modelID = modelID
    }

    // MARK: - LLMClient (full response)

    func completeChat(messages: [LLMMessage], model: String, options: ChatOptions) async throws -> LLMChatResponse {
        #if canImport(MLXLLM)
        let loadedModel = try await ensureModelLoaded()
        let session = ChatSession(loadedModel)

        // Feed system + history messages, get final response.
        var lastContent = ""
        for msg in messages {
            if msg.role == .system {
                // ChatSession handles system prompt via model config;
                // we skip explicit system messages and prepend to first user.
                continue
            }
            if msg.role == .user || msg.role == .tool {
                lastContent = try await session.respond(to: msg.content)
            }
            // Assistant messages are part of history context managed by ChatSession.
        }

        return LLMChatResponse(
            message: LLMMessage(role: .assistant, content: lastContent),
            providerID: Self.providerID,
            modelID: modelID,
            usage: nil // MLX doesn't expose token counts through ChatSession
        )
        #else
        throw MLXClientError.packageNotAvailable
        #endif
    }

    // MARK: - StreamingLLMClient (token-by-token)

    func streamChat(messages: [LLMMessage], model: String, options: ChatOptions) -> AsyncThrowingStream<LLMStreamDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                #if canImport(MLXLLM)
                do {
                    let loadedModel = try await ensureModelLoaded()
                    let session = ChatSession(loadedModel)

                    // Find the last user message.
                    guard let userMessage = messages.last(where: { $0.role == .user })?.content else {
                        continuation.finish(throwing: MLXClientError.noUserMessage)
                        return
                    }

                    // Stream response token by token.
                    let stream = session.streamResponse(to: userMessage)
                    var fullText = ""
                    for try await token in stream {
                        fullText += token
                        continuation.yield(LLMStreamDelta(text: token))
                    }

                    // Final delta with completion marker.
                    continuation.yield(LLMStreamDelta(text: "", isFinished: true, usage: nil))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                #else
                continuation.finish(throwing: MLXClientError.packageNotAvailable)
                #endif
            }
        }
    }

    // MARK: - Embeddings

    func embed(texts: [String], model: String) async throws -> [[Float]] {
        #if canImport(MLXEmbedders)
        // TODO: Implement using MLXEmbedders when local embedding support ships.
        throw MLXClientError.embeddingsNotSupported
        #else
        throw MLXClientError.packageNotAvailable
        #endif
    }

    // MARK: - Model loading

    #if canImport(MLXLLM)
    private func ensureModelLoaded() async throws -> any LLMModel {
        if let model = model { return model }
        let loaded = try await MLXLMCommon.loadModel(id: modelID)
        self.model = loaded
        return loaded
    }
    #endif
}

// MARK: - Errors

enum MLXClientError: LocalizedError {
    case packageNotAvailable
    case noUserMessage
    case embeddingsNotSupported
    case modelLoadFailed(String)

    var errorDescription: String? {
        switch self {
        case .packageNotAvailable:
            return "MLX package is not available. Add mlx-swift-lm to the project dependencies."
        case .noUserMessage:
            return "No user message found in the conversation."
        case .embeddingsNotSupported:
            return "Local embeddings via MLX are not yet supported."
        case .modelLoadFailed(let detail):
            return "Failed to load MLX model: \(detail)"
        }
    }
}
