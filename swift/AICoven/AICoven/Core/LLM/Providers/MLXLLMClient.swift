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

    /// Default fallback model ID.
    let defaultModelID: String

    /// Provider identifier for routing.
    static let providerID = "mlx"

    #if canImport(MLXLLM)
    /// Cache: loaded model container keyed by model ID.
    private var loadedContainers: [String: ModelContainer] = [:]
    private let lock = NSLock()
    #endif

    init(modelID: String) {
        self.defaultModelID = modelID
    }

    // MARK: - LLMClient (full response)

    func completeChat(messages: [LLMMessage], model: String, options: ChatOptions) async throws -> LLMChatResponse {
        let effectiveModel = model.isEmpty ? defaultModelID : model
        print("🧠 [MLXLLMClient.completeChat] model=\(effectiveModel), messages=\(messages.count)")

        #if canImport(MLXLLM)
        let container = try await ensureModelLoaded(effectiveModel)
        let session = ChatSession(container)

        // Build system instructions from system messages — this includes
        // tool documentation injected by ContextBuilder.
        let systemPrompt = messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n")
        if !systemPrompt.isEmpty {
            session.instructions = systemPrompt
        }

        // Find last user message.
        guard let userMessage = messages.last(where: { $0.role == .user })?.content else {
            throw MLXClientError.noUserMessage
        }

        print("🧠 [MLXLLMClient] Generating response for: \(userMessage.prefix(80))...")
        let response = try await session.respond(to: userMessage)
        print("🧠 [MLXLLMClient] Response complete (\(response.count) chars)")

        return LLMChatResponse(
            message: LLMMessage(role: .assistant, content: response),
            providerID: Self.providerID,
            modelID: effectiveModel,
            usage: nil
        )
        #else
        print("❌ [MLXLLMClient] MLXLLM package NOT available")
        throw MLXClientError.packageNotAvailable
        #endif
    }

    // MARK: - StreamingLLMClient (token-by-token)

    func streamChat(messages: [LLMMessage], model: String, options: ChatOptions) -> AsyncThrowingStream<LLMStreamDelta, Error> {
        let effectiveModel = model.isEmpty ? defaultModelID : model

        return AsyncThrowingStream { continuation in
            Task {
                #if canImport(MLXLLM)
                do {
                    let container = try await self.ensureModelLoaded(effectiveModel)
                    let session = ChatSession(container)

                    // System prompt (includes tool docs from ContextBuilder).
                    let systemPrompt = messages
                        .filter { $0.role == .system }
                        .map(\.content)
                        .joined(separator: "\n")
                    if !systemPrompt.isEmpty {
                        session.instructions = systemPrompt
                    }

                    guard let userMessage = messages.last(where: { $0.role == .user })?.content else {
                        continuation.finish(throwing: MLXClientError.noUserMessage)
                        return
                    }

                    print("🧠 [MLXLLMClient] Streaming \(effectiveModel): \(userMessage.prefix(80))...")

                    let stream = session.streamResponse(to: userMessage)
                    var tokenCount = 0
                    for try await token in stream {
                        tokenCount += 1
                        continuation.yield(LLMStreamDelta(text: token))
                    }

                    print("🧠 [MLXLLMClient] Stream complete (\(tokenCount) tokens)")
                    continuation.yield(LLMStreamDelta(text: "", isFinished: true, usage: nil))
                    continuation.finish()
                } catch {
                    print("❌ [MLXLLMClient] Stream error: \(error)")
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
        throw MLXClientError.embeddingsNotSupported
    }

    // MARK: - Model loading

    #if canImport(MLXLLM)
    private func ensureModelLoaded(_ modelID: String) async throws -> ModelContainer {
        // Fast path: already loaded.
        lock.lock()
        if let existing = loadedContainers[modelID] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        print("🧠 [MLXLLMClient] Loading \(modelID)... (first load downloads from HuggingFace)")

        let container = try await loadModelContainer(id: modelID) { progress in
            let pct = Int(progress.fractionCompleted * 100)
            if pct % 25 == 0 {
                print("🧠 [MLXLLMClient] \(modelID) download: \(pct)%")
            }
        }

        print("✅ [MLXLLMClient] Model loaded: \(modelID)")

        lock.lock()
        loadedContainers[modelID] = container
        lock.unlock()

        return container
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
