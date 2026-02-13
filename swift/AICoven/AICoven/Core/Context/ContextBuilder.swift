import Foundation

/// Builds the layered "context sandwich" used for LLM calls.
///
/// This version implements the full context sandwich:
/// - Layer 1: system contract (with optional tool documentation)
/// - Layer 2: runtime info (time)
/// - Layer 3: policies and safety guidelines
/// - Layer 4: retrieved memories (embedding-based search)
/// - Layer 5: thread summary
/// - Layer 6: recent turns
/// - Layer 7: tool-generated context
/// - Layer 8: current user message
/// - Layer 9: response checklist
struct ContextBuilder {
    let threadRepository: ThreadRepository
    let memoryRepository: MemoryRepository
    let embeddingService: EmbeddingService
    let toolService: ToolService

    /// Parameters that affect how much history/memory is included.
    /// Conforms to Sendable since all properties are value types.
    struct Limits: Sendable {
        let maxRecentMessages: Int
        let maxRecentMemories: Int
    }

    /// Configuration for tool-enabled prompts.
    /// Conforms to Sendable since all properties are value types.
    struct ToolConfig: Sendable {
        /// Set of tool names that are enabled for this context.
        let enabledTools: Set<String>
        /// Whether to include thought block instructions.
        let includeThoughtBlocks: Bool
        /// Whether to include scratchpad instructions.
        let includeScratchpad: Bool
        /// Whether to include memory write instructions.
        let includeMemoryWrite: Bool
        /// Whether the provider is a local model (MLX/Ollama), which needs
        /// shorter, more directive prompts.
        let isLocalModel: Bool

        /// Default configuration with basic chat tools enabled.
        static let `default` = ToolConfig(
            enabledTools: PromptTemplates.basicChatTools,
            includeThoughtBlocks: true,
            includeScratchpad: true,
            includeMemoryWrite: true,
            isLocalModel: false
        )

        /// Configuration with no tools enabled.
        static let noTools = ToolConfig(
            enabledTools: [],
            includeThoughtBlocks: false,
            includeScratchpad: false,
            includeMemoryWrite: false,
            isLocalModel: false
        )

        /// Configuration with all tools enabled.
        static let allTools = ToolConfig(
            enabledTools: PromptTemplates.allTools,
            includeThoughtBlocks: true,
            includeScratchpad: true,
            includeMemoryWrite: true,
            isLocalModel: false
        )

        /// Configuration optimized for small local models (MLX, Ollama).
        /// Uses fewer tools and no thought/scratchpad/memory instructions.
        static let mlxTools = ToolConfig(
            enabledTools: PromptTemplates.basicChatTools
                .union(PromptTemplates.fileTools)
                .union(PromptTemplates.shellTools),
            includeThoughtBlocks: false,
            includeScratchpad: false,
            includeMemoryWrite: false,
            isLocalModel: true
        )
    }

    let limits: Limits

    init(
        threadRepository: ThreadRepository = .shared,
        memoryRepository: MemoryRepository = .shared,
        embeddingService: EmbeddingService = .shared,
        toolService: ToolService = .shared,
        limits: Limits = .init(maxRecentMessages: 16, maxRecentMemories: 16)
    ) {
        self.threadRepository = threadRepository
        self.memoryRepository = memoryRepository
        self.embeddingService = embeddingService
        self.toolService = toolService
        self.limits = limits
    }

