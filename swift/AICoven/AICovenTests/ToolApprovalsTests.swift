@testable import AICoven
import XCTest

/// Approvals: a tool that changes something asks first and waits; the
/// person's answer, or the turn stopping, ends the wait.
@MainActor
final class ToolApprovalsTests: XCTestCase {
    /// What the approvals were told to do later, run by hand.
    private var scheduled: [@MainActor () -> Void] = []

    private func makeApprovals() -> ToolApprovals {
        ToolApprovals { [weak self] _, action in self?.scheduled.append(action) }
    }

    /// Runs what is due, then what that scheduled, until nothing is left.
    private func runScheduled() {
        while !scheduled.isEmpty {
            scheduled.removeFirst()()
        }
    }

    private func approval(in thread: String = "thread-1", _ question: String = "Run this command?") -> ToolApproval {
        ToolApproval(threadID: thread, question: question, details: "git push\nIn /tmp", toolName: "shell.execute")
    }

    /// Waits until the approvals have `count` asked and not yet answered.
    private func asked(_ approvals: ToolApprovals, _ count: Int) async {
        while (approvals.showing?.phase == .asking ? 1 : 0) + approvals.waiting.count < count {
            await Task.yield()
        }
    }

    // MARK: - The queue

    func testAnApproval_showsWaitsForItsAnswerAndSaysWhatWasChosen() async {
        let approvals = makeApprovals()
        let first = approval()
        let asking = Task { await approvals.ask(first) }
        await asked(approvals, 1)

        XCTAssertEqual(approvals.showing, .init(approval: first, phase: .asking))
        XCTAssertEqual(approvals.askingThreadIDs, ["thread-1"])

        approvals.answer(first.id, approve: true)
        let approved = await asking.value

        XCTAssertTrue(approved)
        XCTAssertEqual(approvals.showing?.phase, .answered(.approved))
        XCTAssertEqual(approvals.askingThreadIDs, [])
        runScheduled()
        XCTAssertNil(approvals.showing)
    }

    func testADeniedApproval_isRefused() async {
        let approvals = makeApprovals()
        let first = approval()
        let asking = Task { await approvals.ask(first) }
        await asked(approvals, 1)

        approvals.answer(first.id, approve: false)
        let approved = await asking.value

        XCTAssertFalse(approved)
        XCTAssertEqual(approvals.showing?.phase, .answered(.denied))
    }

    func testApprovals_showOneAtATimeInTheOrderAskedAndTheNextCanBeBroughtForward() async {
        let approvals = makeApprovals()
        let first = approval(in: "thread-1", "First?")
        let second = approval(in: "thread-2", "Second?")
        let third = approval(in: "thread-3", "Third?")
        let askingFirst = Task { await approvals.ask(first) }
        await asked(approvals, 1)
        let askingSecond = Task { await approvals.ask(second) }
        await asked(approvals, 2)
        let askingThird = Task { await approvals.ask(third) }
        await asked(approvals, 3)

        XCTAssertEqual(approvals.showing?.approval, first)
        XCTAssertEqual(approvals.waiting, [second, third])
        XCTAssertEqual(approvals.askingThreadIDs, ["thread-1", "thread-2", "thread-3"])

        // Only the one showing can be answered.
        approvals.answer(second.id, approve: true)
        XCTAssertEqual(approvals.waiting, [second, third])

        approvals.showNext()
        XCTAssertEqual(approvals.showing?.approval, second)
        XCTAssertEqual(approvals.waiting, [third, first])

        approvals.answer(second.id, approve: true)
        runScheduled()
        XCTAssertEqual(approvals.showing, .init(approval: third, phase: .asking))
        XCTAssertEqual(approvals.askingThreadIDs, ["thread-1", "thread-3"])

        approvals.answer(third.id, approve: false)
        runScheduled()
        approvals.answer(first.id, approve: true)
        runScheduled()

        let answers = await [askingFirst.value, askingSecond.value, askingThird.value]
        XCTAssertEqual(answers, [true, true, false])
        XCTAssertNil(approvals.showing)
    }

