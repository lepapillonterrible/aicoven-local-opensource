@testable import AICoven
internal import Combine
import GRDB
import XCTest

/// The turn engine: a reply runs and is stored without the screen that
/// started it, and every turn is recorded from start to outcome.
@MainActor
final class TurnEngineTests: XCTestCase {
    private var threadID = ""
    private let provider = ScriptedProvider()

    override func setUp() async throws {
        try await super.setUp()
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        await ThreadService.shared.reloadForCurrentUser()
        threadID = try await ThreadService.shared.createThread(title: "Turns \(UUID().uuidString)").id
    }

    override func tearDown() async throws {
        provider.release()
        try? await ThreadService.shared.deleteThread(threadId: threadID)
        await ThreadService.shared.reloadForCurrentUser()
        await DataEncryptionService.shared.lock()
        try await super.tearDown()
    }

    // MARK: - A turn from start to outcome

    func testATurn_storesTheQuestionRunsWithoutAScreenAndStoresTheReply() async throws {
        let engine = makeEngine()

        let question = try await engine.start(
            threadID: threadID, text: "What is the plan?", context: "What is the plan?", roleID: nil, agentName: "Strix", attachments: nil
        )
        XCTAssertEqual(engine.running[threadID]?.message, TurnProgress.startingMessage)
        let turn = try await storedTurn()
        XCTAssertEqual(turn?.status, "running")

        provider.release()
        await finished(engine)

        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(messages.first, question)
        XCTAssertEqual(messages.last?.content, "The plan is ready.")
        XCTAssertEqual(messages.last?.metadata?["role_name"], AnyJSONValue("Strix"))
        let ended = try await storedTurn()
        XCTAssertEqual(ended?.status, "completed")
        XCTAssertEqual(ended?.messageID, messages.last?.id)
        XCTAssertNil(engine.running[threadID])
    }

