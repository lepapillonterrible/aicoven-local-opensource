import Foundation

/// Minimal agent profile – can be extended later with tool whitelists
/// and more detailed configuration.
struct AgentProfile {
    let type: String
    let displayName: String
    let description: String
}

/// Executes autonomous agent runs with a user-defined maximum number of steps.
actor AgentRunner {
    /// Shared singleton configured with built-in providers (OpenAI, Anthropic, Gemini),
    /// filtered to those that actually have API keys configured.
    static let shared: AgentRunner = {
        let toolEnv = ToolEnvironment.make()
        return AgentRunner(
            agentRunRepository: .shared,
            threadRepository: .shared,
            contextBuilder: ContextBuilder(),
            modelRouter: HeuristicModelRouter(availableModels: toolEnv.models),
            llmClients: toolEnv.clients,
            toolExecutionService: .shared
        )
    }()

    private let agentRunRepository: AgentRunRepository
    private let threadRepository: ThreadRepository
    private let contextBuilder: ContextBuilder
    private let modelRouter: ModelRouter
    private let llmClients: [String: LLMClient] // keyed by providerID
    private let toolExecutionService: ToolExecutionService

    init(
        agentRunRepository: AgentRunRepository,
        threadRepository: ThreadRepository,
        contextBuilder: ContextBuilder,
        modelRouter: ModelRouter,
        llmClients: [String: LLMClient],
        toolExecutionService: ToolExecutionService = .shared
    ) {
        self.agentRunRepository = agentRunRepository
        self.threadRepository = threadRepository
        self.contextBuilder = contextBuilder
        self.modelRouter = modelRouter
        self.llmClients = llmClients
        self.toolExecutionService = toolExecutionService
    }

    /// Starts and executes an agent run.
    /// - Parameters:
    ///   - profile: Agent configuration.
    ///   - threadID: Optional existing thread to work within.
    ///   - maxSteps: User-defined hard cap on steps.
    ///   - userMessage: The initial user instruction or goal.
    func run(
        profile: AgentProfile,
        threadID: String?,
        maxSteps: Int,
        userMessage: String
    ) async {
        guard maxSteps > 0 else { return }

        // Configure available tools validation for this agent type
        // For now, we allow all tools, but this is where we'd set the whitelist
        // await toolExecutionService.setWhitelist(for: profile.type, tools: ["web_search", "current_time", "file.read"])

        let agentGoal = userMessage
        let agentInstruction = """
        You are an autonomous local-first agent running entirely on the user's device.

        You have access to tools. Use them to gather information or perform actions.

        TOOL PROTOCOL:
        - To use tools, output a specific XML block:
          <TOOL_CALL>
          tool_name
          {"arg": "value"}
          </TOOL_CALL>
        - You can also use JSON format: {"tool": "name", "args": {...}}
        - You can use <thought>...</thought> blocks to reason before acting.
        - You can use <scratchpad>...</scratchpad> to track tasks.

        User goal: \(agentGoal)
        """

        var toolContextLog = ""
        var stepHistory: [String] = [] // Track tool signatures for loop detection

        do {
            let run = try await agentRunRepository.createRun(
                threadID: threadID,
                agentType: profile.type,
                maxSteps: maxSteps
            )

            var currentThreadID = threadID
            if currentThreadID == nil {
                let thread = try await threadRepository.createThread(title: profile.displayName)
                currentThreadID = thread.id
            }

            // Main loop
            for stepIndex in 0 ..< maxSteps {
                guard let tID = currentThreadID else { break }

                // Route to model
                let routingContext = RoutingContext(
                    task: .agentStep,
                    requireLocalOnly: false,
                    requireLongContext: false,
                    preferHighQuality: true
                )
                guard let modelDescriptor = modelRouter.route(for: routingContext),
                      let client = llmClients[modelDescriptor.providerID] else {
                    try await agentRunRepository.updateStatus(runID: run.id, status: "error")
                    return
                }

                // Build message
                let effectiveUserMessage: String = if toolContextLog.isEmpty {
                    agentInstruction
                } else {
                    agentInstruction + "\n\n" + toolContextLog
                }

                // Build context
                let promptBudget = Int(Double(modelDescriptor.maxContextTokens) * 0.8)
                let contextMessages = try await contextBuilder.buildContext(
                    threadID: tID,
                    userMessage: effectiveUserMessage,
                    maxContextTokens: promptBudget
                )

                let options = ChatOptions(temperature: 0.2, maxTokens: nil, stream: false)
                let response = try await client.completeChat(
                    messages: contextMessages,
                    model: modelDescriptor.modelID,
                    options: options
                )

                let outputText = response.message.content.trimmingCharacters(in: .whitespacesAndNewlines)

                // Parse output
                let parsed = ToolCallParser.parse(outputText)

                // If thought/scratchpad present, we might want to emit events (future)
                // For now, checks are done implicitly via parsing

                // Store step
                // We store the raw tool calls JSON if any exist
                let toolCallsJSON = parsed.toolCalls.isEmpty ? nil : encodeToolCalls(parsed.toolCalls)

                // Log which tools were called in this step
                let inputSummary = parsed.toolCalls.isEmpty
                    ? "Agent step #\(stepIndex + 1) NO TOOLS for goal: \(agentGoal)"
                    : "Agent step #\(stepIndex + 1) TOOLS: \(parsed.toolCalls.map(\.name).joined(separator: ", "))"

                _ = try await agentRunRepository.appendStep(
                    runID: run.id,
                    stepIndex: stepIndex,
                    input: inputSummary,
                    output: outputText,
                    toolCallsJSON: toolCallsJSON
                )

                if parsed.toolCalls.isEmpty {
                    // Final natural language answer
                    // Strip markup for final display
                    let finalAnswer = parsed.strippedText

                    _ = try await threadRepository.appendMessage(toThreadID: tID, role: "assistant", content: finalAnswer)
                    try await agentRunRepository.updateStatus(runID: run.id, status: "completed")
                    return
                }

                // Execute tools
                for toolCall in parsed.toolCalls {
                    // Loop detection - prevent the model from calling the same tool with identical args repeatedly
                    // Use canonical JSON encoding with sorted keys for stable signature comparison
                    let signature = canonicalToolSignature(name: toolCall.name, args: toolCall.args)
                    let loopCount = stepHistory.count(where: { $0 == signature })
                    if loopCount >= 3 {
                        // Create error result and use its info in the context log
                        let errorResult = ToolExecutionResult.error(
                            tool: toolCall.name,
                            message: "Loop detected: You have called this tool with these exact arguments 3 times. Stop and try a different approach.",
                            errorType: "loop_detected"
                        )
                        // Use the error message from the result so the model can react appropriately
                        let block = "[Tool Error: \(errorResult.tool)]\n\(errorResult.error ?? "Loop detected")"
                        if toolContextLog.isEmpty { toolContextLog = block } else { toolContextLog += "\n\n" + block }
                        continue
                    }
                    stepHistory.append(signature)

                    // Execute via Service
                    let result = await toolExecutionService.execute(toolCall: toolCall, agentType: profile.type, threadID: tID)

                    // Accumulate context
                    if let block = result.contextBlock {
                        if toolContextLog.isEmpty {
                            toolContextLog = block
                        } else {
                            toolContextLog += "\n\n" + block
                        }
                    }
                }
            }

            try await agentRunRepository.updateStatus(runID: run.id, status: "completed")
        } catch {
            AppErrorReporter.log(error: error, context: "AgentRunner.run")
        }
    }

    private func encodeToolCalls(_ calls: [ParsedToolCall]) -> String? {
        guard let data = try? JSONEncoder().encode(calls) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Generate a canonical signature for a tool call that is stable regardless of dictionary key order.
    /// This ensures loop detection works correctly even when args dictionaries have the same content
    /// but different internal ordering.
    private func canonicalToolSignature(name: String, args: [String: AnyJSONValue]) -> String {
        // Sort keys alphabetically and build a deterministic string representation
        let sortedKeys = args.keys.sorted()
        let canonicalArgs = sortedKeys.map { key -> String in
            let value = args[key]?.value
            // Convert value to a stable string representation
            let valueString: String = if let str = value as? String {
                "\"\(str)\""
            } else if let num = value as? NSNumber {
                num.stringValue
            } else if let bool = value as? Bool {
                bool ? "true" : "false"
            } else if value == nil || value is NSNull {
                "null"
            } else {
                // Fallback: use description but this should be rare
                String(describing: value ?? "null")
            }
            return "\(key):\(valueString)"
        }.joined(separator: ",")

        return "\(name):{\(canonicalArgs)}"
    }
}
