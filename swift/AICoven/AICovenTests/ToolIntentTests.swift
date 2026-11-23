@testable import AICoven
import XCTest

/// Whether a turn is offered tools at all, read from its words: what is
/// asked of the place's tasks and assets, a message that names a tool, and
/// a turn the app words itself keep their tools.
@MainActor
final class ToolIntentTests: XCTestCase {
    private func usesTools(_ message: String) -> Bool {
        if case .useTools = ToolIntentDecision.heuristic(for: message) { return true }
        return false
    }

    private func refusesTools(_ message: String) -> Bool {
        if case .noTools = ToolIntentDecision.heuristic(for: message) { return true }
        return false
    }

    func testWhatIsAskedOfThePlacesTasksAndAssetsKeepsItsTools_whateverElseItSays() {
        for message in [
            "Add a task to draft the brief", "Remind me to summarize the notes tomorrow", "remember to explain the plan to Sam",
            "Save this draft as an asset", "Compare the two mockups in Assets", "Hi, what's on my to-do list?", "Rewrite my TODO for Friday",
            "Mark the translate task done, thanks",
        ] {
            XCTAssertTrue(usesTools(message), message)
        }
        // A message that names a tool asks for tools.
        XCTAssertTrue(usesTools("Explain what web_search found"))
        XCTAssertTrue(usesTools("Use asset.get to read it, then draft a summary."))
        // Conversation is still read as conversation.
        for message in ["Explain how photosynthesis works", "Draft an email to Sam", "Summarize what we said", "hello there", "Thanks!"] {
            XCTAssertTrue(refusesTools(message), message)
        }
        // And what plainly asks for a tool still does.
        XCTAssertTrue(usesTools("search for the launch date"))
    }

    /// A model that answers with a script and keeps what it was asked.
    /// Sendable by hand: what changes is read and written under its lock.
    private final class Scripted: LLMClient, @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String]
        private var heard: [String] = []

        init(_ answers: [String]) {
            self.answers = answers
        }

        var asked: [String] {
            lock.withLock { heard }
        }

        func completeChat(messages: [LLMMessage], model: String, options _: ChatOptions) async throws -> LLMChatResponse {
            let answer = lock.withLock { () -> String in
                heard.append(messages.map(\.content).joined(separator: "\n"))
                return answers.isEmpty ? "Done." : answers.removeFirst()
            }
            return LLMChatResponse(message: LLMMessage(role: .assistant, content: answer), providerID: "test", modelID: model, usage: nil)
        }

        func embed(texts: [String], model _: String) async throws -> [[Float]] {
            Array(repeating: [0, 1], count: texts.count)
        }
    }

    /// Runs a turn with `message`, whose model first calls a tool, and
    /// answers with the model.
    private func turn(_ message: String, offersToolsWhateverItSays: Bool) async throws -> Scripted {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        await ThreadService.shared.reloadForCurrentUser()
        addTeardownBlock { await DataEncryptionService.shared.lock() }
        await ToolExecutionService.shared.forgetCalls()
        let thread = try await ThreadService.shared.createThread(title: "Its tools \(UUID().uuidString)")
        addTeardownBlock { try? await ThreadService.shared.deleteThread(threadId: thread.id) }
        let call = #"{"tool":"task.list","input":{"query":"no such task \#(UUID().uuidString)"},"reason":"look"}"#
        let model = Scripted([call, "Nothing there."])
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
        try await chat.streamMessage(
            threadId: thread.id, message: message, offersToolsWhateverItSays: offersToolsWhateverItSays, onStateChange: { _ in }
        )
        return model
    }

    func testATurnTheAppWordsItselfIsOfferedItsTools_whateverATitleInItSays() async throws {
        // The words Tasks sends for a task handed to an agent, with a title that reads as conversation.
        let handedOver = "Please do this for me: Draft the Q3 report and explain the numbers"
        XCTAssertTrue(refusesTools(handedOver), "Read by its words alone, it would be given no tools")
        var model = try await turn(handedOver, offersToolsWhateverItSays: true)
        XCTAssertTrue(model.asked.last?.contains("[Tasks] None found.") == true, "Its tool ran")
        // The same words typed by the person are read as before.
        model = try await turn(handedOver, offersToolsWhateverItSays: false)
        XCTAssertFalse(model.asked.contains { $0.contains("[Tasks] None found.") })
    }
}
