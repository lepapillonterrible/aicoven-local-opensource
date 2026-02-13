import XCTest
@testable import AICoven

final class ToolCallParserTests: XCTestCase {

    // MARK: - JSON Format Tests

    func testParseJSONToolCall_simpleFormat() {
        let input = """
        {"tool": "web_search", "input": "weather in London", "reason": "User asked about weather"}
        """

        let result = ToolCallParser.parse(input)

        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "web_search")
        XCTAssertEqual(result.toolCalls.first?.args["input"]?.value as? String, "weather in London")
        XCTAssertEqual(result.toolCalls.first?.reason, "User asked about weather")
    }

    func testParseJSONToolCall_withArgsDict() {
        let input = """
        {"tool": "file.read", "args": {"path": "/tmp/test.txt", "encoding": "utf-8"}}
        """

        let result = ToolCallParser.parse(input)

        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "file.read")
        XCTAssertEqual(result.toolCalls.first?.args["path"]?.value as? String, "/tmp/test.txt")
        XCTAssertEqual(result.toolCalls.first?.args["encoding"]?.value as? String, "utf-8")
    }

    func testParseJSONToolCall_withInputDict() {
        let input = """
        {"tool": "github.readFile", "input": {"repo": "owner/repo", "path": "README.md"}}
        """

        let result = ToolCallParser.parse(input)

        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "github.readFile")
        XCTAssertEqual(result.toolCalls.first?.args["repo"]?.value as? String, "owner/repo")
        XCTAssertEqual(result.toolCalls.first?.args["path"]?.value as? String, "README.md")
    }

    func testParseJSONToolCall_embeddedInText() {
        let input = """
        I'll search the web for that information.

        {"tool": "web_search", "input": "current time in Tokyo"}

        Let me find that for you.
        """

        let result = ToolCallParser.parse(input)

        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "web_search")
    }

    // MARK: - Angle-Bracket Format Tests

    func testParseAngleBracketToolCall() {
        let input = """
        <TOOL_CALL>
        github.createBranch
        {"repo": "owner/repo", "base_ref": "main", "new_branch": "feature/test"}
        </TOOL_CALL>
        """

        let result = ToolCallParser.parse(input)

        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "github.createBranch")
        XCTAssertEqual(result.toolCalls.first?.args["repo"]?.value as? String, "owner/repo")
        XCTAssertEqual(result.toolCalls.first?.args["base_ref"]?.value as? String, "main")
    }

    func testParseAngleBracketToolCall_withWhitespace() {
        let input = """
        < TOOL_CALL >
        shell.execute
        {"command": "ls -la"}
        < / TOOL_CALL >
        """

        let result = ToolCallParser.parse(input)

        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "shell.execute")
    }

    func testParseAngleBracketToolCall_multipleTools() {
        let input = """
        <TOOL_CALL>
        file.read
        {"path": "/tmp/a.txt"}
        </TOOL_CALL>

        <TOOL_CALL>
        file.write
        {"path": "/tmp/b.txt", "content": "hello"}
        </TOOL_CALL>
        """

        let result = ToolCallParser.parse(input)

        XCTAssertEqual(result.toolCalls.count, 2)
        XCTAssertEqual(result.toolCalls[0].name, "file.read")
        XCTAssertEqual(result.toolCalls[1].name, "file.write")
    }

    // MARK: - Square-Bracket Format Tests

    func testParseSquareBracketToolCall() {
        let input = """
        [TOOL_CALL: name=github.writeFile]
        {"repo": "owner/repo", "path": "test.txt", "content": "hello", "branch": "main", "commit_message": "Add test file"}
        [/TOOL_CALL]
        """

        let result = ToolCallParser.parse(input)

        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "github.writeFile")
        XCTAssertEqual(result.toolCalls.first?.args["repo"]?.value as? String, "owner/repo")
    }

    func testParseSquareBracketToolCall_withoutName() {
        let input = """
        [TOOL_CALL: image.generate]
        {"prompt": "A sunset over mountains"}
        [/TOOL_CALL]
        """

        let result = ToolCallParser.parse(input)

        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "image.generate")
    }

    // MARK: - Thought Parsing Tests

    func testParseThoughts() {
        let input = """
        <thought>
        I need to search the web to find current weather information.
        </thought>

        {"tool": "web_search", "input": "weather London"}
        """

        let result = ToolCallParser.parse(input)

        XCTAssertEqual(result.thoughts.count, 1)
        XCTAssertTrue(result.thoughts.first?.content.contains("search the web") == true)
    }

    func testParseThoughts_multiple() {
        let input = """
        <thought>First thought about the problem.</thought>

        Some text here.

        <thought>Second thought after analysis.</thought>
        """

        let result = ToolCallParser.parse(input)

        XCTAssertEqual(result.thoughts.count, 2)
        XCTAssertTrue(result.thoughts[0].content.contains("First thought"))
        XCTAssertTrue(result.thoughts[1].content.contains("Second thought"))
    }

    // MARK: - Scratchpad Parsing Tests

    func testParseScratchpadTasks() {
        let input = """
        <scratchpad>
        Tasks:
        - [ ] Create the branch
        - [x] Read the existing file
        - [ ] Write the updated content
        </scratchpad>
        """

        let result = ToolCallParser.parse(input)

        XCTAssertEqual(result.scratchpadTasks.count, 3)
        XCTAssertEqual(result.scratchpadTasks[0].title, "Create the branch")
        XCTAssertFalse(result.scratchpadTasks[0].completed)
        XCTAssertEqual(result.scratchpadTasks[1].title, "Read the existing file")
        XCTAssertTrue(result.scratchpadTasks[1].completed)
        XCTAssertEqual(result.scratchpadTasks[2].title, "Write the updated content")
        XCTAssertFalse(result.scratchpadTasks[2].completed)
    }

    func testParseScratchpadTasks_usesLastBlock() {
        let input = """
        <scratchpad>
        - [ ] Task 1
        </scratchpad>

        Some work done...

        <scratchpad>
        - [x] Task 1
        - [ ] Task 2
        </scratchpad>
        """

        let result = ToolCallParser.parse(input)

        // Should use the last scratchpad
        XCTAssertEqual(result.scratchpadTasks.count, 2)
        XCTAssertTrue(result.scratchpadTasks[0].completed)
    }

    // MARK: - Stripping Tests

    func testStripAllMarkup_toolCalls() {
        let input = """
        Here is my response.

        <TOOL_CALL>
        web_search
        {"query": "test"}
        </TOOL_CALL>

        And here is more text.
        """

        let result = ToolCallParser.parse(input)

        XCTAssertTrue(result.strippedText.contains("Here is my response"))
        XCTAssertTrue(result.strippedText.contains("And here is more text"))
        XCTAssertFalse(result.strippedText.contains("TOOL_CALL"))
        XCTAssertFalse(result.strippedText.contains("web_search"))
    }

    func testStripAllMarkup_thoughts() {
        let input = """
        <thought>This is my reasoning.</thought>

        The answer is 42.
        """

        let result = ToolCallParser.parse(input)

        XCTAssertTrue(result.strippedText.contains("The answer is 42"))
        XCTAssertFalse(result.strippedText.contains("thought"))
        XCTAssertFalse(result.strippedText.contains("reasoning"))
    }

    func testStripAllMarkup_scratchpad() {
        let input = """
        <scratchpad>
        - [ ] Task 1
        - [x] Task 2
        </scratchpad>

        Here is the final result.
        """

        let result = ToolCallParser.parse(input)

        XCTAssertTrue(result.strippedText.contains("final result"))
        XCTAssertFalse(result.strippedText.contains("scratchpad"))
        XCTAssertFalse(result.strippedText.contains("Task 1"))
    }

    func testStripAllMarkup_preservesNormalText() {
        let input = """
        This is a normal response without any tool calls or special markup.
        It should be preserved exactly as is.
        """

        let result = ToolCallParser.parse(input)

        XCTAssertTrue(result.strippedText.contains("normal response"))
        XCTAssertTrue(result.strippedText.contains("preserved exactly"))
    }

    // MARK: - Edge Cases

    func testEmptyInput() {
        let result = ToolCallParser.parse("")

        XCTAssertTrue(result.toolCalls.isEmpty)
        XCTAssertTrue(result.thoughts.isEmpty)
        XCTAssertTrue(result.scratchpadTasks.isEmpty)
        XCTAssertTrue(result.strippedText.isEmpty)
    }

    func testMalformedJSON() {
        let input = """
        {"tool": "test", "input": broken json here}
        """

        let result = ToolCallParser.parse(input)

        // Should not crash, just return empty tool calls
        XCTAssertTrue(result.toolCalls.isEmpty)
    }

    func testMalformedToolCall_unclosedTag() {
        let input = """
        <TOOL_CALL>
        web_search
        {"query": "test"}

        Some text without closing tag.
        """

        let result = ToolCallParser.parse(input)

        // Should handle gracefully (fallback parsing may or may not succeed)
        // The important thing is it doesn't crash
        XCTAssertNotNil(result.strippedText)
    }
}
