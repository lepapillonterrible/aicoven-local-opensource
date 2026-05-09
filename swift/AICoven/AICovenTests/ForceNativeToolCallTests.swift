import XCTest
@testable import AICoven

final class ForceNativeToolCallTests: XCTestCase {

    // MARK: - Time patterns (existing)

    func testForceNative_matchesWhatTime() {
        let result = ChatService.forceNativeToolCall(userMessage: "What time is it?")

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.tool, "current_time")
    }

    func testForceNative_matchesCurrentDate() {
        let result = ChatService.forceNativeToolCall(userMessage: "What is the current date?")

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.tool, "current_time")
    }

    // MARK: - Web search patterns (existing)

    func testForceNative_matchesSearchFor() {
        let result = ChatService.forceNativeToolCall(userMessage: "Search for Swift concurrency")

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.tool, "web_search")
        let query = (result?.input?.value as? [String: AnyJSONValue])?["query"]?.value as? String
        XCTAssertEqual(query, "Swift concurrency")
    }

    func testForceNative_matchesWeatherIn() {
        let result = ChatService.forceNativeToolCall(userMessage: "What's the weather in Tokyo?")

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.tool, "web_search")
        let query = (result?.input?.value as? [String: AnyJSONValue])?["query"]?.value as? String
        XCTAssertEqual(query, "What's the weather in Tokyo")
    }

    // MARK: - File read patterns (new)

    func testForceNative_matchesReadFile() {
        let result = ChatService.forceNativeToolCall(
            userMessage: "Read the file at /Users/me/project/README.md"
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.tool, "file.read")
        let path = (result?.input?.value as? [String: AnyJSONValue])?["path"]?.value as? String
        XCTAssertEqual(path, "/Users/me/project/README.md")
    }

    func testForceNative_matchesCatWithPath() {
        let result = ChatService.forceNativeToolCall(
            userMessage: "cat /tmp/test.txt"
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.tool, "file.read")
        let path = (result?.input?.value as? [String: AnyJSONValue])?["path"]?.value as? String
        XCTAssertEqual(path, "/tmp/test.txt")
    }

    func testForceNative_matchesShowFile() {
        let result = ChatService.forceNativeToolCall(
            userMessage: "Show file ~/Documents/config.yaml"
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.tool, "file.read")
    }

    func testForceNative_readFile_nilWithoutPath() {
        // "read file" without a path should not match
        let result = ChatService.forceNativeToolCall(
            userMessage: "Read file and tell me about it"
        )

        XCTAssertNil(result)
    }

    // MARK: - File list patterns (new)

    func testForceNative_matchesListFiles() {
        let result = ChatService.forceNativeToolCall(
            userMessage: "List files in /Users/me/project"
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.tool, "file.list")
        let path = (result?.input?.value as? [String: AnyJSONValue])?["path"]?.value as? String
        XCTAssertEqual(path, "/Users/me/project")
    }

    func testForceNative_matchesLs() {
        let result = ChatService.forceNativeToolCall(
            userMessage: "ls /tmp"
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.tool, "file.list")
    }

    func testForceNative_matchesShowDirectory() {
        let result = ChatService.forceNativeToolCall(
            userMessage: "Show directory ~/Documents"
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.tool, "file.list")
    }

    func testForceNative_listFiles_defaultsPathToDot() {
        let result = ChatService.forceNativeToolCall(
            userMessage: "List files here please"
        )

        // No path extracted → defaults to "."
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.tool, "file.list")
        let path = (result?.input?.value as? [String: AnyJSONValue])?["path"]?.value as? String
        XCTAssertEqual(path, ".")
    }

    // MARK: - Shell execute patterns (new)

    func testForceNative_matchesRunCommand() {
        let result = ChatService.forceNativeToolCall(
            userMessage: "Run `ls -la /tmp`"
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.tool, "shell.execute")
        let cmd = (result?.input?.value as? [String: AnyJSONValue])?["command"]?.value as? String
        XCTAssertEqual(cmd, "ls -la /tmp")
    }

    func testForceNative_matchesExecuteCommand() {
        let result = ChatService.forceNativeToolCall(
            userMessage: "Execute `npm test`"
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.tool, "shell.execute")
    }

    func testForceNative_matchesRunInTerminal() {
        let result = ChatService.forceNativeToolCall(
            userMessage: "Run this in the terminal: `git status`"
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.tool, "shell.execute")
        let cmd = (result?.input?.value as? [String: AnyJSONValue])?["command"]?.value as? String
        XCTAssertEqual(cmd, "git status")
    }

    // MARK: - No Match

    func testForceNative_nilForGenericQuestion() {
        let result = ChatService.forceNativeToolCall(
            userMessage: "Explain how Swift closures work"
        )

        XCTAssertNil(result)
    }

    func testForceNative_nilForEmptyMessage() {
        let result = ChatService.forceNativeToolCall(userMessage: "")

        XCTAssertNil(result)
    }

    // MARK: - extractFilePath

    func testExtractFilePath_absolutePath() {
        let path = ChatService.extractFilePath(from: "Read /Users/me/file.txt")
        XCTAssertEqual(path, "/Users/me/file.txt")
    }

    func testExtractFilePath_tildePath() {
        let path = ChatService.extractFilePath(from: "Open ~/Documents/config.yaml")
        XCTAssertEqual(path, "~/Documents/config.yaml")
    }

    func testExtractFilePath_backtickPath() {
        let path = ChatService.extractFilePath(from: "Read `my-file.txt` please")
        XCTAssertEqual(path, "my-file.txt")
    }

    func testExtractFilePath_quotedPath() {
        let path = ChatService.extractFilePath(from: "Read \"some file.txt\" please")
        XCTAssertEqual(path, "some file.txt")
    }

    func testExtractFilePath_nilForNoPath() {
        let path = ChatService.extractFilePath(from: "Hello world")
        XCTAssertNil(path)
    }

    // MARK: - extractShellCommand

    func testExtractShellCommand_backtickFenced() {
        let cmd = ChatService.extractShellCommand(from: "Run `npm install`")
        XCTAssertEqual(cmd, "npm install")
    }

    func testExtractShellCommand_quoted() {
        let cmd = ChatService.extractShellCommand(from: "Execute \"git push origin main\"")
        XCTAssertEqual(cmd, "git push origin main")
    }

    func testExtractShellCommand_nilForNoCommand() {
        let cmd = ChatService.extractShellCommand(from: "Run the tests please")
        XCTAssertNil(cmd)
    }

    // MARK: - extractWebSearchQuery

    func testExtractWebSearchQuery_stripsContinuationClauses() {
        let query = ChatService.extractWebSearchQuery(
            from: "Find me information about Swift concurrency and then summarize it"
        )

        XCTAssertEqual(query, "Swift concurrency")
    }

    func testExtractWebSearchQuery_fallsBackToWholeMessageWhenNoTrigger() {
        let query = ChatService.extractWebSearchQuery(
            from: "Latest news about Foundation models"
        )

        XCTAssertEqual(query, "Latest news about Foundation models")
    }
}
