@testable import AICoven
internal import Combine
import GRDB
import XCTest

/// The turn engine: a reply runs and is stored without the screen that
/// started it, and every turn is recorded from start to outcome.
@MainActor
final class TurnEngineTests: XCTestCase {
    private var threadID = ""
    private let provider = ScriptedProvider()

    override func setUp() async throws {
        try await super.setUp()
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        await ThreadService.shared.reloadForCurrentUser()
        threadID = try await ThreadService.shared.createThread(title: "Turns \(UUID().uuidString)").id
    }

    override func tearDown() async throws {
        provider.release()
        try? await ThreadService.shared.deleteThread(threadId: threadID)
        await ThreadService.shared.reloadForCurrentUser()
        await DataEncryptionService.shared.lock()
        try await super.tearDown()
    }

    // MARK: - A turn from start to outcome

    func testATurn_storesTheQuestionRunsWithoutAScreenAndStoresTheReply() async throws {
        let engine = makeEngine()

        let question = question("What is the plan?")
        try await engine.start(with: question, context: "What is the plan?", roleID: nil, agentName: "Strix", attachments: nil)
        XCTAssertEqual(engine.running[threadID]?.message, TurnProgress.startingMessage)
        let turn = try await storedTurn()
        XCTAssertEqual(turn?.status, "running")

        provider.release()
        await finished(engine)

        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(messages.first, question)
        XCTAssertEqual(messages.last?.content, "The plan is ready.")
        XCTAssertEqual(messages.last?.metadata?["role_name"], AnyJSONValue("Strix"))
        let ended = try await storedTurn()
        XCTAssertEqual(ended?.status, "completed")
        XCTAssertEqual(ended?.messageID, messages.last?.id)
        XCTAssertNil(engine.running[threadID])
        XCTAssertEqual(engine.endings[threadID]?.messages, [messages[1]])
        XCTAssertEqual(engine.endings[threadID]?.stored, true)
        // The work behind the reply is kept with it.
        let traces = try await ThreadRepository.shared.loadWorkTraces(threadID: threadID)
        XCTAssertEqual(traces[messages[1].id], engine.endings[threadID]?.trace)
        XCTAssertNotNil(engine.endings[threadID]?.trace.finishedAt)
    }