    func testAnAnsweredApproval_takesNoSecondAnswer() async {
        let approvals = makeApprovals()
        let first = approval()
        let asking = Task { await approvals.ask(first) }
        await asked(approvals, 1)

        approvals.answer(first.id, approve: false)
        approvals.answer(first.id, approve: true)
        let approved = await asking.value

        XCTAssertFalse(approved)
        XCTAssertEqual(approvals.showing?.phase, .answered(.denied))
    }

    // MARK: - A turn that stops

    func testAnApprovalWhoseTurnStops_isRefusedAndSaysItIsNoLongerWaiting() async {
        let approvals = makeApprovals()
        let first = approval(in: "thread-1")
        let second = approval(in: "thread-2")
        let askingFirst = Task { await approvals.ask(first) }
        await asked(approvals, 1)
        let askingSecond = Task { await approvals.ask(second) }
        await asked(approvals, 2)

        // The one waiting behind leaves without being shown.
        askingSecond.cancel()
        let secondApproved = await askingSecond.value
        XCTAssertFalse(secondApproved)
        XCTAssertEqual(approvals.waiting, [])
        XCTAssertEqual(approvals.showing, .init(approval: first, phase: .asking))

        // The one showing says so, and can no longer be approved.
        askingFirst.cancel()
        let firstApproved = await askingFirst.value
        XCTAssertFalse(firstApproved)
        XCTAssertEqual(approvals.showing?.phase, .answered(.noLongerWaiting))
        XCTAssertEqual(approvals.askingThreadIDs, [])
        approvals.answer(first.id, approve: true)
        XCTAssertEqual(approvals.showing?.phase, .answered(.noLongerWaiting))
        runScheduled()
        XCTAssertNil(approvals.showing)
    }

    func testAnApprovalAskedByAStoppedTurn_isRefusedWithoutBeingShown() async {
        let approvals = makeApprovals()
        let asking = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await approvals.ask(self.approval())
        }

        let approved = await asking.value

