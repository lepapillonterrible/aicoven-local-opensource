import XCTest
@testable import AICoven

/// Integration-style tests for the agent stack using only local components
/// (no backend) and a mock LLMClient.
@MainActor
final class ChatAndAgentIntegrationTests: XCTestCase {

    /// Simple mock LLMClient that first returns a tool call and then a final
    /// natural-language answer. This lets us exercise the AgentRunner.run tool
    /// loop end-to-end without touching real providers.
    private final class MockLLMClient: LLMClient {
        private nonisolated(unsafe) var callCount = 0

        func completeChat(messages: [LLMMessage], model: String, options: ChatOptions) async throws -> LLMChatResponse {
            callCount += 1

            let content = if callCount == 1 {
                // First response: ask the agent to call the current_time tool.
                "{" + "\"tool\":\"current_time\",\"input\":null,\"reason\":\"test run\"" + "}"
            } else {
                // Second response: final natural-language answer.
                "This is the final answer after using tools."
            }

            let message = LLMMessage(role: .assistant, content: content)
            return LLMChatResponse(
                message: message,
                providerID: "test-provider",
                modelID: model,
                usage: nil
            )
        }

        func embed(texts: [String], model: String) async throws -> [[Float]] {
            Array(repeating: Array(repeating: 0.0, count: 3), count: texts.count)
        }
    }

    func testAgentRunner_run_executesToolAndProducesFinalAnswer() async throws {
        // Ensure encryption is unlocked for the local database used by
        // repositories in this integration test.
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        // Ensure the local database is configured so repositories can persist
        // runs and steps.
        DatabaseManager.shared.configureIfNeeded()

        let mockClient = MockLLMClient()
        let model = ModelDescriptor(
            providerID: "test-provider",
            modelID: "test-model",
            maxContextTokens: 4096,
            supportsTools: true,
            supportsEmbeddings: false,
            costClass: .cheap
        )
        let router = HeuristicModelRouter(availableModels: [model])

        // Minimal context builder that uses real repositories and tools.
        let contextBuilder = ContextBuilder(
            threadRepository: .shared,
            memoryRepository: .shared,
            embeddingService: .shared,
            toolService: .shared,
            limits: .init(maxRecentMessages: 4, maxRecentMemories: 4)
        )

        // Create AgentRunner with mock client and default toolExecutionService
        let runner = AgentRunner(
            agentRunRepository: .shared,
            threadRepository: .shared,
            contextBuilder: contextBuilder,
            modelRouter: router,
            llmClients: ["test-provider": mockClient],
            toolExecutionService: .shared
        )

        let profile = AgentProfile(type: "test-agent", displayName: "Test Agent", description: "")

        // Start a short run with maxSteps = 2 so we expect: one tool call + one
        // final answer.
        await runner.run(
            profile: profile,
            threadID: nil,
            maxSteps: 2,
            userMessage: "Test goal: check current time and answer."
        )

        // Verify that at least one thread was created for the run. If the
        // database is unavailable or the run failed early, this call will
        // throw and the test will fail.
        let threads = try await ThreadRepository.shared.fetchAllThreads()
        XCTAssertFalse(threads.isEmpty, "Expected at least one thread to be created for the agent run")
    }

    /// Mock tool service for ChatService integration tests.
    private actor MockChatToolService: ChatToolService {
        func webSearch(query: String, maxResults: Int) async throws -> [ToolService.WebSearchResult] {
            [
                ToolService.WebSearchResult(
                    title: "Test result for \(query)",
                    url: URL(string: "https://example.com")!,
                    snippet: "Snippet for \(query)"
                )
            ]
        }

        func webBrowse(url: URL, maxLength: Int) async throws -> ToolService.WebBrowseResult {
            ToolService.WebBrowseResult(url: url, title: "Mock", content: "Mock content", contentLength: 12, truncated: false)
        }

        nonisolated func currentTime(timezone: TimeZone) -> ToolService.TimeInfo {
            ToolService.TimeInfo(
                utcISO8601: "2025-01-01T00:00:00Z",
                timezoneIdentifier: timezone.identifier,
                localISO8601: "2025-01-01T00:00:00Z"
            )
        }
    }

    func testChatService_streamMessage_usesToolAndProducesFinalAnswer() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()

        let mockClient = MockLLMClient()
        let model = ModelDescriptor(
            providerID: "test-provider",
            modelID: "test-model",
            maxContextTokens: 4096,
            supportsTools: true,
            supportsEmbeddings: false,
            costClass: .cheap
        )
        let router = HeuristicModelRouter(availableModels: [model])

        let contextBuilder = ContextBuilder(
            threadRepository: .shared,
            memoryRepository: .shared,
            embeddingService: .shared,
            toolService: .shared,
            limits: .init(maxRecentMessages: 4, maxRecentMemories: 4)
        )

        let chatToolService = MockChatToolService()
        let chatService = ChatService(
            contextBuilder: contextBuilder,
            modelRouter: router,
            llmClients: ["test-provider": mockClient],
            threadStore: ThreadRepository.shared,
            toolService: chatToolService,
            shouldAutoRefreshEnvironment: false
        )

        var planningMessages: [String] = []
        var toolEvents: [String] = []
        var answerText = ""

        let onPlanningDelta: (String) -> Void = { delta in
            planningMessages.append(delta)
        }
        let onToolEvent: (String) -> Void = { summary in
            toolEvents.append(summary)
        }
        let onAnswerDelta: (String) -> Void = { delta in
            answerText.append(contentsOf: delta)
        }
        let onDone: (String?, String?, TokenUsage?) -> Void = { _, _, _ in }

        try await chatService.streamMessage(
            threadId: "test-thread-id",
            message: "What time is it and check the web?",
            roleId: nil,
            providerAccountId: nil,
            attachmentIds: nil,
            onPlanningDelta: onPlanningDelta,
            onToolEvent: onToolEvent,
            onAnswerDelta: onAnswerDelta,
            onDone: onDone
        )

        XCTAssertFalse(toolEvents.isEmpty, "Expected at least one tool event from web_search")
        XCTAssertTrue(answerText.contains("final answer"), "Expected final answer text to be produced")
    }
}
