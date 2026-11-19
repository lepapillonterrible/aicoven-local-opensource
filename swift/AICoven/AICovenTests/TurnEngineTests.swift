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

        let question = question("What is the plan?")
        try await engine.start(with: question, context: "What is the plan?", roleID: nil, agentName: "Strix", attachments: nil)
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
        XCTAssertEqual(engine.endings[threadID]?.messages, [messages[1]])
        XCTAssertEqual(engine.endings[threadID]?.stored, true)
    }

    func testATurn_thatFailsStoresWhatWentWrongAndIsRecordedAsFailed() async throws {
        provider.fail(with: "The provider is down")
        provider.release()
        let engine = makeEngine()

        try await engine.start(with: question("Hello"), context: "Hello", roleID: nil, agentName: nil, attachments: nil)
        await finished(engine)

        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.map(\.role), ["user", "assistant"])
        XCTAssertTrue(messages.last?.content.contains("The provider is down") == true)
        let turn = try await storedTurn()
        XCTAssertEqual(turn?.status, "failed")
    }

    func testASecondSend_whileAReplyIsOnItsWayStartsNothing() async throws {
        let engine = makeEngine()
        try await engine.start(with: question("First"), context: "First", roleID: nil, agentName: nil, attachments: nil)

        do {
            try await engine.start(with: question("Second"), context: "Second", roleID: nil, agentName: nil, attachments: nil)
            XCTFail("A thread runs one turn at a time")
        } catch {
            XCTAssertTrue(error is TurnEngine.TurnError)
        }

        provider.release()
        await finished(engine)
        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.filter { $0.role == "user" }.map(\.content), ["First"])
    }

    func testAReplyThatCannotBeStored_isShownKeptAndStoredBeforeTheNextTurn() async throws {
        let engine = makeEngine()
        try await engine.start(with: question("First"), context: "First", roleID: nil, agentName: nil, attachments: nil)
        // Locked while the turn runs: however it ends, its ending cannot be
        // encrypted.
        await DataEncryptionService.shared.lock()
        provider.release()
        await finished(engine)

        let unsaved = try XCTUnwrap(engine.endings[threadID])
        XCTAssertFalse(unsaved.stored)
        XCTAssertEqual(unsaved.messages.count, 2)
        XCTAssertTrue(unsaved.messages[1].content.hasPrefix("AICoven couldn't save this reply yet"))

        // While it still cannot be stored, nothing new starts in the thread
        // and the ending is kept.
        do {
            try await engine.start(with: question("Too soon"), context: "Too soon", roleID: nil, agentName: nil, attachments: nil)
            XCTFail("A new turn must wait for the earlier ending to be stored")
        } catch {}
        XCTAssertEqual(engine.endings[threadID], unsaved)
        XCTAssertNil(engine.running[threadID])

        // Storable again: opening the thread keeps the turn, and the next
        // send stores the earlier ending ahead of the new question.
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        try await engine.start(with: question("Second"), context: "Second", roleID: nil, agentName: nil, attachments: nil)
        await finished(engine)

        // The first question was stored under the key before the lock, so
        // it is not among what the test key now reads.
        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0], unsaved.messages[0])
        XCTAssertEqual(messages[1].content, "Second")
        XCTAssertEqual(messages[2].content, "The plan is ready.")
        let statuses = try await DatabaseManager.shared.dbQueue?.read { [threadID] db in
            try String.fetchAll(db, sql: "SELECT status FROM turns WHERE thread_id = ? ORDER BY started_at", arguments: [threadID])
        }
        XCTAssertEqual(statuses?.contains("running"), false)
    }

    // MARK: - A turn the app closed on

    func testOpeningAThread_endsATurnTheAppClosedOnAndSaysSoOnce() async throws {
        let engine = makeEngine()
        try await ThreadRepository.shared.beginTurn(id: "turn-\(threadID)", userMessage: question("Left hanging"))

        await engine.settleInterruptedTurns(threadID: threadID)
        await engine.settleInterruptedTurns(threadID: threadID)

        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.map(\.content), ["Left hanging", TurnProgress.interruptedNotice])
        let turn = try await storedTurn()
        XCTAssertEqual(turn?.status, "interrupted")
    }

    func testOpeningAThread_leavesATurnThatIsRunningAlone() async throws {
        let engine = makeEngine()
        try await engine.start(with: question("Still going"), context: "Still going", roleID: nil, agentName: nil, attachments: nil)

        await engine.settleInterruptedTurns(threadID: threadID)

        let turn = try await storedTurn()
        XCTAssertEqual(turn?.status, "running")
        provider.release()
        await finished(engine)
        let ended = try await storedTurn()
        XCTAssertEqual(ended?.status, "completed")
    }

    func testATurn_endsOnce() async throws {
        try await ThreadRepository.shared.beginTurn(id: "turn-\(threadID)", userMessage: question("Question"))
        let reply = TurnProgress.message(in: threadID, role: "assistant", content: "Reply")
        let late = TurnProgress.message(in: threadID, role: "assistant", content: "Too late")

        let ended = try await ThreadRepository.shared.endTurn(id: "turn-\(threadID)", outcome: .completed, message: reply)
        let endedAgain = try await ThreadRepository.shared.endTurn(id: "turn-\(threadID)", outcome: .interrupted, message: late)
        XCTAssertTrue(ended)
        XCTAssertFalse(endedAgain)

        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.map(\.content), ["Question", "Reply"])
        let turn = try await storedTurn()
        XCTAssertEqual(turn?.status, "completed")
    }

    func testATurn_belongsToItsThreadsOwnerAndGoesWithItsThread() async throws {
        try await ThreadRepository.shared.beginTurn(id: "turn-\(threadID)", userMessage: question("Mine"))
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)

        // A turn for this thread under another user is refused.
        XCTAssertThrowsError(try queue.inDatabase { [threadID] db in
            try db.execute(
                sql: "INSERT INTO turns (id, user_id, thread_id, status, started_at) VALUES (?, ?, ?, ?, ?)",
                arguments: ["someone-elses-\(threadID)", "another-user", threadID, "running", Date()]
            )
        })

        try await ThreadService.shared.deleteThread(threadId: threadID)
        let left = try await queue.read { [threadID] db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM turns WHERE thread_id = ?", arguments: [threadID])
        }
        XCTAssertEqual(left, 0)
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

    func testProgress_endsAsFailedWhenTheServiceThrowsOrReportsAFailure() {
        var progress = TurnProgress(agentName: nil)
        progress.note(TurnState(scratchpad: "Thinking", phase: .planning))
        progress.note(TurnState(answer: "Error: no model", status: .failed, phase: .finalizing))

        let reported = progress.ending(in: "t", thrown: nil)
        XCTAssertEqual(reported.outcome, .failed)
        XCTAssertEqual(reported.message.content, "Error: no model")
        let thrown = progress.ending(in: "t", thrown: NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "No network"]))
        XCTAssertEqual(thrown.outcome, .failed)
        XCTAssertTrue(thrown.message.content.contains("No network"))
    }

    // MARK: - Helpers

    private func question(_ text: String) -> ChatMessage {
        TurnProgress.message(in: threadID, role: "user", content: text)
    }

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