    func testATurn_thatFailsStoresWhatWentWrongAndIsRecordedAsFailed() async throws {
        provider.fail(with: "The provider is down")
        provider.release()
        let engine = makeEngine()

        try await engine.start(with: question("Hello"), context: "Hello", roleID: nil, agentName: nil, attachments: nil)
        await finished(engine)

        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.map(\.role), ["user", "assistant"])
        XCTAssertTrue(messages.last?.content.contains("The provider is down") == true)
        let turn = try await storedTurn()
        XCTAssertEqual(turn?.status, "failed")
    }

    func testASecondSend_whileAReplyIsOnItsWayStartsNothing() async throws {
        let engine = makeEngine()
        try await engine.start(with: question("First"), context: "First", roleID: nil, agentName: nil, attachments: nil)

        do {
            try await engine.start(with: question("Second"), context: "Second", roleID: nil, agentName: nil, attachments: nil)
            XCTFail("A thread runs one turn at a time")
        } catch {
            XCTAssertTrue(error is TurnEngine.TurnError)
        }

        provider.release()
        await finished(engine)
        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.filter { $0.role == "user" }.map(\.content), ["First"])
    }

    func testAReplyThatCannotBeStored_isShownKeptAndStoredBeforeTheNextTurn() async throws {
        let engine = makeEngine()
        try await engine.start(with: question("First"), context: "First", roleID: nil, agentName: nil, attachments: nil)
        // Locked while the turn runs: however it ends, its ending cannot be
        // encrypted.
        await DataEncryptionService.shared.lock()
        provider.release()
        await finished(engine)

        let unsaved = try XCTUnwrap(engine.endings[threadID])
        XCTAssertFalse(unsaved.stored)
        XCTAssertEqual(unsaved.messages.count, 2)
        XCTAssertTrue(unsaved.messages[1].content.hasPrefix("AICoven couldn't save this reply yet"))

        // While it still cannot be stored, nothing new starts in the thread
        // and the ending is kept.
        do {
            try await engine.start(with: question("Too soon"), context: "Too soon", roleID: nil, agentName: nil, attachments: nil)
            XCTFail("A new turn must wait for the earlier ending to be stored")
        } catch {}
        XCTAssertEqual(engine.endings[threadID], unsaved)
        XCTAssertNil(engine.running[threadID])

        // Storable again. Opening the thread and sending both try to store
        // the earlier ending; whichever gets there first, the send goes
        // through, and the ending is stored ahead of the new question.
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        async let opened: Void = engine.settleInterruptedTurns(threadID: threadID)
        try await engine.start(with: question("Second"), context: "Second", roleID: nil, agentName: nil, attachments: nil)
        await opened
        await finished(engine)

        // The first question was stored under the key before the lock, so
        // it is not among what the test key now reads.
        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0], unsaved.messages[0])
        XCTAssertEqual(messages[1].content, "Second")
        XCTAssertEqual(messages[2].content, "The plan is ready.")
        let statuses = try await DatabaseManager.shared.dbQueue?.read { [threadID] db in
            try String.fetchAll(db, sql: "SELECT status FROM turns WHERE thread_id = ? ORDER BY started_at", arguments: [threadID])
        }
        XCTAssertEqual(statuses?.contains("running"), false)
    }

    // MARK: - Approvals

    func testATurn_keepsTheAnswersItWasGivenAndTheNextTurnStartsWithNone() async throws {
        let approvals = ToolApprovals(schedule: { _, action in action() })
        let engine = makeEngine(provider: provider, approvals: approvals)
        // An answer left by a turn that never ended here.
        let stale = ToolApproval(threadID: threadID, question: "Run this command?", details: "rm old", toolName: "shell.execute")
        let leaving = Task { await approvals.ask(stale, for: UserScope.currentUserID) }
        while approvals.showing == nil {
            await Task.yield()
        }
        approvals.answer(stale.id, approve: true)
        _ = await leaving.value

        try await engine.start(with: question("Push it"), context: "Push it", roleID: nil, agentName: nil, attachments: nil)
        XCTAssertNil(approvals.answered[threadID], "A turn starts with no answers")
        let asked = ToolApproval(threadID: threadID, question: "Run this command?", details: "git push\nIn /tmp", toolName: "shell.execute")
        let asking = Task { await approvals.ask(asked, for: UserScope.currentUserID) }
        while approvals.showing?.approval.id != asked.id {
            await Task.yield()
        }
        approvals.answer(asked.id, approve: false)
        _ = await asking.value
        // What the approvals still hold at the moment the ending is there to
        // show: the thread shows the lines from one or the other, with no gap.
        var heldWhenEnded: [WorkTrace.Approval]?
        let watching = engine.$endings.sink { [threadID] endings in
            if endings[threadID] != nil, heldWhenEnded == nil {
                heldWhenEnded = approvals.answered[threadID]
            }
        }
        provider.release()
        await finished(engine)
        watching.cancel()

        let kept = [WorkTrace.Approval(id: asked.id, subject: "git push", approved: false)]
        XCTAssertEqual(heldWhenEnded, kept)
        XCTAssertEqual(engine.endings[threadID]?.trace.approvals, kept)
        XCTAssertNil(approvals.answered[threadID], "The turn took its answers with it")
        let reply = try XCTUnwrap(engine.endings[threadID]?.messages.first)
        let stored = try await ThreadRepository.shared.loadWorkTraces(threadID: threadID)
        XCTAssertEqual(stored[reply.id]?.approvals, kept)
    }

    func testATurnWhoseEndingCannotBeStored_keepsItsAnswersWithIt() async throws {
        let approvals = ToolApprovals(schedule: { _, action in action() })
        let engine = makeEngine(provider: provider, approvals: approvals)
        try await engine.start(with: question("Push it"), context: "Push it", roleID: nil, agentName: nil, attachments: nil)
        let asked = ToolApproval(threadID: threadID, question: "Run this command?", details: "git push\nIn /tmp", toolName: "shell.execute")
        let asking = Task { await approvals.ask(asked, for: UserScope.currentUserID) }
        while approvals.showing?.approval.id != asked.id {
            await Task.yield()
        }
        approvals.answer(asked.id, approve: true)
        _ = await asking.value

        // Locked while the turn runs: its ending cannot be encrypted.
        await DataEncryptionService.shared.lock()
        provider.release()
        await finished(engine)

        let unsaved = try XCTUnwrap(engine.endings[threadID])
        XCTAssertFalse(unsaved.stored)
        XCTAssertEqual(unsaved.trace.approvals, [WorkTrace.Approval(id: asked.id, subject: "git push", approved: true)])
        XCTAssertNil(approvals.answered[threadID])
    }

    // MARK: - Details and announcements

    func testDetails_followsItsOwnTurnAndNotTheNextOneInTheThread() async throws {
        let engine = makeEngine()
        try await engine.start(with: question("First"), context: "First", roleID: nil, agentName: nil, attachments: nil)
        let firstID = try XCTUnwrap(engine.running[threadID]?.turnID)
        let details = WorkTraceTarget.running(threadID: threadID, turnID: firstID)
        XCTAssertNil(details.trace(in: engine)?.finishedAt, "A running turn's trace is not finished")

        provider.release()
        await finished(engine)
        let firstTrace = try XCTUnwrap(engine.endings[threadID]?.trace)
        XCTAssertEqual(details.trace(in: engine), firstTrace)

        // The thread's next turn, started from another window.
        provider.hold()
        try await engine.start(with: question("Second"), context: "Second", roleID: nil, agentName: nil, attachments: nil)
        XCTAssertNotEqual(engine.running[threadID]?.turnID, firstID)
        XCTAssertEqual(details.trace(in: engine), firstTrace, "Details still shows the turn it was opened on")

        provider.release()
        await finished(engine)
        XCTAssertNil(details.trace(in: engine), "The next turn's trace is never shown in its place")
    }

    func testAStatus_isAnnouncedOnceHoweverManyWindowsShowItAndWhateverOtherTurnsSay() async throws {
        let engine = makeEngine()
        let otherThread = try await ThreadService.shared.createThread(title: "Turns \(UUID().uuidString)").id
        addTeardownBlock { try? await ThreadService.shared.deleteThread(threadId: otherThread) }
        try await engine.start(with: question("First"), context: "First", roleID: nil, agentName: nil, attachments: nil)
        try await engine.start(
            with: TurnProgress.message(in: otherThread, role: "user", content: "Other"),
            context: "Other", roleID: nil, agentName: nil, attachments: nil
        )
        let one = try XCTUnwrap(engine.running[threadID]?.turnID)
        let two = try XCTUnwrap(engine.running[otherThread]?.turnID)

        XCTAssertTrue(engine.announceStatus("Planning: the route", of: one))
        XCTAssertTrue(engine.announceStatus("Using tool web.search…", of: two), "Another turn's status is its own")
        XCTAssertFalse(engine.announceStatus("Planning: the route", of: one), "A second window showing the turn says nothing")
        XCTAssertFalse(engine.announceStatus("Using tool web.search…", of: two))
        XCTAssertTrue(engine.announceStatus("Using tool web.search…", of: one))
        XCTAssertTrue(engine.announceStatus("Planning: the route", of: one), "A status the turn returns to is said again")

        provider.release()
        await finished(engine)
        await finished(engine, in: otherThread)
        XCTAssertFalse(engine.announceStatus("Planning: the route", of: one), "A turn that has ended has no status to say")
    }

    func testTextOfAFailedSend_isKeptForItsThreadAndGivenBackOnce() async {
        // Makes this test a task, as every test that makes an engine must
        // be: a main-actor object released outside a task crashes on
        // macOS 15 (issue #61).
        await Task.yield()
        let engine = makeEngine()

        engine.keepUnsent("Do not lose this", for: threadID, because: "The data is locked")

        XCTAssertNil(engine.takeUnsent(for: "another-thread"))
        let kept = engine.takeUnsent(for: threadID)
        XCTAssertEqual(kept?.text, "Do not lose this")
        XCTAssertEqual(kept?.reason, "The data is locked")
        XCTAssertNil(engine.takeUnsent(for: threadID))

        // What is kept for a thread that already has something kept is
        // added after it: neither is lost.
        engine.keepUnsent("First", for: threadID, because: "The data is locked")
        engine.keepUnsent("Second", for: threadID, because: "The thread was left")
        let both = engine.takeUnsent(for: threadID)
        XCTAssertEqual(both?.text, "First\nSecond")
        XCTAssertEqual(both?.reason, "The thread was left")
    }

    // MARK: - Stop

    func testStop_saysStoppingUntilTheTurnHasEndedThenRecordsItAsStopped() async throws {
        let engine = makeEngine()
        try await engine.start(with: question("A long one"), context: "A long one", roleID: nil, agentName: nil, attachments: nil)
        await provider.called()

        engine.stop(threadID: threadID)
        // A second press changes nothing.
        engine.stop(threadID: threadID)
        XCTAssertEqual(engine.running[threadID]?.isStopping, true)
        XCTAssertEqual(engine.running[threadID]?.message, TurnProgress.stoppingMessage)
        await finished(engine)

        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.map(\.content), ["A long one", "Stopped before any reply."])
        XCTAssertEqual(engine.endings[threadID]?.outcome, .cancelled)
        let turn = try await storedTurn()
        XCTAssertEqual(turn?.status, "cancelled")
        // Another send starts once the stopped turn is over.
        provider.release()
        try await engine.start(with: question("Next"), context: "Next", roleID: nil, agentName: nil, attachments: nil)
        await finished(engine)
    }

    func testStop_keepsWhatAStreamedAnswerHadSaidAndDoesNotCallItComplete() async throws {
        let firstPart = expectation(description: "The answer has started to arrive")
        let engine = makeEngine(provider: StreamingProvider(parts: [LLMStreamDelta(text: "Once upon a")], sent: firstPart))
        // A request the reply loop answers without tools, so the answer is
        // streamed.
        try await engine.start(with: question("Tell me about dragons"), context: "Tell me about dragons", roleID: nil, agentName: nil, attachments: nil)
        await fulfillment(of: [firstPart], timeout: 10)

        engine.stop(threadID: threadID)
        await finished(engine)

        // The stream ended without an error when it was cancelled, as an
        // on-device model's does; that is not a finished answer.
        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.last?.content, "Once upon a\n\n_Stopped here._")
        let turn = try await storedTurn()
        XCTAssertEqual(turn?.status, "cancelled")
    }

    func testStop_afterAStreamedAnswerHasArrivedInFullKeepsItAsTheReply() async throws {
        let wholeAnswer = expectation(description: "The whole answer has arrived")
        let engine = makeEngine(provider: StreamingProvider(
            parts: [LLMStreamDelta(text: "Dragons are large."), LLMStreamDelta(text: "", isFinished: true)],
            sent: wholeAnswer
        ))
        try await engine.start(with: question("Tell me about dragons"), context: "Tell me about dragons", roleID: nil, agentName: nil, attachments: nil)
        await fulfillment(of: [wholeAnswer], timeout: 10)

        // The stream has said it is finished but has not closed.
        engine.stop(threadID: threadID)
        await finished(engine)

        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.last?.content, "Dragons are large.")
        let turn = try await storedTurn()
        XCTAssertEqual(turn?.status, "completed")
    }

    func testStop_startsNoToolOnceTheTurnIsStopped() async {
        let stopped = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ChatService.shared.executeChatToolCall(ChatToolInvocation(tool: "current_time", input: nil, reason: nil), threadID: nil)
        }

        do {
            _ = try await stopped.value
            XCTFail("A stopped turn must not start a tool")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testStop_worksOnATurnStartedRightAfterAnotherEnded() async throws {
        let engine = makeEngine()
        try await engine.start(with: question("First"), context: "First", roleID: nil, agentName: nil, attachments: nil)
        provider.release()
        await finished(engine)
        // The first turn's summary is still to be asked for, or is waiting on
        // the provider, when the next turn starts.
        provider.hold()
        try await engine.start(with: question("Second"), context: "Second", roleID: nil, agentName: nil, attachments: nil)

        engine.stop(threadID: threadID)
        XCTAssertEqual(engine.running[threadID]?.isStopping, true)
        await finished(engine)

        let statuses = try await DatabaseManager.shared.dbQueue?.read { [threadID] db in
            try String.fetchAll(db, sql: "SELECT status FROM turns WHERE thread_id = ? ORDER BY started_at", arguments: [threadID])
        }
        XCTAssertEqual(statuses, ["completed", "cancelled"])
    }

    func testStop_doesNothingWhereNoTurnRuns() async {
        // A task, for the engine's release; see the note on issue #61 above.
        await Task.yield()
        let engine = makeEngine()

        engine.stop(threadID: threadID)

        XCTAssertNil(engine.running[threadID])
    }

    func testAStoppedTurn_keepsWhatHadBeenAnsweredAndAReplyThatArrivedInFullWins() {
        var stoppedMidAnswer = TurnProgress(agentName: nil)
        stoppedMidAnswer.note(TurnState(answer: "Half of the ans", phase: .answering))
        stoppedMidAnswer.note(TurnState(answer: "Error: cancelled", status: .failed, phase: .finalizing))
        let partial = stoppedMidAnswer.ending(in: "t", thrown: nil, stopped: true)
        XCTAssertEqual(partial.outcome, .cancelled)
        XCTAssertEqual(partial.message.content, "Half of the ans\n\n_Stopped here._")

        var finishedFirst = TurnProgress(agentName: nil)
        finishedFirst.note(TurnState(answer: "The whole answer.", status: .completed, phase: .finalizing))
        let whole = finishedFirst.ending(in: "t", thrown: nil, stopped: true)
        XCTAssertEqual(whole.outcome, .completed)
        XCTAssertEqual(whole.message.content, "The whole answer.")
    }

    // MARK: - A turn the app closed on

    func testOpeningAThread_endsATurnTheAppClosedOnAndSaysSoOnce() async throws {
        let engine = makeEngine()
        try await ThreadRepository.shared.beginTurn(id: "turn-\(threadID)", userMessage: question("Left hanging"))

        await engine.settleInterruptedTurns(threadID: threadID)
        await engine.settleInterruptedTurns(threadID: threadID)

        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.map(\.content), ["Left hanging", TurnProgress.interruptedNotice])
        let turn = try await storedTurn()
        XCTAssertEqual(turn?.status, "interrupted")
    }

    func testOpeningAThread_leavesATurnThatIsRunningAlone() async throws {
        let engine = makeEngine()
        try await engine.start(with: question("Still going"), context: "Still going", roleID: nil, agentName: nil, attachments: nil)

        await engine.settleInterruptedTurns(threadID: threadID)

        let turn = try await storedTurn()
        XCTAssertEqual(turn?.status, "running")
        provider.release()
        await finished(engine)
        let ended = try await storedTurn()
        XCTAssertEqual(ended?.status, "completed")
    }

    func testATurn_endsOnce() async throws {
        try await ThreadRepository.shared.beginTurn(id: "turn-\(threadID)", userMessage: question("Question"))
        let reply = TurnProgress.message(in: threadID, role: "assistant", content: "Reply")
        let late = TurnProgress.message(in: threadID, role: "assistant", content: "Too late")

        let ended = try await ThreadRepository.shared.endTurn(id: "turn-\(threadID)", outcome: .completed, message: reply)
        let endedAgain = try await ThreadRepository.shared.endTurn(id: "turn-\(threadID)", outcome: .interrupted, message: late)
        XCTAssertTrue(ended)
        XCTAssertFalse(endedAgain)

        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.map(\.content), ["Question", "Reply"])
        let turn = try await storedTurn()
        XCTAssertEqual(turn?.status, "completed")
    }

    func testATurn_belongsToItsThreadsOwnerAndGoesWithItsThread() async throws {
        try await ThreadRepository.shared.beginTurn(id: "turn-\(threadID)", userMessage: question("Mine"))
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)

        // A turn for this thread under another user is refused.
        XCTAssertThrowsError(try queue.inDatabase { [threadID] db in
            try db.execute(
                sql: "INSERT INTO turns (id, user_id, thread_id, status, started_at) VALUES (?, ?, ?, ?, ?)",
                arguments: ["someone-elses-\(threadID)", "another-user", threadID, "running", Date()]
            )
        })

        try await ThreadService.shared.deleteThread(threadId: threadID)
        let left = try await queue.read { [threadID] db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM turns WHERE thread_id = ?", arguments: [threadID])
        }
        XCTAssertEqual(left, 0)
    }

    // MARK: - What a running turn shows

    func testProgress_saysWhatTheTurnIsDoingAndKeepsItsThoughtsForTheReply() {
        var progress = TurnProgress(agentName: nil)
        progress.note(TurnState(scratchpad: "Reading the question", phase: .planning))
        XCTAssertEqual(progress.activity, "Planning: Reading the question")

        let search = TurnToolCall(id: "1", name: "web.search", arguments: [:], result: nil, status: "running")
        progress.note(TurnState(toolsInProgress: ["1": search], phase: .tooling))
        XCTAssertEqual(progress.activity, "Using web.search to look up information on the web…")

        progress.note(TurnState(scratchpad: "Reading the results", phase: .planning))
        XCTAssertEqual(progress.activity, "Using tools and memory: Reading the results")

        progress.note(TurnState(answer: "Done.", status: .completed, phase: .finalizing))
        let ending = progress.ending(in: "t", thrown: nil)
        XCTAssertEqual(ending.outcome, .completed)
        XCTAssertEqual(ending.message.content, "Done.")
        XCTAssertEqual(ending.message.metadata?["thoughts"], AnyJSONValue(["Reading the question Reading the results"]))
    }

    func testProgress_endsAsFailedWhenTheServiceThrowsOrReportsAFailure() {
        var progress = TurnProgress(agentName: nil)
        progress.note(TurnState(scratchpad: "Thinking", phase: .planning))
        progress.note(TurnState(answer: "Error: no model", status: .failed, phase: .finalizing))

        let reported = progress.ending(in: "t", thrown: nil)
        XCTAssertEqual(reported.outcome, .failed)
        XCTAssertEqual(reported.message.content, "Error: no model")
        let thrown = progress.ending(in: "t", thrown: NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "No network"]))
        XCTAssertEqual(thrown.outcome, .failed)
        XCTAssertTrue(thrown.message.content.contains("No network"))
    }

    // MARK: - Messages sent while a reply runs

    private func waiting(_ text: String, attachments: [FileAttachmentDetail] = []) -> TurnEngine.WaitingMessage {
        TurnEngine.WaitingMessage(text: text, userText: text, context: text, roleID: nil, agentName: "Strix", attachments: attachments)
    }

    /// Waits until the thread has no turn running and nothing waiting.
    private func settled(_ engine: TurnEngine) async {
        let threadID = threadID
        let done = expectation(description: "Nothing runs and nothing waits")
        done.assertForOverFulfill = false
        let watching = engine.$running.combineLatest(engine.$waiting).sink { running, waiting in
            if running[threadID] == nil, waiting[threadID] == nil { done.fulfill() }
        }
        await fulfillment(of: [done], timeout: 10)
        watching.cancel()
    }

    func testAMessageSentWhileAReplyRuns_waitsAndGoesWhenTheReplyCompletes() async throws {
        let engine = makeEngine()
        XCTAssertFalse(engine.enqueue(waiting("Too early"), threadID: threadID), "With no reply running it is sent now, not kept")
        XCTAssertNil(engine.waiting[threadID])

        try await engine.start(with: question("First"), context: "First", roleID: nil, agentName: "Strix", attachments: nil)
        XCTAssertTrue(engine.enqueue(waiting("Second"), threadID: threadID))
        XCTAssertTrue(engine.enqueue(waiting("Third"), threadID: threadID))
        XCTAssertEqual(engine.waiting[threadID]?.map(\.text), ["Second", "Third"])
        let stored = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(stored.map(\.content), ["First"], "A waiting message is not in the thread yet")

        provider.release()
        await settled(engine)

        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.map(\.role), ["user", "assistant", "user", "assistant", "user", "assistant"])
        XCTAssertEqual(messages.filter { $0.role == "user" }.map(\.content), ["First", "Second", "Third"], "Each goes in the order it was sent, after the reply it waited for")
        // A thread on screen shows what the engine added, all of it and in
        // order, however its updates fall: each reply, and each waiting
        // message as it was stored.
        let added = try XCTUnwrap(engine.additions[threadID])
        XCTAssertEqual(added.map(\.message), Array(messages.dropFirst()))
        XCTAssertEqual(added.map(\.sequence), added.map(\.sequence).sorted())
        XCTAssertEqual(added.map { $0.trace != nil }, [true, false, true, false, true], "A reply comes with the work behind it")
        XCTAssertNil(engine.starting[threadID])
        XCTAssertNil(engine.returned[threadID])
        XCTAssertNil(engine.notSent[threadID])
    }

    func testAFirstMessageThatCouldNotBeSent_isHandedBackInFrontOfWhatWasHandedBackBefore_withWhy() async {
        let engine = makeEngine()
        let file = FileAttachmentDetail(id: "a", name: "notes.txt", mimeType: "text/plain", sizeBytes: 3, width: nil, height: nil, url: nil)
        let later = FileAttachmentDetail(id: "b", name: "more.txt", mimeType: "text/plain", sizeBytes: 3, width: nil, height: nil, url: nil)

        // Nothing to hand back is nothing said.
        engine.handBack(ComposerDraft(text: "  "), to: threadID, because: URLError(.networkConnectionLost))
        XCTAssertNil(engine.returned[threadID])
        XCTAssertNil(engine.notSent[threadID])

        engine.handBack(ComposerDraft(text: "Read these", attachments: [file]), to: threadID, because: URLError(.networkConnectionLost))
        XCTAssertEqual(engine.returned[threadID], ComposerDraft(text: "Read these", attachments: [file]))
        XCTAssertEqual(engine.notSent[threadID]?.hasPrefix("Your message could not be sent: "), true)
        // What comes after joins it, and takes nothing of it away.
        engine.handBack(ComposerDraft(text: "And this", attachments: [later]), to: threadID, because: URLError(.networkConnectionLost))
        XCTAssertEqual(engine.returned[threadID], ComposerDraft(text: "Read these\n\nAnd this", attachments: [file, later]))
        // Taken once, by the thread's composer.
        XCTAssertEqual(engine.takeReturned(threadID: threadID)?.attachments, [file, later])
        XCTAssertNil(engine.returned[threadID])
        // Freed inside a task: a main-actor object released outside one
        // aborts on macOS 15 (issue #61).
        await Task.yield()
    }

    func testANewThreadsFirstMessageThatCouldNotBeSent_goesToItsComposerInFrontOfWhatItHolds_notOverIt() async {
        let engine = makeEngine()
        let file = FileAttachmentDetail(id: "a", name: "notes.txt", mimeType: "text/plain", sizeBytes: 3, width: nil, height: nil, url: nil)
        let newer = FileAttachmentDetail(id: "n", name: "newer.txt", mimeType: "text/plain", sizeBytes: 3, width: nil, height: nil, url: nil)
        // The thread was opened while its first message was on its way, and something was written there.
        let written = ComposerDraft(text: "Newer words", attachments: [newer])
        ComposerDrafts.shared.set(written, for: threadID)

        NewThreadComposer.handBack("Read these", [file], toThread: threadID, because: URLError(.networkConnectionLost), engine: engine)

        // What was written there is as it was: nothing replaced it.
        let kept = await ComposerDrafts.shared.draft(for: threadID)
        XCTAssertEqual(kept, written)
        // The message waits for the thread's composer, which puts it in front of what it holds.
        let handedBack = engine.takeReturned(threadID: threadID)
        XCTAssertEqual(handedBack, ComposerDraft(text: "Read these", attachments: [file]))
        XCTAssertEqual(handedBack?.followed(by: kept), ComposerDraft(text: "Read these\n\nNewer words", attachments: [file, newer]))
        XCTAssertNotNil(engine.notSent[threadID])
        ComposerDrafts.shared.set(ComposerDraft(), for: threadID)
        await ComposerDrafts.shared.saveNow()
    }

    func testAfterAStop_nothingWaitingIsSentAndItGoesBackToTheComposer() async throws {
        let engine = makeEngine()
        let file = FileAttachmentDetail(id: "a", name: "notes.txt", mimeType: "text/plain", sizeBytes: 3, width: nil, height: nil, url: nil)
        try await engine.start(with: question("First"), context: "First", roleID: nil, agentName: "Strix", attachments: nil)
        XCTAssertTrue(engine.enqueue(waiting("Second", attachments: [file]), threadID: threadID))
        XCTAssertTrue(engine.enqueue(waiting("Third"), threadID: threadID))
        await provider.called()

        engine.stop(threadID: threadID)
        await settled(engine)

        XCTAssertEqual(engine.returned[threadID], ComposerDraft(text: "Second\n\nThird", attachments: [file]))
        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.filter { $0.role == "user" }.map(\.content), ["First"])
        XCTAssertEqual(engine.takeReturned(threadID: threadID)?.text, "Second\n\nThird")
        XCTAssertNil(engine.takeReturned(threadID: threadID), "Taken once")
    }

    func testAfterAReplyThatFails_nothingWaitingIsSent() async throws {
        let engine = makeEngine()
        provider.fail(with: "The provider is down")
        try await engine.start(with: question("First"), context: "First", roleID: nil, agentName: "Strix", attachments: nil)
        XCTAssertTrue(engine.enqueue(waiting("Second"), threadID: threadID))

        provider.release()
        await settled(engine)

        XCTAssertEqual(engine.endings[threadID]?.outcome, .failed)
        XCTAssertEqual(engine.returned[threadID]?.text, "Second")
        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.filter { $0.role == "user" }.map(\.content), ["First"])
    }

    func testAReplyThatArrivedInFullAfterStopWasPressed_isNotAGoAheadForWhatWaits() async throws {
        let wholeAnswer = expectation(description: "The whole answer has arrived")
        let engine = makeEngine(provider: StreamingProvider(
            parts: [LLMStreamDelta(text: "Dragons are large."), LLMStreamDelta(text: "", isFinished: true)],
            sent: wholeAnswer
        ))
        try await engine.start(with: question("Tell me about dragons"), context: "Tell me about dragons", roleID: nil, agentName: nil, attachments: nil)
        XCTAssertTrue(engine.enqueue(waiting("And wyverns?"), threadID: threadID))
        await fulfillment(of: [wholeAnswer], timeout: 10)

        engine.stop(threadID: threadID)
        await settled(engine)

        XCTAssertEqual(engine.endings[threadID]?.outcome, .completed, "The reply that arrived in full is kept as the reply")
        XCTAssertEqual(engine.returned[threadID]?.text, "And wyverns?", "The person meant to stop: nothing more is sent")
        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.map(\.role), ["user", "assistant"])
    }

    func testAWaitingMessage_canBeRemovedOrTakenBackToBeEdited() async throws {
        let engine = makeEngine()
        try await engine.start(with: question("First"), context: "First", roleID: nil, agentName: "Strix", attachments: nil)
        let second = waiting("Second")
        let third = waiting("Third")
        let fourth = waiting("Fourth")
        for message in [second, third, fourth] {
            XCTAssertTrue(engine.enqueue(message, threadID: threadID))
        }

        engine.removeWaiting(second.id, threadID: threadID)
        XCTAssertEqual(engine.waiting[threadID]?.map(\.text), ["Third", "Fourth"])
        XCTAssertNil(engine.returned[threadID], "Removed is gone, not handed back")

        engine.editWaiting(fourth.id, threadID: threadID)
        XCTAssertEqual(engine.waiting[threadID]?.map(\.text), ["Third"])
        XCTAssertEqual(engine.returned[threadID]?.text, "Fourth")
        engine.editWaiting("no-such-message", threadID: threadID)
        XCTAssertEqual(engine.waiting[threadID]?.map(\.text), ["Third"])

        // What is handed back before the composer takes it adds up, in order.
        engine.editWaiting(third.id, threadID: threadID)
        XCTAssertNil(engine.waiting[threadID])
        XCTAssertEqual(engine.returned[threadID]?.text, "Fourth\n\nThird")

        provider.release()
        await settled(engine)
        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.filter { $0.role == "user" }.map(\.content), ["First"], "Nothing taken out of the queue was sent")
    }

    func testAWaitingMessageThatCannotBeSent_goesBackToTheComposerWithWhatWaitedBehindItAndSaysWhy() async throws {
        let engine = makeEngine()
        try await engine.start(with: question("First"), context: "First", roleID: nil, agentName: "Strix", attachments: nil)
        XCTAssertTrue(engine.enqueue(waiting("Second"), threadID: threadID))
        XCTAssertTrue(engine.enqueue(waiting("Third"), threadID: threadID))
        await provider.called()
        // The thread goes while the turn runs: the reply arrives, but
        // nothing more can be stored there, so nothing new can start.
        try await ThreadService.shared.deleteThread(threadId: threadID)
        provider.release()
        await settled(engine)

        XCTAssertEqual(engine.endings[threadID]?.outcome, .completed)
        XCTAssertEqual(engine.returned[threadID]?.text, "Second\n\nThird")
        XCTAssertEqual(engine.notSent[threadID]?.hasPrefix("Your waiting message could not be sent: "), true)
        XCTAssertEqual(engine.additions[threadID]?.count, 2, "The reply and the line saying it could not be saved; no waiting message")

        // The next message sent there takes back what the composer said.
        XCTAssertFalse(engine.enqueue(waiting("Again"), threadID: threadID))
        try? await engine.start(with: question("Again"), context: "Again", roleID: nil, agentName: nil, attachments: nil)
        XCTAssertNil(engine.notSent[threadID])
    }

    func testAWaitingMessageWhoseTurnIsBeingStarted_canNoLongerBeEditedOrRemoved() async throws {
        let engine = makeEngine()
        try await engine.start(with: question("First"), context: "First", roleID: nil, agentName: "Strix", attachments: nil)
        let second = waiting("Second")
        XCTAssertTrue(engine.enqueue(second, threadID: threadID))
        let threadID = threadID
        // As soon as it is on its way, both are tried.
        let tried = expectation(description: "Edit and Remove were tried while it was being sent")
        tried.assertForOverFulfill = false
        let watching = engine.$starting.sink { starting in
            guard starting[threadID] == second.id else { return }
            Task { @MainActor in
                engine.removeWaiting(second.id, threadID: threadID)
                engine.editWaiting(second.id, threadID: threadID)
                tried.fulfill()
            }
        }

        provider.release()
        await fulfillment(of: [tried], timeout: 10)
        await settled(engine)
        watching.cancel()

        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.filter { $0.role == "user" }.map(\.content), ["First", "Second"], "It was sent, once")
        XCTAssertNil(engine.returned[threadID], "And not handed back as well")
    }

    func testMessagesSetToWaitForATurnThatCouldNotBeStarted_goBackToTheComposer() async throws {
        let engine = makeEngine()
        // Locked: the message cannot be stored, so the turn cannot start.
        await DataEncryptionService.shared.lock()
        let threadID = threadID
        // The turn shows as running from the moment it is asked for:
        // another window on the thread can send while it is being stored.
        // Sent here as soon as it shows, before the storing can have
        // failed: the main actor takes this up when the start first waits.
        let second = waiting("Second")
        let enqueued = expectation(description: "A second message was sent while the first was being started")
        enqueued.assertForOverFulfill = false
        let watching = engine.$running.sink { running in
            guard running[threadID] != nil else { return }
            Task { @MainActor in
                XCTAssertTrue(engine.enqueue(second, threadID: threadID))
                enqueued.fulfill()
            }
        }

        do {
            try await engine.start(with: question("First"), context: "First", roleID: nil, agentName: "Strix", attachments: nil)
            XCTFail("The turn cannot start while its message cannot be stored")
        } catch {}
        await fulfillment(of: [enqueued], timeout: 10)
        watching.cancel()

        XCTAssertNil(engine.running[threadID])
        XCTAssertNil(engine.waiting[threadID], "Nothing is left waiting for a turn that never started")
        XCTAssertEqual(engine.returned[threadID]?.text, "Second")
        XCTAssertEqual(engine.notSent[threadID]?.hasPrefix("Your waiting message could not be sent: "), true)
        await DataEncryptionService.shared.unlockForTestingEphemeral()
    }

    func testTheEnginesAdditionsToAThread_areNumberedInOrderAndTheLastFewKept() async throws {
        let engine = makeEngine()
        provider.release()
        let turns = TurnEngine.additionsKept + 3
        for number in 1 ... turns {
            try await engine.start(with: question("Question \(number)"), context: "Question \(number)", roleID: nil, agentName: nil, attachments: nil)
            await finished(engine)
        }

        // One reply a turn: the first three are no longer kept, and the
        // numbers say so to a thread that has not taken them in.
        let added = try XCTUnwrap(engine.additions[threadID])
        XCTAssertEqual(added.map(\.sequence), Array(4 ... turns))
        XCTAssertEqual(added.count, TurnEngine.additionsKept)
        // Numbered in each thread on its own.
        XCTAssertNil(engine.additions["another-thread"])
    }

    // MARK: - Attached files

    private func messageID(of attachmentID: String) async throws -> String? {
        try await DatabaseManager.shared.dbQueue?.read { db in
            try String.fetchOne(db, sql: "SELECT message_id FROM attachments WHERE id = ?", arguments: [attachmentID])
        }
    }

    func testATurnsFiles_areTheThreadsOnceItStarts_andUnsentAgainIfItCannotStart() async throws {
        let engine = makeEngine()
        let file = try await AttachmentStore.shared.add(Data("notes".utf8), named: "notes.txt", mimeType: "text/plain", toThread: threadID)

        // A turn that cannot start (locked: its message cannot be stored)
        // leaves the file unsent, to send again or take out.
        await DataEncryptionService.shared.lock()
        let unsent = question("With a file")
        do {
            try await engine.start(with: unsent, context: "With a file", roleID: nil, agentName: nil, attachments: [file])
            XCTFail("The turn cannot start while its message cannot be stored")
        } catch {}
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        let afterFailure = try await messageID(of: file.id)
        XCTAssertNil(afterFailure)
        XCTAssertNil(engine.running[threadID])

        // A turn that starts marks it sent with its message.
        let sent = question("With a file")
        try await engine.start(with: sent, context: "With a file", roleID: nil, agentName: nil, attachments: [file])
        let marked = try await messageID(of: file.id)
        XCTAssertEqual(marked, sent.id)
        provider.release()
        await finished(engine)

        // A message is not sent with a file that is no longer there.
        let gone = try await AttachmentStore.shared.add(Data("gone".utf8), named: "gone.txt", mimeType: "text/plain", toThread: threadID)
        await AttachmentStore.shared.removeUnsent([gone.id])
        do {
            try await engine.start(with: question("With a file that is gone"), context: "x", roleID: nil, agentName: nil, attachments: [gone])
            XCTFail("Nothing is sent with a file that is gone")
        } catch {
            XCTAssertEqual(error as? AttachmentStore.Failure, .missing)
        }
        XCTAssertNil(engine.running[threadID])
        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        XCTAssertEqual(messages.filter { $0.role == "user" }.map(\.id), [sent.id], "And its message is not stored")
    }

    func testAWaitingMessagesFiles_areStoredWithItWhenItIsSent() async throws {
        let engine = makeEngine()
        let file = try await AttachmentStore.shared.add(Data("notes".utf8), named: "notes.txt", mimeType: "text/plain", toThread: threadID)
        try await engine.start(with: question("First"), context: "First", roleID: nil, agentName: "Strix", attachments: nil)
        XCTAssertTrue(engine.enqueue(waiting("Second", attachments: [file]), threadID: threadID))

        provider.release()
        await settled(engine)

        let messages = try await ChatService.shared.loadMessages(threadId: threadID)
        let second = try XCTUnwrap(messages.first { $0.content == "Second" })
        XCTAssertEqual(FileAttachmentDetail.attachments(in: second.metadata ?? [:]), [file], "The thread shows the message with its file")
        let marked = try await messageID(of: file.id)
        XCTAssertEqual(marked, second.id, "And the file is that message's from then on")
    }

    // MARK: - Helpers

    private func question(_ text: String) -> ChatMessage {
        TurnProgress.message(in: threadID, role: "user", content: text)
    }

    private func makeEngine() -> TurnEngine {
        makeEngine(provider: provider)
    }

    private func makeEngine(provider: LLMClient, approvals: ToolApprovals = .shared) -> TurnEngine {
        let model = ModelDescriptor(
            providerID: "test-provider", modelID: "test-model", maxContextTokens: 4096,
            supportsTools: false, supportsEmbeddings: false, costClass: .cheap
        )
        return TurnEngine(chat: ChatService(
            contextBuilder: ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4)),
            modelRouter: HeuristicModelRouter(availableModels: [model]),
            llmClients: ["test-provider": provider],
            threadStore: ThreadRepository.shared,
            toolService: NoTools(),
            shouldAutoRefreshEnvironment: false
        ), approvals: approvals)
    }

    /// Waits until the engine has no turn running in the thread.
    private func finished(_ engine: TurnEngine, in thread: String? = nil) async {
        let threadID = thread ?? threadID
        let done = expectation(description: "The turn ended")
        done.assertForOverFulfill = false
        let watching = engine.$running.sink { running in
            if running[threadID] == nil { done.fulfill() }
        }
        await fulfillment(of: [done], timeout: 10)
        watching.cancel()
    }

    private func storedTurn() async throws -> (status: String, messageID: String?)? {
        try await DatabaseManager.shared.dbQueue?.read { [threadID] db in
            try Row.fetchOne(db, sql: "SELECT status, message_id FROM turns WHERE thread_id = ?", arguments: [threadID])
                .map { ($0["status"], $0["message_id"]) }
        }
    }
}

