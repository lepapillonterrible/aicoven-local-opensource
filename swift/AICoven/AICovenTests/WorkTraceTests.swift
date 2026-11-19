@testable import AICoven
import GRDB
import XCTest

/// The work trace: what a turn's reports become, what it says about itself,
/// and that it is kept with the turn.
@MainActor
final class WorkTraceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testTrace_recordsEachToolOnceWithItsTimesAndEachNewLineOfReasoning() {
        var trace = WorkTrace(startedAt: start)
        let search = TurnToolCall(id: "a", name: "web.search", arguments: [:], result: nil, status: "running")
        var finished = search
        finished.status = "completed"
        let quick = TurnToolCall(id: "b", name: "current_time", arguments: [:], result: nil, status: "failed")

        trace.note(TurnState(scratchpad: "Looking it up", phase: .planning), at: start.addingTimeInterval(1))
        trace.note(TurnState(scratchpad: "Looking it up", toolsInProgress: ["a": search], phase: .tooling), at: start.addingTimeInterval(2))
        trace.note(TurnState(toolsInProgress: ["a": search], phase: .tooling), at: start.addingTimeInterval(3))
        trace.note(TurnState(toolsCompleted: [finished], phase: .tooling), at: start.addingTimeInterval(6))
        // One that started and finished between two reports.
        trace.note(TurnState(scratchpad: "Reading the results", toolsCompleted: [finished, quick], phase: .planning), at: start.addingTimeInterval(7))

        XCTAssertEqual(trace.steps, [
            WorkTrace.Step(id: "a", tool: "web.search", startedAt: start.addingTimeInterval(2), finishedAt: start.addingTimeInterval(6)),
            WorkTrace.Step(id: "b", tool: "current_time", startedAt: start.addingTimeInterval(7), finishedAt: start.addingTimeInterval(7), failed: true),
        ])
        XCTAssertEqual(trace.reasoning, ["Looking it up", "Reading the results"])
    }

    func testReceipt_saysHowLongAndHowManyStepsAndIsAbsentWhereNoWorkShowed() {
        var plain = WorkTrace(startedAt: start)
        plain.finishedAt = start.addingTimeInterval(4)
        XCTAssertNil(plain.receipt)

        var thought = WorkTrace(startedAt: start, reasoning: ["Thinking"])
        XCTAssertNil(thought.receipt, "A running turn has no receipt")
        thought.finishedAt = start.addingTimeInterval(12)
        XCTAssertEqual(thought.receipt, "Worked 12 seconds")

        let step = WorkTrace.Step(id: "a", tool: "web.search", startedAt: start, finishedAt: start.addingTimeInterval(3))
        var worked = WorkTrace(startedAt: start, finishedAt: start.addingTimeInterval(130), steps: [step])
        XCTAssertEqual(worked.receipt, "Worked 2 minutes · 1 step")
        worked.steps.append(WorkTrace.Step(id: "b", tool: "web.browse", startedAt: start))
        XCTAssertEqual(worked.receipt, "Worked 2 minutes · 2 steps")
    }

    func testWording_ofDurationsOffsetsAndSteps() {
        XCTAssertEqual(WorkTrace.durationWords(0.2), "1 second")
        XCTAssertEqual(WorkTrace.durationWords(59), "59 seconds")
        XCTAssertEqual(WorkTrace.durationWords(3900), "1 hour, 5 minutes")
        XCTAssertEqual(WorkTrace.clock(12), "0:12")
        XCTAssertEqual(WorkTrace.clock(245), "4:05")
        XCTAssertEqual(WorkTrace.clock(3729), "1:02:09")

        let running = WorkTrace.Step(id: "a", tool: "shell.execute", startedAt: start)
        var done = running
        done.finishedAt = start.addingTimeInterval(3)
        var failed = done
        failed.failed = true
        XCTAssertEqual(WorkTraceView.kindLabel(running, turnFinished: false), "Tool · running")
        XCTAssertEqual(WorkTraceView.kindLabel(running, turnFinished: true), "Tool · not finished")
        XCTAssertEqual(WorkTraceView.kindLabel(done, turnFinished: true), "Tool · 3 seconds")
        XCTAssertEqual(WorkTraceView.kindLabel(failed, turnFinished: true), "Tool · failed · 3 seconds")
    }

    func testTrace_isStoredWithItsTurnAndLoadedByTheReplyItEndedWith() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        await ThreadService.shared.reloadForCurrentUser()
        let threadID = try await ThreadService.shared.createThread(title: "Trace \(UUID().uuidString)").id
        let store = ThreadRepository.shared
        let step = WorkTrace.Step(id: "a", tool: "web.search", startedAt: start, finishedAt: start.addingTimeInterval(3))
        let trace = WorkTrace(startedAt: start, finishedAt: start.addingTimeInterval(9), steps: [step], reasoning: ["Looking it up"])
        let reply = TurnProgress.message(in: threadID, role: "assistant", content: "Here it is.")
        let plainReply = TurnProgress.message(in: threadID, role: "assistant", content: "Hello.")

        try await store.beginTurn(id: "t1-\(threadID)", userMessage: TurnProgress.message(in: threadID, role: "user", content: "Find it"))
        try await store.endTurn(id: "t1-\(threadID)", outcome: .completed, message: reply, trace: trace)
        try await store.beginTurn(id: "t2-\(threadID)", userMessage: TurnProgress.message(in: threadID, role: "user", content: "Hi"))
        try await store.endTurn(id: "t2-\(threadID)", outcome: .completed, message: plainReply)

        let loaded = try await store.loadWorkTraces(threadID: threadID)
        let stored = try await DatabaseManager.shared.dbQueue?.read { db in
            try Data.fetchOne(db, sql: "SELECT trace_ciphertext FROM turns WHERE id = ?", arguments: ["t1-\(threadID)"])
        }

        XCTAssertEqual(loaded, [reply.id: trace])
        XCTAssertNil(stored?.range(of: Data("web.search".utf8)), "A trace is not readable in the database file")

        try await ThreadService.shared.deleteThread(threadId: threadID)
        await ThreadService.shared.reloadForCurrentUser()
        await DataEncryptionService.shared.lock()
    }

    func testTraces_ofAnotherAccountsTurnsAreNotRead() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let threadID = "theirs-\(UUID().uuidString)"
        // Encrypted with the key in memory, so only whose turn it is keeps
        // it from being read.
        let trace = WorkTrace(startedAt: start, finishedAt: start.addingTimeInterval(9), reasoning: ["Looking it up"])
        let ciphertext = try await DataEncryptionService.shared.encrypt(JSONEncoder().encode(trace), purpose: "turn_trace")
        try await queue.write { [start] db in
            try db.execute(
                sql: "INSERT INTO threads (id, user_id, created_at) VALUES (?, ?, ?)",
                arguments: [threadID, "another-user", start]
            )
            try db.execute(
                sql: "INSERT INTO turns (id, user_id, thread_id, status, started_at, message_id, trace_ciphertext) VALUES (?, ?, ?, ?, ?, ?, ?)",
                arguments: ["turn-\(threadID)", "another-user", threadID, "completed", start, "reply-\(threadID)", ciphertext]
            )
        }

        let loaded = try await ThreadRepository.shared.loadWorkTraces(threadID: threadID)

        XCTAssertEqual(loaded, [:])
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM threads WHERE id = ?", arguments: [threadID])
        }
        await DataEncryptionService.shared.lock()
    }
}
