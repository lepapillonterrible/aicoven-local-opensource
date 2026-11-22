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
    struct Limits {
        let maxRecentMessages: Int
        let maxRecentMemories: Int

        /// Tighter limits for iPhones running local models where RAM is shared
        /// with the MLX model weights (~1–2 GB). Fewer messages and memories
        /// means smaller strings in the context sandwich.
        static let mobile = Limits(maxRecentMessages: 6, maxRecentMemories: 4)
    }

    /// Who answers a turn: an agent by its name, with the instructions the
    /// person wrote for it, and the account whose agent it is. A turn is
    /// told of it only while that account is the one signed in.
    struct Agent: Equatable {
        let name: String
        let instructions: String?
        let account: String

        /// What the agent is told first, as the cloud app composes it: its
        /// instructions, or for none that it is a helpful assistant of
        /// that name; then, unless the instructions have such a section
        /// already, that its name is the agent's and not the model's.
        var systemPrompt: String {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            var prompt = instructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if prompt.isEmpty {
                prompt = "You are \(name.isEmpty ? "Strix" : name), a helpful AI assistant."
            }
            guard !prompt.contains("## Identity") else { return prompt }
            return """
            \(prompt)

            ## Identity
            - When asked your name, always identify yourself using the role name "\(name.isEmpty ? "Assistant" : name)" from this system prompt, not the underlying model or provider names.
            - Never claim that your name is Claude, Gemini, GPT-4, ChatGPT, or any other provider/model name. Those are implementation details, not your identity.
            - If the user asks which models/providers you use, you may mention them, but your name must still be given as the role name above.
            """
        }
    }

    /// Configuration for tool-enabled prompts.
    /// Conforms to Sendable since all properties are value types.
    struct ToolConfig {
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

        /// All active MCP server configurations with their cached tools.
        let mcpServers: [MCPServerAccount]

        /// Default configuration with basic chat tools enabled.
        static let `default` = ToolConfig(
            enabledTools: PromptTemplates.basicChatTools,
            includeThoughtBlocks: true,
            includeScratchpad: true,
            includeMemoryWrite: true,
            isLocalModel: false,
            mcpServers: []
        )

        /// Configuration with no tools enabled.
        static let noTools = ToolConfig(
            enabledTools: [],
            includeThoughtBlocks: false,
            includeScratchpad: false,
            includeMemoryWrite: false,
            isLocalModel: false,
            mcpServers: []
        )

        /// Configuration with all tools enabled.
        static let allTools = ToolConfig(
            enabledTools: PromptTemplates.allTools,
            includeThoughtBlocks: true,
            includeScratchpad: true,
            includeMemoryWrite: true,
            isLocalModel: false,
            mcpServers: []
        )

        /// Configuration that dynamically includes only tools whose backing
        /// connected app (GitHub, Google Workspace) is actually linked.
        /// Call this instead of `.allTools` so the LLM never sees tools it can't use.
        ///
        /// `deliversFiles` says the caller gives the files a tool makes to
        /// its reply (a chat turn does; an agent run does not): only then
        /// are the tools that make files for the person offered.
        ///
        /// `seesPictures` says the caller's model can be sent pictures and
        /// the caller sends it those a tool makes (a chat turn of such a
        /// model does; an agent run does not): only then are the tools
        /// that make pictures for the model offered.
        ///
        /// `connections` is the choice of the thread's coven
        /// (`CovenService.connections(forThread:)`): the connected apps'
        /// tools and the MCP servers offered are those it allows.
        static func connected(deliversFiles: Bool = false, seesPictures: Bool = false, connections: CovenConnections? = nil) async -> ToolConfig {
            var connectedTools = await PromptTemplates.connectedToolSet()
            if deliversFiles {
                connectedTools.formUnion(PromptTemplates.offeredImageTools())
            }
            connectedTools.formUnion(PromptTemplates.pictureTools(among: connectedTools, seesPictures: seesPictures))
            let (tools, mcpServers) = await CovenConnectionRules.offered(
                tools: connectedTools,
                servers: ConnectedAccountsService.shared.getAllMCPServers(),
                in: connections
            )

            // Add all cached tools to the enabled list so the prompt generator includes them.
            var allTools = tools
            for server in mcpServers {
                let mcpToolNames = PromptTemplates.mcpToolDefinitions(from: [server]).map(\.name)
                allTools.formUnion(mcpToolNames)
            }

            return ToolConfig(
                enabledTools: allTools,
                includeThoughtBlocks: true,
                includeScratchpad: true,
                includeMemoryWrite: true,
                isLocalModel: false,
                mcpServers: mcpServers
            )
        }

        /// Configuration optimized for small local models (MLX, Ollama).
        /// Uses fewer tools and no thought/scratchpad/memory instructions.
        static func mlxTools(connections: CovenConnections? = nil) async -> ToolConfig {
            let (_, mcpServers) = await CovenConnectionRules.offered(tools: [], servers: ConnectedAccountsService.shared.getAllMCPServers(), in: connections)
            var tools = PromptTemplates.basicChatTools
                .union(PromptTemplates.fileTools)
                .union(PromptTemplates.shellTools)

            for server in mcpServers {
                let mcpToolNames = PromptTemplates.mcpToolDefinitions(from: [server]).map(\.name)
                tools.formUnion(mcpToolNames)
            }

            return ToolConfig(
                enabledTools: tools,
                includeThoughtBlocks: false,
                includeScratchpad: false,
                includeMemoryWrite: false,
                isLocalModel: true,
                mcpServers: mcpServers
            )
        }
    }

    let limits: Limits

    init(
        threadRepository: ThreadRepository? = nil,
        memoryRepository: MemoryRepository? = nil,
        embeddingService: EmbeddingService? = nil,
        toolService: ToolService? = nil,
        limits: Limits = .init(maxRecentMessages: 16, maxRecentMemories: 16)
    ) {
        self.threadRepository = threadRepository ?? .shared
        self.memoryRepository = memoryRepository ?? .shared
        self.embeddingService = embeddingService ?? .shared
        self.toolService = toolService ?? .shared
        self.limits = limits
    }

    /// Where a thread of `account`'s is: the coven it is stored in, or
    /// Strix for one in none (and for no thread). Nil where the thread is
    /// not that account's, where it cannot be read, or where the account
    /// changes while it is: what cannot be placed is told and reads
    /// nothing of any place. The coven itself is not read here: the stores
    /// read and keep what is a coven's only as the account whose coven it
    /// is, so a coven that is gone, or is not that account's, has nothing.
    func scope(ofThread threadID: String?, for account: String) async -> ShellScope? {
        guard UserScope.currentUserID == account else { return nil }
        guard let threadID else { return .strix }
        do {
            let covenID = try await threadRepository.covenID(ofThread: threadID, for: account)
            guard UserScope.currentUserID == account else { return nil }
            return ShellScope(covenID: covenID)
        } catch {
            // The kind of failure only.
            AppErrorReporter.log(message: "A thread could not be placed (\(type(of: error)))", context: "ContextBuilder.scope")
            return nil
        }
    }

    /// What every agent where the thread is is told ("Every agent here
    /// knows…"), as a part of the agent's instructions under the cloud
    /// app's heading; nil where there is none, or it cannot be read.
    private func covenContext(in scope: ShellScope?, for account: String) async -> String? {
        guard let scope else { return nil }
        do {
            let knows = try await CovenContextRepository.shared.context(ofCoven: scope.covenID, as: account)
            return knows.isEmpty ? nil : "## Coven Context\n\(knows)"
        } catch {
            // The kind of failure only.
            AppErrorReporter.log(message: "What a scope's agents are told could not be read (\(type(of: error)))", context: "ContextBuilder.covenContext")
            return nil
        }
    }

    /// Builds a basic context sandwich for a chat turn.
    /// - Parameters:
    ///   - threadID: Optional existing thread to pull history from.
    ///   - userMessage: The current user input. This may contain appended
    ///     tool-generated context blocks (e.g. "[Web search results]" or
    ///     "[Attachment analysis]") which we treat as system context rather
    ///     than literal user text.
    ///   - images: The pictures that go with the current user input, for a
    ///     model that can see them.
    ///   - maxContextTokens: Optional soft limit on prompt tokens for the
    ///     assembled context. When provided, we apply truncation rules that
    ///     preserve system/policies, thread summary, top memories, and the last
    ///     few turns while dropping older context first.
    ///   - toolConfig: Configuration for which tools are enabled and what
    ///     instructions to include. Defaults to basic chat tools.
    ///   - agent: Who answers the turn. Its instructions are what the model
    ///     is told first; with none given (an agent run of the app's own),
    ///     or one of an account no longer signed in, nothing is said of who
    ///     answers.
    func buildContext(
        threadID: String?,
        userMessage: String,
        images: [LLMImage] = [],
        maxContextTokens: Int? = nil,
        toolConfig: ToolConfig? = nil,
        agent: Agent? = nil
    ) async throws -> [LLMMessage] {
        let config = toolConfig ?? .default

        // Split combined user text into the visible question and any
        // tool-generated context block appended by the composer/tools layer.
        let split = Self.splitUserAndToolContext(from: userMessage)
        let question = split.userText
        let toolContext = split.toolContext

        var segments = ContextSegments()

        // Whose turn it is, read once: who answers, where the thread is,
        // what its scope's agents are told and its memory are all read as
        // the same account.
        let account = UserScope.currentUserID

        // Layer 1: system contract (with tool documentation if tools are enabled)
        let systemPrompt: String = if !config.enabledTools.isEmpty {
            if config.isLocalModel {
                // Use lean MLX-optimized prompt for small local models.
                // Pass the user message so the tool selector can pick only
                // the most relevant MCP tools instead of all 200+.
                // This is async because it may use EmbeddingService for
                // semantic tool selection.
                await PromptTemplates.generateMLXAgentPrompt(
                    enabledTools: config.enabledTools,
                    mcpServers: config.mcpServers,
                    userMessage: question
                )
            } else {
                // Generate full agent prompt with tool documentation
                PromptTemplates.generateAgentPrompt(
                    enabledTools: config.enabledTools,
                    mcpServers: config.mcpServers,
                    includeThoughtBlocks: config.includeThoughtBlocks,
                    includeScratchpad: config.includeScratchpad,
                    includeMemoryWrite: config.includeMemoryWrite
                )
            }
        } else {
            // Basic prompt without tool instructions
            "You are a local-first assistant running entirely on the user's device. " +
                "Use the provided memories and conversation context to respond helpfully."
        }
        segments.system.append(LLMMessage(role: .system, content: systemPrompt))

        // Where the thread is: what its scope's agents are told, and its
        // memory, are read for it as that account.
        let scope = await scope(ofThread: threadID, for: account)
        if let knows = await covenContext(in: scope, for: account) {
            segments.system.append(LLMMessage(role: .system, content: knows))
        }

        // Layer 2: runtime info (timezone-aware via ToolService)
        let time = toolService.currentTime(timezone: .current)
        let timeInfo = "Current time: \(time.localISO8601) (timezone: \(time.timezoneIdentifier), UTC: \(time.utcISO8601))"
        segments.system.append(LLMMessage(role: .system, content: timeInfo))

        // Layer 3: policies – include explicit guidance around PII and memory.
        let policies = "Treat all information as private to this device. Do not expose sensitive personal data (PII) from memories unless the user has explicitly brought the same details into the current question. " +
            "When uncertain, ask clarifying questions. When you propose new memories, present them as suggestions for the user to confirm; do not assume they are persisted."
        segments.system.append(LLMMessage(role: .system, content: policies))

        // Layer 4: memories – embedding-based when possible. A thread's
        // turns read the memory of where the thread is: its coven's pages,
        // or in no coven the person's own memory and Strix's pages.
        let places = scope.map { MemoryPlace.read(inCoven: $0.covenID) } ?? []
        let allMemories = places.isEmpty ? [] : try await embeddingService.searchRelevantMemories(
            query: question,
            in: places,
            of: account,
            topK: limits.maxRecentMemories,
            candidateLimit: limits.maxRecentMemories * 8
        )

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
                let content = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                // Deduplicate: skip the last user message if it matches the
                // current user question. The caller persists the user message
                // before calling buildContext, so it already appears in the
                // message store. Without this check, the same message would
                // appear twice: once here in recents and again in Layer 7.
                if role == .user, content == question {
                    // Only skip if this is the very last message in history
                    // (i.e. the one just persisted before this call).
                    if msg.id == recent.last?.id {
                        continue
                    }
                }
                segments.recents.append(LLMMessage(role: role, content: content))
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
        segments.user.append(LLMMessage(role: .user, content: question, images: images))

        // Layer 8: response guidance – kept deliberately brief and
        // conversational so models do not echo it verbatim.
        let checklist = "Reply concisely. Ground your answer in the provided memories and conversation context—do not invent facts. If you used tools (web search, files), mention it naturally. Ask clarifying questions when details are ambiguous."
        segments.checklist.append(LLMMessage(role: .system, content: checklist))

        // Who answers, and how the person asked it to: before anything
        // else the model is told. Decided last, once everything that was
        // waited for is in: not an agent of an account that is not the
        // one this context was read as, nor once another is signed in.
        if let agent, agent.account == account, UserScope.currentUserID == account {
            segments.system.insert(LLMMessage(role: .system, content: agent.systemPrompt), at: 0)
        }

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

        // Markers that separate user text from tool-generated context.
        // "You have tool results below" is prepended by ChatService when
        // appending MCP / tool-loop results to the composed message.
        let markers = ["[Web search results]", "[Attachment analysis]", "You have tool results below"]
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
    /// sufficient for truncation decisions. A picture counts as a flat
    /// number of tokens, as the cloud app counts it.
    static func approximateTokenCount(for messages: [LLMMessage]) -> Int {
        var total = 0
        for message in messages {
            let charCount = message.content.count
            total += max(1, charCount / 4) + message.images.count * tokensPerImage
        }
        return total
    }

    static let tokensPerImage = 560

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