        XCTAssertFalse(approved)
        XCTAssertNil(approvals.showing)
        XCTAssertEqual(approvals.askingThreadIDs, [])
    }

    // MARK: - The tools that ask

    func testWritingAFile_asksWithItsFullPathAndWritesOnlyWhenApproved() async throws {
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("approvals-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notes.txt")
        let call = ParsedToolCall(name: "file.write", args: ["path": AnyJSONValue(file.path), "content": AnyJSONValue("Hello")])
        let asked = Asked()

        let denying = ToolExecutionService(toolService: ToolService.shared) { approval in
            await asked.note(approval)
            return false
        }
        await denying.setWhitelist(for: "chat", tools: ["file.write"])
        let denied = await denying.execute(toolCall: call, agentType: "chat", threadID: "thread-1")

        XCTAssertEqual(denied.status, "denied")
        XCTAssertEqual(denied.errorType, "user_denied")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "Nothing is written or created before the answer")
        let first = await asked.all.first
        XCTAssertEqual(first?.threadID, "thread-1")
        XCTAssertEqual(first?.question, "Write this file?")
        XCTAssertEqual(first?.details.hasPrefix(file.path), true)
        XCTAssertEqual(first?.details.hasSuffix("Hello"), true)

        let approving = ToolExecutionService(toolService: ToolService.shared) { approval in
            await asked.note(approval)
            return true
        }
        await approving.setWhitelist(for: "chat", tools: ["file.write"])
        let written = await approving.execute(toolCall: call, agentType: "chat", threadID: "thread-1")
        XCTAssertEqual(written.status, "ok")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Hello")

        // Writing it again replaces it, and the approval says so.
        _ = await approving.execute(toolCall: call, agentType: "chat", threadID: "thread-1")
        let last = await asked.all.last
        XCTAssertEqual(last?.question, "Replace this file?")
    }

    func testAWriteWithNoThreadToAskIn_isRefusedWithoutAsking() async {
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("approvals-\(UUID().uuidString)")
        let call = ParsedToolCall(
            name: "file.write",
            args: ["path": AnyJSONValue(folder.appendingPathComponent("notes.txt").path), "content": AnyJSONValue("Hello")]
        )
        let asked = Asked()
        let service = ToolExecutionService(toolService: ToolService.shared) { approval in
            await asked.note(approval)
            return true
        }
        await service.setWhitelist(for: "chat", tools: ["file.write"])

        let result = await service.execute(toolCall: call, agentType: "chat", threadID: nil)

        XCTAssertEqual(result.errorType, "user_denied")
        let all = await asked.all
        XCTAssertEqual(all, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    #if os(macOS)
    func testAShellCommand_asksWithTheCommandAndItsDirectoryAndRunsOnlyWhenApproved() async throws {
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("approvals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let made = folder.appendingPathComponent("made.txt")
        let asked = Asked()

        let denied = await ShellToolService.shared.execute(command: "touch made.txt", workingDir: folder.path) { command, directory in
            await asked.note(.shell(command: command, directory: directory, threadID: "thread-1"))
            return false
        }

        XCTAssertEqual(denied.errorType, "user_denied")
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.path))
        let first = await asked.all.first
        XCTAssertEqual(first?.details.hasPrefix("touch made.txt\nIn "), true)

        let ran = await ShellToolService.shared.execute(command: "touch made.txt", workingDir: folder.path) { _, _ in true }
        XCTAssertEqual(ran.status, "ok")
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.path))
    }
    #endif

    func testOnlyAFewCommandsThatReadRunWithoutAsking() {
        for command in ["pwd", "whoami", "date", "git status", "git status --short", "git branch --show-current", " git remote -v "] {
            XCTAssertTrue(ShellToolService.isReadOnly(command), command)
        }
        for command in [
            "ls", "cat notes.txt", "git push", "git status; rm -rf build", "pwd && touch x", "date > out.txt",
            "git status /etc", "git branch -D main", "pwd | sh", "whoami `id`", "date $(touch x)", "pwd\nrm x", "sudo pwd",
        ] {
            XCTAssertFalse(ShellToolService.isReadOnly(command), command)
        }
    }

    // MARK: - What an approval says

    func testAnApproval_saysExactlyWhatWillHappen() {
        let long = String(repeating: "a", count: ToolApproval.shownTextLimit + 5)

        let commit = ToolApproval.gitHubWriteFile(
            owner: "octo", repo: "site", path: "README.md", branch: nil, message: "Update", content: long, threadID: "t"
        )
        XCTAssertEqual(commit.question, "Commit this file to GitHub?")
        XCTAssertTrue(commit.details.hasPrefix("README.md in octo/site, on the default branch\nCommit message: Update\n"))
        XCTAssertTrue(commit.details.hasSuffix("… and 5 more characters"), "A long file shows its start and how much more there is")

        let branch = ToolApproval.gitHubCreateBranch(owner: "octo", repo: "site", newBranch: "fix", baseBranch: "main", threadID: "t")
        XCTAssertEqual(branch.details, "fix in octo/site\nFrom main")

        let pull = ToolApproval.gitHubCreatePR(owner: "octo", repo: "site", title: "Fix it", head: "fix", base: "main", body: "Why", threadID: "t")
        XCTAssertEqual(pull.details, "Fix it\nfix into main in octo/site\n\nWhy")

        let upload = ToolApproval.driveUpload(name: "plan.txt", mimeType: "text/plain", content: "Plan", threadID: "t")
        XCTAssertEqual(upload.question, "Upload this file to Google Drive?")
        XCTAssertTrue(upload.details.hasPrefix("plan.txt\ntext/plain · "))

        let sheet = ToolApproval.sheetsWrite(spreadsheetID: "abc", range: "A1:B2", values: [["1", "2"], ["3", "4"]], threadID: "t")
        XCTAssertEqual(sheet.details, "A1:B2 in spreadsheet abc\n2 rows\n\n1\t2\n3\t4")
    }
}

/// The approvals a test's tools asked for.
private actor Asked {
    private(set) var all: [ToolApproval] = []

    func note(_ approval: ToolApproval) {
        all.append(approval)
    }
}
