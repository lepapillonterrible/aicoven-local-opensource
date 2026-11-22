@testable import AICoven
internal import Combine
import XCTest

/// Approvals: a tool that changes something asks first and waits; the
/// person's answer, or the turn stopping, ends the wait.
@MainActor
final class ToolApprovalsTests: XCTestCase {
    /// What the approvals were told to do later, run by hand.
    private var scheduled: [@MainActor () -> Void] = []

    /// The time, as the approvals are told it.
    private var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// How long each thing scheduled was asked to wait.
    private var delays: [TimeInterval] = []

    private func makeApprovals() -> ToolApprovals {
        ToolApprovals(holdInterval: 3, now: { [unowned self] in clock }, schedule: { [weak self] delay, action in
            self?.delays.append(delay)
            self?.scheduled.append(action)
        })
    }

    /// Waits until the approvals hold `count` back from the screen.
    private func held(_ approvals: ToolApprovals, _ count: Int) async {
        let reached = expectation(description: "\(count) held back")
        reached.assertForOverFulfill = false
        let watching = approvals.$held.sink { held in
            if held.count >= count { reached.fulfill() }
        }
        await fulfillment(of: [reached], timeout: 10)
        watching.cancel()
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

    // MARK: - Another account

    func testWhenAnotherAccountSignsIn_everythingAskedLeavesUnanswered_andCannotBeAnswered() async {
        let approvals = makeApprovals()
        let first = approval(in: "thread-1"), second = approval(in: "thread-2", "Write this file?")
        let asking = Task { await approvals.ask(first) }
        await asked(approvals, 1)
        let askingToo = Task { await approvals.ask(second) }
        await asked(approvals, 2)
        // A third is held back while the person composes.
        approvals.composerFocusChanged(true)
        approvals.noteComposerChanged()
        let third = approval(in: "thread-3", "Create this branch?")
        let askingHeld = Task { await approvals.ask(third) }
        await held(approvals, 1)
        XCTAssertEqual(approvals.askingThreadIDs, ["thread-1", "thread-2", "thread-3"])

        approvals.accountChanged()

        XCTAssertNil(approvals.showing, "Whoever is signed in next is shown nothing of it")
        XCTAssertEqual(approvals.waiting, [])
        XCTAssertEqual(approvals.held, [])
        XCTAssertEqual(approvals.askingThreadIDs, [])
        let answers = await [asking.value, askingToo.value, askingHeld.value]
        XCTAssertEqual(answers, [.withdrawn, .withdrawn, .withdrawn], "The turns that asked are told it was withdrawn: none is approved")
        // Nor can it be answered afterwards, or come back when what was scheduled runs.
        approvals.answer(first.id, approve: true)
        approvals.composerFocusChanged(false)
        runScheduled()
        XCTAssertNil(approvals.showing)
        XCTAssertEqual(approvals.answered, [:])
    }

    func testAnAnswerGivenJustBeforeAnotherAccountSignsIn_isNotTaken_norKept() async {
        let approvals = makeApprovals()
        let first = approval(in: "thread-1")
        let asking = Task { await approvals.ask(first) }
        await asked(approvals, 1)

        // Approve is pressed, and the account changes before the turn that asked has heard of it.
        approvals.answer(first.id, approve: true)
        approvals.accountChanged()
        let answer = await asking.value

        XCTAssertEqual(answer, .withdrawn, "What was approved is not done for an account that is gone")
        XCTAssertEqual(approvals.answered, [:], "Nor is a line of it kept among the next account's")
        XCTAssertNil(approvals.showing)
        XCTAssertEqual(approvals.askingThreadIDs, [])
    }

    // MARK: - Not while typing

    func testAnApprovalAskedWhileThePersonIsTyping_isHeldUntilTheyPause() async {
        let approvals = makeApprovals()
        approvals.composerFocusChanged(true)
        approvals.noteComposerChanged()
        XCTAssertTrue(approvals.isComposing)

        let first = approval()
        let asking = Task { await approvals.ask(first) }
        await held(approvals, 1)

        XCTAssertNil(approvals.showing, "Nothing comes up under what is being typed")
        XCTAssertEqual(approvals.waiting, [])
        XCTAssertEqual(approvals.askingThreadIDs, ["thread-1"], "The thread still says it needs an answer")
        XCTAssertFalse(approvals.announceShowing(first.id), "Nor is it announced before it shows")
        XCTAssertEqual(delays, [3], "It looks again when the pause would be long enough")

        // Still typing when that comes: it looks again later.
        clock += 2
        approvals.noteComposerChanged()
        clock += 1
        scheduled.removeFirst()()
        XCTAssertNil(approvals.showing)
        XCTAssertEqual(delays, [3, 2])

        // Three seconds with nothing typed: it comes in.
        clock += 2
        scheduled.removeFirst()()
        XCTAssertEqual(approvals.showing, .init(approval: first, phase: .asking))
        XCTAssertEqual(approvals.held, [])
        XCTAssertFalse(approvals.isComposing)

        approvals.answer(first.id, approve: true)
        let answer = await asking.value
        XCTAssertEqual(answer, .approved)
    }

    func testWhatIsHeld_comesInWhenThePersonSendsOrLeavesTheField() async {
        // Sending lets it in.
        let sending = makeApprovals()
        sending.composerFocusChanged(true)
        sending.noteComposerChanged()
        let first = approval()
        let second = approval(in: "thread-2", "Write this file?")
        let askingFirst = Task { await sending.ask(first) }
        await held(sending, 1)
        let askingSecond = Task { await sending.ask(second) }
        await held(sending, 2)

        sending.noteSent()
        XCTAssertEqual(sending.showing?.approval, first, "In the order they were asked")
        XCTAssertEqual(sending.waiting, [second])
        XCTAssertEqual(sending.held, [])
        XCTAssertFalse(sending.isComposing, "A message sent is not one being typed")
        sending.answer(first.id, approve: false)
        _ = await askingFirst.value
        askingSecond.cancel()
        _ = await askingSecond.value

        // So does leaving the field.
        let leaving = makeApprovals()
        leaving.composerFocusChanged(true)
        leaving.noteComposerChanged()
        let third = approval()
        let askingThird = Task { await leaving.ask(third) }
        await held(leaving, 1)
        leaving.composerFocusChanged(false)
        XCTAssertEqual(leaving.showing?.approval, third)
        askingThird.cancel()
        _ = await askingThird.value
    }

    func testWithTheOnScreenKeyboardUp_approvalsAreHeldUntilItGoesDownOrAMessageIsSent() async {
        let approvals = makeApprovals()
        approvals.keyboardVisibilityChanged(true)
        XCTAssertTrue(approvals.isComposing, "Whether or not anything was typed")
        let first = approval()
        let asking = Task { await approvals.ask(first) }
        await held(approvals, 1)
        XCTAssertEqual(delays, [], "Nothing to look again for: the keyboard going down says so itself")

        clock += 60
        XCTAssertNil(approvals.showing)
        approvals.keyboardVisibilityChanged(false)
        XCTAssertEqual(approvals.showing?.approval, first)
        approvals.answer(first.id, approve: false)
        _ = await asking.value

        // Sent with the keyboard still up: what was held comes in, and the
        // next one asked is held again.
        approvals.keyboardVisibilityChanged(true)
        let second = approval(in: "thread-2")
        let askingSecond = Task { await approvals.ask(second) }
        await held(approvals, 1)
        approvals.noteSent()
        XCTAssertEqual(approvals.held, [])
        XCTAssertTrue(([approvals.showing?.approval].compactMap(\.self) + approvals.waiting).contains(second))
        askingSecond.cancel()
        _ = await askingSecond.value
    }

    func testAnApprovalHeld_leavesUnseenWhenItsTurnStops() async {
        let approvals = makeApprovals()
        approvals.composerFocusChanged(true)
        approvals.noteComposerChanged()
        let first = approval()
        let asking = Task { await approvals.ask(first) }
        await held(approvals, 1)

        asking.cancel()
        let answer = await asking.value

        XCTAssertEqual(answer, .withdrawn)
        XCTAssertEqual(approvals.held, [])
        XCTAssertEqual(approvals.askingThreadIDs, [])
        XCTAssertNil(approvals.showing, "It was never shown, and says nothing on leaving")
        // The pause it was waiting for finds nothing to let in.
        clock += 5
        runScheduled()
        XCTAssertNil(approvals.showing)
    }

    func testAnApprovalHeldWhoseTurnHasJustStopped_isNotShownByWhatLetsHeldOnesIn() async {
        // By a message being sent.
        let sending = makeApprovals()
        sending.composerFocusChanged(true)
        sending.noteComposerChanged()
        let first = approval()
        let asking = Task { await sending.ask(first) }
        await held(sending, 1)
        // The turn stops, and before the queue has been told, a message is
        // sent: nothing of the stopped turn comes up.
        asking.cancel()
        sending.noteSent()
        XCTAssertNil(sending.showing)
        XCTAssertEqual(sending.waiting, [])
        XCTAssertFalse(sending.announceShowing(first.id))
        let answer = await asking.value
        XCTAssertEqual(answer, .withdrawn)
        XCTAssertNil(sending.showing)
        XCTAssertEqual(sending.askingThreadIDs, [])

        // By the field being left, with another still to come in.
        let leaving = makeApprovals()
        leaving.composerFocusChanged(true)
        leaving.noteComposerChanged()
        let stoppedOne = approval()
        let other = approval(in: "thread-2", "Write this file?")
        let askingStopped = Task { await leaving.ask(stoppedOne) }
        await held(leaving, 1)
        let askingOther = Task { await leaving.ask(other) }
        await held(leaving, 2)
        askingStopped.cancel()
        leaving.composerFocusChanged(false)
        XCTAssertEqual(leaving.showing?.approval, other, "The one whose turn goes on comes in")
        XCTAssertEqual(leaving.waiting, [])
        _ = await askingStopped.value
        askingOther.cancel()
        _ = await askingOther.value
    }

    func testAWaitingApprovalWhoseTurnHasJustStopped_isNotTheNextOneShown() async {
        let approvals = makeApprovals()
        let first = approval()
        let second = approval(in: "thread-2", "Write this file?")
        let third = approval(in: "thread-3", "Create this branch?")
        let askingFirst = Task { await approvals.ask(first) }
        await asked(approvals, 1)
        let askingSecond = Task { await approvals.ask(second) }
        await asked(approvals, 2)
        let askingThird = Task { await approvals.ask(third) }
        await asked(approvals, 3)

        // The second's turn stops, and before the queue has been told, the
        // person asks for the next one: it is the third.
        askingSecond.cancel()
        approvals.showNext()
        XCTAssertEqual(approvals.showing?.approval, third)
        XCTAssertEqual(approvals.waiting, [first])
        _ = await askingSecond.value

        // And when the one showing is answered, the stopped one is not next.
        let stopping = makeApprovals()
        let shown = approval()
        let stoppedOne = approval(in: "thread-2")
        let askingShown = Task { await stopping.ask(shown) }
        await asked(stopping, 1)
        let askingStopped = Task { await stopping.ask(stoppedOne) }
        await asked(stopping, 2)
        askingStopped.cancel()
        stopping.answer(shown.id, approve: false)
        runScheduled()
        XCTAssertNil(stopping.showing)
        _ = await askingShown.value
        _ = await askingStopped.value
        for task in [askingFirst, askingThird] {
            task.cancel()
            _ = await task.value
        }
    }

    func testFocusWithoutTyping_orTypingLongAgo_holdsNothingBack() async {
        let approvals = makeApprovals()
        approvals.composerFocusChanged(true)
        XCTAssertFalse(approvals.isComposing, "The field has focus most of the time: that alone is not composing")
        approvals.noteComposerChanged()
        clock += 3
        XCTAssertFalse(approvals.isComposing)
        // Typed in a field that does not have focus (text put there, not typed).
        approvals.composerFocusChanged(false)
        approvals.noteComposerChanged()
        XCTAssertFalse(approvals.isComposing)

        let first = approval()
        let asking = Task { await approvals.ask(first) }
        await asked(approvals, 1)
        XCTAssertEqual(approvals.showing?.approval, first)
        asking.cancel()
        _ = await asking.value
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

    func testAQuestionAskedOnceItsTurnHasEnded_marksNoThreadAsWaiting_andLeavesNoLineOfATurn() async {
        let approvals = makeApprovals()
        let question = ToolApproval.memory("Ships on Fridays", forACoven: true, threadID: "thread-1")
        XCTAssertEqual(question.question, "Remember this for the coven?")
        XCTAssertEqual(ToolApproval.memory("Lives in Lisbon", forACoven: false, threadID: "thread-1").question, "Remember this about you?")
        XCTAssertEqual(
            ToolApproval.memory("Lives in Lisbon", forACoven: false, threadID: "thread-1", afterAFailedAnswer: true).question,
            "Couldn't confirm your answer. Remember this about you?"
        )

        let asking = Task { await approvals.ask(question) }
        await asked(approvals, 1)
        XCTAssertEqual(approvals.showing, .init(approval: question, phase: .asking), "It is asked in the one spot, like any approval")
        XCTAssertEqual(approvals.askingThreadIDs, [], "No turn of the thread waits on it")

        // A turn's approval asked meanwhile marks its thread, and still does once the question is answered.
        let ofATurn = approval(in: "thread-2")
        let turn = Task { await approvals.ask(ofATurn) }
        await asked(approvals, 2)
        XCTAssertEqual(approvals.askingThreadIDs, ["thread-2"])
        approvals.answer(question.id, approve: true)
        let answer = await asking.value
        XCTAssertEqual(answer, .approved)
        XCTAssertEqual(approvals.askingThreadIDs, ["thread-2"])
        XCTAssertNil(approvals.answered["thread-1"], "Its answer is no line of a turn's")

        runScheduled()
        approvals.answer(ofATurn.id, approve: false)
        _ = await turn.value
        XCTAssertEqual(approvals.answered["thread-2"]?.count, 1)
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
            owner: "octo", repo: "site", path: "README.md", branch: nil, message: "Update", content: long, replaces: true, threadID: "t"
        )
        XCTAssertEqual(commit.question, "Commit this file to GitHub?")
        XCTAssertTrue(commit.details.hasPrefix("README.md in octo/site, on the default branch\nCommit message: Update\nReplaces the file that is there · "))
        let new = ToolApproval.gitHubWriteFile(owner: "octo", repo: "site", path: "NEW.md", branch: "docs", message: "Add", content: "hi", replaces: false, threadID: "t")
        XCTAssertTrue(new.details.hasPrefix("NEW.md in octo/site, on docs\nCommit message: Add\nA new file · "))
        XCTAssertTrue(commit.details.hasSuffix("… and 5 more characters"), "A long file shows its start and how much more there is")

        let branch = ToolApproval.gitHubCreateBranch(owner: "octo", repo: "site", newBranch: "fix", baseBranch: "main", threadID: "t")
        XCTAssertEqual(branch.details, "fix in octo/site\nFrom main")

        let pull = ToolApproval.gitHubCreatePR(owner: "octo", repo: "site", title: "Fix it", head: "fix", base: "main", body: "Why", threadID: "t")
        XCTAssertEqual(pull.details, "Fix it\nfix into main in octo/site\n\nWhy")

        let upload = ToolApproval.driveUpload(name: "plan.txt", mimeType: "text/plain", content: "Plan", threadID: "t")
        XCTAssertEqual(upload.question, "Upload this file to Google Drive?")
        XCTAssertTrue(upload.details.hasPrefix("plan.txt\ntext/plain · "))

        let sheet = ToolApproval.sheetsWrite(spreadsheetID: "abc", range: "A1:B2", values: [["1", "2"], ["3", "4"]], threadID: "t")
        XCTAssertEqual(sheet.details, "A1:B2 in spreadsheet abc\n2 rows, entered as if typed (formulas are worked out)\n\n1\t2\n3\t4")
        XCTAssertEqual(sheet.toolName, "google_sheets.updateValues")
        let raw = ToolApproval.sheetsWrite(spreadsheetID: "abc", range: "A1", values: [["=1+1"]], asTyped: false, threadID: "t")
        XCTAssertEqual(raw.details, "A1 in spreadsheet abc\n1 row, entered exactly as written\n\n=1+1")

        let inFolders = ToolApproval.driveUpload(name: "plan.txt", mimeType: "text/plain", content: "Plan", folders: ["f1", "f2"], threadID: "t")
        XCTAssertTrue(inFolders.details.hasPrefix("plan.txt\nIn folders f1, f2\ntext/plain · "))

        let added = ToolApproval.docsAddText(documentID: "doc1", text: "Next steps", index: nil, threadID: "t")
        XCTAssertEqual(added.question, "Add this text to the Google Doc?")
        XCTAssertTrue(added.details.hasPrefix("Document doc1\nAt the end · "))
        XCTAssertTrue(added.details.hasSuffix("\n\nNext steps"))
        XCTAssertTrue(ToolApproval.docsAddText(documentID: "doc1", text: "x", index: 5, threadID: "t").details.hasPrefix("Document doc1\nAt position 5 · "))

        let changes = ToolApproval.googleRequests(.presentation, id: "deck1", requests: [["createSlide": .dictionary([:])], ["deleteObject": .dictionary(["objectId": .string("p2")])]], threadID: "t")
        XCTAssertEqual(changes.question, "Change this Google Slides presentation?")
        XCTAssertEqual(changes.toolName, "google_slides.update")
        XCTAssertTrue(changes.details.hasPrefix("Presentation deck1\n2 changes, as Google is asked to make them:\n\n["))
        XCTAssertTrue(changes.details.contains("\"objectId\" : \"p2\""), "The requests are shown as they will be sent")
        let one = ToolApproval.googleRequests(.spreadsheet, id: "s1", requests: [["addSheet": .dictionary([:])]], threadID: "t")
        XCTAssertTrue(one.details.hasPrefix("Spreadsheet s1\n1 change, as Google is asked to make it:\n\n"))
        XCTAssertEqual(ToolApproval.googleRequests(.document, id: "d", requests: [["x": .null]], threadID: "t").question, "Change this Google Doc?")
    }
}

/// The approvals a test's tools asked for.
private actor Asked {
    private(set) var all: [ToolApproval] = []

    func note(_ approval: ToolApproval) {
        all.append(approval)
    }
}
