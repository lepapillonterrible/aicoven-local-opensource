import Foundation

/// Task from an agent's planning scratchpad
struct AgentTask: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    var completed: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, completed
    }
}

/// Message model for chat
struct ChatMessage: Codable, Identifiable, Hashable {
    let id: String
    let threadId: String
    let role: String
    let content: String
    let metadata: [String: AnyJSONValue]?
    let tokenUsage: TokenUsage?
    let createdAt: Date?
    let isEncrypted: Bool?
    let keyFingerprint: String?

    enum CodingKeys: String, CodingKey {
        case id
        case threadId = "thread_id"
        case role, content, metadata
        case tokenUsage = "token_usage"
        case createdAt = "created_at"
        case isEncrypted = "is_encrypted"
        case keyFingerprint = "key_fingerprint"
    }
}

/// Token usage information
struct TokenUsage: Codable, Hashable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

/// Event from the /chat/stream SSE endpoint
///
/// The backend may emit different event types:
/// - "metadata": initial provider/model info
/// - "delta": streamed text chunks (with optional `phase`)
/// - "thought": parsed <thought> blocks
/// - "tool_call": tool invocation (name + args)
/// - "tool_result": tool execution results
/// - "memory_proposal": memory write proposals
/// - "done": final completion marker (includes provider/model/token_usage)
struct ChatStreamEvent: Decodable {
    let type: String
    let content: String?
    let phase: String?
    let provider: String?
    let model: String?
    let messageId: String?
    let tokenUsage: TokenUsage?
    // Optional fields for tool events
    let name: String?
    let args: [String: AnyJSONValue]?

    enum CodingKeys: String, CodingKey {
        case type
        case content
        case phase
        case provider
        case model
        case messageId = "message_id"
        case tokenUsage = "token_usage"
        case name
        case args
    }
}

// MARK: - Tool Intent Decision

/// Result of the heuristic intent gate that decides whether a user message
/// needs tool calls before the model sees tool instructions.
enum ToolIntentDecision {
    /// The message is clearly conversational; skip the tool loop entirely.
    case noTools(reason: String)
    /// The message likely needs tools (search, file ops, etc.).
    case useTools(suggested: [String])
    /// Ambiguous — fall through to the LLM with tool instructions.
    case ambiguous

    /// Heuristic fast-path: classify a user message without an LLM call.
    /// Returns `.noTools` for obviously conversational requests and
    /// `.useTools` for obvious tool requests; `.ambiguous` otherwise.
    static func heuristic(for message: String) -> ToolIntentDecision {
        let lower = message.lowercased()

        // Obvious no-tool patterns (conversational, opinion, summarization)
        let noToolPatterns = [
            "give me a proposal", "explain", "summarize", "what do you think",
            "review this", "help me understand", "tell me about",
            "what is", "what are", "how does", "how do",
            "can you describe", "opinion on", "compare",
            "write me", "draft", "rewrite", "translate",
            "hello", "hi ", "hey ", "thanks", "thank you"
        ]
        if noToolPatterns.contains(where: { lower.contains($0) }) {
            return .noTools(reason: "Heuristic: conversational/opinion/writing request")
        }

        // Obvious tool patterns (web search, file ops, github, time)
        let toolPatterns = [
            "search for", "look up", "find on github", "google",
            "what's the weather", "weather in", "current weather",
            "read file", "write file", "list files",
            "run command", "execute", "shell",
            "what time", "current time", "what date",
            "open the url", "browse", "fetch",
            "github.com", "create a pr", "pull request",
            "create branch", "list repos"
        ]
        if toolPatterns.contains(where: { lower.contains($0) }) {
            return .useTools(suggested: [])
        }

        return .ambiguous
    }
}

