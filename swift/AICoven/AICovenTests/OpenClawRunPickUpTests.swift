@testable import AICoven
internal import Combine
import CryptoKit
import XCTest

/// The states a turn reported, in order. Added to from the turn's task and
/// read by the test, under the lock.
private final class PickUpReports: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [TurnState] = []

    func add(_ state: TurnState) {
        lock.withLock { states.append(state) }
    }

    var last: TurnState? {
        lock.withLock { states.last }
    }

    var answers: [String] {
        lock.withLock { states.map(\.answer) }
    }
}

/// A run OpenClaw went on with while this app was closed: where it stands is
/// read through the Gateway, and it is followed from there or shown as it
/// ended.
final class OpenClawRunPickUpTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private let address = "ws://127.0.0.1:18789"

    private func session(_ threadID: String = "thread-1") -> String {
        "agent:main:aicoven-local:\(threadID)"
    }

    private func turn(
        over socket: ScriptedGatewaySocket,
        threadID: String = "thread-1",
        ask: @escaping @Sendable (ToolApproval) async -> ApprovalAnswer = { _ in .denied }
    ) throws -> OpenClawTurn {
        let identity = try OpenClawDeviceIdentity(privateKey: key.rawRepresentation)
        return try OpenClawTurn(
            address: XCTUnwrap(OpenClawGatewayConnection.address(address)),
            token: "TOKEN",
            threadID: threadID,
            ask: ask,
            open: { _, token in
                let gateway = OpenClawGatewayConnection(socket: socket, identity: identity, token: token)
                socket.push(ScriptedGatewaySocket.challenge)
                return try await (gateway, gateway.open())
            },
            // Not the five seconds a person is given.
            longestWaitToStop: 0.2
        )
    }

    private func answer(_ request: [String: Any], with payload: [String: Any]) -> [String: Any] {
        ["type": "res", "id": request["id"] ?? "", "ok": true, "payload": payload]
    }

    private func chat(_ state: String, _ more: [String: Any] = [:], in threadID: String = "thread-1") -> [String: Any] {
        var payload: [String: Any] = ["sessionKey": session(threadID), "runId": "run-1", "state": state]
        payload.merge(more) { _, new in new }
        return ["type": "event", "event": "chat", "payload": payload]
    }

    private func row(_ role: String, _ more: [String: Any] = [:], run: String = "run-1") -> [String: Any] {
        var row: [String: Any] = ["role": role, "__openclaw": ["runId": run]]
        row.merge(more) { _, new in new }
        return row
    }

    /// Plays a Gateway asked about `run-1`: it welcomes the connection,
    /// names the session with what is `waiting` to be allowed in it, says
    /// where the run stands (`wait`), and holds `history` of it; `then` is
    /// what it sends after the history, and `after` how it answers
    /// anything else.
    private func play(
        _ socket: ScriptedGatewaySocket,
        threadID: String = "thread-1",
        waiting: [[String: Any]] = [],
        wait: [String: Any],
        history: [String: Any] = [:],
        then: [[String: Any]] = [],
        after: @escaping @Sendable (_ request: [String: Any]) -> [[String: Any]] = { _ in [] }
    ) {
        let session = session(threadID)
        // Only read, by the socket's tasks.
        nonisolated(unsafe) let (waiting, wait, history, then) = (waiting, wait, history, then)
        socket.answer { [self] request in
            switch request["method"] as? String {
            case "connect":
                return [ScriptedGatewaySocket.welcome(to: request["id"] as? String ?? "")]
            case "sessions.messages.subscribe":
                return [answer(request, with: ["subscribed": true, "key": session, "approvalReplay": ["approvals": waiting]])]
            case "agent.wait":
                return [answer(request, with: wait)]
            case "chat.history":
                return [answer(request, with: history)] + then
            default:
                return after(request)
            }
        }
    }

    // MARK: - Where the run stands

    func testARunThatEndedWhileTheAppWasClosed_showsTheAnswerItsHistoryHolds() async throws {
        let socket = ScriptedGatewaySocket()
        play(
            socket,
            wait: ["runId": "run-1", "status": "ok", "endedAt": 1_791_417_700_000],
            history: ["messages": [
                row("assistant", ["content": [["type": "toolCall", "name": "exec"]], "stopReason": "toolUse"]),
                row("toolResult"),
                row("assistant", ["content": "Another run's answer.", "stopReason": "stop"], run: "run-0"),
                row("assistant", ["content": [["type": "text", "text": "Done while away."]], "stopReason": "stop"]),
            ]]
        )
        let reports = PickUpReports()

        try await turn(over: socket).resume(runID: "run-1", report: reports.add)

        XCTAssertEqual(reports.last?.status, .completed)
        XCTAssertEqual(reports.last?.answer, "Done while away.")
        let requests = socket.sent.dropFirst()
        XCTAssertEqual(requests.map { $0["method"] as? String }, ["sessions.messages.subscribe", "agent.wait", "chat.history"], "No run is started")
        let subscribe = try XCTUnwrap(requests.first?["params"] as? [String: Any])
        XCTAssertEqual(subscribe["key"] as? String, "aicoven-local:thread-1")
        XCTAssertEqual(subscribe["includeApprovals"] as? Bool, true)
        let wait = try XCTUnwrap(requests.dropFirst().first?["params"] as? [String: Any])
        XCTAssertEqual(wait["runId"] as? String, "run-1")
        XCTAssertEqual(wait["timeoutMs"] as? Int, 1000)
        let history = try XCTUnwrap(requests.last?["params"] as? [String: Any])
        XCTAssertEqual(history["sessionKey"] as? String, session(), "Asked under the Gateway's own name for the session")
        XCTAssertEqual(history["inputRunIds"] as? [String], ["run-1"])
        XCTAssertEqual(history["limit"] as? Int, 20)
        XCTAssertEqual(history["maxChars"] as? Int, 65536)
        XCTAssertTrue(socket.isClosed)
    }

    func testARunThatEndedWithNoAnswerToRead_saysWhereItsAnswerIs() async throws {
        let socket = ScriptedGatewaySocket()
        play(socket, wait: ["status": "ok", "endedAt": 1], history: ["messages": [row("toolResult")]])
        let reports = PickUpReports()

        try await turn(over: socket).resume(runID: "run-1", report: reports.add)

        XCTAssertEqual(reports.last?.status, .completed)
        XCTAssertEqual(reports.last?.answer, OpenClawTurn.noAnswerToShow)
    }

    func testARunThatFailedOrWasStoppedWhileTheAppWasClosed_endsAsItDid() async throws {
        let failed = ScriptedGatewaySocket()
        play(failed, wait: ["status": "error", "errorKind": "timeout", "endedAt": 1])
        let failure = PickUpReports()
        try await turn(over: failed).resume(runID: "run-1", report: failure.add)
        XCTAssertEqual(failure.last?.status, .failed)
        XCTAssertEqual(failure.last?.answer, "OpenClaw could not finish this run. It timed out.")
        XCTAssertFalse(failed.sent.contains { $0["method"] as? String == "chat.history" })

        let stopped = ScriptedGatewaySocket()
        play(stopped, wait: ["status": "error", "stopReason": "rpc", "endedAt": 1])
        let stop = PickUpReports()
        try await turn(over: stopped).resume(runID: "run-1", report: stop.add)
        XCTAssertEqual(stop.last?.status, .cancelled)

        // A wait that ran out with the run ended is of a run that failed.
        let ranOut = ScriptedGatewaySocket()
        play(ranOut, wait: ["status": "timeout", "endedAt": 1])
        let out = PickUpReports()
        try await turn(over: ranOut).resume(runID: "run-1", report: out.add)
        XCTAssertEqual(out.last?.status, .failed)
        XCTAssertEqual(out.last?.answer, OpenClawTurn.notFinished)

        // An end time is a number: true is not one, and the run is not ended by it.
        let notATime = ScriptedGatewaySocket()
        play(notATime, wait: ["status": "timeout", "endedAt": true], history: ["sessionInfo": ["activeRunIds": ["run-1"]]], then: [chat("final", ["finalText": "Done."])])
        let going = PickUpReports()
        try await turn(over: notATime).resume(runID: "run-1", report: going.add)
        XCTAssertEqual(going.last?.status, .completed)
        XCTAssertEqual(going.last?.answer, "Done.")
    }

    func testARunTheGatewayNoLongerHas_endsSayingSo() async throws {
        let socket = ScriptedGatewaySocket()
        // Not ended as far as the wait says, and the session has no run going.
        play(socket, wait: ["status": "timeout"], history: ["messages": [], "sessionInfo": ["activeRunIds": ["run-9"]]])
        let reports = PickUpReports()

        try await turn(over: socket).resume(runID: "run-1", report: reports.add)

        XCTAssertEqual(reports.last?.status, .failed)
        XCTAssertEqual(reports.last?.answer, OpenClawTurn.runGone)
    }

    func testARunStillGoing_isFollowedToItsEnd() async throws {
        for history in [
            ["sessionInfo": ["activeRunIds": ["run-1"]]],
            ["inFlightRun": ["runId": "run-1", "text": "So far"], "sessionInfo": ["activeRunIds": [String]()]],
            // The history does not say; the wait did.
            ["messages": [[String: Any]]()],
        ] as [[String: Any]] {
            let socket = ScriptedGatewaySocket()
            play(socket, wait: ["status": "timeout"], history: history, then: [
                chat("delta", ["deltaText": "and "]),
                chat("final", ["finalText": "Started before, and done."]),
            ])
            let reports = PickUpReports()

            try await turn(over: socket).resume(runID: "run-1", report: reports.add)

            XCTAssertEqual(reports.answers, ["and ", "Started before, and done."])
            XCTAssertEqual(reports.last?.status, .completed)
            XCTAssertFalse(socket.sent.contains { $0["method"] as? String == "chat.send" })
        }
    }

    func testWhatARunPickedUpIsWaitingToBeAllowed_isAskedAgain() async throws {
        let socket = ScriptedGatewaySocket()
        let waiting: [String: Any] = [
            "id": "approval:1", "status": "pending",
            "presentation": ["kind": "exec", "commandText": "git push", "allowedDecisions": ["allow-once", "deny"]],
        ]
        play(socket, waiting: [waiting], wait: ["status": "timeout"], history: ["sessionInfo": ["activeRunIds": ["run-1"]]], after: { [self] request in
            guard request["method"] as? String == "approval.resolve" else { return [] }
            return [answer(request, with: ["ok": true]), chat("final", ["finalText": "Pushed."])]
        })
        let asked = expectation(description: "The person is asked")
        let reports = PickUpReports()

        try await turn(over: socket) { approval in
            XCTAssertEqual(approval.details, "git push")
            asked.fulfill()
            return .approved
        }.resume(runID: "run-1", report: reports.add)

        await fulfillment(of: [asked], timeout: 10)
        let resolved = socket.sent.filter { $0["method"] as? String == "approval.resolve" }.compactMap { $0["params"] as? [String: String] }
        XCTAssertEqual(resolved, [["id": "approval:1", "kind": "exec", "decision": "allow-once"]])
        XCTAssertEqual(reports.last?.answer, "Pushed.")
    }

    func testWhenContactIsLostAsARunIsLookedFor_theTurnSaysTheRunMayBeGoing() async throws {
        let socket = ScriptedGatewaySocket()
        let session = session()
        socket.answer { [self] request in
            switch request["method"] as? String {
            case "connect":
                return [ScriptedGatewaySocket.welcome(to: request["id"] as? String ?? "")]
            case "sessions.messages.subscribe":
                return [answer(request, with: ["subscribed": true, "key": session])]
            default:
                socket.close()
                return []
            }
        }
        let reports = PickUpReports()

        try await turn(over: socket).resume(runID: "run-1", report: reports.add)

        XCTAssertEqual(reports.last?.status, .failed)
        XCTAssertEqual(reports.last?.answer, OpenClawTurn.lostContact)
    }

    func testWhenTheGatewayCannotBeReachedOrContactIsLostAsTheSessionIsAskedFor_theTurnSaysTheRunMayBeGoing() async throws {
        // The Gateway is not there.
        var unreachable = try turn(over: ScriptedGatewaySocket())
        unreachable.open = { _, _ in throw URLError(.cannotConnectToHost) }
        let none = PickUpReports()
        try await unreachable.resume(runID: "run-1", report: none.add)
        XCTAssertEqual(none.last?.status, .failed)
        XCTAssertEqual(none.last?.answer, OpenClawTurn.lostContact)

        // Contact is lost as the session is asked for.
        let socket = ScriptedGatewaySocket()
        socket.answer { request in
            guard request["method"] as? String == "connect" else {
                socket.close()
                return []
            }
            return [ScriptedGatewaySocket.welcome(to: request["id"] as? String ?? "")]
        }
        let lost = PickUpReports()
        try await turn(over: socket).resume(runID: "run-1", report: lost.add)
        XCTAssertEqual(lost.last?.status, .failed)
        XCTAssertEqual(lost.last?.answer, OpenClawTurn.lostContact)

        // What the Gateway refuses is thrown as it is given.
        let refusing = ScriptedGatewaySocket()
        refusing.answer { request in
            guard request["method"] as? String == "connect" else {
                return [["type": "res", "id": request["id"] ?? "", "ok": false, "error": ["code": "UNAVAILABLE", "message": "Busy"]]]
            }
            return [ScriptedGatewaySocket.welcome(to: request["id"] as? String ?? "")]
        }
        do {
            try await turn(over: refusing).resume(runID: "run-1", report: { _ in XCTFail("Nothing is known of the run") })
            XCTFail("A refusal does not end as a reply")
        } catch {
            XCTAssertEqual(error as? OpenClawGatewayError, .refused(code: "UNAVAILABLE", message: "Busy"))
        }
    }

    func testStoppingATurnPickedUpBeforeTheGatewayNamesItsSession_stillStopsTheRun() async throws {
        let socket = ScriptedGatewaySocket()
        let aborted = expectation(description: "The Gateway is told to stop the run")
        socket.answer { [self] request in
            switch request["method"] as? String {
            case "connect":
                return [ScriptedGatewaySocket.welcome(to: request["id"] as? String ?? "")]
            case "chat.abort":
                aborted.fulfill()
                return [answer(request, with: ["ok": true, "aborted": true])]
            default:
                // The Gateway does not answer the subscribe.
                return []
            }
        }
        let turn = try turn(over: socket)
        let running = Task { try await turn.resume(runID: "run-1", report: { _ in }) }
        await fulfillment(of: [socket.expectSent(2)], timeout: 10)

        running.cancel()
        do {
            try await running.value
            XCTFail("A stopped turn does not end as a reply")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await fulfillment(of: [aborted], timeout: 10)

        let abort = socket.sent.first { $0["method"] as? String == "chat.abort" }?["params"] as? [String: String]
        XCTAssertEqual(abort, ["sessionKey": "aicoven-local:thread-1", "runId": "run-1"], "Under the name the session was asked for with")
    }

    func testStoppingATurnPickedUpWhileItsConnectionIsOpening_stopsTheRunOnceItIsOpen() async throws {
        let socket = ScriptedGatewaySocket()
        let aborted = expectation(description: "The Gateway is told to stop the run")
        socket.answer { [self] request in
            switch request["method"] as? String {
            case "connect":
                return [ScriptedGatewaySocket.welcome(to: request["id"] as? String ?? "")]
            case "chat.abort":
                aborted.fulfill()
                return [answer(request, with: ["ok": true, "aborted": true])]
            default:
                return []
            }
        }
        let opening = expectation(description: "The connection is being opened")
        var turn = try turn(over: socket)
        let open = turn.open
        turn.open = { address, token in
            opening.fulfill()
            // Held until the turn is stopped; the handshake then completes.
            while !Task.isCancelled {
                await Task.yield()
            }
            return try await open(address, token)
        }
        let running = Task { [turn] in try await turn.resume(runID: "run-1", report: { _ in }) }
        await fulfillment(of: [opening], timeout: 10)

        running.cancel()
        do {
            try await running.value
            XCTFail("A stopped turn does not end as a reply")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await fulfillment(of: [aborted], timeout: 10)

        XCTAssertFalse(socket.sent.contains { $0["method"] as? String == "sessions.messages.subscribe" }, "Nothing more is asked of a turn that was stopped")
        let abort = socket.sent.first { $0["method"] as? String == "chat.abort" }?["params"] as? [String: String]
        XCTAssertEqual(abort, ["sessionKey": "aicoven-local:thread-1", "runId": "run-1"])
    }

    func testStoppingATurnPickedUp_stopsTheRunInOpenClaw() async throws {
        let socket = ScriptedGatewaySocket()
        let aborted = expectation(description: "The Gateway is told to stop the run")
        play(socket, wait: ["status": "timeout"], history: ["sessionInfo": ["activeRunIds": ["run-1"]]], then: [chat("delta", ["deltaText": "Working"])], after: { [self] request in
            guard request["method"] as? String == "chat.abort" else { return [] }
            aborted.fulfill()
            return [answer(request, with: ["ok": true, "aborted": true])]
        })
        let working = expectation(description: "The run is being followed")
        working.assertForOverFulfill = false
        let turn = try turn(over: socket)
        let running = Task { try await turn.resume(runID: "run-1", report: { _ in working.fulfill() }) }
        await fulfillment(of: [working], timeout: 10)

        running.cancel()
        do {
            try await running.value
            XCTFail("A stopped turn does not end as a reply")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await fulfillment(of: [aborted], timeout: 10)

        let abort = socket.sent.first { $0["method"] as? String == "chat.abort" }?["params"] as? [String: String]
        XCTAssertEqual(abort, ["sessionKey": session(), "runId": "run-1"])
    }

    // MARK: - What the history holds of a run

    func testTheHistorysNewestRowOfTheRun_saysHowItEndedOrThatItHasNot() {
        func ending(_ rows: [[String: Any]]) -> String? {
            OpenClawTurn.ending(of: "run-1", in: ["messages": rows]).map { "\($0.status.rawValue): \($0.answer)" }
        }
        XCTAssertEqual(ending([row("assistant", ["content": "Done.", "stopReason": "stop"])]), "completed: Done.")
        XCTAssertEqual(ending([row("assistant", ["content": "Cut sho", "stopReason": "length"])]), "completed: Cut sho")
        XCTAssertEqual(ending([row("assistant", ["content": "Half", "openclawAbort": ["aborted": true]])]), "cancelled: Half")
        XCTAssertEqual(ending([row("assistant", ["stopReason": "aborted"])]), "cancelled: ")
        XCTAssertEqual(
            ending([row("assistant", ["stopReason": "error", "errorKind": "rate_limit"])]),
            "failed: OpenClaw could not finish this run. Its model's provider is limiting requests."
        )
        // Not ended by: a step that calls a tool, a tool's result, an
        // answer with nothing in it, a row with no reason to have stopped.
        XCTAssertNil(ending([row("assistant", ["content": [["type": "text", "text": "Let me look"], ["type": "toolCall"]], "stopReason": "stop"])]))
        XCTAssertNil(ending([row("assistant", ["content": "Done.", "stopReason": "stop"]), row("toolResult")]))
        XCTAssertNil(ending([row("assistant", ["content": "  ", "stopReason": "stop"])]))
        XCTAssertNil(ending([row("assistant", ["content": "Thinking"])]))
        // Nor by another run's rows, or a row that is not the run's own.
        XCTAssertNil(ending([row("assistant", ["content": "Done.", "stopReason": "stop"], run: "run-2")]))
        XCTAssertNil(ending([["role": "assistant", "content": "Done.", "stopReason": "stop"]]))
        XCTAssertNil(ending([row("user", ["content": "Done.", "stopReason": "stop"])]))

        XCTAssertEqual(OpenClawTurn.isGoing("run-1", in: ["inFlightRun": ["runId": "run-1"]]), true)
        XCTAssertEqual(OpenClawTurn.isGoing("run-1", in: ["sessionInfo": ["activeRunIds": ["run-1"]]]), true)
        XCTAssertEqual(OpenClawTurn.isGoing("run-1", in: ["sessionInfo": ["activeRunIds": ["run-2"], "hasActiveRun": true]]), false)
        XCTAssertEqual(OpenClawTurn.isGoing("run-1", in: ["sessionInfo": ["hasActiveRun": false]]), false)
        XCTAssertNil(OpenClawTurn.isGoing("run-1", in: ["inFlightRun": ["runId": "run-2"]]))
        XCTAssertNil(OpenClawTurn.isGoing("run-1", in: [:]))
    }

    // MARK: - From the chat, and from the thread

    private func chatService(_ turn: OpenClawTurn?) -> ChatService {
        ChatService(
            contextBuilder: ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4)),
            modelRouter: HeuristicModelRouter(availableModels: []),
            llmClients: [:],
            threadStore: ThreadRepository.shared,
            toolService: ToolService.shared,
            shouldAutoRefreshEnvironment: false,
            hermesAgent: { nil },
            openClawTurn: { _ in turn }
        )
    }

    func testARunCanBePickedUp_onlyThroughTheGatewayItWasStartedThrough() async throws {
        let connected = try chatService(turn(over: ScriptedGatewaySocket()))
        let here = AgentRun(provider: AgentRun.openClaw, runID: "run-1", origin: address)
        let elsewhere = AgentRun(provider: AgentRun.openClaw, runID: "run-1", origin: "wss://other.example")
        let unplaced = AgentRun(provider: AgentRun.openClaw, runID: "run-1")

        let canHere = await connected.canResume(here)
        let canElsewhere = await connected.canResume(elsewhere)
        let canUnplaced = await connected.canResume(unplaced)
        let canWithNone = await chatService(nil).canResume(here)
        XCTAssertTrue(canHere)
        XCTAssertFalse(canElsewhere)
        XCTAssertFalse(canUnplaced)
        XCTAssertFalse(canWithNone)

        do {
            try await connected.resumeAgentRun(elsewhere, threadId: "thread-1", onStateChange: { _ in })
            XCTFail("A run started through another Gateway is not looked for at this one")
        } catch {
            XCTAssertEqual(error as? OpenClawTurn.CannotPickUp, OpenClawTurn.CannotPickUp())
        }
    }

    @MainActor
    func testATurnTheAppClosedOnWhileOpenClawRanIt_isPickedUpWhenItsThreadIsOpened() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        await ThreadService.shared.reloadForCurrentUser()
        let threadID = try await ThreadService.shared.createThread(title: "OpenClaw \(UUID().uuidString)").id
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await ThreadService.shared.deleteThread(threadId: threadID)
            await ThreadService.shared.reloadForCurrentUser()
            await DataEncryptionService.shared.lock()
        }
        let store = ThreadRepository.shared
        // As the app left it: a turn recorded as running, with its run and
        // the Gateway it was started through.
        let turnID = "turn-\(threadID)"
        try await store.beginTurn(id: turnID, userMessage: TurnProgress.message(in: threadID, role: "user", content: "Tidy the repo"))
        let run = AgentRun(provider: AgentRun.openClaw, runID: "run-1", agentName: "Claw", origin: address)
        try await store.keepRun(run, forTurn: turnID)
        let kept = try await store.runningTurns(threadID: threadID)
        XCTAssertEqual(kept.map(\.run), [run])

        let socket = ScriptedGatewaySocket()
        play(
            socket, threadID: threadID,
            wait: ["status": "ok", "endedAt": 1],
            history: ["messages": [row("assistant", ["content": "Done while away.", "stopReason": "stop"])]]
        )
        let engine = try TurnEngine(chat: chatService(turn(over: socket, threadID: threadID)))

        let ended = expectation(description: "The turn picked up has ended")
        ended.assertForOverFulfill = false
        let watching = engine.$endings.sink { endings in
            if endings[threadID] != nil { ended.fulfill() }
        }
        await engine.settleInterruptedTurns(threadID: threadID)
        await fulfillment(of: [ended], timeout: 10)
        watching.cancel()
        // The ending is published just before the turn stops being shown
        // as running.
        await Task.yield()

        XCTAssertEqual(engine.endings[threadID]?.outcome, .completed)
        let messages = try await store.loadChatMessages(threadID: threadID, limit: 10, before: nil)
        XCTAssertEqual(messages.map(\.content), ["Tidy the repo", "Done while away."])
        XCTAssertEqual(messages.last?.metadata?["role_name"], AnyJSONValue("Claw"))
        let left = try await store.runningTurns(threadID: threadID)
        XCTAssertEqual(left, [])
        await DataEncryptionService.shared.lock()
    }

    @MainActor
    func testARunStoppedInOpenClawWhileTheAppWasClosed_keepsWhatItHadAnswered() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        await ThreadService.shared.reloadForCurrentUser()
        let threadID = try await ThreadService.shared.createThread(title: "OpenClaw \(UUID().uuidString)").id
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await ThreadService.shared.deleteThread(threadId: threadID)
            await ThreadService.shared.reloadForCurrentUser()
            await DataEncryptionService.shared.lock()
        }
        let store = ThreadRepository.shared
        let turnID = "turn-\(threadID)"
        try await store.beginTurn(id: turnID, userMessage: TurnProgress.message(in: threadID, role: "user", content: "Tidy the repo"))
        try await store.keepRun(AgentRun(provider: AgentRun.openClaw, runID: "run-1", origin: address), forTurn: turnID)
        let socket = ScriptedGatewaySocket()
        play(
            socket, threadID: threadID,
            wait: ["status": "ok", "endedAt": 1],
            history: ["messages": [row("assistant", ["content": "Half the answer", "openclawAbort": ["aborted": true]])]]
        )
        let engine = try TurnEngine(chat: chatService(turn(over: socket, threadID: threadID)))

        let ended = expectation(description: "The turn picked up has ended")
        ended.assertForOverFulfill = false
        let watching = engine.$endings.sink { endings in
            if endings[threadID] != nil { ended.fulfill() }
        }
        await engine.settleInterruptedTurns(threadID: threadID)
        await fulfillment(of: [ended], timeout: 10)
        watching.cancel()

        XCTAssertEqual(engine.endings[threadID]?.outcome, .cancelled)
        let messages = try await store.loadChatMessages(threadID: threadID, limit: 10, before: nil)
        XCTAssertEqual(messages.map(\.content), ["Tidy the repo", "Half the answer\n\n_Stopped here._"])
        await DataEncryptionService.shared.lock()
    }

    @MainActor
    func testATurnWhoseGatewayIsNoLongerTheOneConnected_isEndedAsInterrupted() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        await ThreadService.shared.reloadForCurrentUser()
        let threadID = try await ThreadService.shared.createThread(title: "OpenClaw \(UUID().uuidString)").id
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await ThreadService.shared.deleteThread(threadId: threadID)
            await ThreadService.shared.reloadForCurrentUser()
            await DataEncryptionService.shared.lock()
        }
        let store = ThreadRepository.shared
        let turnID = "turn-\(threadID)"
        try await store.beginTurn(id: turnID, userMessage: TurnProgress.message(in: threadID, role: "user", content: "Tidy the repo"))
        try await store.keepRun(AgentRun(provider: AgentRun.openClaw, runID: "run-1", origin: "wss://other.example"), forTurn: turnID)
        let socket = ScriptedGatewaySocket()
        let engine = try TurnEngine(chat: chatService(turn(over: socket, threadID: threadID)))

        await engine.settleInterruptedTurns(threadID: threadID)

        let messages = try await store.loadChatMessages(threadID: threadID, limit: 10, before: nil)
        XCTAssertEqual(messages.map(\.content), ["Tidy the repo", TurnProgress.interruptedNotice])
        XCTAssertEqual(socket.sent.count, 0, "The Gateway connected is not asked about another's run")
        await DataEncryptionService.shared.lock()
    }
}
