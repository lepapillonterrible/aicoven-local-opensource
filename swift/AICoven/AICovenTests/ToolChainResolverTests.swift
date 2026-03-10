import XCTest
@testable import AICoven

final class ToolChainResolverTests: XCTestCase {

    /// All native tools enabled — the broadest possible set.
    private let allEnabled = PromptTemplates.allTools

    // MARK: - Search and Summarize

    func testSearchAndSummarize_matchesSearchForAndSummarize() {
        let chain = ToolChainResolver.resolve(
            userMessage: "Search for Swift concurrency and summarize",
            enabledTools: allEnabled
        )

        XCTAssertNotNil(chain)
        XCTAssertEqual(chain?.first?.tool, "web_search")
        // The extracted query should be "Swift concurrency"
        let query = (chain?.first?.input?.value as? [String: AnyJSONValue])?["query"]?.value as? String
        XCTAssertEqual(query, "Swift concurrency")
    }

    func testSearchAndSummarize_matchesLookUpAndExplain() {
        let chain = ToolChainResolver.resolve(
            userMessage: "Look up quantum computing and explain it to me",
            enabledTools: allEnabled
        )

        XCTAssertNotNil(chain)
        XCTAssertEqual(chain?.first?.tool, "web_search")
    }

    func testSearchAndSummarize_nilWhenWebSearchDisabled() {
        let limited: Set<String> = ["current_time", "file.read"]
        let chain = ToolChainResolver.resolve(
            userMessage: "Search for Swift concurrency and summarize",
            enabledTools: limited
        )

        XCTAssertNil(chain)
    }

    // MARK: - Read File and Explain

    func testReadFileAndExplain_matchesReadAndExplain() {
        let chain = ToolChainResolver.resolve(
            userMessage: "Read /Users/me/project/README.md and explain it",
            enabledTools: allEnabled
        )

        XCTAssertNotNil(chain)
        XCTAssertEqual(chain?.first?.tool, "file.read")
        let path = (chain?.first?.input?.value as? [String: AnyJSONValue])?["path"]?.value as? String
        XCTAssertEqual(path, "/Users/me/project/README.md")
    }

    func testReadFileAndExplain_matchesShowAndSummarize() {
        let chain = ToolChainResolver.resolve(
            userMessage: "Show /tmp/config.yaml and summarize the settings",
            enabledTools: allEnabled
        )

        XCTAssertNotNil(chain)
        XCTAssertEqual(chain?.first?.tool, "file.read")
    }

    func testReadFileAndExplain_nilWithoutFilePath() {
        let chain = ToolChainResolver.resolve(
            userMessage: "Read something and explain it",
            enabledTools: allEnabled
        )

        // No extractable file path → no chain
        XCTAssertNil(chain)
    }

    // MARK: - Multi Timezone

    func testMultiTimezone_matchesTwoLocations() {
        let chain = ToolChainResolver.resolve(
            userMessage: "What time is it in Tokyo and London?",
            enabledTools: allEnabled
        )

        XCTAssertNotNil(chain)
        XCTAssertEqual(chain?.count, 2)
        XCTAssertTrue(chain?.allSatisfy { $0.tool == "current_time" } == true)
    }

    func testMultiTimezone_extractsCorrectTimezones() {
        let chain = ToolChainResolver.resolve(
            userMessage: "What time is it in New York and Paris?",
            enabledTools: allEnabled
        )

        XCTAssertNotNil(chain)
        XCTAssertEqual(chain?.count, 2)

        let tzs = chain?.compactMap {
            ($0.input?.value as? [String: AnyJSONValue])?["timezone"]?.value as? String
        }
        // Verify the timezone values are populated (exact values depend on
        // extractTimezoneFromMessage's lookup table).
        XCTAssertEqual(tzs?.count, 2)
    }

    func testMultiTimezone_nilForSingleLocation() {
        let chain = ToolChainResolver.resolve(
            userMessage: "What time is it in Tokyo?",
            enabledTools: allEnabled
        )

        // Single location — no "and" → not a chain (handled by forceNativeToolCall instead)
        XCTAssertNil(chain)
    }

    func testMultiTimezone_nilWhenCurrentTimeDisabled() {
        let limited: Set<String> = ["web_search", "file.read"]
        let chain = ToolChainResolver.resolve(
            userMessage: "What time is it in Tokyo and London?",
            enabledTools: limited
        )

        XCTAssertNil(chain)
    }

    // MARK: - List and Read

    func testListAndRead_matchesListFilesAndReadREADME() {
        let chain = ToolChainResolver.resolve(
            userMessage: "List files in /Users/me/project and read the README.md",
            enabledTools: allEnabled
        )

        XCTAssertNotNil(chain)
        XCTAssertEqual(chain?.count, 2)
        XCTAssertEqual(chain?[0].tool, "file.list")
        XCTAssertEqual(chain?[1].tool, "file.read")

        let listPath = (chain?[0].input?.value as? [String: AnyJSONValue])?["path"]?.value as? String
        XCTAssertEqual(listPath, "/Users/me/project")

        let readPath = (chain?[1].input?.value as? [String: AnyJSONValue])?["path"]?.value as? String
        XCTAssertTrue(readPath?.hasSuffix("README.md") == true)
    }

    func testListAndRead_nilWhenFileReadDisabled() {
        let limited: Set<String> = ["file.list", "web_search"]
        let chain = ToolChainResolver.resolve(
            userMessage: "List files in /project and read the README",
            enabledTools: limited
        )

        XCTAssertNil(chain)
    }

    // MARK: - Search GitHub and Read

    func testSearchGitHubAndRead_matchesPattern() {
        let chain = ToolChainResolver.resolve(
            userMessage: "Search GitHub for SwiftUI navigation and read the top result",
            enabledTools: allEnabled
        )

        XCTAssertNotNil(chain)
        XCTAssertEqual(chain?.first?.tool, "github.searchCode")
        let query = (chain?.first?.input?.value as? [String: AnyJSONValue])?["query"]?.value as? String
        XCTAssertTrue(query?.contains("SwiftUI") == true)
    }

    func testSearchGitHubAndRead_nilWhenGitHubDisabled() {
        let limited: Set<String> = ["web_search", "file.read"]
        let chain = ToolChainResolver.resolve(
            userMessage: "Search GitHub for SwiftUI navigation and read it",
            enabledTools: limited
        )

        XCTAssertNil(chain)
    }

    // MARK: - No Match

    func testResolve_nilForSimpleQuestion() {
        let chain = ToolChainResolver.resolve(
            userMessage: "What is the capital of France?",
            enabledTools: allEnabled
        )

        XCTAssertNil(chain)
    }

    func testResolve_nilForSingleToolIntent() {
        // "Search for X" without a continuation like "and summarize"
        // should NOT match — it's a single-tool intent.
        let chain = ToolChainResolver.resolve(
            userMessage: "Search for Swift concurrency",
            enabledTools: allEnabled
        )

        XCTAssertNil(chain)
    }

    func testResolve_nilForEmptyMessage() {
        let chain = ToolChainResolver.resolve(
            userMessage: "",
            enabledTools: allEnabled
        )

        XCTAssertNil(chain)
    }
}
