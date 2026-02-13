import XCTest
@testable import AICoven

// MARK: - Mock ChatToolService

/// A mock ChatToolService that returns deterministic results without network access.
private final class MockToolService: ChatToolService, @unchecked Sendable {

    /// Configurable web search results returned by `webSearch`.
    var webSearchResults: [ToolService.WebSearchResult] = []

    /// Optional error to throw from `webSearch`.
    var webSearchError: Error?

    func webSearch(query: String, maxResults: Int) async throws -> [ToolService.WebSearchResult] {
        if let error = webSearchError { throw error }
        return Array(webSearchResults.prefix(maxResults))
    }

    func webBrowse(url: URL, maxLength: Int) async throws -> ToolService.WebBrowseResult {
        ToolService.WebBrowseResult(
            url: url,
            title: "Mock Page",
            content: "Mock content for \(url.absoluteString)",
            contentLength: 100,
            truncated: false
        )
    }

    nonisolated func currentTime(timezone: TimeZone) -> ToolService.TimeInfo {
        ToolService.TimeInfo(
            utcISO8601: "2026-01-01T00:00:00Z",
            timezoneIdentifier: timezone.identifier,
            localISO8601: "2026-01-01T00:00:00+00:00"
        )
    }
}

// MARK: - Tests

/// Tests for tool execution via ToolExecutionService.
/// Uses a mock ChatToolService so tests are deterministic and don't require network.
final class AgentRunnerToolingTests: XCTestCase {

    /// Test that the current_time tool produces a valid result with context.
    func testToolExecution_currentTimeProducesContextBlock() async {
        let mock = MockToolService()
        let service = ToolExecutionService(toolService: mock)

        let call = ParsedToolCall(name: "current_time", args: [:])
        let result = await service.execute(toolCall: call, agentType: "test-agent")

        XCTAssertEqual(result.status, "ok", "Expected tool to succeed")
        XCTAssertNotNil(result.contextBlock, "Expected contextBlock to be present")
        XCTAssertTrue(result.contextBlock?.contains("[Current Time]") == true, "Expected context to contain time info")
    }

    /// Test that web_search returns a well-structured success result when results are available.
    func testToolExecution_webSearchReturnsSuccessResult() async throws {
        let mock = MockToolService()
        mock.webSearchResults = try [
            ToolService.WebSearchResult(
                title: "Swift Programming Language",
                url: XCTUnwrap(URL(string: "https://swift.org")),
                snippet: "Swift is a powerful and intuitive programming language."
            ),
            ToolService.WebSearchResult(
                title: "Swift Documentation",
                url: XCTUnwrap(URL(string: "https://developer.apple.com/swift/")),
                snippet: "Official Apple documentation for Swift."
            )
        ]

        let service = ToolExecutionService(toolService: mock)
        let call = ParsedToolCall(name: "web_search", args: ["query": AnyJSONValue("swift programming")])
        let result = await service.execute(toolCall: call, agentType: "test-agent")

        XCTAssertEqual(result.status, "ok", "Expected success status")
        XCTAssertNotNil(result.contextBlock, "Expected contextBlock with search results")
        XCTAssertTrue(result.contextBlock?.contains("Swift Programming Language") == true)
        XCTAssertTrue(result.contextBlock?.contains("swift.org") == true)
    }

    /// Test that web_search returns no_results when the search yields no hits.
    func testToolExecution_webSearchReturnsNoResults() async {
        let mock = MockToolService()
        mock.webSearchResults = [] // No results

        let service = ToolExecutionService(toolService: mock)
        let call = ParsedToolCall(name: "web_search", args: ["query": AnyJSONValue("xyznonexistentquery12345")])
        let result = await service.execute(toolCall: call, agentType: "test-agent")

        XCTAssertEqual(result.status, "ok", "Expected ok status even for no results")
        XCTAssertNotNil(result.contextBlock, "Expected contextBlock for no results case")
        XCTAssertTrue(result.contextBlock?.contains("No results found") == true)
    }

    /// Test that web_search returns an error result when the search fails.
    func testToolExecution_webSearchReturnsErrorOnFailure() async {
        let mock = MockToolService()
        mock.webSearchError = NSError(
            domain: "TestError",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Network offline"]
        )

        let service = ToolExecutionService(toolService: mock)
        let call = ParsedToolCall(name: "web_search", args: ["query": AnyJSONValue("swift programming")])
        let result = await service.execute(toolCall: call, agentType: "test-agent")

        XCTAssertEqual(result.status, "error", "Expected error status")
        XCTAssertNotNil(result.error, "Expected error message")
        XCTAssertTrue(result.error?.contains("Network offline") == true)
    }

    /// Test that web_search requires a query argument.
    func testToolExecution_webSearchMissingQueryReturnsValidationError() async {
        let mock = MockToolService()
        let service = ToolExecutionService(toolService: mock)

        let call = ParsedToolCall(name: "web_search", args: [:])
        let result = await service.execute(toolCall: call, agentType: "test-agent")

        XCTAssertEqual(result.status, "error", "Expected error for missing query")
    }

    /// Test that unknown tools return an error.
    func testToolExecution_unknownToolReturnsError() async {
        let mock = MockToolService()
        let service = ToolExecutionService(toolService: mock)

        let call = ParsedToolCall(name: "nonexistent_tool", args: [:])
        let result = await service.execute(toolCall: call, agentType: "test-agent")

        XCTAssertEqual(result.status, "error", "Expected error status for unknown tool")
        XCTAssertTrue(result.error?.contains("Unknown tool") == true)
    }
}
