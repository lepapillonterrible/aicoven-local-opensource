@testable import AICoven
import XCTest

/// A stand-in for a Hermes agent's API server: answers each request from a
/// script, and keeps what it was sent.
final class HermesStub: URLProtocol {
    struct Sent: Equatable {
        let method: String
        let path: String
        let body: String
        let key: String?
        let session: String?
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var answers: [String: [(status: Int, body: String)]] = [:]
    private nonisolated(unsafe) static var sent: [Sent] = []

    /// Answers requests for `method path` with these, in turn; the last
    /// one goes on answering.
    static func answer(_ method: String, _ path: String, with answers: (status: Int, body: String)...) {
        lock.withLock { self.answers["\(method) \(path)"] = answers }
    }

    static func reset() {
        lock.withLock {
            answers = [:]
            sent = []
        }
    }

    static var requests: [Sent] {
        lock.withLock { sent }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HermesStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        let answer: (status: Int, body: String) = Self.lock.withLock {
            Self.sent.append(Sent(
                method: method,
                path: path,
                body: String(data: body, encoding: .utf8) ?? "",
                key: request.value(forHTTPHeaderField: "Authorization"),
                session: request.value(forHTTPHeaderField: "X-Hermes-Session-Key")
            ))
            let key = "\(method) \(path)"
            guard var scripted = Self.answers[key], !scripted.isEmpty else { return (404, "{}") }
            let next = scripted.removeFirst()
            if !scripted.isEmpty {
                Self.answers[key] = scripted
            }
            return next
        }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The states a turn reported, in order.
private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [TurnState] = []

    func add(_ state: TurnState) {
        lock.withLock { states.append(state) }
    }

    var all: [TurnState] {
        lock.withLock { states }
    }
}

/// What a turn asked the person, and the answer the test gives.
private actor Asked {
    private(set) var approvals: [ToolApproval] = []

    func note(_ approval: ToolApproval) {
        approvals.append(approval)
    }
}

/// The Hermes agent: a run is started, followed, answered and stopped
/// through Hermes's own API, and reported as any other turn.
final class HermesAgentTests: XCTestCase {
    private let events = "/v1/runs/run_1/events"

    override func setUp() {
        super.setUp()
        HermesStub.reset()
        HermesStub.answer("POST", "/v1/runs", with: (200, #"{"run_id":"run_1","status":"started"}"#))
    }

    private var client: HermesAgentClient {
        HermesAgentClient(baseURL: URL(string: "http://127.0.0.1:8642")!, apiKey: "KEY", session: HermesStub.session())
    }

    private func stream(_ lines: String...) -> String {
        lines.map { "data: \($0)\n\n" }.joined()
    }

    private func turn(ask: @escaping @Sendable (ToolApproval) async -> ApprovalAnswer = { _ in .denied }) -> HermesTurn {
        HermesTurn(client: client, threadID: "thread-1", ask: ask, lookAgainAfter: .milliseconds(1), looksBeforeGivingUp: 3)
    }

    // MARK: - A run from start to answer

    func testARun_isStartedWithTheMessageAndFollowedToItsAnswer() async throws {
        HermesStub.answer("GET", events, with: (200, stream(
            #"{"event":"reasoning.available","text":"Checking the repository"}"#,
            #"{"event":"tool.started","tool":"terminal"}"#,
            ": keep-alive",
            #"{"event":"tool.completed","tool":"terminal","error":false}"#,
            #"{"event":"message.delta","delta":"All "}"#,
            #"{"event":"message.delta","delta":"done"}"#,
            #"{"event":"run.completed","output":"All done."}"#
        )))
        let reports = Reports()

        try await turn().run(
            input: "Tidy the repo",
            history: [.init(role: "user", content: "Hello"), .init(role: "assistant", content: "Hi")],
            model: nil,
            report: reports.add
        )

        let start = try XCTUnwrap(HermesStub.requests.first)
        XCTAssertEqual(start.method, "POST")
        XCTAssertEqual(start.path, "/v1/runs")
        XCTAssertEqual(start.key, "Bearer KEY")
        XCTAssertEqual(start.session, "thread-1")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(start.body.utf8)) as? [String: Any])
        XCTAssertEqual(sent["input"] as? String, "Tidy the repo")
        XCTAssertEqual(sent["session_id"] as? String, "thread-1")
        XCTAssertEqual((sent["conversation_history"] as? [[String: String]])?.map { $0["content"] }, ["Hello", "Hi"])
        XCTAssertNil(sent["model"], "Hermes uses the model it is set up with")

        let states = reports.all
        XCTAssertEqual(states.first?.scratchpad, "Checking the repository")
        XCTAssertTrue(states.contains { $0.toolsInProgress.values.contains { $0.name == "terminal" } })
        XCTAssertTrue(states.contains { $0.answer == "All done" && $0.phase == .answering })
        let last = try XCTUnwrap(states.last)
        XCTAssertEqual(last.status, .completed)
        XCTAssertEqual(last.answer, "All done.", "The run's own output is the answer")
        XCTAssertEqual(last.toolsCompleted.map(\.name), ["terminal"])
        XCTAssertEqual(last.toolsCompleted.first?.status, "completed")
        XCTAssertTrue(last.toolsInProgress.isEmpty)
    }