/// Service for chat and message API calls
actor ChatService {
    /// Shared singleton using the core LLM router + context builder. The
    /// environment is filtered to providers that actually have API keys
    /// configured via ProviderKeysView / ProviderAccountService.
    static let shared: ChatService = {
        let env = LLMConfiguration.makeEnvironment()
        return ChatService(
            contextBuilder: ContextBuilder(),
            modelRouter: HeuristicModelRouter(availableModels: env.models),
            llmClients: env.clients,
            threadStore: ThreadRepository.shared,
            toolService: ToolService.shared
        )
    }()

    private let contextBuilder: ContextBuilder
    private var modelRouter: ModelRouter
    private var llmClients: [String: LLMClient]
    /// Abstraction over thread persistence so chat logic does not depend on
    /// the concrete GRDB repository.
    private let threadStore: ThreadStore
    /// Tool facade used by chat for web search and time; injected for tests.
    private let toolService: ChatToolService
    /// Whether ChatService should automatically refresh its LLM environment
    /// from ProviderAccountService on each call. Tests can disable this to
    /// keep injected mock clients and routers.
    private let shouldAutoRefreshEnvironment: Bool

    /// In-memory local message store keyed by thread ID. This gives us basic
    /// per-thread history for contextual chat without any backend.
    private var messageStore: [String: [ChatMessage]] = [:]
    /// Maximum number of prior turns to include when building LLM context.
    private let maxContextMessages = 20

    /// Whether we've attempted to hydrate the in-memory store from disk.
    private var hasLoadedFromDisk = false

    /// User-scoped on-disk cache location for message history.
    private var messageStoreURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("AICovenOpen", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Use user-scoped filename so each user gets their own message history
        let filename = UserScope.scopedFilename("messages", extension: "json")
        return dir.appendingPathComponent(filename, isDirectory: false)
    }

    /// Reload message store for the current user. Call after user switch.
    func reloadForCurrentUser() {
        // Clear in-memory cache
        messageStore = [:]
        hasLoadedFromDisk = false
        // Next call to loadMessages will reload from user-scoped file
    }

    init(
        contextBuilder: ContextBuilder,
        modelRouter: ModelRouter,
        llmClients: [String: LLMClient],
        threadStore: ThreadStore,
        toolService: ChatToolService,
        shouldAutoRefreshEnvironment: Bool = true
    ) {
        self.contextBuilder = contextBuilder
        self.modelRouter = modelRouter
        self.llmClients = llmClients
        self.threadStore = threadStore
        self.toolService = toolService
        self.shouldAutoRefreshEnvironment = shouldAutoRefreshEnvironment
    }

    /// Ensure that we have an up-to-date LLM environment based on the latest
    /// provider keys in UserDefaults and the live model lists returned by each
    /// provider. This is important because `ChatService` is initialized once at
    /// app launch; users may add or remove keys later.
    private func ensureEnvironment() async {
        guard shouldAutoRefreshEnvironment else { return }

        // Rebuild the client map from the latest cached API keys.
        let env = LLMConfiguration.makeEnvironment()
        llmClients = env.clients

        do {
            // Build dynamic model descriptors from live ListModels responses for
            // all configured provider accounts.
            let allDescriptors = try await ProviderAccountService.shared.loadAllModelDescriptors()
            // Only keep descriptors for providers we actually have clients for.
            let allowed = Set(llmClients.keys)
            let models = allDescriptors.filter { allowed.contains($0.providerID) }
            modelRouter = HeuristicModelRouter(availableModels: models)
        } catch {
            AppErrorReporter.log(error: error, context: "ChatService.ensureEnvironment.loadModelDescriptors")
            modelRouter = HeuristicModelRouter(availableModels: [])
        }
    }

    // MARK: - Local message store (memory + disk)

    /// Append a message to the local in-memory history for its thread and
    /// persist the updated store to disk.
    func addLocalMessage(_ message: ChatMessage) {
        var messages = messageStore[message.threadId] ?? []
        messages.append(message)
        messageStore[message.threadId] = messages
        saveMessageStoreToDisk()
    }

    /// Ensure the in-memory message store is hydrated from disk at most once.
    private func ensureLoadedFromDisk() {
        guard !hasLoadedFromDisk else { return }
        hasLoadedFromDisk = true
        let fm = FileManager.default
        guard fm.fileExists(atPath: messageStoreURL.path) else { return }
        do {
            let data = try Data(contentsOf: messageStoreURL)
            let decoded = try JSONDecoder().decode([String: [ChatMessage]].self, from: data)
            messageStore = decoded
        } catch {
            AppErrorReporter.log(error: error, context: "ChatService.ensureLoadedFromDisk")
        }
    }

    /// Persist the current in-memory message store to disk.
    private func saveMessageStoreToDisk() {
        do {
            let data = try JSONEncoder().encode(messageStore)
            try data.write(to: messageStoreURL, options: .atomic)
        } catch {
            AppErrorReporter.log(error: error, context: "ChatService.saveMessageStoreToDisk")
        }
    }

    /// Load messages for a thread
    /// - Parameters:
    ///   - threadId: The thread ID
    ///   - limit: Maximum number of messages to load
    ///   - before: Load messages before this message ID
    /// - Returns: List of messages
    func loadMessages(threadId: String, limit: Int = 1000, before: String? = nil) async throws -> [ChatMessage] {
        ensureLoadedFromDisk()
        let all = messageStore[threadId] ?? []
        guard !all.isEmpty else { return [] }

        // Messages are stored in ascending order (oldest first). We support
        // simple pagination using the optional `before` message ID.
        if let beforeId = before, let idx = all.firstIndex(where: { $0.id == beforeId }) {
            let end = idx
            let start = max(0, end - limit)
            return Array(all[start ..< end])
        } else {
            let end = all.count
            let start = max(0, end - limit)
            return Array(all[start ..< end])
        }
    }

    /// Send a message and get AI response (non-streaming)
    /// - Parameters:
    ///   - threadId: The thread ID
    ///   - message: User message content
    ///   - roleId: AI role/agent ID (optional)
    ///   - providerAccountId: Provider account to use (optional)
    ///   - attachmentIds: File attachment IDs (optional)
    /// - Returns: The AI response message
    func sendMessage(
        threadId: String,
        message: String,
        roleId: String? = nil,
        providerAccountId: String? = nil,
        attachmentIds: [String]? = nil
    ) async throws -> ChatResponse {
        // Local-only open source client: non-streaming chat against the
        // legacy backend is not supported. For now, return a simple
        // placeholder response so call sites don't crash.
        AppErrorReporter.log(message: "sendMessage called in local-only build – returning placeholder response.", context: "ChatService.sendMessage")
        return ChatResponse(
            messageId: UUID().uuidString,
            content: "This local AICoven Local build does not yet support non-streaming chat.",
            role: "assistant",
            provider: "local",
            model: nil,
            tokenUsage: nil,
            memoryProposals: [],
            thoughts: nil,
            toolCalls: nil,
            metadata: [:]
        )
    }

    /// Stream a message using the local LLM client and surface planning/answer phases.
    ///
    /// This uses non-streaming provider SDKs under the hood but can perform a
    /// small tool-calling loop (web_search, current_time) before returning the
    /// final natural-language answer. The loop follows the same JSON protocol
    /// as AgentRunner so models can decide when to call tools.
    ///
    /// - Parameters:
    ///   - threadId: The thread ID
    ///   - message: User message content
    ///   - roleId: AI role/agent ID (optional)
    ///   - providerAccountId: Provider account to use (optional)
    ///   - attachments: File attachments with local URLs (optional). File contents will be read and injected into the context.
    func streamMessage(
        threadId: String,
        message: String,
        roleId: String? = nil,
        providerAccountId: String? = nil,
        attachments: [FileAttachmentDetail]? = nil,
        onPlanningDelta: @escaping (String) -> Void,
        onToolEvent: @escaping (String) -> Void,
        onAnswerDelta: @escaping (String) -> Void,
        onDone: @escaping (_ provider: String?, _ model: String?, _ tokenUsage: TokenUsage?) -> Void
    ) async throws {
        // Ensure we see any provider keys and live model lists that may have
        // been added or changed after ChatService was first initialized.
        await ensureEnvironment()

        // Resolve provider + model: prefer role-specific settings when a
        // roleId is provided (coven agent threads), otherwise fall back to
        // the user's global preference from UserDefaults.
        let prefProvider: String
        let prefModel: String

        if let roleId,
           let role = try? await RoleService.shared.getRole(roleId: roleId),
           let roleProvider = role.provider, !roleProvider.isEmpty,
           let roleModel = role.model, !roleModel.isEmpty {
            prefProvider = roleProvider.lowercased()
            prefModel = roleModel
            #if DEBUG
            AppErrorReporter.log(message: "Role '\(role.name)' resolved provider=\(prefProvider) model=\(prefModel)", context: "ChatService.streamMessage.roleResolution")
            #endif
        } else {
            let (globalProvider, globalModel) = resolveProviderAndModel()
            prefProvider = globalProvider
            prefModel = globalModel
            #if DEBUG
            AppErrorReporter.log(message: "No role override (roleId=\(roleId ?? "nil")); using global provider=\(prefProvider) model=\(prefModel)", context: "ChatService.streamMessage.roleResolution")
            #endif
        }

        let descriptor: ModelDescriptor
        let client: LLMClient

        if let prefClient = llmClients[prefProvider],
           let match = modelRouter.findExact(providerID: prefProvider, modelID: prefModel) {
            descriptor = match
            client = prefClient
        } else {
            // Fall back to heuristic routing.
            let routingContext = RoutingContext(
                task: .chat,
                requireLocalOnly: false,
                requireLongContext: false,
                preferHighQuality: true
            )
            guard let fallbackDescriptor = modelRouter.route(for: routingContext),
                  let fallbackClient = llmClients[fallbackDescriptor.providerID] else {
                let msg = "No configured providers/models available for chat. Add provider keys in Settings."
                onPlanningDelta("")
                onAnswerDelta(msg)
                onDone(nil, nil, nil)
                return
            }
            descriptor = fallbackDescriptor
            client = fallbackClient
        }

        // Give the UI an immediate hint that we're contacting the provider.
        onPlanningDelta("Thinking about your question…")

        // Intent gate: decide whether this message needs tools at all.
        // This prevents unnecessary tool loops for conversational requests
        // and avoids injecting tool protocol instructions that cause the
        // model to regurgitate its own rules.
        let intent = ToolIntentDecision.heuristic(for: message)
        let toolsAllowed: Bool
        switch intent {
        case let .noTools(reason):
            #if DEBUG
            AppErrorReporter.log(message: "Intent gate: skipping tools — \(reason)", context: "ChatService.streamMessage.intentGate")
            #endif
            toolsAllowed = false
        case .useTools:
            toolsAllowed = true
        case .ambiguous:
            // For ambiguous messages, allow tools but the model decides.
            toolsAllowed = true
        }

        // Simple tool loop: allow the model a configurable number of tool
        // invocations before we require a natural-language answer. The
        // `chat_max_tool_steps` budget controls how many *tool calls* are
        // allowed; the user always gets a final answer attempt even if the
        // budget is exhausted.
        let maxToolSteps = toolsAllowed ? max(0, Self.currentMaxToolSteps()) : 0
        var remainingToolSteps = maxToolSteps
        #if DEBUG
        AppErrorReporter.log(message: "streamMessage starting: provider=\(descriptor.providerID) model=\(descriptor.modelID) maxToolSteps=\(maxToolSteps) toolsAllowed=\(toolsAllowed)", context: "ChatService.streamMessage")
        #endif
        var toolContextLog = ""
        var finalText: String?
        var finalUsage: TokenUsage?
        var streamedAnswer = false

        // Local models (MLX, Ollama) get a shorter, more assertive prompt.
        let isLocalModel = ["mlx", "ollama"].contains(descriptor.providerID)
        let toolConfig: ContextBuilder.ToolConfig = isLocalModel ? .mlxTools : .allTools

        // ── Context-aware repeat detection (ported from backend) ──────────
        // Tracks tool-call signatures across loop iterations so we can
        // detect the model calling the exact same tool with the same args
        // in consecutive steps *without* the context changing between calls.
        // Format: signature → [(stepNumber, contextHash)]
        var toolCallHistory: [String: [(step: Int, contextHash: String)]] = [:]
        let maxConsecutiveSameCalls = 2
        var stepNumber = 0

        // ── Continuation prompts (ported from backend) ───────────────────
        // When the model says "I'll now do X" but forgets to call a tool,
        // we inject a nudge prompt up to this many times before giving up.
        var continuationCount = 0
        let maxContinuationPrompts = 2

        // ── Tool result compression threshold ────────────────────────────
        // Once toolContextLog exceeds this length (chars), older results
        // are truncated to prevent context overflow.
        let toolContextCompressThreshold = 3000

        // Track initial message sent
        AnalyticsService.shared.trackMessageSent(threadId: threadId, hasAttachments: !(attachments?.isEmpty ?? true), attachmentCount: attachments?.count ?? 0)

        // ── Build attachment context block ────────────────────────────────
        // Read file contents from local attachments and build a context block
        // so the agent can see the attached files.
        var attachmentContextBlock = ""
        if let attachments, !attachments.isEmpty {
            var attachmentLines: [String] = []
            for attachment in attachments {
                let name = attachment.name
                let mime = attachment.mimeType ?? "unknown"

                // Try to read file contents from the local URL
                if let url = attachment.url {
                    do {
                        if mime.hasPrefix("image/") {
                            // For images, describe them (actual image content would need vision API)
                            let sizeDesc = attachment.sizeBytes.map { "\(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))" } ?? "unknown size"
                            let dims = (attachment.width != nil && attachment.height != nil) ? "\(attachment.width!)×\(attachment.height!)" : ""
                            attachmentLines.append("[Image: \(name)] (\(mime), \(sizeDesc)\(dims.isEmpty ? "" : ", \(dims)"))")
                            attachmentLines.append("Note: This is an image attachment. Describe what you see or ask the user about it if needed.")
                        } else {
                            // For text-based files, read the content
                            let data = try Data(contentsOf: url)
                            if let text = String(data: data, encoding: .utf8) {
                                // Truncate very large files to avoid context overflow
                                let maxChars = 8000
                                let truncated = text.count > maxChars
                                let content = truncated ? String(text.prefix(maxChars)) + "\n... [truncated, \(text.count - maxChars) more characters]" : text
                                attachmentLines.append("[File: \(name)] (\(mime))")
                                attachmentLines.append("```")
                                attachmentLines.append(content)
                                attachmentLines.append("```")
                            } else {
                                // Binary file that's not an image - just note its presence
                                let sizeDesc = attachment.sizeBytes.map { "\(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))" } ?? "unknown size"
                                attachmentLines.append("[Binary file: \(name)] (\(mime), \(sizeDesc)) - Contents cannot be displayed as text.")
                            }
                        }
                    } catch {
                        AppErrorReporter.log(error: error, context: "ChatService.streamMessage.readAttachment")
                        attachmentLines.append("[File: \(name)] (\(mime)) - Unable to read file contents: \(error.localizedDescription)")
                    }
                } else {
                    // No URL available, just describe the attachment
                    let sizeDesc = attachment.sizeBytes.map { "\(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))" } ?? "unknown size"
                    attachmentLines.append("[File: \(name)] (\(mime), \(sizeDesc)) - No local file URL available.")
                }
            }
            if !attachmentLines.isEmpty {
                attachmentContextBlock = "\n\n[User attached files]\n" + attachmentLines.joined(separator: "\n")
            }
        }

        // Append attachment context to the message so the LLM can see the files
        let messageWithAttachments = attachmentContextBlock.isEmpty ? message : message + attachmentContextBlock

        // First phase: while we still have tool budget, let the model decide
        // whether to call a tool. Each successful tool invocation consumes one
        // step from the budget; a direct natural-language reply ends the loop.
        while remainingToolSteps > 0, finalText == nil {
            stepNumber += 1
            // Build the effective user message. Only append tool protocol
            // instructions when tools are allowed — the system prompt from
            // ContextBuilder already includes full tool documentation, so
            // appending here too caused double-injection and prompt
            // regurgitation.
            // Include attachment context so the model can see any attached files.
            var composedUserMessage = messageWithAttachments
            if !toolContextLog.isEmpty {
                // When we have accumulated tool results, include a brief
                // instruction so the model knows to incorporate them.
                composedUserMessage += "\n\nYou have tool results below. Use them to answer the user's question. If you need more information, call another tool. Otherwise, provide your final answer in natural language.\n\n" + toolContextLog
            }

            // Build LLM context using the shared ContextBuilder, which will pull
            // in runtime info, policies, memories, and recent turns for this
            // thread. We respect the model's max context tokens with a safety
            // margin.
            let promptBudget = Int(Double(descriptor.maxContextTokens) * 0.8)
            let contextMessages = try await contextBuilder.buildContext(
                threadID: threadId,
                userMessage: composedUserMessage,
                maxContextTokens: promptBudget,
                toolConfig: toolConfig
            )

            do {
                // Pass native tool definitions for API providers (not local models).
                let nativeTools: [LLMToolDefinition]? = isLocalModel ? nil
                    : PromptTemplates.llmToolDefinitions(for: toolConfig.enabledTools)
                let options = ChatOptions(
                    temperature: 0.7,
                    maxTokens: nil,
                    stream: false,
                    tools: nativeTools
                )
                let response = try await client.completeChat(
                    messages: contextMessages,
                    model: descriptor.modelID,
                    options: options
                )
                let rawText = response.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                #if DEBUG
                AppErrorReporter.log(message: "provider response (tool phase, truncated): \(rawText.prefix(200))", context: "ChatService.streamMessage.toolLoop")
                #endif
                let usage = response.usage.map { core in
                    TokenUsage(
                        promptTokens: core.promptTokens,
                        completionTokens: core.completionTokens,
                        totalTokens: core.totalTokens
                    )
                }
                finalUsage = usage

                // ── Check for native tool calls first ──────────────────────
                // API providers (OpenAI, Anthropic, Gemini) return structured
                // tool calls via response.toolCalls. Convert the first one to
                // a ChatToolInvocation for the existing execution pipeline.
                let toolCall: ChatToolInvocation?
                if let nativeCalls = response.toolCalls, let first = nativeCalls.first {
                    toolCall = ChatToolInvocation(
                        tool: first.name,
                        input: AnyJSONValue(first.arguments),
                        reason: "Native \(descriptor.providerID) tool call"
                    )
                    #if DEBUG
                    AppErrorReporter.log(message: "Native tool call from \(descriptor.providerID): \(first.name)", context: "ChatService.streamMessage.nativeToolCall")
                    #endif
                } else {
                    // Fall back to text parsing for local models or text-based calls
                    toolCall = ChatToolInvocation.from(jsonString: rawText)
                }
                // Remap hallucinated tool names (e.g. "python" → "shell.execute")
                if let toolCall = toolCall?.remapped() {
                    // ── Context-aware repeat detection ────────────────────
                    // Build a stable signature from the tool name + normalized args.
                    let rawInput = extractToolInputString(from: toolCall.input) ?? ""
                    let normalizedInputForSignature = Self.normalizeForDedupe(rawInput)
                    let signature = "\(toolCall.tool.lowercased())|\(normalizedInputForSignature)"

                    // Hash the current accumulated context so we can tell
                    // whether anything changed between repeated calls.
                    let contextHash = Self.computeContextHash(toolContextLog)

                    // Record this call with its step number and context hash.
                    toolCallHistory[signature, default: []].append((step: stepNumber, contextHash: contextHash))

                    // Check for N consecutive steps with the same call AND
                    // unchanged context (ported from backend).
                    let history = toolCallHistory[signature]!
                    if history.count >= maxConsecutiveSameCalls {
                        let recent = Array(history.suffix(maxConsecutiveSameCalls))
                        let isConsecutive = recent.count == maxConsecutiveSameCalls
                            && (1 ..< recent.count).allSatisfy { recent[$0].step == recent[$0 - 1].step + 1 }
                        let contextUnchanged = Set(recent.map(\.contextHash)).count == 1

                        if isConsecutive, contextUnchanged {
                            #if DEBUG
                            AppErrorReporter.log(
                                message: "Repeat loop detected: \(toolCall.tool) called \(maxConsecutiveSameCalls)x with unchanged context. Breaking.",
                                context: "ChatService.streamMessage.repeatDetection"
                            )
                            #endif
                            let explanation = "I called tools several times but still couldn't finish this request reliably. Please try rephrasing or simplifying the request, or use a dedicated service if you need precise real-time data."
                            finalText = explanation
                            break
                        }
                    }

                    // Reset continuation counter when the model makes progress
                    continuationCount = 0

                    #if DEBUG
                    AppErrorReporter.log(message: "Parsed chat tool call: \(toolCall.tool) (remaining before decrement=\(remainingToolSteps))", context: "ChatService.streamMessage.toolLoop")
                    #endif
                    // We only honor tool calls while there is remaining budget.
                    remainingToolSteps -= 1

                    // Track tool usage
                    AnalyticsService.shared.trackToolUsed(toolName: toolCall.tool, threadId: threadId)

                    let (summary, contextBlock) = try await executeChatToolCall(toolCall)
                    onToolEvent(summary)
                    if let block = contextBlock {
                        if toolContextLog.isEmpty {
                            toolContextLog = block
                        } else {
                            toolContextLog += "\n\n" + block
                        }
                    }

                    // ── Tool result compression ──────────────────────────
                    // Prevent context overflow when many tool steps run.
                    if toolContextLog.count > toolContextCompressThreshold {
                        let keep = toolContextCompressThreshold / 2
                        let suffix = String(toolContextLog.suffix(keep))
                        toolContextLog = "... (older tool results truncated)\n\n" + suffix
                    }
                    // Loop again with updated tool context.
                    continue
                } else {
                    // If the model refused to answer a weather question without
                    // using tools, optionally force a single web_search call.
                    // This is behind a feature flag (default OFF) because it
                    // overrides the model's own decision and can contribute to
                    // unexpected tool loops.
                    let forceSearchEnabled = UserDefaults.standard.bool(forKey: "force_search_enabled")
                    if forceSearchEnabled,
                       remainingToolSteps > 0,
                       let forcedQuery = maybeForceSearchQuery(userMessage: message, modelReply: rawText) {
                        let inputDict: [String: AnyJSONValue] = ["query": AnyJSONValue(forcedQuery)]
                        let forcedCall = ChatToolInvocation(
                            tool: "web_search",
                            input: AnyJSONValue(inputDict),
                            reason: "User asked for current weather; previous reply said I cannot answer, but I can search the web."
                        )
                        let normalizedInputForSignature = Self.normalizeForDedupe(forcedQuery)
                        let signature = "web_search|\(normalizedInputForSignature)"
                        let ctxHash = Self.computeContextHash(toolContextLog)
                        toolCallHistory[signature, default: []].append((step: stepNumber, contextHash: ctxHash))
                        remainingToolSteps -= 1

                        // Track tool usage
                        AnalyticsService.shared.trackToolUsed(toolName: "web_search", threadId: threadId)

                        let (summary, contextBlock) = try await executeChatToolCall(forcedCall)
                        onToolEvent(summary)
                        if let block = contextBlock {
                            if toolContextLog.isEmpty {
                                toolContextLog = block
                            } else {
                                toolContextLog += "\n\n" + block
                            }
                        }
                        // Loop again with updated tool context.
                        continue
                    }
                    // ── Malformed tool output detection ──────────────────
                    // If the response has broken tool markup that didn't
                    // parse, treat it as a final answer rather than looping.
                    if Self.detectMalformedToolOutput(rawText) {
                        #if DEBUG
                        AppErrorReporter.log(message: "Malformed tool output detected; treating cleaned text as final answer.", context: "ChatService.streamMessage.malformed")
                        #endif
                        finalText = Self.stripToolMarkup(rawText)
                        break
                    }

                    // ── Premature stop detection ─────────────────────────
                    // If the model says "I'll now do X" but didn't call a
                    // tool, nudge it to continue (up to max prompts).
                    if continuationCount < maxContinuationPrompts,
                       Self.detectPrematureStop(rawText, stepCount: stepNumber, maxSteps: maxToolSteps) {
                        continuationCount += 1
                        #if DEBUG
                        AppErrorReporter.log(message: "Premature stop detected (\(continuationCount)/\(maxContinuationPrompts)); injecting continuation prompt.", context: "ChatService.streamMessage.continuation")
                        #endif
                        // Append the model's partial response and a nudge
                        if !toolContextLog.isEmpty { toolContextLog += "\n\n" }
                        toolContextLog += "[Assistant partial response]\n" + rawText
                        toolContextLog += "\n\n[System] You indicated there is more work to do but didn't call any tools. Please continue with the next step. Use the appropriate tool to proceed."
                        continue
                    }

                    // Treat this as the final natural-language answer.
                    #if DEBUG
                    AppErrorReporter.log(message: "No tool call detected in provider response; treating as final answer.", context: "ChatService.streamMessage.toolLoop")
                    #endif
                    finalText = rawText
                    break
                }
            } catch {
                let msg: String
                let errorCode: String
                if let localError = error as? LocalChatError {
                    msg = localError.localizedDescription
                    errorCode = localError.analyticsCode
                } else {
                    msg = error.localizedDescription
                    errorCode = "unknown_error"
                }

                // Track error with a low-cardinality code; avoid logging full
                // user-visible error text into analytics.
                AnalyticsService.shared.trackMessageError(threadId: threadId, errorType: errorCode)

                onPlanningDelta("")
                onAnswerDelta("Error: \(msg)")
                onDone(nil, nil, nil)
                return
            }
        }

        // Second phase: if we used up the tool budget without the model ever
        // producing a natural-language answer, give it one final, tool-free
        // chance. On this last attempt we *always* treat the response as the
        // answer (even if it contains JSON) so the user is never left hanging
        // with a generic failure.
        if finalText == nil {
            // Final phase: no tool instructions — just ask the model to
            // answer in natural language using whatever it already knows.
            // Include attachment context so the model can see any attached files.
            var composedUserMessage = messageWithAttachments + "\n\nIMPORTANT: You must now answer the user directly in natural language. Do NOT call tools or return JSON. Provide the most helpful answer you can using your own reasoning and the information already available (including any tool results and your built-in knowledge). Do NOT say that you cannot answer because you cannot use tools or the web; instead, make your best effort to answer, even if it is an approximation, and clearly explain any uncertainty."
            if !toolContextLog.isEmpty {
                composedUserMessage += "\n\n" + toolContextLog
            }

            let promptBudget = Int(Double(descriptor.maxContextTokens) * 0.8)
            let contextMessages = try await contextBuilder.buildContext(
                threadID: threadId,
                userMessage: composedUserMessage,
                maxContextTokens: promptBudget,
                toolConfig: toolConfig
            )

            do {
                // If the client supports streaming, use token-by-token delivery
                // for the final answer so the user sees text appear in real time.
                if let streamingClient = client as? StreamingLLMClient {
                    let options = ChatOptions(temperature: 0.7, maxTokens: nil, stream: true)
                    onPlanningDelta("")
                    var accumulated = ""
                    let stream = streamingClient.streamChat(
                        messages: contextMessages,
                        model: descriptor.modelID,
                        options: options
                    )
                    for try await delta in stream {
                        if !delta.text.isEmpty {
                            accumulated += delta.text
                            onAnswerDelta(delta.text)
                        }
                        if let usage = delta.usage {
                            finalUsage = TokenUsage(
                                promptTokens: usage.promptTokens,
                                completionTokens: usage.completionTokens,
                                totalTokens: usage.totalTokens
                            )
                        }
                    }
                    // Mark streaming final answer so we skip the post-loop emission.
                    finalText = accumulated
                    streamedAnswer = true
                } else {
                    let options = ChatOptions(temperature: 0.7, maxTokens: nil, stream: false)
                    let response = try await client.completeChat(
                        messages: contextMessages,
                        model: descriptor.modelID,
                        options: options
                    )
                    let rawText = response.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    #if DEBUG
                    AppErrorReporter.log(message: "provider response (final phase, truncated): \(rawText.prefix(200))", context: "ChatService.streamMessage.finalPhase")
                    #endif
                    let usage = response.usage.map { core in
                        TokenUsage(
                            promptTokens: core.promptTokens,
                            completionTokens: core.completionTokens,
                            totalTokens: core.totalTokens
                        )
                    }
                    finalUsage = usage
                    finalText = rawText
                }
            } catch {
                let msg: String
                let errorCode: String
                if let localError = error as? LocalChatError {
                    msg = localError.localizedDescription
                    errorCode = localError.analyticsCode
                } else {
                    msg = error.localizedDescription
                    errorCode = "unknown_error"
                }

                // Track error with a low-cardinality code; avoid logging full
                // user-visible error text into analytics.
                AnalyticsService.shared.trackMessageError(threadId: threadId, errorType: errorCode)

                onPlanningDelta("")
                onAnswerDelta("Error: \(msg)")
                onDone(nil, nil, nil)
                return
            }
        }

        // By this point we should always have some text for the user. As a
        // final safeguard, fall back to a generic message if for some reason we
        // still ended up without an answer.
        let rawAnswer = finalText ?? "I wasn't able to finish this request after using tools. Please try rephrasing or asking a simpler version."

        // Parse the response to extract memory proposals and strip markup
        // ── Response text deduplication (ported from backend) ────────────
        // Strip duplicate paragraphs that the model sometimes produces.
        let dedupedAnswer = Self.dedupeResponseText(rawAnswer)
        let parseResult = ToolCallParser.parse(dedupedAnswer)
        let answer = parseResult.strippedText.isEmpty ? rawAnswer : parseResult.strippedText

        // Process any memory proposals from the LLM
        if !parseResult.memoryProposals.isEmpty {
            for proposal in parseResult.memoryProposals {
                // Auto-save memory proposals (scope can be "user" or "thread")
                let effectiveScope = proposal.scope == "thread" ? "thread" : "user"
                do {
                    _ = try await MemoryService.shared.createMemory(
                        covenId: nil,
                        scope: effectiveScope,
                        title: nil,
                        content: proposal.content,
                        tags: proposal.category.map { [$0] },
                        isPinned: false
                    )
                    AppErrorReporter.log(message: "Saved memory proposal: scope=\(effectiveScope) content=\(proposal.content.prefix(50))...", context: "ChatService.streamMessage.memoryWrite")
                } catch {
                    AppErrorReporter.log(error: error, context: "ChatService.streamMessage.memoryWrite")
                }
            }
        }

        AppErrorReporter.log(message: "streamMessage completed with answer length=\(answer.count) provider=\(descriptor.providerID) model=\(descriptor.modelID) usedTools=\(maxToolSteps - remainingToolSteps)", context: "ChatService.streamMessage")
        onPlanningDelta("")
        // Only emit the full answer if we haven't already streamed it
        // token-by-token via StreamingLLMClient.
        if !streamedAnswer {
            onAnswerDelta(answer)
        }

        // Persist a lightweight usage entry so the local Budgets & Usage
        // dashboard can approximate spend per provider.
        await UsageService.shared.recordLocalUsage(
            provider: descriptor.providerID,
            model: descriptor.modelID,
            usage: finalUsage,
            threadId: threadId
        )

        onDone(descriptor.providerID, descriptor.modelID, finalUsage)

        // Track message received. We don't currently measure precise
        // end-to-end latency here, so omit response time instead of
        // sending a misleading placeholder.
        let totalTokens = finalUsage?.totalTokens ?? 0
        AnalyticsService.shared.trackMessageReceived(
            threadId: threadId,
            provider: descriptor.providerID,
            model: descriptor.modelID,
            tokenCount: totalTokens
        )
    }

    /// Recompute and persist a compact summary for the given thread using the
    /// configured LLM providers. This runs independently of any one chat turn
    /// and is safe to call opportunistically after new messages are added.
    func updateThreadSummary(threadId: String) async {
        // Ensure environment is ready before routing summarization calls.
        await ensureEnvironment()
        do {
            // Use the same history seen by the chat UI.
            let history = try await loadMessages(threadId: threadId, limit: maxContextMessages)
            guard !history.isEmpty else { return }

            var messages: [LLMMessage] = []
            messages.append(
                LLMMessage(
                    role: .system,
                    content: "You are summarizing a conversation so it can be used as context in future turns. " +
                        "Write a concise summary in 3-6 bullet points focusing on key facts, decisions, and open questions."
                )
            )
            for msg in history {
                let role: LLMMessage.Role = (msg.role == "user") ? .user : .assistant
                messages.append(LLMMessage(role: role, content: msg.content))
            }

            let routingContext = RoutingContext(
                task: .chat,
                requireLocalOnly: false,
                requireLongContext: false,
                preferHighQuality: true
            )
            guard let descriptor = modelRouter.route(for: routingContext),
                  let client = llmClients[descriptor.providerID] else {
                return
            }

            let options = ChatOptions(temperature: 0.2, maxTokens: nil, stream: false)
            let response = try await client.completeChat(
                messages: messages,
                model: descriptor.modelID,
                options: options
            )
            let summary = response.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { return }

            try await threadStore.updateSummary(forThreadID: threadId, summary: summary)
        } catch {
            // Thread summaries are an optional optimization. In the local-only
            // client we treat *all* failures as non-fatal and skip logging to
            // avoid noisy console output (network hiccups, provider errors,
            // etc.). They can always be recomputed on a later turn.
            if let nsError = error as NSError?,
               nsError.domain == "DataEncryptionService",
               nsError.code == -3 {
                return
            }
            return
        }
    }

    /// Resolve the current provider + model from simple local settings.
    ///
    /// This is a temporary shim until Strix + ProviderAccountService are fully
    /// localized. It prefers explicit overrides in UserDefaults:
    ///  - llm_provider: "openai" | "anthropic" | "google"
    ///  - openai_model / anthropic_model / gemini_model
    private func resolveProviderAndModel() -> (String, String) {
        let provider = UserDefaults.standard.string(forKey: UserScope.scopedKey("llm_provider"))?.lowercased() ?? "openai"
        switch provider {
        case "anthropic":
            let model = UserDefaults.standard.string(forKey: UserScope.scopedKey("anthropic_model")) ?? "claude-3-5-sonnet-20241022"
            return ("anthropic", model)
        case "google", "gemini":
            let model = UserDefaults.standard.string(forKey: UserScope.scopedKey("gemini_model")) ?? "gemini-1.5-pro"
            return ("google", model)
        case "mlx":
            let model = UserDefaults.standard.string(forKey: "MLXModelManager.activeModelID") ?? "mlx-community/Qwen3-4B-4bit"
            return ("mlx", model)
        case "ollama":
            let model = UserDefaults.standard.string(forKey: UserScope.scopedKey("ollama_model")) ?? "llama3.2"
            return ("ollama", model)
        default:
            let model = UserDefaults.standard.string(forKey: UserScope.scopedKey("openai_model")) ?? "gpt-4o"
            return ("openai", model)
        }
    }

    /// Human-readable label for a provider string.
    private func providerLabel(for provider: String) -> String {
        switch provider {
        case "anthropic": "Anthropic"
        case "google": "Google Gemini"
        default: "OpenAI"
        }
    }

    /// Fetch the current Strix system prompt, if any, from local settings.
    /// Errors are treated as "no system prompt" so chat continues gracefully.
    private func currentSystemPrompt() async -> String? {
        do {
            let role = try await StrixSettingsService.shared.loadPersonalStrix()
            return role.systemPrompt
        } catch {
            AppErrorReporter.log(error: error, context: "ChatService.currentSystemPrompt.loadPersonalStrix")
            return nil
        }
    }
}

