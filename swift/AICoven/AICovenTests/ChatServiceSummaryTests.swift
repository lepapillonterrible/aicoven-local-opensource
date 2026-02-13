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

        await chatService.updateThreadSummary(threadId: threadID)

        let summary = mockThreadStore.updatedSummaries[threadID]
        XCTAssertEqual(summary, "This is a summary from mock client.")
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

        await chatService.updateThreadSummary(threadId: threadID)

        // With no available models or clients, updateThreadSummary should exit
        // early and never call into the thread store.
        XCTAssertNil(mockThreadStore.updatedSummaries[threadID])
    }
}