    func testARunThatFails_endsFailedAndSaysWhatHermesSaid() async throws {
        HermesStub.answer("GET", events, with: (200, stream(#"{"event":"run.failed","error":"The model refused"}"#)))
        let reports = Reports()

        try await turn().run(input: "Go", history: [], model: nil, report: reports.add)

        XCTAssertEqual(reports.all.last?.status, .failed)
        XCTAssertEqual(reports.all.last?.answer, "Hermes could not finish this run. The model refused")
    }

    func testARunThatCannotBeStarted_throwsAndReportsNothing() async {
        HermesStub.answer("POST", "/v1/runs", with: (401, "{}"))
        let reports = Reports()

        do {
            try await turn().run(input: "Go", history: [], model: nil, report: reports.add)
            XCTFail("A run Hermes refused has not started")
        } catch {
            XCTAssertEqual(error as? HermesAgentError, .refused(status: 401))
        }
        XCTAssertTrue(reports.all.isEmpty)
    }

    // MARK: - Approvals

    func testWhatHermesAsksToBeAllowed_isAskedOfThePersonAndTheirAnswerGivenToHermes() async throws {
        let request = #"{"event":"approval.request","approval":{"command":"rm -rf build","description":"delete in project path"},"tool_name":"terminal"}"#
        HermesStub.answer("GET", events, with: (200, stream(request, request, #"{"event":"run.completed","output":"Removed."}"#)))
        HermesStub.answer("POST", "/v1/runs/run_1/approval", with: (200, "{}"))
        let asked = Asked()

        try await turn { approval in
            await asked.note(approval)
            return .approved
        }.run(input: "Clean up", history: [], model: nil, report: { _ in })

        let approvals = await asked.approvals
        XCTAssertEqual(approvals.count, 1, "A request repeated while it waits is asked once")
        XCTAssertEqual(approvals.first?.threadID, "thread-1")
        XCTAssertEqual(approvals.first?.question, "Let Hermes run this command?")
        XCTAssertEqual(approvals.first?.details, "rm -rf build\ndelete in project path")
        XCTAssertEqual(approvals.first?.toolName, "terminal")
        let answers = HermesStub.requests.filter { $0.path == "/v1/runs/run_1/approval" }
        XCTAssertEqual(answers.map(\.body), [#"{"choice":"once"}"#])
    }

    func testEachThingHermesAsksInARun_isAskedOnceHoweverOftenItIsSent() async throws {
        HermesStub.answer("GET", events, with: (200, stream(
            #"{"event":"approval.request","approval_id":"a1","command":"git add ."}"#,
            #"{"event":"approval.request","approval_id":"a1","command":"git add ."}"#,
            #"{"event":"approval.resolved","approval_id":"a1"}"#,
            #"{"event":"approval.request","approval_id":"a2","command":"git commit"}"#,
            #"{"event":"tool.started","tool":"terminal"}"#,
            #"{"event":"approval.request","command":"git push"}"#,
            #"{"event":"run.completed","output":"Pushed."}"#
        )))
        HermesStub.answer("POST", "/v1/runs/run_1/approval", with: (200, "{}"))
        let asked = Asked()

        try await turn { approval in
            await asked.note(approval)
            return .approved
        }.run(input: "Ship it", history: [], model: nil, report: { _ in })

        let approvals = await asked.approvals
        XCTAssertEqual(approvals.map(\.details), ["git add .", "git commit", "git push"])
    }

    func testADeniedApprovalAndOneThatCannotBeAsked_areBothGivenToHermesAsNo() async throws {
        for answer in [ApprovalAnswer.denied, .notAsked] {
            HermesStub.reset()
            HermesStub.answer("POST", "/v1/runs", with: (200, #"{"run_id":"run_1"}"#))
            HermesStub.answer("GET", events, with: (200, stream(
                #"{"event":"approval.request","command":"git push"}"#,
                #"{"event":"run.completed","output":"Left as it is."}"#
            )))
            HermesStub.answer("POST", "/v1/runs/run_1/approval", with: (200, "{}"))

            try await turn { _ in answer }.run(input: "Push", history: [], model: nil, report: { _ in })

            XCTAssertEqual(HermesStub.requests.filter { $0.path.hasSuffix("/approval") }.map(\.body), [#"{"choice":"deny"}"#])
        }
    }

    // MARK: - Stop

    func testStoppingTheTurn_stopsTheRunInHermesAndEndsAsStopped() async throws {
        HermesStub.answer("GET", events, with: (200, stream(#"{"event":"approval.request","command":"sleep 600"}"#)))
        HermesStub.answer("POST", "/v1/runs/run_1/stop", with: (200, "{}"))
        let waiting = expectation(description: "The turn is waiting on the person")
        let running = Task {
            try await self.turn { _ in
                waiting.fulfill()
                // As the approvals do: the wait ends when the turn stops.
                while !Task.isCancelled {
                    await Task.yield()
                }
                return .withdrawn
            }.run(input: "Wait", history: [], model: nil, report: { _ in })
        }
        await fulfillment(of: [waiting], timeout: 10)

        running.cancel()
        do {
            try await running.value
            XCTFail("A stopped turn does not end as a reply")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        // Hermes is told in a task of its own.
        for _ in 0 ..< 10000 where !HermesStub.requests.contains(where: { $0.path.hasSuffix("/stop") }) {
            await Task.yield()
        }
        XCTAssertTrue(HermesStub.requests.contains { $0.method == "POST" && $0.path == "/v1/runs/run_1/stop" })
        XCTAssertFalse(HermesStub.requests.contains { $0.path.hasSuffix("/approval") }, "A stopped turn answers nothing")
    }

    func testARunHermesSaysWasCancelled_endsAsStopped() async {
        HermesStub.answer("GET", events, with: (200, stream(#"{"event":"message.delta","delta":"Half"}"#, #"{"event":"run.cancelled"}"#)))

        do {
            try await turn().run(input: "Go", history: [], model: nil, report: { _ in })
            XCTFail("A cancelled run does not end as a reply")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    // MARK: - A stream that is lost

    func testWhenTheEventsAreLost_theRunIsReadBackUntilItEnds() async throws {
        // The stream ends with the run still going, twice; then Hermes says
        // it has completed.
        HermesStub.answer("GET", events, with: (200, stream(#"{"event":"message.delta","delta":"Working"}"#)), (500, ""))
        HermesStub.answer("GET", "/v1/runs/run_1", with: (200, #"{"status":"running"}"#), (200, #"{"status":"completed","output":"Finished."}"#))
        let reports = Reports()

        try await turn().run(input: "Go", history: [], model: nil, report: reports.add)

        XCTAssertEqual(reports.all.last?.status, .completed)
        XCTAssertEqual(reports.all.last?.answer, "Finished.")
    }

    func testARunHermesNoLongerHas_endsFailedAndSaysSo() async throws {
        HermesStub.answer("GET", events, with: (500, ""))
        HermesStub.answer("GET", "/v1/runs/run_1", with: (404, "{}"))
        let reports = Reports()

        try await turn().run(input: "Go", history: [], model: nil, report: reports.add)

        XCTAssertEqual(reports.all.last?.status, .failed)
        XCTAssertEqual(reports.all.last?.answer, HermesTurn.runGone)
    }

    func testWhenHermesCannotBeReached_theTurnGivesUpAndSaysTheRunMayStillBeGoing() async throws {
        HermesStub.answer("GET", events, with: (500, ""))
        HermesStub.answer("GET", "/v1/runs/run_1", with: (503, "{}"))
        let reports = Reports()

        try await turn().run(input: "Go", history: [], model: nil, report: reports.add)

        XCTAssertEqual(reports.all.last?.status, .failed)
        XCTAssertEqual(reports.all.last?.answer, HermesTurn.lostContact)
        XCTAssertEqual(HermesStub.requests.count(where: { $0.path == "/v1/runs/run_1" }), 3, "As many looks as it is given")
    }

    func testAnApprovalFoundWhenReadingBack_isAskedToo() async throws {
        HermesStub.answer("GET", events, with: (500, ""), (200, stream(#"{"event":"run.completed","output":"Done."}"#)))
        HermesStub.answer("GET", "/v1/runs/run_1", with: (200, #"{"status":"waiting_for_approval","pending_approval":{"command":"git push"}}"#))
        HermesStub.answer("POST", "/v1/runs/run_1/approval", with: (200, "{}"))
        let asked = Asked()

        try await turn { approval in
            await asked.note(approval)
            return .approved
        }.run(input: "Push", history: [], model: nil, report: { _ in })

        let approvals = await asked.approvals
        XCTAssertEqual(approvals.map(\.details), ["git push"])
        XCTAssertEqual(HermesStub.requests.filter { $0.path.hasSuffix("/approval") }.map(\.body), [#"{"choice":"once"}"#])
    }

    // MARK: - Reading what Hermes sends

    func testEvents_areReadWhateverShapeTheApprovalTakes() {
        XCTAssertEqual(HermesAgentClient.event(from: ["event": "message.delta", "delta": "Hi"]), .text("Hi"))
        XCTAssertNil(HermesAgentClient.event(from: ["event": "message.delta", "delta": ""]))
        XCTAssertEqual(HermesAgentClient.event(from: ["event": "tool.completed", "tool": "browser", "error": true]), .toolCompleted("browser", failed: true))
        XCTAssertEqual(HermesAgentClient.event(from: ["event": "approval.responded"]), .approvalResolved)
        XCTAssertEqual(HermesAgentClient.event(from: ["event": "run.completed"]), .completed(output: nil))
        XCTAssertNil(HermesAgentClient.event(from: ["event": "run.status", "status": "queued"]))
        XCTAssertNil(HermesAgentClient.event(from: ["something": "else"]))

        let nested: [String: Any] = ["event": "approval.request", "payload": ["request": ["tool_call": ["name": "terminal", "arguments": ["cmd": "ls"]]]]]
        XCTAssertEqual(
            HermesAgentClient.event(from: nested),
            .approvalRequested(HermesApprovalRequest(command: "ls", description: nil, tool: "terminal"))
        )
        XCTAssertEqual(
            HermesAgentClient.event(from: ["event": "approval.request", "approval_id": "a1", "summary": "Send the email"]),
            .approvalRequested(HermesApprovalRequest(id: "a1", command: nil, description: "Send the email", tool: nil))
        )
        let bare = ToolApproval.hermes(HermesApprovalRequest(), threadID: "t")
        XCTAssertEqual(bare.question, "Let Hermes do this?")
        XCTAssertEqual(bare.details, "Hermes did not say what it is for.")
    }

    func testARunID_isOnlyOneThatIsSafeInAPath() {
        XCTAssertEqual(HermesAgentClient.validRunID(" run_1-a.b "), "run_1-a.b")
        for bad in ["", "..", "run/1", "run 1", "run?x=1", "../etc", String(repeating: "a", count: 241)] {
            XCTAssertNil(HermesAgentClient.validRunID(bad), bad)
        }
    }

    // MARK: - In the app

    func testAHermesConnection_isTheAgentTheAppRunsHermesTurnsWith() async throws {
        let defaults = UserDefaults.standard
        let keys = ["provider_accounts.v1", "hermes_model_connections_converted.v1"].map(UserScope.scopedKey)
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                defaults.set(value, forKey: key)
            }
        }
        defaults.removeObject(forKey: keys[0])
        // The models' connections have been converted: this one is an agent's.
        defaults.set(true, forKey: keys[1])
        XCTAssertNil(ProviderAccountService.hermesAgent())

        let account = try await ProviderAccountService.shared.createHermesAgentAccount(
            displayName: "My Hermes", baseURL: "http://127.0.0.1:8642/v1/", apiKey: "KEY"
        )
        addTeardownBlock { try? await ProviderAccountService.shared.deleteProviderAccount(id: account.id) }

        let agent = try XCTUnwrap(ProviderAccountService.hermesAgent())
        XCTAssertEqual(agent.baseURL.absoluteString, "http://127.0.0.1:8642")
        XCTAssertEqual(agent.apiKey, "KEY")
        XCTAssertEqual(account.provider, "hermes")
    }

    func testAReplyWhereHermesIsChosen_isMadeByAHermesRunAndNotByAModel() async throws {
        let defaults = UserDefaults.standard
        let keys = ["llm_provider", "hermes_model_connections_converted.v1"].map(UserScope.scopedKey)
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set("hermes", forKey: keys[0])
        defaults.set(true, forKey: keys[1])
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        await MainActor.run { DatabaseManager.shared.configureIfNeeded() }
        HermesStub.answer("GET", events, with: (200, stream(#"{"event":"run.completed","output":"From Hermes."}"#)))
        let agent = client
        let chat = ChatService(
            contextBuilder: ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4)),
            modelRouter: HeuristicModelRouter(availableModels: []),
            llmClients: [:],
            threadStore: ThreadRepository.shared,
            toolService: ToolService.shared,
            shouldAutoRefreshEnvironment: false,
            hermesAgent: { agent }
        )
        let reports = Reports()
        let threadID = "hermes-\(UUID().uuidString)"

        try await chat.streamMessage(threadId: threadID, message: "Hello", onStateChange: reports.add)

        XCTAssertEqual(reports.all.last?.status, .completed)
        XCTAssertEqual(reports.all.last?.answer, "From Hermes.")
        XCTAssertEqual(HermesStub.requests.first?.session, threadID)
        await DataEncryptionService.shared.lock()
    }

    func testTheHistoryGivenToARun_leavesOutTheMessageItAnswersAndAnythingNotSaid() {
        func message(_ role: String, _ content: String) -> ChatMessage {
            TurnProgress.message(in: "thread-1", role: role, content: content)
        }
        let stored = [message("user", "Hello"), message("assistant", "Hi"), message("assistant", ""), message("system", "note"), message("user", "Tidy the repo")]

        XCTAssertEqual(ChatService.hermesHistory(from: stored), [.init(role: "user", content: "Hello"), .init(role: "assistant", content: "Hi")])
        XCTAssertEqual(ChatService.hermesHistory(from: []), [])
    }
}
