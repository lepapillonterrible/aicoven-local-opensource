import GRDB
import XCTest
@testable import AICoven

/// Tests focused on ChatService.updateThreadSummary behavior.
@MainActor
final class ChatServiceSummaryTests: XCTestCase {

    private final class MockThreadStore: ThreadStore {
        private(set) var updatedSummaries: [String: String?] = [:]

        func createThread(title: String?) async throws -> LocalThread {
            fatalError("Not used in tests")
        }

        func loadThread(id: String) async throws -> LocalThread? {
            fatalError("Not used in tests")
        }

        func fetchAllThreads() async throws -> [LocalThread] {
            fatalError("Not used in tests")
        }

        func updateSummary(forThreadID threadID: String, summary: String?) async throws {
            updatedSummaries[threadID] = summary
        }

        func appendMessage(toThreadID threadID: String, role: String, content: String) async throws -> LocalMessage {
            fatalError("Not used in tests")
        }

        func loadMessages(forThreadID threadID: String, limit: Int?) async throws -> [LocalMessage] {
            fatalError("Not used in tests")
        }

        private var chatMessages: [ChatMessage] = []

        func appendChatMessage(_ message: ChatMessage) async throws {
            chatMessages.append(message)
        }

        func loadChatMessages(threadID: String, limit: Int, before: String?) async throws -> [ChatMessage] {
            Array(chatMessages.filter { $0.threadId == threadID }.suffix(limit))
        }
    }

    private final class MockLLMClient: LLMClient {
        func completeChat(messages: [LLMMessage], model: String, options: ChatOptions) async throws -> LLMChatResponse {
            // Return a deterministic summary so the test can assert on it.
            let msg = LLMMessage(role: .assistant, content: "This is a summary from mock client.")
            return LLMChatResponse(
                message: msg,
                providerID: "test-provider",
                modelID: model,
                usage: nil
            )
        }

        func embed(texts: [String], model: String) async throws -> [[Float]] {
            Array(repeating: [0.0, 1.0], count: texts.count)
        }
    }

    private actor MockChatToolService: ChatToolService {
        func webSearch(query: String, maxResults: Int) async throws -> [ToolService.WebSearchResult] {
            []
        }

        func webBrowse(url: URL, maxLength: Int) async throws -> ToolService.WebBrowseResult {
            ToolService.WebBrowseResult(url: url, title: "Mock", content: "", contentLength: 0, truncated: false)
        }

        nonisolated func currentTime(timezone: TimeZone) -> ToolService.TimeInfo {
            ToolService.TimeInfo(
                utcISO8601: "2025-01-01T00:00:00Z",
                timezoneIdentifier: timezone.identifier,
                localISO8601: "2025-01-01T00:00:00Z"
            )
        }
    }

    func testUpdateThreadSummaryWritesSummaryViaThreadStore() async {
        let threadID = "thread-summary-test"

        let model = ModelDescriptor(
            providerID: "test-provider",
            modelID: "test-model",
            maxContextTokens: 4096,
            supportsTools: false,
            supportsEmbeddings: false,
            costClass: .cheap
        )
        let router = HeuristicModelRouter(availableModels: [model])
        let mockClient = MockLLMClient()
        let mockThreadStore = MockThreadStore()
        let toolService = MockChatToolService()

        let chatService = ChatService(
            contextBuilder: ContextBuilder(),
            modelRouter: router,
            llmClients: ["test-provider": mockClient],
            threadStore: mockThreadStore,
            toolService: toolService,
            shouldAutoRefreshEnvironment: false
        )

        // Seed local message history for this thread so updateThreadSummary has
        // content to summarize.
        let userMessage = ChatMessage(
            id: UUID().uuidString,
            threadId: threadID,
            role: "user",
            content: "Hello world",
            metadata: nil,
            tokenUsage: nil,
            createdAt: Date(),
            isEncrypted: false,
            keyFingerprint: nil
        )
        await chatService.addLocalMessage(userMessage)

        await chatService.updateThreadSummary(threadId: threadID, roleId: nil, as: UserScope.currentUserID)

        let summary = mockThreadStore.updatedSummaries[threadID]
        XCTAssertEqual(summary, "This is a summary from mock client.")
    }

    /// Answers its first request only once let go, and each with its own
    /// words. Sendable by hand, under `lock`.
    private final class HeldClient: LLMClient, @unchecked Sendable {
        private let lock = NSLock()
        private var answered = 0
        private var held: CheckedContinuation<Void, Never>?
        private var arrived: CheckedContinuation<Void, Never>?
        private var isHeld = false

        /// Waits until the first request has arrived and is held.
        func firstArrived() async {
            await withCheckedContinuation { continuation in
                let already = lock.withLock {
                    if isHeld { return true }
                    arrived = continuation
                    return false
                }
                if already { continuation.resume() }
            }
        }

        func letGo() {
            lock.withLock { held }?.resume()
        }

        func completeChat(messages _: [LLMMessage], model: String, options _: ChatOptions) async throws -> LLMChatResponse {
            let number = lock.withLock {
                answered += 1
                return answered
            }
            if number == 1 {
                await withCheckedContinuation { continuation in
                    let waiting = lock.withLock {
                        held = continuation
                        isHeld = true
                        return arrived
                    }
                    waiting?.resume()
                }
            }
            return LLMChatResponse(message: LLMMessage(role: .assistant, content: "Summary \(number)"), providerID: "test-provider", modelID: model, usage: nil)
        }