// MARK: - LocalChatError analytics helpers

private extension LocalChatError {
    /// Stable, low-cardinality error code for analytics.
    var analyticsCode: String {
        switch self {
        case .missingOpenAIAPIKey:
            "missing_openai_api_key"
        case .invalidResponse:
            "invalid_response"
        }
    }
}

// MARK: - Tool-calling helpers for chat

/// Lightweight tool-call envelope used in the chat path. This mirrors the
/// JSON protocol used by AgentRunner so models can reuse the same patterns.
///
/// NOTE: Some models emit `input` as a string ("query"), others as an object
/// (e.g., `{}` or `{ "query": "..." }`). We decode it as `AnyJSONValue` and
/// normalize to a string inside `executeChatToolCall` so that both shapes are
/// supported.
struct ChatToolInvocation: Codable {
    let tool: String
    let input: AnyJSONValue?
    let reason: String?

    static func from(jsonString: String) -> ChatToolInvocation? {
        var trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip <think>...</think> blocks emitted by reasoning models (e.g. Qwen3).
        // These appear before the tool-call JSON and prevent parsing.
        trimmed = trimmed.replacingOccurrences(
            of: "<think>[\\s\\S]*?</think>",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        // Also handle unclosed <think> tags (model started thinking but response was cut off).
        if let thinkStart = trimmed.range(of: "<think>") {
            trimmed = String(trimmed[..<thinkStart.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip markdown code fences that local models often wrap tool calls in.
        // Handles ```json, ```JSON, and bare ``` markers.
        if let fenceStart = trimmed.range(of: "```", options: .literal) {
            // Remove opening fence line (```json\n or ```\n)
            let afterFence = trimmed[fenceStart.upperBound...]
            if let newlineIdx = afterFence.firstIndex(of: "\n") {
                let afterOpening = String(afterFence[afterFence.index(after: newlineIdx)...])
                // Remove closing fence
                if let closingFence = afterOpening.range(of: "```", options: .backwards) {
                    trimmed = String(afterOpening[..<closingFence.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    trimmed = afterOpening.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        let decoder = JSONDecoder()

        // Fast path: whole string is a JSON object.
        if trimmed.first == "{",
           let data = trimmed.data(using: .utf8),
           let call = try? decoder.decode(ChatToolInvocation.self, from: data) {
            return call
        }

        // Fallback 1: many models (especially Gemini) emit reasoning text
        // followed by a JSON object that starts with {"tool": ...}. Try to
        // locate a balanced {...} region beginning at that marker.
        if let markerRange = trimmed.range(of: "{\"tool\"") {
            if let call = extractAndDecodeJSON(from: trimmed, startingAt: markerRange.lowerBound, using: decoder) {
                return call
            }
        }

        // Fallback 2: older formats may still have a JSON object at the end;
        // attempt to parse the last {...} block in the string.
        if let start = trimmed.lastIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}"),
           start < end {
            let range = start ... end
            let jsonSub = String(trimmed[range])
            if let data = jsonSub.data(using: .utf8),
               let call = try? decoder.decode(ChatToolInvocation.self, from: data) {
                return call
            }
        }

        return nil
    }

    /// Helper used by `from(jsonString:)` to slice out a balanced JSON object
    /// starting at a given index and decode it into `ChatToolInvocation`.
    private static func extractAndDecodeJSON(
        from text: String,
        startingAt startIndex: String.Index,
        using decoder: JSONDecoder
    ) -> ChatToolInvocation? {
        var depth = 0
        var endIndex: String.Index?
        var idx = startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    endIndex = idx
                    break
                }
            }
            text.formIndex(after: &idx)
        }
        guard let end = endIndex else { return nil }
        let jsonSub = String(text[startIndex ... end])
        if let data = jsonSub.data(using: .utf8),
           let call = try? decoder.decode(ChatToolInvocation.self, from: data) {
            return call
        }

        // Best-effort fallback: some models may use single quotes instead of
        // double quotes. Replace them and retry, accepting that this is not
        // perfect but dramatically improves robustness.
        let normalized = jsonSub.replacingOccurrences(of: "'", with: "\"")
        if let data = normalized.data(using: .utf8),
           let call = try? decoder.decode(ChatToolInvocation.self, from: data) {
            return call
        }
        return nil
    }

    // MARK: - Hallucinated Tool Name Remapping

    /// Common tool name hallucinations from local models mapped to actual tool names.
    private static let toolNameRemapping: [String: String] = [
        // Code execution → shell.execute
        "python": "shell.execute",
        "python3": "shell.execute",
        "code": "shell.execute",
        "run": "shell.execute",
        "execute": "shell.execute",
        "exec": "shell.execute",
        "bash": "shell.execute",
        "terminal": "shell.execute",
        "cmd": "shell.execute",
        "run_code": "shell.execute",
        "code_runner": "shell.execute",
        // Search → web_search
        "search": "web_search",
        "google": "web_search",
        "google_search": "web_search",
        "internet_search": "web_search",
        // File operations → file.*
        "read": "file.read",
        "read_file": "file.read",
        "readFile": "file.read",
        "cat": "file.read",
        "open": "file.read",
        "open_file": "file.read",
        "write": "file.write",
        "write_file": "file.write",
        "writeFile": "file.write",
        "save": "file.write",
        "save_file": "file.write",
        "list": "file.list",
        "list_files": "file.list",
        "listFiles": "file.list",
        "ls": "file.list",
        "dir": "file.list",
        // Time
        "time": "current_time",
        "get_time": "current_time",
        "datetime": "current_time",
    ]

    /// Returns a new invocation with corrected tool name and remapped input keys
    /// if the model hallucinated a tool name.
    func remapped() -> ChatToolInvocation {
        guard let actualTool = Self.toolNameRemapping[tool] else { return self }

        #if DEBUG
        AppErrorReporter.log(
            message: "Remapped hallucinated tool '\(tool)' → '\(actualTool)'",
            context: "ChatToolInvocation.remapped"
        )
        #endif

        // Remap input keys based on the target tool
        var remappedInput = input
        if actualTool == "shell.execute", let inputVal = input {
            // Model may send "code" key instead of "command"
            if case var .dictionary(dict) = inputVal {
                if let code = dict["code"], dict["command"] == nil {
                    // Wrap code in python3 -c if it came from a "python" tool call
                    if tool == "python" || tool == "python3" {
                        if case let .string(codeStr) = code {
                            dict["command"] = .string("python3 -c '\(codeStr.replacingOccurrences(of: "'", with: "'\\''"))'")
                        } else {
                            dict["command"] = code
                        }
                    } else {
                        dict["command"] = code
                    }
                    dict.removeValue(forKey: "code")
                    remappedInput = .dictionary(dict)
                }
            }
        } else if actualTool == "file.read", let inputVal = input {
            // Model may send "file" or "filename" instead of "path"
            if case var .dictionary(dict) = inputVal {
                let fileKey = dict["file"] ?? dict["filename"] ?? dict["file_path"]
                if let fk = fileKey, dict["path"] == nil {
                    dict["path"] = fk
                    dict.removeValue(forKey: "file")
                    dict.removeValue(forKey: "filename")
                    dict.removeValue(forKey: "file_path")
                    remappedInput = .dictionary(dict)
                }
            }
        }

        return ChatToolInvocation(tool: actualTool, input: remappedInput, reason: reason)
    }
}

extension ChatService {
    /// Generate tool instructions using PromptTemplates for the chat context.
    /// This replaces the hardcoded chatToolInstruction with dynamic tool documentation.
    static func generateChatToolInstruction(enabledTools: Set<String>) -> String {
        // Generate a concise version for chat (full docs are in system prompt)
        """
        You are the user's personal assistant. You can optionally call tools to
        help answer their question when your built-in knowledge or the local
        context sandwich is not enough.

        Before calling a tool, first think about whether you can answer directly
        using your own reasoning and the provided context. Only call a tool when
        you genuinely need fresh external information.

        \(PromptTemplates.toolProtocolInstructions)
        """
    }

    /// Legacy static instruction for backward compatibility.
    static let chatToolInstruction: String = generateChatToolInstruction(enabledTools: PromptTemplates.allTools)

    /// Resolve the maximum number of tool steps to allow in a single chat
    /// turn. This is configurable via UserDefaults under the key
    /// "chat_max_tool_steps"; values <= 0 fall back to a sane default.
    static func currentMaxToolSteps() -> Int {
        let stored = UserDefaults.standard.integer(forKey: UserScope.scopedKey("chat_max_tool_steps"))
        // Default to 5 tool steps for chat (conservative to prevent thrash);
        // users can raise this in Strix / agent role settings. Hard cap at 15.
        if stored <= 0 { return 5 }
        return min(stored, 15)
    }

    /// Execute a chat tool call using ToolExecutionService and return a short summary
    /// plus an optional context block that can be fed back into the context sandwich.
    /// This enhanced version routes through the central ToolExecutionService for all tools.
    nonisolated func executeChatToolCall(_ call: ChatToolInvocation) async throws -> (summary: String, contextBlock: String?) {
        // Convert ChatToolInvocation to ParsedToolCall for ToolExecutionService
        var args: [String: AnyJSONValue] = [:]
        if let input = call.input {
            // Input can be a string or dict
            if let dict = input.value as? [String: AnyJSONValue] {
                args = dict
            } else if let dict = input.value as? [String: Any] {
                for (key, value) in dict {
                    args[key] = AnyJSONValue(value)
                }
            } else if let str = input.value as? String {
                // For web_search, put string in "query" key
                args["query"] = AnyJSONValue(str)
                args["input"] = AnyJSONValue(str)
            }
        }

        let parsedCall = ParsedToolCall(
            name: call.tool,
            args: args,
            reason: call.reason
        )

        // Execute via ToolExecutionService
        let result = await ToolExecutionService.shared.execute(
            toolCall: parsedCall,
            agentType: "chat", // Chat context uses "chat" agent type
            threadID: nil
        )

        // Convert ToolExecutionResult to summary/contextBlock format.
        // Summaries are user-facing so use friendly descriptions.
        if result.status == "ok" {
            let summary = Self.friendlyToolSummary(for: call.tool)
            return (summary, result.contextBlock)
        } else if result.status == "denied" {
            let message = result.error ?? "Permission denied"
            let summary = "⚠️ \(Self.friendlyToolName(call.tool)): permission denied"
            return (summary, "[Tool Permission Denied: \(result.tool)]\n\(message)")
        } else {
            // Error or validation error
            let message = result.error ?? "Unknown error"
            let summary = "⚠️ \(Self.friendlyToolName(call.tool)): error"
            return (summary, "[Tool Error: \(result.tool)]\n\(message)")
        }
    }

    /// Execute a parsed tool call directly (used by enhanced streamMessage).
    /// Returns a ToolExecutionResult for more detailed handling.
    nonisolated func executeParsedToolCall(_ call: ParsedToolCall, threadID: String?) async -> ToolExecutionResult {
        await ToolExecutionService.shared.execute(
            toolCall: call,
            agentType: "chat",
            threadID: threadID
        )
    }

    /// Normalize a tool `input` field (which may be a string or an object) into
    /// a best-effort string representation for tools like `web_search`.
    nonisolated func extractToolInputString(from value: AnyJSONValue?) -> String? {
        guard let value else { return nil }
        let raw = value.value
        if let s = raw as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let dict = raw as? [String: AnyJSONValue] {
            // Common patterns: { "query": "..." } or { "q": "..." }
            if let q = dict["query"]?.value as? String ?? dict["q"]?.value as? String {
                let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        return nil
    }

    /// Heuristic: if the user asked about weather and the model replied that it
    /// cannot provide current weather without actually calling tools, synthesize
    /// a web_search query so we can still show search results.
    nonisolated func maybeForceSearchQuery(userMessage: String, modelReply: String) -> String? {
        let lowerUser = userMessage.lowercased()
        let lowerReply = modelReply.lowercased()
        guard lowerUser.contains("weather") else { return nil }
        let refusalSnippets = [
            "cannot tell you the current weather",
            "cannot provide the current weather",
            "do not have access to real-time weather",
            "don\'t have access to real-time weather",
            "do not have access to real time weather",
            "don\'t have access to real time weather",
            "cannot access real-time weather",
            "cannot access real time weather"
        ]
        guard refusalSnippets.contains(where: { lowerReply.contains($0) }) else {
            return nil
        }
        // Try to extract a simple "weather in X" style query; if we can't,
        // fall back to the full user message.
        if let range = lowerUser.range(of: "weather in ") {
            let cityPart = userMessage[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !cityPart.isEmpty {
                return "weather in \(cityPart)"
            }
        }
        return userMessage
    }

    // MARK: - Tool Normalization & Friendly Names

    /// Normalize a tool-input string for deduplication signatures.
    /// Lowercases, collapses whitespace, and trims punctuation so the model
    /// can't bypass deduplication with trivial formatting changes.
    nonisolated static func normalizeForDedupe(_ raw: String) -> String {
        raw.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters)
    }

    /// Human-readable name for a tool identifier, used in user-facing summaries.
    nonisolated static func friendlyToolName(_ tool: String) -> String {
        switch tool.lowercased() {
        case "web_search": "Web Search"
        case "web_browse": "Web Browse"
        case "current_time": "Current Time"
        case "file.read": "File Read"
        case "file.write": "File Write"
        case "file.list": "File List"
        case "shell.execute": "Shell Command"
        case _ where tool.hasPrefix("github."): "GitHub"
        case _ where tool.hasPrefix("google_drive"): "Google Drive"
        case _ where tool.hasPrefix("google_sheets"): "Google Sheets"
        default: tool
        }
    }

    /// User-facing activity string emitted via `onToolEvent` while a tool runs.
    nonisolated static func friendlyToolSummary(for tool: String) -> String {
        switch tool.lowercased() {
        case "web_search": "🔍 Searching the web…"
        case "web_browse": "🌐 Reading webpage…"
        case "current_time": "🕐 Checking current time…"
        case "file.read": "📄 Reading file…"
        case "file.write": "✍️ Writing file…"
        case "file.list": "📂 Listing files…"
        case "shell.execute": "💻 Running command…"
        case _ where tool.hasPrefix("github."): "🐙 Working with GitHub…"
        case _ where tool.hasPrefix("google_drive"): "📁 Accessing Google Drive…"
        case _ where tool.hasPrefix("google_sheets"): "📊 Working with Sheets…"
        default: "⚙️ Using \(tool)…"
        }
    }

    // MARK: - Context Hash (ported from backend _compute_context_hash)

    /// Compute a short hash of the accumulated tool context so we can detect
    /// whether anything meaningfully changed between consecutive identical
    /// tool calls.
    ///
    /// The backend hashes the last 5 messages; here we hash `toolContextLog`
    /// which serves the same role (accumulated tool results within a turn).
    nonisolated static func computeContextHash(_ context: String) -> String {
        // Use a simple hash of the last ~500 chars for efficiency.
        let tail = context.isEmpty ? "" : String(context.suffix(500))
        var hasher = Hasher()
        hasher.combine(tail)
        let hash = hasher.finalize()
        return String(format: "%08x", abs(hash))
    }

    // MARK: - Response Text Deduplication (ported from backend _dedupe_response_text)

    /// Remove duplicate paragraphs from an LLM response.
    ///
    /// Models sometimes repeat entire paragraphs, especially after
    /// multi-step tool loops. This splits on double newlines, dedupes by
    /// normalised content, and rejoins.
    nonisolated static func dedupeResponseText(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        let chunks = text.components(separatedBy: "\n\n")
        var seen = Set<String>()
        var deduped: [String] = []

        for chunk in chunks {
            let normalized = chunk.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { continue }
            if !seen.contains(normalized) {
                seen.insert(normalized)
                deduped.append(chunk)
            }
        }

        return deduped.joined(separator: "\n\n")
    }

    // MARK: - Premature Stop Detection (ported from backend _detect_premature_stop)

    /// Returns `true` if the model's response looks like it planned to
    /// continue but forgot to call a tool — e.g. "I'll now search for…"
    /// without an actual `<TOOL_CALL>` block.
    ///
    /// Only triggers when we still have step budget (`stepCount < maxSteps - 1`)
    /// and the response isn't a clear final answer.
    nonisolated static func detectPrematureStop(
        _ responseText: String,
        stepCount: Int,
        maxSteps: Int
    ) -> Bool {
        guard !responseText.isEmpty else { return false }
        // Don't continue if near the step limit.
        guard stepCount < maxSteps - 1 else { return false }

        let lower = responseText.lowercased()

        // If it looks like a clear final answer, don't nudge.
        let finalMarkers = [
            "in summary", "to summarize", "in conclusion",
            "based on my analysis", "based on my review",
            "i have completed", "task is complete", "task complete",
            "here's what i found", "here is what i found",
            "unfortunately, i couldn't", "i wasn't able to",
            "i couldn't find",
        ]
        for marker in finalMarkers where lower.contains(marker) {
            return false
        }

        // Check for continuation phrases that suggest the model intended
        // to keep going.
        let continuationMarkers = [
            "i'll now", "i will now",
            "next, i'll", "next i'll",
            "next, i will", "next i will",
            "let me now", "now i'll", "now i will",
            "the next step", "my next step",
            "proceeding to",
            "i need to also", "i should also",
        ]
        for marker in continuationMarkers where lower.contains(marker) {
            return true
        }

        return false
    }

    // MARK: - Malformed Tool Output Detection (ported from backend _detect_malformed_tool_output)

    /// Returns `true` if the response contains apparent tool-call markup
    /// that couldn't be parsed — indicating the model mangled the format.
    nonisolated static func detectMalformedToolOutput(_ responseText: String) -> Bool {
        guard !responseText.isEmpty else { return false }

        let lower = responseText.lowercased()

        let toolMarkerCount = lower.components(separatedBy: "<tool_call>").count - 1
            + lower.components(separatedBy: "[tool_call").count - 1
            + lower.components(separatedBy: "functions.").count - 1

        // Many markers but nothing parsed → malformed.
        if toolMarkerCount >= 2, !responseText.contains("{") {
            return true
        }

        // Unclosed TOOL_CALL tags.
        let openCount = lower.components(separatedBy: "<tool_call>").count - 1
        let closeCount = lower.components(separatedBy: "</tool_call>").count - 1
        if openCount > 0, closeCount == 0 {
            return true
        }

        // Multiple markers with no JSON objects at all.
        if lower.contains("<tool_call>"), toolMarkerCount >= 3, !responseText.contains("{") {
            return true
        }

        return false
    }

    /// Strip broken tool-call markup from a response, leaving only the prose.
    nonisolated static func stripToolMarkup(_ text: String) -> String {
        var result = text
        // Remove <TOOL_CALL>…</TOOL_CALL> blocks (case-insensitive).
        while let openRange = result.range(of: "<tool_call>", options: .caseInsensitive),
              let closeRange = result.range(of: "</tool_call>", options: .caseInsensitive),
              openRange.lowerBound < closeRange.upperBound {
            result.removeSubrange(openRange.lowerBound ..< closeRange.upperBound)
        }
        // Remove any remaining unclosed <TOOL_CALL> tags.
        result = result.replacingOccurrences(of: "<tool_call>", with: "", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "</tool_call>", with: "", options: .caseInsensitive)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Chat response from AI
struct ChatResponse: Codable {
    let messageId: String
    let content: String
    let role: String
    let provider: String
    let model: String?
    let tokenUsage: TokenUsage?
    let memoryProposals: [ChatMemoryProposal]
    let thoughts: [String]?
    let toolCalls: [ChatToolCall]?
    let metadata: [String: AnyJSONValue]

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case content, role, provider, model
        case tokenUsage = "token_usage"
        case memoryProposals = "memory_proposals"
        case thoughts
        case toolCalls = "tool_calls"
        case metadata
    }
}

/// Memory proposal from AI in chat responses (different from MemoryProposal in MemoryService)
struct ChatMemoryProposal: Codable {
    let content: String
    let scope: String
    let category: String?
}

/// Tool call from AI in chat responses
struct ChatToolCall: Codable {
    let name: String
    let args: [String: AnyJSONValue]
    let result: AnyJSONValue? // Changed from String? to handle dict/any type
    let error: String?
    let status: String?
}