/// A provider that streams the parts it is given and then nothing more,
/// until its consumer is cancelled; the stream then ends without an error.
/// It says its parts are read when the consumer asks for the one after.
private final class StreamingProvider: StreamingLLMClient, @unchecked Sendable {
    // The consumer asks for one part at a time, so nothing here is touched
    // from two places at once; the lock is for the compiler's sake too.
    private let lock = NSLock()
    private var remaining: [LLMStreamDelta]
    /// XCTestExpectation is safe to fulfil from any thread.
    private let read: XCTestExpectation

    init(parts: [LLMStreamDelta], sent read: XCTestExpectation) {
        remaining = parts
        self.read = read
    }

    func streamChat(messages _: [LLMMessage], model _: String, options _: ChatOptions) -> AsyncThrowingStream<LLMStreamDelta, Error> {
        AsyncThrowingStream(unfolding: { [self] in
            if let next = lock.withLock({ remaining.isEmpty ? nil : remaining.removeFirst() }) {
                return next
            }
            // Every part has been read. Nothing more comes until the
            // consumer is cancelled, and then the stream just ends.
            read.fulfill()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return nil
        })
    }

    func completeChat(messages _: [LLMMessage], model: String, options _: ChatOptions) async throws -> LLMChatResponse {
        LLMChatResponse(
            message: LLMMessage(role: .assistant, content: "Once upon a time, the end."),
            providerID: "test-provider",
            modelID: model,
            usage: nil
        )
    }

