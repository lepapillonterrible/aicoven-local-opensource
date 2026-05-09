import XCTest
@testable import AICoven

@MainActor
final class ToolRelevanceServiceTests: XCTestCase {

    private let service = ToolRelevanceService.shared

    // MARK: - Always-loaded tools constant

    func testAlwaysLoadedTools_containsExpectedTools() {
        let always = ToolRelevanceService.alwaysLoadedTools

        XCTAssertTrue(always.contains("current_time"))
        XCTAssertTrue(always.contains("web_search"))
        XCTAssertTrue(always.contains("shell.execute"))
        XCTAssertEqual(always.count, 3)
    }

    // MARK: - selectRelevantNativeTools — small set bypass

    func testSelectRelevant_returnsAllWhenFewTools() async {
        // When total tools are ≤ limit, all should be returned without filtering.
        let tools = makeTools(["current_time", "web_search", "file.read"])

        let result = await service.selectRelevantNativeTools(
            userMessage: "anything",
            allTools: tools,
            limit: 10
        )

        XCTAssertEqual(result.count, 3)
    }

    // MARK: - selectRelevantNativeTools — always-loaded bypass

    func testSelectRelevant_alwaysIncludesAlwaysLoadedTools() async {
        // Even with a tight limit, always-loaded tools must be present.
        let tools = makeTools([
            "current_time", "web_search", "shell.execute",
            "file.read", "file.write", "file.list",
            "github.listRepos", "github.readFile", "github.writeFile",
            "github.searchCode",
        ])

        let result = await service.selectRelevantNativeTools(
            userMessage: "read a file",
            allTools: tools,
            limit: 5
        )

        let names = Set(result.map(\.name))
        XCTAssertTrue(names.contains("current_time"))
        XCTAssertTrue(names.contains("web_search"))
        XCTAssertTrue(names.contains("shell.execute"))
        XCTAssertTrue(result.count <= 5)
    }

    // MARK: - selectRelevantNativeTools — keyword relevance

    func testSelectRelevant_prefersRelevantToolsByKeyword() async {
        let tools = makeTools([
            "current_time", "web_search", "shell.execute",
            "file.read", "file.write", "file.list",
            "github.listRepos", "github.readFile", "github.writeFile",
            "github.searchCode",
        ])

        let result = await service.selectRelevantNativeTools(
            userMessage: "read the file at /tmp",
            allTools: tools,
            limit: 5
        )

        let names = Set(result.map(\.name))
        // "file.read" should be selected because "read" and "file" match.
        XCTAssertTrue(names.contains("file.read"))
    }

    // MARK: - Compressed native catalog

    func testCompressedCatalog_returnsNilForEmpty() {
        let catalog = ToolRelevanceService.generateCompressedNativeCatalog(excluded: [])
        XCTAssertNil(catalog)
    }

    func testCompressedCatalog_listsToolNames() {
        let tools = makeTools(["github.listRepos", "github.readFile"])
        let catalog = ToolRelevanceService.generateCompressedNativeCatalog(excluded: tools)

        XCTAssertNotNil(catalog)
        XCTAssertTrue(catalog?.contains("github.listRepos") == true)
        XCTAssertTrue(catalog?.contains("github.readFile") == true)
        XCTAssertTrue(catalog?.contains("OTHER AVAILABLE TOOLS") == true)
    }

    // MARK: - scoreNativeTool — keyword fallback

    func testScoreNativeTool_keywordFallback() async {
        let tools = makeTools(["file.read", "web_search"])

        // "read" should give file.read a nonzero score.
        let score = await service.scoreNativeTool(
            toolName: "file.read",
            userMessage: "read the configuration file",
            allTools: tools
        )

        XCTAssertGreaterThan(score, 0)
    }

    func testScoreNativeTool_zeroForUnrelated() async {
        let tools = makeTools(["github.listRepos"])

        let score = await service.scoreNativeTool(
            toolName: "github.listRepos",
            userMessage: "what time is it",
            allTools: tools
        )

        // "what time is it" has no overlap with "github.listRepos"
        XCTAssertEqual(score, 0)
    }

    func testScoreNativeTool_zeroForNonexistentTool() async {
        let tools = makeTools(["web_search"])

        let score = await service.scoreNativeTool(
            toolName: "nonexistent_tool",
            userMessage: "search for something",
            allTools: tools
        )

        XCTAssertEqual(score, 0)
    }

    // MARK: - Helpers

    /// Build minimal ToolDefinition stubs for testing. Descriptions are
    /// derived from the tool name to give the keyword scorer something
    /// to match against.
    private func makeTools(_ names: [String]) -> [ToolDefinition] {
        names.map { name in
            ToolDefinition(
                name: name,
                description: "Tool: \(name.replacingOccurrences(of: ".", with: " "))",
                parameters: [],
                example: "{}"
            )
        }
    }
}
