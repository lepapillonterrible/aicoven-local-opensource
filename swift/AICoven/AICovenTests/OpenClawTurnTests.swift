@testable import AICoven
import CryptoKit
import XCTest

/// The states a turn reported, in order. Added to from the turn's task and
/// read by the test, under the lock.
private final class TurnReports: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [TurnState] = []

    func add(_ state: TurnState) {
        lock.withLock { states.append(state) }
    }

    var all: [TurnState] {
        lock.withLock { states }
    }
}

/// What a turn asked the person.
private actor AskedOfThePerson {
    private(set) var approvals: [ToolApproval] = []

    func note(_ approval: ToolApproval) {
        approvals.append(approval)
    }
}

/// One of the app's own models, which counts how often it is called.
private final class CountingChatModel: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var calls: Int {
        lock.withLock { count }
    }

    func completeChat(messages _: [LLMMessage], model _: String, options _: ChatOptions) async throws -> LLMChatResponse {
        lock.withLock { count += 1 }
        throw URLError(.badServerResponse)
    }

    func embed(texts _: [String], model _: String) async throws -> [[Float]] {
        lock.withLock { count += 1 }
        return []
    }
}

/// The run ids a turn told of.
private actor RunsToldOf {
    private(set) var ids: [String] = []

    func note(_ id: String) {
        ids.append(id)
    }
}