        func embed(texts: [String], model _: String) async throws -> [[Float]] {
            Array(repeating: [0, 0, 0], count: texts.count)
        }
    }

    /// Of two summaries of a thread, only the one asked for last is kept:
    /// one that comes back late does not overwrite it.
    func testASummaryThatComesBackLate_doesNotOverwriteANewerOne() async {
        let model = ModelDescriptor(providerID: "test-provider", modelID: "test-model", maxContextTokens: 4096, supportsTools: false, supportsEmbeddings: false, costClass: .cheap)
        let store = MockThreadStore()
        let client = HeldClient()
        let chatService = ChatService(
            contextBuilder: ContextBuilder(), modelRouter: HeuristicModelRouter(availableModels: [model]),
            llmClients: ["test-provider": client], threadStore: store, toolService: MockChatToolService(), shouldAutoRefreshEnvironment: false
        )
        await chatService.addLocalMessage(ChatMessage(
            id: UUID().uuidString, threadId: "late", role: "user", content: "Hello", metadata: nil, tokenUsage: nil,
            createdAt: Date(), isEncrypted: false, keyFingerprint: nil
        ))
        let first = Task { await chatService.updateThreadSummary(threadId: "late", roleId: nil, as: UserScope.currentUserID) }
        await client.firstArrived()
        await chatService.updateThreadSummary(threadId: "late", roleId: nil, as: UserScope.currentUserID)
        XCTAssertEqual(store.updatedSummaries["late"], "Summary 2")
        client.letGo()
        await first.value
        XCTAssertEqual(store.updatedSummaries["late"], "Summary 2", "The older summary is not kept over it")
    }

    /// A thread's summary is kept with the thread and offered to no memory:
    /// it was once proposed as one about the person after every turn.
    func testASummaryIsOfferedToNoMemory_andTheOnesThatWaitedAreTakenAway() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        addTeardownBlock { await DataEncryptionService.shared.lock() }
        DatabaseManager.shared.configureIfNeeded()
        let account = UserScope.currentUserID
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        func waiting() async throws -> Int {
            try await queue.read { db in
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM memory_proposals WHERE user_id = ? AND status = 'pending' AND title = 'Thread Summary'",
                    arguments: [account]
                ) ?? 0
            }
        }
        let before = try await waiting()

        let model = ModelDescriptor(providerID: "test-provider", modelID: "test-model", maxContextTokens: 4096, supportsTools: false, supportsEmbeddings: false, costClass: .cheap)
        let store = MockThreadStore()
        let chatService = ChatService(
            contextBuilder: ContextBuilder(), modelRouter: HeuristicModelRouter(availableModels: [model]),
            llmClients: ["test-provider": MockLLMClient()], threadStore: store, toolService: MockChatToolService(), shouldAutoRefreshEnvironment: false
        )
        await chatService.addLocalMessage(ChatMessage(
            id: UUID().uuidString, threadId: "thread-no-proposal", role: "user", content: "Hello", metadata: nil, tokenUsage: nil,
            createdAt: Date(), isEncrypted: false, keyFingerprint: nil
        ))
        await chatService.updateThreadSummary(threadId: "thread-no-proposal", roleId: nil, as: UserScope.currentUserID)
        XCTAssertEqual(store.updatedSummaries["thread-no-proposal"], "This is a summary from mock client.")
        let after = try await waiting()
        XCTAssertEqual(after, before, "No proposal is made of it")

        // What the migration takes away: only the app's own summary proposals that still wait.
        try await queue.write { db in
            for (id, by, title, status) in [
                ("s-waiting", "system", "Thread Summary", "pending"), ("s-answered", "system", "Thread Summary", "approved"),
                ("s-agent", "agent", "Thread Summary", "pending"), ("s-other", "system", "Something else", "pending"),
            ] {
                try db.execute(
                    sql: "INSERT INTO memory_proposals (id, proposed_content, status, proposed_by, title, created_at, user_id) VALUES (?, '', ?, ?, ?, ?, ?)",
                    arguments: [id, status, by, title, Date(), account]
                )
            }
            try db.execute(sql: DatabaseManager.summaryProposalsThatWait)
            let left = try String.fetchAll(db, sql: "SELECT id FROM memory_proposals WHERE id LIKE 's-%' ORDER BY id")
            XCTAssertEqual(left, ["s-agent", "s-answered", "s-other"])
            try db.execute(sql: "DELETE FROM memory_proposals WHERE id LIKE 's-%'")
        }
    }

    func testUpdateThreadSummaryDoesNothingWhenNoModelAvailable() async {
        let threadID = "thread-no-model"

        let router = HeuristicModelRouter(availableModels: [])
        let mockThreadStore = MockThreadStore()
        let toolService = MockChatToolService()

        let chatService = ChatService(
            contextBuilder: ContextBuilder(),
            modelRouter: router,
            llmClients: [:],
            threadStore: mockThreadStore,
            toolService: toolService,
            shouldAutoRefreshEnvironment: false
        )

        let userMessage = ChatMessage(
            id: UUID().uuidString,
            threadId: threadID,
            role: "user",
            content: "Hello world",
            metadata: nil,
            tokenUsage: nil,
            createdAt: Date(),
            isEncrypted: false,
            keyFingerprint: nil
        )
        await chatService.addLocalMessage(userMessage)

        await chatService.updateThreadSummary(threadId: threadID, roleId: nil, as: UserScope.currentUserID)

        // With no available models or clients, updateThreadSummary should exit
        // early and never call into the thread store.
        XCTAssertNil(mockThreadStore.updatedSummaries[threadID])
    }
}