    /// Builds a basic context sandwich for a chat turn.
    /// - Parameters:
    ///   - threadID: Optional existing thread to pull history from.
    ///   - userMessage: The current user input. This may contain appended
    ///     tool-generated context blocks (e.g. "[Web search results]" or
    ///     "[Attachment analysis]") which we treat as system context rather
    ///     than literal user text.
    ///   - maxContextTokens: Optional soft limit on prompt tokens for the
    ///     assembled context. When provided, we apply truncation rules that
    ///     preserve system/policies, thread summary, top memories, and the last
    ///     few turns while dropping older context first.
    ///   - toolConfig: Configuration for which tools are enabled and what
    ///     instructions to include. Defaults to basic chat tools.
    func buildContext(
        threadID: String?,
        userMessage: String,
        maxContextTokens: Int? = nil,
        toolConfig: ToolConfig = .default
    ) async throws -> [LLMMessage] {
        // Split combined user text into the visible question and any
        // tool-generated context block appended by the composer/tools layer.
        let split = Self.splitUserAndToolContext(from: userMessage)
        let question = split.userText
        let toolContext = split.toolContext

        var segments = ContextSegments()

        // Layer 1: system contract (with tool documentation if tools are enabled)
        let systemPrompt: String = if !toolConfig.enabledTools.isEmpty {
            if toolConfig.isLocalModel {
                // Use lean MLX-optimized prompt for small local models
                PromptTemplates.generateMLXAgentPrompt(
                    enabledTools: toolConfig.enabledTools
                )
            } else {
                // Generate full agent prompt with tool documentation
                PromptTemplates.generateAgentPrompt(
                    enabledTools: toolConfig.enabledTools,
                    includeThoughtBlocks: toolConfig.includeThoughtBlocks,
                    includeScratchpad: toolConfig.includeScratchpad,
                    includeMemoryWrite: toolConfig.includeMemoryWrite
                )
            }
        } else {
            // Basic prompt without tool instructions
            "You are a local-first assistant running entirely on the user's device. " +
                "Use the provided memories and conversation context to respond helpfully."
        }
        segments.system.append(LLMMessage(role: .system, content: systemPrompt))

        // Layer 2: runtime info (timezone-aware via ToolService)
        let time = toolService.currentTime(timezone: .current)
        let timeInfo = "Current time: \(time.localISO8601) (timezone: \(time.timezoneIdentifier), UTC: \(time.utcISO8601))"
        segments.system.append(LLMMessage(role: .system, content: timeInfo))

        // Layer 3: policies – include explicit guidance around PII and memory.
        let policies = "Treat all information as private to this device. Do not expose sensitive personal data (PII) from memories unless the user has explicitly brought the same details into the current question. " +
            "When uncertain, ask clarifying questions. When you propose new memories, present them as suggestions for the user to confirm; do not assume they are persisted."
        segments.system.append(LLMMessage(role: .system, content: policies))

        // Layer 4: memories – embedding-based when possible. For personal
        // threads we combine user-scoped memories (available to all agents) and
        // thread-scoped memories tied to this specific thread. This mirrors the
        // "user" vs "thread" access levels in the design.
        var allMemories: [LocalMemoryChunk] = []

        if let threadID {
            // Thread-specific scope convention: "thread:<threadId>".
            let threadScope = "thread:\(threadID)"

            let userMems = try await embeddingService.searchRelevantMemories(
                query: question,
                scope: "user",
                topK: limits.maxRecentMemories / 2,
                candidateLimit: limits.maxRecentMemories * 4
            )
            let threadMems = try await embeddingService.searchRelevantMemories(
                query: question,
                scope: threadScope,
                topK: limits.maxRecentMemories,
                candidateLimit: limits.maxRecentMemories * 4
            )

            // Combine with thread memories first, deduping by id.
            var seen = Set<String>()
            for m in threadMems + userMems {
                if !seen.contains(m.id) {
                    seen.insert(m.id)
                    allMemories.append(m)
                    if allMemories.count >= limits.maxRecentMemories { break }
                }
            }
        } else {
            // No thread context: just use user-scoped memories.
            allMemories = try await embeddingService.searchRelevantMemories(
                query: question,
                scope: "user",
                topK: limits.maxRecentMemories,
                candidateLimit: limits.maxRecentMemories * 8
            )
        }

        if !allMemories.isEmpty {
            let header = "Relevant memories (for your reasoning; avoid reciting private details verbatim):"
            segments.memories.append(LLMMessage(role: .system, content: header))
            for memory in allMemories {
                let line = "- [scope=\(memory.scope)] \(memory.text)"
                segments.memories.append(LLMMessage(role: .system, content: line))
            }
        }

        // Layer 5: thread summary – if we have a stored summary, include it
        // once before recent turns. This keeps long threads compact.
        if let threadID,
           let thread = try? await threadRepository.loadThread(id: threadID),
           let summary = thread.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            let summaryLine = "Thread summary (for the assistant, not to be recited verbatim): \(summary)"
            segments.summary.append(LLMMessage(role: .system, content: summaryLine))
        }

        // Layer 6: recent turns
        if let threadID {
            // Use the local ChatService history so we see the same messages
            // that the UI renders (including tool metadata, etc.).
            let recent = try await ChatService.shared.loadMessages(threadId: threadID, limit: limits.maxRecentMessages)
            for msg in recent {
                let role: LLMMessage.Role = (msg.role == "user") ? .user : .assistant
                segments.recents.append(LLMMessage(role: role, content: msg.content))
            }
        }