/// A turn made by OpenClaw through its Gateway: the run is started in the
/// thread's session, followed, answered and stopped through the Gateway.
final class OpenClawTurnTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    /// The Gateway's own name for the thread's session.
    private let session = "agent:main:aicoven-local:thread-1"

    private func turn(
        over socket: ScriptedGatewaySocket,
        threadID: String = "thread-1",
        ask: @escaping @Sendable (ToolApproval) async -> ApprovalAnswer = { _ in .denied }
    ) throws -> OpenClawTurn {
        let identity = try OpenClawDeviceIdentity(privateKey: key.rawRepresentation)
        return try OpenClawTurn(
            address: XCTUnwrap(OpenClawGatewayConnection.address("ws://127.0.0.1:18789")),
            token: "TOKEN",
            threadID: threadID,
            ask: ask,
            open: { _, token in
                let gateway = OpenClawGatewayConnection(socket: socket, identity: identity, token: token)
                socket.push(ScriptedGatewaySocket.challenge)
                return try await (gateway, gateway.open())
            }
        )
    }

    private func answer(_ request: [String: Any], with payload: [String: Any]) -> [String: Any] {
        ["type": "res", "id": request["id"] ?? "", "ok": true, "payload": payload]
    }

    private func chat(_ state: String, run: String, _ more: [String: Any] = [:]) -> [String: Any] {
        var payload: [String: Any] = ["sessionKey": session, "runId": run, "state": state]
        payload.merge(more) { _, new in new }
        return ["type": "event", "event": "chat", "payload": payload]
    }

    /// Plays a Gateway that welcomes the connection, names the session and
    /// starts the run; `during` says what it sends once the run has
    /// started, and `after` how it answers anything else.
    private func play(
        _ socket: ScriptedGatewaySocket,
        during run: @escaping @Sendable (_ runID: String) -> [[String: Any]],
        after: @escaping @Sendable (_ request: [String: Any]) -> [[String: Any]] = { _ in [] }
    ) {
        let session = session
        socket.answer { [self] request in
            let params = request["params"] as? [String: Any] ?? [:]
            switch request["method"] as? String {
            case "connect":
                return [ScriptedGatewaySocket.welcome(to: request["id"] as? String ?? "")]
            case "sessions.messages.subscribe":
                return [answer(request, with: ["subscribed": true, "key": session, "agentId": "main"])]
            case "chat.send":
                let runID = params["idempotencyKey"] as? String ?? ""
                return [answer(request, with: ["runId": runID, "status": "started", "messageSeq": 1])] + run(runID)
            default:
                return after(request)
            }
        }
    }

    // MARK: - A run from start to answer

    func testARun_isStartedInTheThreadsSessionAndFollowedToItsAnswer() async throws {
        let socket = ScriptedGatewaySocket()
        play(socket) { [self] runID in
            [
                chat("status", run: runID, ["phase": "starting_model"]),
                chat("delta", run: runID, ["deltaText": "All "]),
                chat("delta", run: "another-run", ["deltaText": "not this run's"]),
                chat("delta", run: runID, ["deltaText": "dne"]),
                chat("delta", run: runID, ["deltaText": "All done", "replace": true]),
                chat("final", run: runID, ["finalText": "All done.", "stopReason": "stop"]),
            ]
        }
        let reports = TurnReports()
        let started = RunsToldOf()

        try await turn(over: socket).run(
            message: "Tidy the repo",
            started: { await started.note($0) },
            report: reports.add
        )

        let requests = socket.sent.dropFirst()
        XCTAssertEqual(requests.map { $0["method"] as? String }, ["sessions.messages.subscribe", "chat.send"])
        let subscribe = try XCTUnwrap(requests.first?["params"] as? [String: Any])
        XCTAssertEqual(subscribe["key"] as? String, "aicoven-local:thread-1")
        XCTAssertEqual(subscribe["includeApprovals"] as? Bool, true)
        let send = try XCTUnwrap(requests.last?["params"] as? [String: Any])
        XCTAssertEqual(send["sessionKey"] as? String, session, "The run is started under the Gateway's own name for the session")
        XCTAssertEqual(send["message"] as? String, "Tidy the repo")
        let runID = try XCTUnwrap(send["idempotencyKey"] as? String)
        XCTAssertEqual(Set(send.keys), ["sessionKey", "message", "idempotencyKey"])
        let told = await started.ids
        XCTAssertEqual(told, [runID], "The run's id is told as soon as there is one")

        let states = reports.all
        XCTAssertEqual(states.map(\.answer), ["All ", "All dne", "All done", "All done."])
        XCTAssertEqual(states.last?.status, .completed)
        XCTAssertTrue(socket.isClosed, "The connection is for the one run")
    }

    func testARunThatEndsInAnError_endsFailedAndSaysWhy() async throws {
        let socket = ScriptedGatewaySocket()
        play(socket) { [self] runID in [chat("error", run: runID, ["errorKind": "rate_limit", "errorMessage": "429"])] }
        let reports = TurnReports()

        try await turn(over: socket).run(message: "Go", report: reports.add)

        XCTAssertEqual(reports.all.last?.status, .failed)
        XCTAssertEqual(reports.all.last?.answer, "OpenClaw could not finish this run. Its model's provider is limiting requests.")
    }

    func testARunOpenClawSaysWasStoppedThere_endsAsStoppedWithWhatHadBeenAnswered() async throws {
        let socket = ScriptedGatewaySocket()
        play(socket) { [self] runID in
            [chat("delta", run: runID, ["deltaText": "Half"]), chat("aborted", run: runID, ["stopReason": "rpc"])]
        }
        let reports = TurnReports()

        try await turn(over: socket).run(message: "Go", report: reports.add)

        XCTAssertEqual(reports.all.last?.status, .cancelled)
        XCTAssertEqual(reports.all.last?.answer, "Half")
    }

    func testWhenTheConnectionIsLostBeforeTheRunEnds_theTurnFailsSayingTheRunMayStillBeGoing() async throws {
        let socket = ScriptedGatewaySocket()
        play(socket) { [self] runID in
            // An event number skipped: the connection can no longer be trusted.
            [
                ["type": "event", "event": "chat", "seq": 1, "payload": ["sessionKey": session, "runId": runID, "state": "delta", "deltaText": "Half"]],
                ["type": "event", "event": "chat", "seq": 5, "payload": ["sessionKey": session, "runId": runID, "state": "final", "finalText": "x"]],
            ]
        }
        let reports = TurnReports()

        try await turn(over: socket).run(message: "Go", report: reports.add)

        XCTAssertEqual(reports.all.last?.status, .failed)
        XCTAssertEqual(reports.all.last?.answer, OpenClawTurn.lostContact)
    }

    func testAGatewayThatLacksWhatATurnNeeds_startsNoRun() async throws {
        let socket = ScriptedGatewaySocket()
        socket.answer { request in
            request["method"] as? String == "connect"
                ? [ScriptedGatewaySocket.welcome(to: request["id"] as? String ?? "", methods: ["chat.send"])]
                : []
        }

        do {
            try await turn(over: socket).run(message: "Go", report: { _ in })
            XCTFail("No run without what a turn needs")
        } catch {
            XCTAssertEqual(error as? OpenClawGatewayError, .notSupported("sessions.messages.subscribe"))
        }
        XCTAssertEqual(socket.sent.count, 1)
        XCTAssertTrue(socket.isClosed)
    }

    // MARK: - Approvals

    private func approval(_ id: String, _ presentation: [String: Any], phase: String = "pending") -> [String: Any] {
        [
            "type": "event", "event": "session.approval",
            "payload": [
                "sessionKey": session, "sourceSessionKey": session, "phase": phase,
                "approval": ["id": id, "status": phase, "presentation": presentation],
            ],
        ]
    }

    func testWhatOpenClawAsksToBeAllowed_isAskedOfThePersonAndTheirAnswerGivenToTheGateway() async throws {
        let socket = ScriptedGatewaySocket()
        let command: [String: Any] = [
            "kind": "exec", "commandText": "rm -rf build", "warningText": "Deletes files", "host": "this-mac",
            "allowedDecisions": ["allow-once", "allow-always", "deny"],
        ]
        play(socket, during: { [self] _ in
            // Sent twice, and once as settled: asked once.
            [approval("approval:1", command), approval("approval:1", command), approval("approval:9", command, phase: "terminal")]
        }, after: { [self] request in
            guard request["method"] as? String == "approval.resolve" else { return [] }
            let runID = (socket.sent.first { $0["method"] as? String == "chat.send" }?["params"] as? [String: Any])?["idempotencyKey"] as? String ?? ""
            return [answer(request, with: ["ok": true]), chat("final", run: runID, ["finalText": "Removed."])]
        })
        let asked = AskedOfThePerson()

        try await turn(over: socket) { approval in
            await asked.note(approval)
            return .approved
        }.run(message: "Clean up", report: { _ in })

        let approvals = await asked.approvals
        XCTAssertEqual(approvals.count, 1)
        XCTAssertEqual(approvals.first?.threadID, "thread-1")
        XCTAssertEqual(approvals.first?.question, "Let OpenClaw run this command?")
        XCTAssertEqual(approvals.first?.details, "rm -rf build\nDeletes files\nOn this-mac")
        XCTAssertEqual(approvals.first?.canApprove, true)
        let resolved = socket.sent.filter { $0["method"] as? String == "approval.resolve" }.compactMap { $0["params"] as? [String: String] }
        XCTAssertEqual(resolved, [["id": "approval:1", "kind": "exec", "decision": "allow-once"]])
    }

    func testADeniedApprovalAndOneThatCannotBeAsked_areGivenToTheGatewayAsDeny() async throws {
        for given in [ApprovalAnswer.denied, .notAsked] {
            let socket = ScriptedGatewaySocket()
            play(socket, during: { [self] _ in
                [approval("approval:1", ["kind": "plugin", "title": "Send the email", "allowedDecisions": ["allow-once", "deny"]])]
            }, after: { [self] request in
                guard request["method"] as? String == "approval.resolve" else { return [] }
                let runID = (socket.sent.first { $0["method"] as? String == "chat.send" }?["params"] as? [String: Any])?["idempotencyKey"] as? String ?? ""
                return [answer(request, with: ["ok": true]), chat("final", run: runID, ["finalText": "Not sent."])]
            })

            try await turn(over: socket) { _ in given }.run(message: "Send it", report: { _ in })

            let resolved = socket.sent.filter { $0["method"] as? String == "approval.resolve" }.compactMap { $0["params"] as? [String: String] }
            XCTAssertEqual(resolved, [["id": "approval:1", "kind": "plugin", "decision": "deny"]])
        }
    }

    func testWhatWasWaitingBeforeTheRunBegan_isNotThisRunsToAskAbout() async throws {
        let socket = ScriptedGatewaySocket()
        let session = session
        socket.answer { [self] request in
            let params = request["params"] as? [String: Any] ?? [:]
            switch request["method"] as? String {
            case "connect":
                return [ScriptedGatewaySocket.welcome(to: request["id"] as? String ?? "")]
            case "sessions.messages.subscribe":
                return [answer(request, with: ["subscribed": true, "key": session, "approvalReplay": ["approvals": [["id": "approval:old"]]]])]
            case "chat.send":
                let runID = params["idempotencyKey"] as? String ?? ""
                return [
                    answer(request, with: ["runId": runID, "status": "started"]),
                    approval("approval:old", ["kind": "exec", "commandText": "old", "allowedDecisions": ["allow-once", "deny"]]),
                    chat("final", run: runID, ["finalText": "Done."]),
                ]
            default:
                return []
            }
        }
        let asked = AskedOfThePerson()

        try await turn(over: socket) { approval in
            await asked.note(approval)
            return .approved
        }.run(message: "Go", report: { _ in })

        let approvals = await asked.approvals
        XCTAssertEqual(approvals, [])
        XCTAssertFalse(socket.sent.contains { $0["method"] as? String == "approval.resolve" })
    }

    func testAnApprovalThatCanOnlyBeDenied_saysSoAndTakesNoApproval() async {
        // The Gateway takes no approval for this once.
        let denyOnly = ToolApproval.openClaw(["kind": "exec", "commandText": "ls", "allowedDecisions": ["deny"]], threadID: "t")
        XCTAssertFalse(denyOnly.canApprove)
        XCTAssertEqual(denyOnly.details, "ls")
        // It does not say what it is for.
        let unexplained = ToolApproval.openClaw(["kind": "plugin", "allowedDecisions": ["allow-once", "deny"]], threadID: "t")
        XCTAssertFalse(unexplained.canApprove)
        XCTAssertEqual(unexplained.details, "OpenClaw did not say what it is for, so it can only be denied.")
        // Its command is too long to show whole.
        let long = String(repeating: "a", count: HermesAgentClient.longestCommandShown + 1)
        let tooLong = ToolApproval.openClaw(["kind": "exec", "commandText": long, "allowedDecisions": ["allow-once", "deny"]], threadID: "t")
        XCTAssertFalse(tooLong.canApprove)
        XCTAssertFalse(tooLong.details.contains("aaaa"))
        // Not all of what it says fits.
        let wordy = ToolApproval.openClaw(["kind": "plugin", "title": "Send", "description": String(repeating: "b", count: 2001), "allowedDecisions": ["allow-once", "deny"]], threadID: "t")
        XCTAssertFalse(wordy.canApprove)
        XCTAssertTrue(wordy.details.hasSuffix("Not all of what OpenClaw said fits here, so it can only be denied."))
        // A plugin's request that says what it is can be approved.
        let plugin = ToolApproval.openClaw(["kind": "plugin", "title": "Send the email", "description": "To Sam", "allowedDecisions": ["allow-once", "deny"]], threadID: "t")
        XCTAssertTrue(plugin.canApprove)
        XCTAssertEqual(plugin.question, "Let OpenClaw do this?")
        XCTAssertEqual(plugin.details, "Send the email\nTo Sam")

        // The approvals take no Approve for one that can only be denied.
        let approvals = await ToolApprovals { _, _ in }
        let asking = Task { await approvals.ask(denyOnly) }
        while await approvals.showing == nil {
            await Task.yield()
        }
        await approvals.answer(denyOnly.id, approve: true)
        let stillAsking = await approvals.showing?.phase
        XCTAssertEqual(stillAsking, .asking)
        await approvals.answer(denyOnly.id, approve: false)
        let answer = await asking.value
        XCTAssertEqual(answer, .denied)
    }

    // MARK: - Stop

    func testStoppingTheTurn_stopsTheRunInOpenClawAndEndsAsStopped() async throws {
        let socket = ScriptedGatewaySocket()
        let aborted = expectation(description: "The Gateway is told to stop the run")
        play(socket, during: { [self] runID in
            [chat("delta", run: runID, ["deltaText": "Working"])]
        }, after: { [self] request in
            guard request["method"] as? String == "chat.abort" else { return [] }
            aborted.fulfill()
            return [answer(request, with: ["ok": true, "aborted": true])]
        })
        let working = expectation(description: "The run is under way")
        working.assertForOverFulfill = false
        let turn = try turn(over: socket)
        let running = Task {
            try await turn.run(message: "Wait", report: { _ in working.fulfill() })
        }
        await fulfillment(of: [working], timeout: 10)

        running.cancel()
        do {
            try await running.value
            XCTFail("A stopped turn does not end as a reply")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await fulfillment(of: [aborted], timeout: 10)

        let abort = try XCTUnwrap(socket.sent.first { $0["method"] as? String == "chat.abort" }?["params"] as? [String: String])
        let runID = (socket.sent.first { $0["method"] as? String == "chat.send" }?["params"] as? [String: Any])?["idempotencyKey"] as? String
        XCTAssertEqual(abort, ["sessionKey": session, "runId": runID ?? ""])
    }

    // MARK: - From the chat

    func testAReplyWhereOpenClawIsChosenAndItsGatewayIsConnected_isMadeByAnOpenClawRunAndNotByAModel() async throws {
        let defaults = UserDefaults.standard
        let key = UserScope.scopedKey("llm_provider")
        let saved = defaults.object(forKey: key)
        defer { defaults.set(saved, forKey: key) }
        defaults.set("openclaw", forKey: key)
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        await MainActor.run { DatabaseManager.shared.configureIfNeeded() }
        await ThreadService.shared.reloadForCurrentUser()
        let threadID = try await ThreadService.shared.createThread(title: "OpenClaw \(UUID().uuidString)").id
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await ThreadService.shared.deleteThread(threadId: threadID)
            await ThreadService.shared.reloadForCurrentUser()
            await DataEncryptionService.shared.lock()
        }
        try await ThreadRepository.shared.appendChatMessage(TurnProgress.message(in: threadID, role: "user", content: "Earlier"))
        try await ThreadRepository.shared.appendChatMessage(TurnProgress.message(in: threadID, role: "assistant", content: "Noted"))

        let socket = ScriptedGatewaySocket()
        let session = "agent:main:aicoven-local:\(threadID)"
        socket.answer { [self] request in
            let params = request["params"] as? [String: Any] ?? [:]
            switch request["method"] as? String {
            case "connect":
                return [ScriptedGatewaySocket.welcome(to: request["id"] as? String ?? "")]
            case "sessions.messages.subscribe":
                return [answer(request, with: ["subscribed": true, "key": session])]
            case "chat.send":
                let runID = params["idempotencyKey"] as? String ?? ""
                return [
                    answer(request, with: ["runId": runID, "status": "started"]),
                    ["type": "event", "event": "chat", "payload": ["sessionKey": session, "runId": runID, "state": "final", "finalText": "From OpenClaw."]],
                ]
            default:
                return []
            }
        }
        let made = try turn(over: socket, threadID: threadID)
        let model = CountingChatModel()
        let chat = ChatService(
            contextBuilder: ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4)),
            modelRouter: HeuristicModelRouter(availableModels: [ModelDescriptor(
                providerID: "openclaw", modelID: "openclaw", maxContextTokens: 4096,
                supportsTools: false, supportsEmbeddings: false, costClass: .cheap
            )]),
            llmClients: ["openclaw": model],
            threadStore: ThreadRepository.shared,
            toolService: ToolService.shared,
            shouldAutoRefreshEnvironment: false,
            hermesAgent: { nil },
            openClawTurn: { _ in made }
        )
        let reports = TurnReports()
        let kept = RunsToldOf()

        try await chat.streamMessage(
            threadId: threadID, message: "And now?",
            onAgentRun: { run in
                XCTAssertEqual(run.provider, AgentRun.openClaw)
                await kept.note(run.runID)
            },
            onStateChange: reports.add
        )

        XCTAssertEqual(reports.all.last?.status, .completed)
        XCTAssertEqual(reports.all.last?.answer, "From OpenClaw.")
        XCTAssertEqual(model.calls, 0, "The turn went to OpenClaw, not to a model")
        let send = try XCTUnwrap(socket.sent.first { $0["method"] as? String == "chat.send" }?["params"] as? [String: Any])
        XCTAssertEqual(send["message"] as? String, "user:\nEarlier\n\nassistant:\nNoted\n\nuser:\nAnd now?", "OpenClaw is given the thread so far")
        let ids = await kept.ids
        XCTAssertEqual(ids, [send["idempotencyKey"] as? String ?? ""], "The run is kept with its turn")

        // What follows a turn is made by the app's own models, and is not
        // made for a turn that went to OpenClaw.
        await chat.updateThreadSummary(threadId: threadID)
        XCTAssertEqual(model.calls, 0)
        await DataEncryptionService.shared.lock()
    }

    func testWithoutAGatewayOnItsConnection_OpenClawIsAModelLikeAnyOther() async throws {
        let defaults = UserDefaults.standard
        let key = UserScope.scopedKey("llm_provider")
        let saved = defaults.object(forKey: key)
        defer { defaults.set(saved, forKey: key) }
        defaults.set("openclaw", forKey: key)
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        await MainActor.run { DatabaseManager.shared.configureIfNeeded() }
        await ThreadService.shared.reloadForCurrentUser()
        let threadID = try await ThreadService.shared.createThread(title: "OpenClaw \(UUID().uuidString)").id
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await ThreadService.shared.deleteThread(threadId: threadID)
            await ThreadService.shared.reloadForCurrentUser()
            await DataEncryptionService.shared.lock()
        }
        let model = CountingChatModel()
        let chat = ChatService(
            contextBuilder: ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4)),
            modelRouter: HeuristicModelRouter(availableModels: [ModelDescriptor(
                providerID: "openclaw", modelID: "openclaw", maxContextTokens: 4096,
                supportsTools: false, supportsEmbeddings: false, costClass: .cheap
            )]),
            llmClients: ["openclaw": model],
            threadStore: ThreadRepository.shared,
            toolService: ToolService.shared,
            shouldAutoRefreshEnvironment: false,
            hermesAgent: { nil },
            openClawTurn: { _ in nil }
        )

        // The model the test stands in refuses; that it was asked is the point.
        _ = try? await chat.streamMessage(threadId: threadID, message: "Hello", onStateChange: { _ in })

        XCTAssertGreaterThan(model.calls, 0)
        await DataEncryptionService.shared.lock()
    }

    // MARK: - What a run is started with

    func testTheMessageARunIsStartedWith_carriesTheThreadSoFarAndDropsItsOldestWhenTooLong() {
        XCTAssertEqual(OpenClawTurn.message("Hello", after: []), "Hello")
        XCTAssertEqual(
            OpenClawTurn.message("And now?", after: [("user", "Hello"), ("assistant", "Hi"), ("assistant", "")]),
            "user:\nHello\n\nassistant:\nHi\n\nuser:\nAnd now?"
        )
        let long = String(repeating: "a", count: OpenClawTurn.longestMessage - 20)
        let cut = OpenClawTurn.message("And now?", after: [("user", "Oldest"), ("assistant", long)])
        XCTAssertFalse(cut.contains("Oldest"))
        XCTAssertTrue(cut.hasSuffix("user:\nAnd now?"))
        XCTAssertLessThanOrEqual(cut.count, OpenClawTurn.longestMessage)

        XCTAssertEqual(OpenClawTurn.finalText(in: ["message": ["content": [["type": "text", "text": "From "], ["type": "text", "text": "parts"]]]]), "From parts")
        XCTAssertEqual(OpenClawTurn.finalText(in: ["text": "Plain"]), "Plain")
        XCTAssertNil(OpenClawTurn.finalText(in: ["stopReason": "stop"]))
        XCTAssertEqual(OpenClawTurn.failure(in: ["errorKind": "unknown", "errorMessage": "boom"]), "OpenClaw could not finish this run. boom")
        XCTAssertEqual(OpenClawTurn.failure(in: [:]), OpenClawTurn.notFinished)
    }
}
