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
    private func asked(_ approvals: ToolApprovals, _ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0 ..< 10000 {
            if (approvals.showing?.phase == .asking ? 1 : 0) + approvals.waiting.count >= count { return }
            await Task.yield()
        }
        XCTFail("The approval was never asked", file: file, line: line)
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
        let answer = await asking.value

        XCTAssertEqual(answer, .approved)
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
        let answer = await asking.value

        XCTAssertEqual(answer, .denied)
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
        XCTAssertEqual(answers, [.approved, .approved, .denied])
        XCTAssertNil(approvals.showing)
    }

    func testAnAnsweredApproval_takesNoSecondAnswer() async {
        let approvals = makeApprovals()
        let first = approval()
        let asking = Task { await approvals.ask(first) }
        await asked(approvals, 1)

        approvals.answer(first.id, approve: false)
        approvals.answer(first.id, approve: true)
        let answer = await asking.value

        XCTAssertEqual(answer, .denied)
        XCTAssertEqual(approvals.showing?.phase, .answered(.denied))
    }

    // MARK: - What a turn keeps

    func testAnswers_areHeldForTheirThreadInOrderUntilItsTurnTakesThem() async {
        let approvals = makeApprovals()
        let first = ToolApproval(threadID: "thread-1", question: "Run this command?", details: "git push\nIn /tmp", toolName: "shell.execute")
        let second = ToolApproval(threadID: "thread-1", question: "Write this file?", details: "/tmp/notes.txt\nA new file", toolName: "file.write")
        let other = approval(in: "thread-2")
        let asking = [first, second, other].map { approval in Task { await approvals.ask(approval) } }
        await asked(approvals, 3)

        approvals.answer(first.id, approve: true)
        runScheduled()
        approvals.answer(second.id, approve: false)
        runScheduled()
        // The other thread's turn stops: nothing was answered, so nothing is kept.
        asking[2].cancel()
        for task in asking {
            _ = await task.value
        }

        XCTAssertEqual(approvals.answered["thread-1"], [
            WorkTrace.Approval(id: first.id, subject: "git push", approved: true),
            WorkTrace.Approval(id: second.id, subject: "/tmp/notes.txt", approved: false),
        ])
        XCTAssertNil(approvals.answered["thread-2"])
        approvals.forgetAnswers(threadID: "thread-1")
        XCTAssertNil(approvals.answered["thread-1"])
    }

    func testTheSubjectOfAnApproval_isItsFirstLineWhateverEndsTheLine() {
        let windows = ToolApproval.shell(command: "echo one\r\necho two", directory: "/tmp", threadID: "t")
        XCTAssertEqual(windows.subject, "echo one")
        let none = ToolApproval(threadID: "t", question: "Run this command?", details: "", toolName: "shell.execute")
        XCTAssertEqual(none.subject, "Run this command?")
        let long = ToolApproval.shell(command: String(repeating: "a", count: ToolApproval.subjectLimit + 50), directory: "/tmp", threadID: "t")
        XCTAssertEqual(long.subject, String(repeating: "a", count: ToolApproval.subjectLimit) + "…")
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
        let secondAnswer = await askingSecond.value
        XCTAssertEqual(secondAnswer, .withdrawn)
        XCTAssertEqual(approvals.waiting, [])
        XCTAssertEqual(approvals.showing, .init(approval: first, phase: .asking))

        // The one showing says so, and can no longer be approved.
        askingFirst.cancel()
        let firstAnswer = await askingFirst.value
        XCTAssertEqual(firstAnswer, .withdrawn)
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

        let answer = await asking.value

        XCTAssertEqual(answer, .withdrawn)
        XCTAssertNil(approvals.showing)
        XCTAssertEqual(approvals.askingThreadIDs, [])
    }

    func testApprovePressedAsTheTurnStops_doesNotLetTheToolRun() async {
        let approvals = makeApprovals()
        let first = approval()
        let asking = Task { await approvals.ask(first) }
        await asked(approvals, 1)

        // Stop, then Approve before the stop has reached the approval.
        asking.cancel()
        approvals.answer(first.id, approve: true)
        XCTAssertEqual(approvals.showing?.phase, .answered(.approved))
        let answer = await asking.value

        XCTAssertEqual(answer, .withdrawn)
        XCTAssertNil(approvals.answered["thread-1"], "An answer the turn did not take leaves no line")
        XCTAssertEqual(approvals.showing?.phase, .answered(.noLongerWaiting), "The block says what in fact happened")
        runScheduled()
        XCTAssertNil(approvals.showing)
    }

    // MARK: - Announcements

    func testAnApproval_isAnnouncedOnceWhenAScreenShowsItAndNotAgainWhenItComesBack() async {
        let approvals = makeApprovals()
        let first = approval(in: "thread-1", "First?")
        let second = approval(in: "thread-2", "Second?")
        let asking = [first, second].map { approval in Task { await approvals.ask(approval) } }
        await asked(approvals, 2)

        XCTAssertFalse(approvals.announceShowing(second.id), "Only the one on screen is announced")
        XCTAssertTrue(approvals.announceShowing(first.id))
        XCTAssertFalse(approvals.announceShowing(first.id), "A second window showing it says nothing")
        approvals.showNext()
        XCTAssertTrue(approvals.announceShowing(second.id))
        approvals.showNext()
        XCTAssertFalse(approvals.announceShowing(first.id), "Brought back to the front, it is not said again")

        approvals.answer(first.id, approve: true)
        XCTAssertFalse(approvals.announceShowing(first.id), "An answered approval is not asked aloud")
        runScheduled()
        approvals.answer(second.id, approve: false)
        for task in asking {
            _ = await task.value
        }
    }

    // MARK: - The tools that ask

    // Writing files is tested on the Mac: on the iPhone a test has no
    // folder the person has granted.
    #if os(macOS)
    func testWritingAFile_asksWithItsFullPathAndWritesOnlyWhenApproved() async throws {
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("approvals-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notes.txt")
        let call = ParsedToolCall(name: "file.write", args: ["path": AnyJSONValue(file.path), "content": AnyJSONValue("Hello")])
        let asked = Asked()

        let denying = ToolExecutionService(toolService: ToolService.shared) { approval in
            await asked.note(approval)
            return .denied
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
            return .approved
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

    func testAFileThatAppearsWhileThePersonIsAsked_isNotReplacedByAnApprovalOfANewFile() async throws {
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("approvals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notes.txt")
        let call = ParsedToolCall(name: "file.write", args: ["path": AnyJSONValue(file.path), "content": AnyJSONValue("Second")])
        let service = ToolExecutionService(toolService: ToolService.shared) { approval in
            XCTAssertEqual(approval.question, "Write this file?")
            // Another turn writes the same path while this one waits.
            try? Data("First".utf8).write(to: file)
            return .approved
        }
        await service.setWhitelist(for: "chat", tools: ["file.write"])

        let result = await service.execute(toolCall: call, agentType: "chat", threadID: "thread-1")

        XCTAssertEqual(result.errorType, "file_appeared")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "First")
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
            return .approved
        }
        await service.setWhitelist(for: "chat", tools: ["file.write"])

        let result = await service.execute(toolCall: call, agentType: "chat", threadID: nil)

        XCTAssertEqual(result.status, "denied")
        XCTAssertEqual(result.errorType, "permission_denied", "The model is not told the person said no when no one was asked")
        let all = await asked.all
        XCTAssertEqual(all, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testAShellCommand_asksWithTheCommandAndItsDirectoryAndRunsOnlyWhenApproved() async throws {
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("approvals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let made = folder.appendingPathComponent("made.txt")
        let asked = Asked()

        let denied = await ShellToolService.shared.execute(command: "touch made.txt", workingDir: folder.path) { command, directory in
            await asked.note(.shell(command: command, directory: directory, threadID: "thread-1"))
            return .denied
        }

        XCTAssertEqual(denied.errorType, "user_denied")
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.path))
        let first = await asked.all.first
        XCTAssertEqual(first?.details.hasPrefix("touch made.txt\nIn "), true)

        let ran = await ShellToolService.shared.execute(command: "touch made.txt", workingDir: folder.path) { _, _ in .approved }
        XCTAssertEqual(ran.status, "ok")
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.path))

        // A turn stopped while it waited is told so, not that the person said no.
        let stopped = await ShellToolService.shared.execute(command: "touch other.txt", workingDir: folder.path) { _, _ in .withdrawn }
        XCTAssertEqual(stopped.errorType, "approval_withdrawn")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("other.txt").path))
    }
    #endif

    func testAnApprovalWhoseThreadCannotBeNamed_isNotAsked() async {
        let answer = await ToolExecutionService.askInItsThread(approval(in: "no-such-thread-\(UUID().uuidString)"))

        XCTAssertEqual(answer, .notAsked)
        XCTAssertNil(ToolApprovals.shared.showing)
    }

    func testOnlyAFewCommandsThatReadRunWithoutAsking() {
        for command in ["pwd", "whoami", "date", "git status", "git status --short", "git branch --show-current", " git remote -v "] {
            XCTAssertTrue(ShellToolService.isReadOnly(command), command)
        }
        for command in [
            "ls", "cat notes.txt", "git push", "git status; rm -rf build", "pwd && touch x", "date > out.txt",
            "git status /etc", "git branch -D main", "pwd | sh", "whoami `id`", "date $(touch x)", "pwd\nrm x", "sudo pwd",
            "pwd\n", "\npwd", "git status\r\n",
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