        // Optional: tool-generated context (web search, attachment analysis)
        if let toolContext, !toolContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.toolContext.append(
                LLMMessage(
                    role: .system,
                    content: "Additional context gathered by local tools (web search, file analysis):\n\n" + toolContext
                )
            )
        }

        // Layer 7: current user message (human-authored question only)
        segments.user.append(LLMMessage(role: .user, content: question))

        // Layer 8: response guidance – kept deliberately brief and
        // conversational so models do not echo it verbatim.
        let checklist = "Reply concisely. Ground your answer in the provided memories and conversation context—do not invent facts. If you used tools (web search, files), mention it naturally. Ask clarifying questions when details are ambiguous."
        segments.checklist.append(LLMMessage(role: .system, content: checklist))

        // If we have a token budget, apply truncation rules before returning.
        if let maxContextTokens {
            let truncated = Self.truncate(segments: segments, maxContextTokens: maxContextTokens)
            return Self.assemble(segments: truncated)
        } else {
            return Self.assemble(segments: segments)
        }
    }
}

private extension ContextBuilder {
    /// Logical segments of the context sandwich so we can apply truncation
    /// decisions (e.g. "keep last 6 turns") without guessing from raw indices.
    struct ContextSegments {
        var system: [LLMMessage] = [] // Layers 1–3
        var memories: [LLMMessage] = [] // Layer 4 (header + lines)
        var summary: [LLMMessage] = [] // Layer 5
        var recents: [LLMMessage] = [] // Layer 6
        var toolContext: [LLMMessage] = [] // Tool-generated context
        var user: [LLMMessage] = [] // Layer 7
        var checklist: [LLMMessage] = [] // Layer 8
    }

    /// Mirror the splitting logic used by PersonalChatView so that any
    /// tool-generated context added in the composer is treated as a separate
    /// system-level context block rather than literal user text.
    static func splitUserAndToolContext(from text: String) -> (userText: String, toolContext: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (userText: "", toolContext: nil) }

        let markers = ["[Web search results]", "[Attachment analysis]"]
        guard let range = markers
            .compactMap({ trimmed.range(of: $0) })
            .sorted(by: { $0.lowerBound < $1.lowerBound })
            .first
        else {
            return (userText: trimmed, toolContext: nil)
        }

        let userPart = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let contextPart = String(trimmed[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        if userPart.isEmpty {
            return (userText: trimmed, toolContext: nil)
        }
        return (userText: userPart, toolContext: contextPart.isEmpty ? nil : contextPart)
    }

    /// Approximate token count for a list of messages. We use a very cheap
    /// heuristic (characters / 4) that is monotonic with true token count and
    /// sufficient for truncation decisions.
    static func approximateTokenCount(for messages: [LLMMessage]) -> Int {
        var total = 0
        for message in messages {
            let charCount = message.content.count
            total += max(1, charCount / 4)
        }
        return total
    }

    /// Assemble segments back into the final ordered message list.
    static func assemble(segments: ContextSegments) -> [LLMMessage] {
        segments.system
            + segments.memories
            + segments.summary
            + segments.recents
            + segments.toolContext
            + segments.user
            + segments.checklist
    }

    /// Apply truncation rules under a soft token limit. We always preserve:
    /// - system/time/policies
    /// - thread summary (if any)
    /// - the current user message
    /// and then progressively shrink recent turns, memories, and finally the
    /// checklist until we are under budget.
    static func truncate(segments: ContextSegments, maxContextTokens: Int) -> ContextSegments {
        var result = segments

        // Reserve some headroom for the model's completion.
        let targetPromptTokens = max(1, Int(Double(maxContextTokens) * 0.8))

        func currentTokenCount() -> Int {
            approximateTokenCount(for: assemble(segments: result))
        }

        // Fast path: already within budget.
        if currentTokenCount() <= targetPromptTokens {
            return result
        }

        // 1) Trim older recent turns but keep up to the last 6.
        let maxRecentToKeep = 6
        if result.recents.count > maxRecentToKeep {
            result.recents = Array(result.recents.suffix(maxRecentToKeep))
        }
        if currentTokenCount() <= targetPromptTokens {
            return result
        }

        // 2) Trim memories down to header + top 4 lines.
        if !result.memories.isEmpty {
            let header = result.memories.first!
            let lines = Array(result.memories.dropFirst())
            let maxMemoryLinesToKeep = 4
            let keptLines = Array(lines.prefix(maxMemoryLinesToKeep))
            result.memories = [header] + keptLines
        }
        if currentTokenCount() <= targetPromptTokens {
            return result
        }

        // 3) As a stronger measure, drop memories entirely.
        result.memories = []
        if currentTokenCount() <= targetPromptTokens {
            return result
        }

        // 4) Finally, drop the checklist if we are still over budget. We avoid
        // touching system, summary, user, or tool context.
        result.checklist = []
        return result
    }
}
