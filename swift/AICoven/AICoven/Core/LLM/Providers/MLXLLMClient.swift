import Foundation
import os

#if canImport(UIKit)
import UIKit
#endif

#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
import MLX
#endif

#if canImport(UIKit)
import UIKit
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

    /// Observer token for memory warning notifications.
    private var memoryWarningObserver: NSObjectProtocol?

    init(modelID: String) {
        defaultModelID = modelID
        registerMemoryWarningObserver()
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Memory Pressure

    /// Listen for OS memory warnings and proactively release cached model
    /// containers (~1–2 GB each). `ensureModelLoaded` will reload on next use.
    private func registerMemoryWarningObserver() {
        #if canImport(UIKit)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.unloadAllModels()
        }
        #endif
    }

    /// Release all cached model containers to free memory.
    /// Called from the memory warning notification (main queue) and may
    /// also be called directly. Thread-safe via `lock`.
    func unloadAllModels() {
        #if canImport(MLXLLM)
        let unloaded = lock.withLock { () -> Int in
            let n = loadedContainers.count
            loadedContainers.removeAll()
            return n
        }
        if unloaded > 0 {
            print("⚠️ [MLXLLMClient] Memory warning: unloaded \(unloaded) model container(s)")
        }
        // Free GPU memory after unloading model containers.
        MLX.GPU.clearCache()
        #endif
    }

    // MARK: - LLMClient (full response)

    func completeChat(messages: [LLMMessage], model: String, options: ChatOptions) async throws -> LLMChatResponse {
        #if canImport(MLXLLM)

        // On iOS, set a strict metal cache limit to prevent jetsam (OOM crashes).
        // iPhones typically allow ~3–4 GB for apps; keep GPU cache small so the
        // model weights + KV cache don't push us over the limit.
        #if os(iOS)
        let memoryLimit = 512 * 1024 * 1024 // 512 MB
        MLX.GPU.set(cacheLimit: memoryLimit)
        #endif

        let effectiveModel = model.isEmpty ? defaultModelID : model
        let container = try await ensureModelLoaded(effectiveModel)

        // Convert LLMMessages to MLXLMCommon's structured Chat.Message format.
        // This properly applies the model's chat template, including system
        // messages (tool docs, instructions, policies) that were previously
        // silently dropped by the old flat-prompt approach.
        let chatMessages = Self.toChatMessages(from: messages)
        let userInput = UserInput(chat: chatMessages)
        // Cap generation length strictly on iOS to save KV cache memory.
        #if os(iOS)
        let maxTokens = min(options.maxTokens ?? 512, 512)
        #else
        let maxTokens = options.maxTokens ?? 1024
        #endif

        // Generate using MLX's perform + generate pattern.
        // The container.perform block gives us a ModelContext for generation.
        let result = try await container.perform { [userInput] context in
            // Prepare the input using the context's processor, which applies
            // the model's chat template (e.g. Qwen3, Mistral, Llama formats).
            let input = try await context.processor.prepare(input: userInput)

            // Set up generation parameters.
            let parameters = GenerateParameters(maxTokens: maxTokens)

            // Wrap the synchronous generate call in autoreleasepool to ensure
            // intermediate MLX buffers are eagerly freed.
            // Explicit [Int] type to disambiguate between the two generate overloads.
            return try autoreleasepool {
                try MLXLMCommon.generate(
                    input: input,
                    parameters: parameters,
                    context: context
                ) { (_: [Int]) -> GenerateDisposition in
                    .more
                }
            }
        }

        // Extract token counts from result.
        // GenerateResult provides promptTokenCount but not completion count directly.
        // Estimate completion tokens from output length (roughly 4 chars per token).
        let estimatedCompletionTokens = max(1, result.output.count / 4)
        let usage = LLMTokenUsage(
            promptTokens: result.promptTokenCount,
            completionTokens: estimatedCompletionTokens
        )

        // On iOS, proactively unload the model after each inference to prevent
        // jetsam (OOM kill). The ~1.5 GB model weights staying resident is the
        // primary cause of memory pressure. The model will reload on next chat.
        #if os(iOS)
        unloadAllModels()
        #endif

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
                    // Delegate to completeChat which uses the structured
                    // Chat.Message format (system messages included).
                    // TODO: Implement true token-by-token streaming with MLX
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

        // On iOS, evict any OTHER cached models before loading a new one.
        // Two models (~1.5 GB each) will exceed the jetsam limit. This
        // ensures at most one model is cached at a time.
        #if os(iOS)
        let evicted = lock.withLock { () -> Int in
            let n = loadedContainers.count
            if n > 0 { loadedContainers.removeAll() }
            return n
        }
        if evicted > 0 {
            MLX.GPU.clearCache()
            print("🔄 [MLXLLMClient] Evicted \(evicted) model(s) before loading \(modelID)")
        }
        #endif

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

    // MARK: - Message conversion

    // Convert internal `LLMMessage` array to MLXLMCommon's structured
    // `Chat.Message` format. System messages are folded into the first
    // user message because many small models (Gemma 2, etc.) don't
    // support the "system" role in their Jinja chat templates and throw
    // a TemplateException.
    //
    // Consecutive messages of the same role are merged into a single
    // entry. This is required because many chat templates (e.g. Mistral)
    // enforce strictly alternating user/assistant turns.
    #if canImport(MLXLLM)
    private static func toChatMessages(from messages: [LLMMessage]) -> [Chat.Message] {
        // Pre-merge consecutive same-role LLMMessages before converting
        // to Chat.Message. This avoids pattern-matching issues with the
        // Chat.Message enum and handles tool→user role coalescing.
        let normalized = mergeConsecutiveRoles(messages)

        var chatMessages: [Chat.Message] = []
        // Collect all system content to prepend to the first user message.
        // Many small models (Gemma 2, Phi, etc.) don't support .system()
        // in their Jinja chat template and throw TemplateException.
        var systemContent: [String] = []
        var systemFlushed = false

        for msg in normalized {
            switch msg.role {
            case .system:
                systemContent.append(msg.content)
            case .user:
                var text = msg.content
                // Prepend accumulated system content to the first user
                // message so instructions aren't lost.
                if !systemFlushed, !systemContent.isEmpty {
                    let systemBlock = systemContent.joined(separator: "\n\n")
                    text = systemBlock + "\n\n" + text
                    systemFlushed = true
                }
                chatMessages.append(.user(text))
            case .assistant:
                chatMessages.append(.assistant(msg.content))
            case .tool:
                // Tool results are injected as user messages since
                // small local models handle them better that way.
                chatMessages.append(.user("[Tool Result]\n" + msg.content))
            }
        }

        // If there were only system messages and no user message,
        // emit them as a single user message so the model can respond.
        if !systemFlushed, !systemContent.isEmpty {
            let systemBlock = systemContent.joined(separator: "\n\n")
            chatMessages.append(.user(systemBlock))
        }

        // Post-merge: folding system messages into user messages and
        // stripping system entries can leave consecutive .user() entries
        // (e.g. when ContextBuilder's dedup fails for rewritten prompts).
        // Gemma 2's template enforces strict alternation and throws
        // TemplateException if adjacent roles match. Merge them here.
        return mergeAdjacentChatMessages(chatMessages)
    }

    /// Merge consecutive Chat.Messages that share the same role so that
    /// strict chat templates (Gemma 2, etc.) never see adjacent
    /// user-user or assistant-assistant pairs.
    private static func mergeAdjacentChatMessages(_ messages: [Chat.Message]) -> [Chat.Message] {
        guard messages.count > 1 else { return messages }
        var result: [Chat.Message] = [messages[0]]

        for msg in messages.dropFirst() {
            let prevRole = chatMessageRole(result.last!)
            let curRole = chatMessageRole(msg)

            if prevRole == curRole, prevRole != "system" {
                // Merge adjacent same-role messages.
                let prevText = chatMessageContent(result.last!)
                let curText = chatMessageContent(msg)
                let merged = prevText + "\n\n" + curText
                if prevRole == "user" {
                    result[result.count - 1] = .user(merged)
                } else {
                    result[result.count - 1] = .assistant(merged)
                }
            } else {
                result.append(msg)
            }
        }
        return result
    }

    /// Extract the role string from a Chat.Message.
    private static func chatMessageRole(_ msg: Chat.Message) -> String {
        switch msg {
        case .user: "user"
        case .assistant: "assistant"
        case .system: "system"
        }
    }

    /// Extract the text content from a Chat.Message.
    private static func chatMessageContent(_ msg: Chat.Message) -> String {
        switch msg {
        case let .user(c, _, _): c
        case let .assistant(c, _, _): c
        case let .system(c): c
        }
    }

    /// Merge consecutive messages that share the same effective role so
    /// that strict chat templates (Mistral, etc.) don't crash. Tool
    /// messages are treated as "user" for merging purposes since they
    /// become user messages in the final Chat.Message array.
    private static func mergeConsecutiveRoles(_ messages: [LLMMessage]) -> [LLMMessage] {
        guard !messages.isEmpty else { return [] }
        var result: [LLMMessage] = []

        /// Effective role for merging: .tool counts as .user.
        func effectiveRole(_ role: LLMMessage.Role) -> LLMMessage.Role {
            role == .tool ? .user : role
        }

        for msg in messages {
            if let last = result.last,
               effectiveRole(last.role) == effectiveRole(msg.role) {
                // Merge with the previous message.
                let merged = last.content + "\n\n" + msg.content
                result[result.count - 1] = LLMMessage(
                    role: last.role,
                    content: merged
                )
            } else {
                result.append(msg)
            }
        }
        return result
    }
    #else
    private static func toChatMessages(from messages: [LLMMessage]) -> [[String: String]] {
        // Stub for when MLX isn't available — won't be called.
        []
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
