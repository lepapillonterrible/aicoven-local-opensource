@testable import AICoven
internal import Combine
import GRDB
import XCTest

/// A model that counts the requests it was sent, and holds each until let
/// go or cancelled. Sendable by hand, under its lock.
private final class CountingModel: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var asked = 0
    private var holds = false
    private var held: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var arrivals: [CheckedContinuation<Void, Never>] = []

    init(holding: Bool = false) {
        holds = holding
    }

    var timesAsked: Int {
        lock.withLock { asked }
    }

    /// Returns once a request has arrived.
    func arrived() async {
        await withCheckedContinuation { continuation in
            let already = lock.withLock {
                if asked > 0 { return true }
                arrivals.append(continuation)
                return false
            }
            if already { continuation.resume() }
        }
    }

    func completeChat(messages _: [LLMMessage], model: String, options _: ChatOptions) async throws -> LLMChatResponse {
        let call = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let (now, watchers) = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
                    asked += 1
                    defer { arrivals = [] }
                    if !holds || Task.isCancelled { return (true, arrivals) }
                    held[call] = continuation
                    return (false, arrivals)
                }
                watchers.forEach { $0.resume() }
                if now { continuation.resume() }
            }
        } onCancel: {
            lock.withLock { held.removeValue(forKey: call) }?.resume()
        }
        try Task.checkCancellation()
        return LLMChatResponse(message: LLMMessage(role: .assistant, content: "Summary."), providerID: "test", modelID: model, usage: nil)
    }

    func embed(texts: [String], model _: String) async throws -> [[Float]] {
        Array(repeating: [0, 1], count: texts.count)
    }
}

/// Who is signed in, as the test says. Sendable by hand, under its lock.
private final class Account: @unchecked Sendable {
    private let lock = NSLock()
    private var account: String

    init(_ account: String) {
        self.account = account
    }

    var now: String {
        get { lock.withLock { account } }
        set { lock.withLock { account = newValue } }
    }
}

private actor NoTools: ChatToolService {
    func webSearch(query _: String, maxResults _: Int) async throws -> [ToolService.WebSearchResult] {
        []
    }

    func webBrowse(url: URL, maxLength _: Int) async throws -> ToolService.WebBrowseResult {
        ToolService.WebBrowseResult(url: url, title: "", content: "", contentLength: 0, truncated: false)
    }

    nonisolated func currentTime(timezone: TimeZone) -> ToolService.TimeInfo {
        ToolService.TimeInfo(utcISO8601: "", timezoneIdentifier: timezone.identifier, localISO8601: "")
    }
}

