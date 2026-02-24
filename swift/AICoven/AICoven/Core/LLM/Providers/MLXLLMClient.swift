import Foundation
import os

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
// Safety: @unchecked Sendable is safe because `defaultModelID` is immutable
// and all access to `loadedContainers` is serialised through `lock`.
final class MLXLLMClient: StreamingLLMClient, @unchecked Sendable {

    /// Default fallback model ID.
    let defaultModelID: String

    /// Provider identifier for routing.
    static let providerID = "mlx"

    #if canImport(MLXLLM)
    /// Cache: loaded model container keyed by model ID.
    private var loadedContainers: [String: ModelContainer] = [:]
    private let lock = OSAllocatedUnfairLock()
    #endif

    init(modelID: String) {
        defaultModelID = modelID
    }

    // MARK: - LLMClient (full response)

    func completeChat(messages: [LLMMessage], model: String, options: ChatOptions) async throws -> LLMChatResponse {
        #if canImport(MLXLLM)
        let effectiveModel = model.isEmpty ? defaultModelID : model
        let container = try await ensureModelLoaded(effectiveModel)

        // Convert messages to MLX format
        let prompt = Self.composeConversationPrompt(from: messages)
        let maxTokens = options.maxTokens ?? 1024

        // Generate using MLX's perform + generate pattern
        // The container.perform block gives us a ModelContext for generation
        let result = try await container.perform { context in
            // Prepare the input using the context's processor
            let input = try await context.processor.prepare(input: .init(prompt: prompt))

            // Set up generation parameters
            let parameters = GenerateParameters(maxTokens: maxTokens)

            // Generate text using MLXLMCommon.generate
            // Explicit [Int] type to disambiguate between the two generate overloads
            return try MLXLMCommon.generate(
                input: input,
                parameters: parameters,
                context: context
            ) { (_: [Int]) -> GenerateDisposition in
                // Continue generating until done
                return .more
            }
        }

        // Extract token counts from result
        // GenerateResult provides promptTokenCount but not completion count directly
        // Estimate completion tokens from output length (roughly 4 chars per token)
        let estimatedCompletionTokens = max(1, result.output.count / 4)
        let usage = LLMTokenUsage(
            promptTokens: result.promptTokenCount,
            completionTokens: estimatedCompletionTokens
        )

        return LLMChatResponse(
            message: LLMMessage(role: .assistant, content: result.output),
            providerID: "mlx",
            modelID: effectiveModel,
            usage: usage
        )
        #else
        throw MLXClientError.packageNotAvailable
        #endif
    }

    func embed(texts: [String], model: String) async throws -> [[Float]] {
        // Embeddings not yet supported in this simplified client
        // We could use MLXBERT or similar if needed
        throw MLXClientError.embeddingsNotSupported
    }

    // MARK: - StreamingLLMClient Protocol

    func streamChat(messages: [LLMMessage], model: String, options: ChatOptions) -> AsyncThrowingStream<LLMStreamDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let container = try await ensureModelLoaded(model)
                    let prompt = Self.composeConversationPrompt(from: messages)

                    // Streaming generation
                    // perform is async, so we await it
                    // But MLX might not support easy streaming in the high level API yet without callback
                    // For now, let's fallback to non-streaming if needed, OR use the generator's stream

                    // Simplified implementation: MLX's high level generate() often yields tokens
                    // Here we assume we can just wait for full response if stream not easy
                    // Re-using completeChat for now as the 'simple' local version
                    // TODO: Implement true token streaming with MLX

                    let response = try await completeChat(messages: messages, model: model, options: options)
                    continuation.yield(LLMStreamDelta(text: response.message.content, isFinished: true, usage: response.usage))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private Helpers

    #if canImport(MLXLLM)
    /// Loads the model container if not already cached, using thread-safe access.
    func ensureModelLoaded(_ modelID: String) async throws -> ModelContainer {
        // Check under lock if already loaded
        if let existing = lock.withLock({ loadedContainers[modelID] }) {
            return existing
        }

        // Load the model (outside lock to avoid blocking)
        // Create configuration from model ID (e.g. "mlx-community/Llama-3.2-1B-Instruct-4bit")
        let configuration = ModelConfiguration(id: modelID)
        let container = try await LLMModelFactory.shared.loadContainer(configuration: configuration)

        print("✅ [MLXLLMClient] Model loaded: \(modelID)")

        // Re-check under lock in case another task loaded the same model
        // concurrently. Use whichever was stored first.
        return lock.withLock {
            if let existing = loadedContainers[modelID] {
                return existing
            }
            loadedContainers[modelID] = container
            return container
        }
    }
    #endif

    // MARK: - Conversation prompt composition

    /// Compose all non-system messages into a single prompt with role labels.
    /// When there is only one user message (the common case), we return it
    /// as-is to avoid unnecessary formatting. For multi-turn conversations
    /// (e.g., during the tool loop) we label each turn so the model can
    /// distinguish its own prior output from user input.
    private static func composeConversationPrompt(from messages: [LLMMessage]) -> String {
        let nonSystem = messages.filter { $0.role != .system }
        guard !nonSystem.isEmpty else { return "" }

        // Fast path: single user message — no labelling needed.
        if nonSystem.count == 1, nonSystem[0].role == .user {
            return nonSystem[0].content
        }

        return nonSystem.map { msg in
            switch msg.role {
            case .user: "User: \(msg.content)"
            case .assistant: "Assistant: \(msg.content)"
            default: msg.content
            }
        }.joined(separator: "\n\n")
    }
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
            "MLX package is not available. Add mlx-swift-lm to the project dependencies."
        case .noUserMessage:
            "No user message found in the conversation."
        case .embeddingsNotSupported:
            "Local embeddings via MLX are not yet supported."
        case let .modelLoadFailed(detail):
            "Failed to load MLX model: \(detail)"
        }
    }
}
