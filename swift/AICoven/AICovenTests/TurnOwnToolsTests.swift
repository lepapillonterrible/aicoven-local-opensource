@testable import AICoven
import XCTest

/// A turn may call the tools it was itself offered, and no others:
/// nothing kept for chat turns as a kind decides it, since two turns
/// running at once are offered different tools.
@MainActor
final class TurnOwnToolsTests: XCTestCase {
    override func tearDown() async throws {
        await ToolExecutionService.shared.setWhitelist(for: "chat", tools: [])
        try await super.tearDown()
    }

    private func call(_ name: String, _ args: [String: Any] = [:]) -> ParsedToolCall {
        ParsedToolCall(name: name, args: args.mapValues { AnyJSONValue($0) })
    }

    func testACallIsAllowedByWhatItsCallerWasOffered_whateverIsKeptForItsKind() async {
        let executor = ToolExecutionService.shared
        await executor.forgetCalls()
        // Kept for chat turns (by another caller), and not offered to this one: refused.
        await executor.setWhitelist(for: "chat", tools: ["task.list"])
        var result = await executor.execute(toolCall: call("task.list"), agentType: "chat", allowed: [], threadID: nil)
        XCTAssertEqual(result.status, "denied")
        XCTAssertEqual(result.errorType, "permission_denied")
        // Offered to this one, and not kept for chat turns: the call reaches the tool, which says what it lacks.
        await executor.setWhitelist(for: "chat", tools: [])
        result = await executor.execute(toolCall: call("task.list"), agentType: "chat", allowed: ["task.list"], threadID: nil)
        XCTAssertEqual(result.errorType, "task_needs_a_thread")
        // A caller that says nothing of what it was offered goes by what is kept for its kind.
        result = await executor.execute(toolCall: call("task.list"), agentType: "chat", threadID: nil)
        XCTAssertEqual(result.status, "denied")
        await executor.setWhitelist(for: "chat", tools: ["task.list"])
        result = await executor.execute(toolCall: call("task.list"), agentType: "chat", threadID: nil)
        XCTAssertEqual(result.errorType, "task_needs_a_thread")
        // A call by a name the tool had before is allowed as the tool is named now.
        result = await executor.execute(toolCall: call("github.getPR"), agentType: "chat", allowed: ["github.getPullRequest"], threadID: nil)
        XCTAssertNotEqual(result.errorType, "permission_denied")
        result = await executor.execute(toolCall: call("github.getPR"), agentType: "chat", allowed: ["github.getPR"], threadID: nil)
        XCTAssertEqual(result.errorType, "permission_denied", "The old name offers nothing")
    }

    /// A model that answers with a script and keeps what it was asked.
    /// Sendable by hand: what changes is read and written under its lock.
    private final class Scripted: LLMClient, @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String]
        private var heard: [String] = []
        /// What happens once the model has been asked for the first time,
        /// before it answers: the turn is under way by then.
        private let onceAsked: @Sendable () async -> Void

        init(_ answers: [String], onceAsked: @escaping @Sendable () async -> Void) {
            self.answers = answers
            self.onceAsked = onceAsked
        }

        var asked: [String] {
            lock.withLock { heard }
        }

        func completeChat(messages: [LLMMessage], model: String, options _: ChatOptions) async throws -> LLMChatResponse {
            let (answer, isFirst) = lock.withLock { () -> (String, Bool) in
                heard.append(messages.map(\.content).joined(separator: "\n"))
                return (answers.isEmpty ? "Done." : answers.removeFirst(), heard.count == 1)
            }
            if isFirst { await onceAsked() }
            return LLMChatResponse(message: LLMMessage(role: .assistant, content: answer), providerID: "test", modelID: model, usage: nil)
        }

        func embed(texts: [String], model _: String) async throws -> [[Float]] {
            Array(repeating: [0, 1], count: texts.count)
        }
    }

    /// Runs a turn whose model answers with `answers`. `keptMeanwhile` is
    /// what is kept for chat turns once the turn is under way (its model
    /// has been asked and has not answered), as another turn starting
    /// then once left it.
    private func turn(answering answers: [String], keptMeanwhile: Set<String>) async throws -> Scripted {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        await ThreadService.shared.reloadForCurrentUser()
        addTeardownBlock { await DataEncryptionService.shared.lock() }
        await ToolExecutionService.shared.forgetCalls()
        let thread = try await ThreadService.shared.createThread(title: "Its own tools \(UUID().uuidString)")
        addTeardownBlock { try? await ThreadService.shared.deleteThread(threadId: thread.id) }
        let model = Scripted(answers) { await ToolExecutionService.shared.setWhitelist(for: "chat", tools: keptMeanwhile) }
        let chat = ChatService(
            contextBuilder: ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4)),
            modelRouter: HeuristicModelRouter(availableModels: [ModelDescriptor(
                providerID: "openai", modelID: "model", maxContextTokens: 128_000,
                supportsTools: false, supportsEmbeddings: false, costClass: .cheap
            )]),
            llmClients: ["openai": model],
            threadStore: ThreadRepository.shared,
            toolService: ToolService.shared,
            shouldAutoRefreshEnvironment: false,
            hermesAgent: { nil },
            openClawTurn: { _ in nil }
        )
        try await chat.streamMessage(threadId: thread.id, message: "What is on my list?", onStateChange: { _ in })
        return model
    }

    func testATurnCallsWhatItWasOffered_thoughNothingIsKeptForChatTurns() async throws {
        // Another turn that is offered nothing starts while this one waits for its model.
        let call = #"{"tool":"task.list","input":{"query":"no such task \#(UUID().uuidString)"},"reason":"look"}"#
        let model = try await turn(answering: [call, "Nothing."], keptMeanwhile: [])
        XCTAssertTrue(model.asked.last?.contains("[Tasks] None found.") == true, "The tool ran: the turn was offered it")
        XCTAssertFalse(model.asked.last?.contains("Tool Permission Denied") == true)
    }

    func testATurnDoesNotCallWhatItWasNotOffered_thoughItIsKeptForChatTurns() async throws {
        // Another turn, offered a tool of a connection this turn has none of, starts while this one waits for its model.
        let notOffered = await ContextBuilder.ToolConfig.connected(deliversFiles: true, seesPictures: true, usesAssets: true)
        try XCTSkipIf(notOffered.enabledTools.contains("github.listRepos"), "This test home has GitHub connected")
        let model = try await turn(answering: [#"{"tool":"github.listRepos","input":{},"reason":"look"}"#, "Could not."], keptMeanwhile: ["github.listRepos"])
        XCTAssertTrue(model.asked.last?.contains("[Tool Permission Denied: github.listRepos]") == true, "Refused: this turn was not offered it")
    }
}