    func testATurn_thatFailsStoresWhatWentWrongAndIsRecordedAsFailed() async throws {
        provider.fail(with: "The provider is down")
        provider.release()
        let engine = makeEngine()

        _ = try await engine.start(threadID: threadID, text: "Hello", context: "Hello", roleID: nil, agentName: nil, attachments: nil)
        await finished(engine)

        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.map(\.role), ["user", "assistant"])
        XCTAssertTrue(messages.last?.content.contains("The provider is down") == true)
        let turn = try await storedTurn()
        XCTAssertEqual(turn?.status, "failed")
    }

    func testASecondSend_whileAReplyIsOnItsWayStartsNothing() async throws {
        let engine = makeEngine()
        _ = try await engine.start(threadID: threadID, text: "First", context: "First", roleID: nil, agentName: nil, attachments: nil)

        do {
            _ = try await engine.start(threadID: threadID, text: "Second", context: "Second", roleID: nil, agentName: nil, attachments: nil)
            XCTFail("A thread runs one turn at a time")
        } catch {
            XCTAssertTrue(error is TurnEngine.TurnError)
        }

        provider.release()
        await finished(engine)
        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.filter { $0.role == "user" }.map(\.content), ["First"])
    }

    // MARK: - A turn the app closed on

    func testOpeningAThread_endsATurnTheAppClosedOnAndSaysSoOnce() async throws {
        let engine = makeEngine()
        let question = TurnProgress.message(in: threadID, role: "user", content: "Left hanging")
        try await ThreadRepository.shared.beginTurn(id: "turn-\(threadID)", userMessage: question)

        await engine.settleInterruptedTurns(threadID: threadID)
        await engine.settleInterruptedTurns(threadID: threadID)

        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.map(\.content), ["Left hanging", TurnProgress.interruptedNotice])
        let turn = try await storedTurn()
        XCTAssertEqual(turn?.status, "interrupted")
    }

    func testOpeningAThread_leavesATurnThatIsRunningAlone() async throws {
        let engine = makeEngine()
        _ = try await engine.start(threadID: threadID, text: "Still going", context: "Still going", roleID: nil, agentName: nil, attachments: nil)

        await engine.settleInterruptedTurns(threadID: threadID)

        let turn = try await storedTurn()
        XCTAssertEqual(turn?.status, "running")
        provider.release()
        await finished(engine)
        let ended = try await storedTurn()
        XCTAssertEqual(ended?.status, "completed")
    }

    func testATurn_endsOnce() async throws {
        let question = TurnProgress.message(in: threadID, role: "user", content: "Question")
        try await ThreadRepository.shared.beginTurn(id: "turn-\(threadID)", userMessage: question)
        let reply = TurnProgress.message(in: threadID, role: "assistant", content: "Reply")
        let late = TurnProgress.message(in: threadID, role: "assistant", content: "Too late")

        try await ThreadRepository.shared.endTurn(id: "turn-\(threadID)", outcome: .completed, message: reply)
        try await ThreadRepository.shared.endTurn(id: "turn-\(threadID)", outcome: .interrupted, message: late)

        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.map(\.content), ["Question", "Reply"])
        let turn = try await storedTurn()
        XCTAssertEqual(turn?.status, "completed")
    }

    // MARK: - What a running turn shows

    func testProgress_saysWhatTheTurnIsDoingAndKeepsItsThoughtsForTheReply() {
        var progress = TurnProgress(agentName: nil)
        progress.note(TurnState(scratchpad: "Reading the question", phase: .planning))
        XCTAssertEqual(progress.activity, "Planning: Reading the question")

        let search = TurnToolCall(id: "1", name: "web.search", arguments: [:], result: nil, status: "running")
        progress.note(TurnState(toolsInProgress: ["1": search], phase: .tooling))
        XCTAssertEqual(progress.activity, "Using web.search to look up information on the web…")

        progress.note(TurnState(scratchpad: "Reading the results", phase: .planning))
        XCTAssertEqual(progress.activity, "Using tools and memory: Reading the results")

        progress.note(TurnState(answer: "Done.", status: .completed, phase: .finalizing))
        let ending = progress.ending(in: "t", thrown: nil)
        XCTAssertEqual(ending.outcome, .completed)
        XCTAssertEqual(ending.message.content, "Done.")
        XCTAssertEqual(ending.message.metadata?["thoughts"], AnyJSONValue(["Reading the question Reading the results"]))
    }

    func testProgress_endsAsFailedWhenTheServiceThrowsOrNeverFinishes() {
        var progress = TurnProgress(agentName: nil)
        progress.note(TurnState(scratchpad: "Thinking", phase: .planning))

        XCTAssertEqual(progress.ending(in: "t", thrown: nil).outcome, .failed)
        let thrown = progress.ending(in: "t", thrown: NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "No network"]))
        XCTAssertEqual(thrown.outcome, .failed)
        XCTAssertTrue(thrown.message.content.contains("No network"))
    }

    // MARK: - Helpers

    private func makeEngine() -> TurnEngine {
        let model = ModelDescriptor(
            providerID: "test-provider", modelID: "test-model", maxContextTokens: 4096,
            supportsTools: false, supportsEmbeddings: false, costClass: .cheap
        )
        return TurnEngine(chat: ChatService(
            contextBuilder: ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4)),
            modelRouter: HeuristicModelRouter(availableModels: [model]),
            llmClients: ["test-provider": provider],
            threadStore: ThreadRepository.shared,
            toolService: NoTools(),
            shouldAutoRefreshEnvironment: false
        ))
    }

    /// Waits until the engine has no turn running in the thread.
    private func finished(_ engine: TurnEngine) async {
        let done = expectation(description: "The turn ended")
        let watching = engine.$running.sink { [threadID] running in
            if running[threadID] == nil { done.fulfill() }
        }
        await fulfillment(of: [done], timeout: 10)
        watching.cancel()
    }

    private func storedTurn() async throws -> (status: String, messageID: String?)? {
        try await DatabaseManager.shared.dbQueue?.read { [threadID] db in
            try Row.fetchOne(db, sql: "SELECT status, message_id FROM turns WHERE thread_id = ?", arguments: [threadID])
                .map { ($0["status"], $0["message_id"]) }
        }
    }
}

/// A provider that answers when the test lets it, with a reply or an error.
private final class ScriptedProvider: LLMClient, @unchecked Sendable {
    // Read and written from the test and from the chat service's actor, so
    // every access takes the lock.
    private let lock = NSLock()
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var failure: String?

    func fail(with message: String) {
        lock.withLock { failure = message }
    }

    func release() {
        let resumed = lock.withLock {
            released = true
            defer { waiting = [] }
            return waiting
        }
        resumed.forEach { $0.resume() }
    }

    func completeChat(messages _: [LLMMessage], model: String, options _: ChatOptions) async throws -> LLMChatResponse {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if released { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        if let failure = lock.withLock({ failure }) {
            throw NSError(domain: "ScriptedProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: failure])
        }
        return LLMChatResponse(
            message: LLMMessage(role: .assistant, content: "The plan is ready."),
            providerID: "test-provider",
            modelID: model,
            usage: nil
        )
    }

    func embed(texts: [String], model _: String) async throws -> [[Float]] {
        Array(repeating: [0, 0, 0], count: texts.count)
    }
}

private actor NoTools: ChatToolService {
    func webSearch(query _: String, maxResults _: Int) async throws -> [ToolService.WebSearchResult] {
        []
    }

    func webBrowse(url: URL, maxLength _: Int) async throws -> ToolService.WebBrowseResult {
        throw URLError(.unsupportedURL, userInfo: [NSURLErrorFailingURLErrorKey: url])
    }

    nonisolated func currentTime(timezone: TimeZone) -> ToolService.TimeInfo {
        ToolService.shared.currentTime(timezone: timezone)
    }
}