/// A turn, its approvals and its summary are the account's that began it:
/// once another account has signed in, nothing of it is sent, asked,
/// stored or shown.
@MainActor
final class TurnsKeepTheirAccountTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        await ThreadService.shared.reloadForCurrentUser()
    }

    override func tearDown() async throws {
        await DataEncryptionService.shared.lock()
        try await super.tearDown()
    }

    private func chat(_ clients: [String: any LLMClient], models: [ModelDescriptor], signedIn: Account) -> ChatService {
        ChatService(
            contextBuilder: ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4)),
            modelRouter: HeuristicModelRouter(availableModels: models),
            llmClients: clients,
            threadStore: ThreadRepository.shared,
            toolService: NoTools(),
            shouldAutoRefreshEnvironment: false,
            hermesAgent: { nil },
            openClawTurn: { _ in nil },
            signedIn: { signedIn.now }
        )
    }

    private func model(_ provider: String, _ id: String) -> ModelDescriptor {
        ModelDescriptor(providerID: provider, modelID: id, maxContextTokens: 32768, supportsTools: false, supportsEmbeddings: false, costClass: .cheap)
    }

    private func newThread(inCoven covenID: String? = nil) async throws -> String {
        let thread = try await ThreadService.shared.createThread(title: "Turn account \(UUID().uuidString)", covenId: covenID)
        addTeardownBlock { try? await ThreadService.shared.deleteThread(threadId: thread.id) }
        try await ThreadRepository.shared.appendChatMessage(TurnProgress.message(in: thread.id, role: "user", content: "Plan the launch."))
        try await ThreadRepository.shared.appendChatMessage(TurnProgress.message(in: thread.id, role: "assistant", content: "Here is the plan."))
        return thread.id
    }

    /// Strix runs on OpenAI here, whatever the test before left.
    private func strixOnOpenAI() {
        for (key, value) in [("llm_provider", "openai"), ("openai_model", "gpt-x")] {
            let scoped = UserScope.scopedKey(key)
            let before = UserDefaults.standard.object(forKey: scoped)
            UserDefaults.standard.set(value, forKey: scoped)
            addTeardownBlock { UserDefaults.standard.set(before, forKey: scoped) }
        }
    }

    // MARK: - The turn

    func testATurnBegunAsOneAccount_sendsNothingOnceAnotherHasSignedIn_evenBeforeItsFirstRequest() async throws {
        let thread = try await newThread()
        let signedIn = Account("someone-else")
        let openAI = CountingModel()
        do {
            try await chat(["openai": openAI], models: [model("openai", "gpt-x")], signedIn: signedIn)
                .streamMessage(threadId: thread, as: UserScope.currentUserID, message: "Plan it", onStateChange: { _ in })
            XCTFail("The turn is not run as whoever signed in since it was sent")
        } catch RepositoryError.accountChanged {}
        XCTAssertEqual(openAI.timesAsked, 0, "Nothing is sent to a provider")
    }

    // MARK: - The summary

    func testACovenThreadIsSummarisedByItsAgentsModel_notStrixs() async throws {
        strixOnOpenAI()
        let account = UserScope.currentUserID
        let coven = try await CovenService.shared.createCoven(name: "Summaries \(UUID().uuidString)")
        addTeardownBlock { try? await CovenService.shared.deleteCoven(id: coven.id) }
        let scout = try await RoleService.shared.createAgent(
            inCoven: coven.id,
            AgentSaving(
                name: "Scout", iconSymbol: "magnifyingglass", iconTint: nil, description: "", instructions: "Be brief.",
                provider: "anthropic", model: "claude-x", providerAccountId: nil, temperature: nil, maxTokens: nil, mostSteps: nil
            ),
            as: account
        )
        let thread = try await newThread(inCoven: coven.id)
        let openAI = CountingModel()
        let anthropic = CountingModel()
        let service = chat(
            ["openai": openAI, "anthropic": anthropic], models: [model("openai", "gpt-x"), model("anthropic", "claude-x")], signedIn: Account(account)
        )

        await service.updateThreadSummary(threadId: thread, roleId: scout.id, as: account)
        XCTAssertEqual(anthropic.timesAsked, 1, "The agent's own model summarises its thread")
        XCTAssertEqual(openAI.timesAsked, 0, "The coven's conversation does not go to Strix's provider")

        // A thread of Strix's own is summarised by Strix's model, as before.
        let strixThread = try await newThread()
        await service.updateThreadSummary(threadId: strixThread, roleId: nil, as: account)
        XCTAssertEqual(openAI.timesAsked, 1)
    }

    func testAnAgentWhoseModelIsNotThere_hasItsThreadSummarisedByNoOtherModel() async throws {
        strixOnOpenAI()
        let account = UserScope.currentUserID
        let coven = try await CovenService.shared.createCoven(name: "Summaries \(UUID().uuidString)")
        addTeardownBlock { try? await CovenService.shared.deleteCoven(id: coven.id) }
        let scout = try await RoleService.shared.createAgent(
            inCoven: coven.id,
            AgentSaving(
                name: "Scout", iconSymbol: "magnifyingglass", iconTint: nil, description: "", instructions: "",
                provider: "anthropic", model: "claude-gone", providerAccountId: nil, temperature: nil, maxTokens: nil, mostSteps: nil
            ),
            as: account
        )
        let thread = try await newThread(inCoven: coven.id)
        let openAI = CountingModel()
        await chat(["openai": openAI], models: [model("openai", "gpt-x")], signedIn: Account(account))
            .updateThreadSummary(threadId: thread, roleId: scout.id, as: account)
        XCTAssertEqual(openAI.timesAsked, 0, "Not routed to some other provider")
    }

    func testNoSummaryIsMade_onceAnotherAccountHasSignedIn() async throws {
        strixOnOpenAI()
        let thread = try await newThread()
        let openAI = CountingModel()
        await chat(["openai": openAI], models: [model("openai", "gpt-x")], signedIn: Account("someone-else"))
            .updateThreadSummary(threadId: thread, roleId: nil, as: UserScope.currentUserID)
        XCTAssertEqual(openAI.timesAsked, 0, "Nothing of the thread is sent")
    }

    // MARK: - Approvals

    func testAnApprovalForAnAccountNoLongerSignedIn_isWithdrawnUnseen() async {
        let approvals = ToolApprovals(schedule: { _, action in action() })
        let approval = ToolApproval(threadID: "thread-a", question: "Run this command?", details: "git push", toolName: "shell.execute")
        let answer = await approvals.ask(approval, for: "someone-else")
        XCTAssertEqual(answer, .withdrawn)
        XCTAssertNil(approvals.showing, "Not shown to whoever is signed in")
        XCTAssertTrue(approvals.waiting.isEmpty)
        XCTAssertTrue(approvals.askingThreadIDs.isEmpty, "No thread is marked as waiting")
    }

    // MARK: - The engine

    func testWhenAnotherAccountSignsIn_aRunningTurnIsStopped_andNothingOfItIsStoredOrShown() async throws {
        let thread = try await newThread()
        let signedIn = Account(UserScope.currentUserID)
        let held = CountingModel(holding: true)
        let gone = expectation(description: "The turn was let go")
        var droppedTurns: [String] = []
        let engine = TurnEngine(
            chat: chat(["openai": held], models: [model("openai", "gpt-x")], signedIn: signedIn),
            approvals: ToolApprovals(schedule: { _, action in action() }),
            currentAccount: { signedIn.now },
            dropped: { turnID in
                droppedTurns.append(turnID)
                gone.fulfill()
            }
        )
        strixOnOpenAI()
        let turnID = try await engine.start(
            with: TurnProgress.message(in: thread, role: "user", content: "Plan it"), context: "Plan it", roleID: nil, agentName: nil, attachments: nil
        )
        await held.arrived()

        signedIn.now = "someone-else"
        engine.accountChanged()
        XCTAssertNil(engine.running[thread], "No longer shown as running, at once")
        await fulfillment(of: [gone], timeout: 10)

        XCTAssertEqual(droppedTurns, [turnID])
        XCTAssertNil(engine.endings[thread], "No ending is published")
        XCTAssertNil(engine.additions[thread], "Nothing is added to the thread")
        let status = try await DatabaseManager.shared.dbQueue?.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM turns WHERE id = ?", arguments: [turnID])
        }
        XCTAssertEqual(status, "running", "Nothing is stored for it: its account is told no reply was saved")
    }

    func testTheSameAccountReportedAgain_leavesItsTurnRunning() async throws {
        let thread = try await newThread()
        let signedIn = Account(UserScope.currentUserID)
        let held = CountingModel(holding: true)
        let engine = TurnEngine(
            chat: chat(["openai": held], models: [model("openai", "gpt-x")], signedIn: signedIn),
            approvals: ToolApprovals(schedule: { _, action in action() }),
            currentAccount: { signedIn.now }
        )
        strixOnOpenAI()
        try await engine.start(
            with: TurnProgress.message(in: thread, role: "user", content: "Plan it"), context: "Plan it", roleID: nil, agentName: nil, attachments: nil
        )
        await held.arrived()
        engine.accountChanged()
        XCTAssertNotNil(engine.running[thread], "Its own account is still signed in")
        engine.stop(threadID: thread)
        let ended = expectation(description: "The turn ended")
        ended.assertForOverFulfill = false
        let watching = engine.$running.sink { running in
            if running[thread] == nil { ended.fulfill() }
        }
        await fulfillment(of: [ended], timeout: 10)
        watching.cancel()
    }
}