    func embed(texts: [String], model _: String) async throws -> [[Float]] {
        Array(repeating: [0, 0, 0], count: texts.count)
    }
}

/// A provider that answers when the test lets it, with a reply or an error,
/// and gives up, as a network call does, when its task is cancelled.
private final class ScriptedProvider: LLMClient, @unchecked Sendable {
    // Read and written from the test and from the chat service's actor, so
    // every access takes the lock.
    private let lock = NSLock()
    private var released = false
    private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var failure: String?
    private var calls = 0
    private var awaitingCall: [CheckedContinuation<Void, Never>] = []

    func fail(with message: String) {
        lock.withLock { failure = message }
    }

    /// Makes the provider wait again before it answers.
    func hold() {
        lock.withLock { released = false }
    }

    func release() {
        let resumed = lock.withLock {
            released = true
            defer { waiting = [:] }
            return Array(waiting.values)
        }
        resumed.forEach { $0.resume() }
    }

    /// Returns once the chat service is waiting on this provider.
    func called() async {
        await withCheckedContinuation { continuation in
            let already = lock.withLock {
                if calls > 0 { return true }
                awaitingCall.append(continuation)
                return false
            }
            if already { continuation.resume() }
        }
    }

    func completeChat(messages _: [LLMMessage], model: String, options _: ChatOptions) async throws -> LLMChatResponse {
        let call = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let (resumeNow, watchers) = lock.withLock {
                    calls += 1
                    defer { awaitingCall = [] }
                    if released || Task.isCancelled { return (true, awaitingCall) }
                    waiting[call] = continuation
                    return (false, awaitingCall)
                }
                watchers.forEach { $0.resume() }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            lock.withLock { waiting.removeValue(forKey: call) }?.resume()
        }
        try Task.checkCancellation()
        if let failure = lock.withLock({ failure }) {
            throw NSError(domain: "ScriptedProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: failure])
        }
        return LLMChatResponse(
            message: LLMMessage(role: .assistant, content: "The plan is ready."),
            providerID: "test-provider",
            modelID: model,
            usage: nil
        )
    }

    func embed(texts: [String], model _: String) async throws -> [[Float]] {
        Array(repeating: [0, 0, 0], count: texts.count)
    }
}

private actor NoTools: ChatToolService {
    func webSearch(query _: String, maxResults _: Int) async throws -> [ToolService.WebSearchResult] {
        []
    }

    func webBrowse(url: URL, maxLength _: Int) async throws -> ToolService.WebBrowseResult {
        throw URLError(.unsupportedURL, userInfo: [NSURLErrorFailingURLErrorKey: url])
    }

    nonisolated func currentTime(timezone: TimeZone) -> ToolService.TimeInfo {
        ToolService.shared.currentTime(timezone: timezone)
    }
}
