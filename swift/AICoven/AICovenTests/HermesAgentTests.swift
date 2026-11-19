@testable import AICoven
internal import Combine
import GRDB
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

    // Read and written from the tests and from the URL loading system's
    // threads: every access is under the lock, which the compiler cannot
    // see for a static, hence `nonisolated(unsafe)`.
    private static let lock = NSLock()
    private nonisolated(unsafe) static var answers: [String: [(status: Int, body: String)]] = [:]
    private nonisolated(unsafe) static var sent: [Sent] = []
    private nonisolated(unsafe) static var watchers: [(path: String, seen: XCTestExpectation)] = []

    /// An expectation met when a request for `path` arrives.
    static func expectRequest(to path: String) -> XCTestExpectation {
        let seen = XCTestExpectation(description: "A request to \(path)")
        lock.withLock { watchers.append((path, seen)) }
        return seen
    }

    /// Answers requests for `method path` with these, in turn; the last
    /// one goes on answering.
    static func answer(_ method: String, _ path: String, with answers: (status: Int, body: String)...) {
        lock.withLock { self.answers["\(method) \(path)"] = answers }
    }

    static func reset() {
        lock.withLock {
            answers = [:]
            sent = []
            watchers = []
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
            for watcher in Self.watchers where watcher.path == path {
                watcher.seen.fulfill()
            }
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

/// The states a turn reported, in order. Added to from the turn's task and
/// read by the test, under the lock.
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

/// One of the app's own models, which counts how often it is called.
private final class CountingModel: LLMClient, @unchecked Sendable {
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

/// The runs a turn said it had started.
private actor Started {
    private(set) var runIDs: [String] = []

    func note(_ runID: String) {
        runIDs.append(runID)
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
        XCTAssertEqual(Set(sent.keys), ["input", "session_id", "conversation_history"], "Hermes uses the model it is set up with")

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

        try await turn().run(input: "Go", history: [], report: reports.add)

        XCTAssertEqual(reports.all.last?.status, .failed)
        XCTAssertEqual(reports.all.last?.answer, "Hermes could not finish this run. The model refused")
    }

    func testARunThatCannotBeStarted_throwsAndReportsNothing() async {
        HermesStub.answer("POST", "/v1/runs", with: (401, "{}"))
        let reports = Reports()

        do {
            try await turn().run(input: "Go", history: [], report: reports.add)
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
        }.run(input: "Clean up", history: [], report: { _ in })

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
        }.run(input: "Ship it", history: [], report: { _ in })

        let approvals = await asked.approvals
        XCTAssertEqual(approvals.map(\.details), ["git add .", "git commit", "git push"])
    }

    func testACommandTooLongToShowWhole_isDeniedWithoutBeingShownInPart() async throws {
        let long = String(repeating: "a", count: HermesAgentClient.longestCommandShown + 1)
        HermesStub.answer("GET", events, with: (200, stream(
            #"{"event":"approval.request","command":"\#(long)"}"#,
            #"{"event":"run.completed","output":"Not run."}"#
        )))
        HermesStub.answer("POST", "/v1/runs/run_1/approval", with: (200, "{}"))
        let asked = Asked()

        try await turn { approval in
            await asked.note(approval)
            return .approved
        }.run(input: "Go", history: [], report: { _ in })

        let approvals = await asked.approvals
        XCTAssertEqual(approvals, [], "Approve would run more than the card could show")
        XCTAssertEqual(HermesStub.requests.filter { $0.path.hasSuffix("/approval") }.map(\.body), [#"{"choice":"deny"}"#])
        // One that fits is kept whole.
        let fits = String(repeating: "b", count: HermesAgentClient.longestCommandShown)
        XCTAssertEqual(HermesAgentClient.approvalRequest(from: ["command": fits]).command, fits)
    }

    func testAnAnswerHermesDoesNotTakeAtFirst_isSentAgainAndThePersonIsNotAskedTwice() async throws {
        let request = #"{"event":"approval.request","approval_id":"a1","command":"git push"}"#
        HermesStub.answer("GET", events, with: (200, stream(request, request, #"{"event":"run.completed","output":"Pushed."}"#)))
        HermesStub.answer("POST", "/v1/runs/run_1/approval", with: (503, ""), (200, "{}"))
        // Still waiting on that request: the answer was not taken.
        HermesStub.answer("GET", "/v1/runs/run_1", with: (200, #"{"status":"waiting_for_approval","pending_approval":{"approval_id":"a1","command":"git push"}}"#))
        let asked = Asked()

        try await turn { approval in
            await asked.note(approval)
            return .approved
        }.run(input: "Push", history: [], report: { _ in })

        let approvals = await asked.approvals
        XCTAssertEqual(approvals.count, 1)
        XCTAssertEqual(HermesStub.requests.filter { $0.path.hasSuffix("/approval") }.map(\.body), [#"{"choice":"once"}"#, #"{"choice":"once"}"#])
    }

    func testAnAnswerHermesNeverTakes_endsTheTurnSayingTheRunIsStillWaiting() async throws {
        HermesStub.answer("GET", events, with: (200, stream(#"{"event":"approval.request","command":"git push"}"#)))
        HermesStub.answer("POST", "/v1/runs/run_1/approval", with: (503, ""))
        HermesStub.answer("GET", "/v1/runs/run_1", with: (200, #"{"status":"waiting_for_approval","pending_approval":{"command":"git push"}}"#))
        let reports = Reports()

        try await turn { _ in .approved }.run(input: "Push", history: [], report: reports.add)

        XCTAssertEqual(reports.all.last?.status, .failed)
        XCTAssertEqual(reports.all.last?.answer, HermesTurn.answerNotTaken)
        XCTAssertEqual(HermesStub.requests.count(where: { $0.path.hasSuffix("/approval") }), 3)
    }

    func testWhenHermesCannotBeReachedAfterAnAnswerFailed_theAnswerIsNotSentBlindAndTheTurnSaysContactWasLost() async throws {
        HermesStub.answer("GET", events, with: (200, stream(#"{"event":"approval.request","command":"git push"}"#)))
        HermesStub.answer("POST", "/v1/runs/run_1/approval", with: (503, ""))
        HermesStub.answer("GET", "/v1/runs/run_1", with: (503, ""))
        let reports = Reports()

        try await turn { _ in .approved }.run(input: "Push", history: [], report: reports.add)

        XCTAssertEqual(reports.all.last?.answer, HermesTurn.lostContact)
        XCTAssertEqual(HermesStub.requests.count(where: { $0.path.hasSuffix("/approval") }), 1, "Not sent again without knowing what Hermes is waiting on")
        XCTAssertEqual(HermesStub.requests.count(where: { $0.path == "/v1/runs/run_1" }), 3, "As many looks as the turn is given")
    }

    func testWhenHermesNoLongerHasTheRunAfterAnAnswerFailed_theTurnSaysSoAtOnce() async throws {
        HermesStub.answer("GET", events, with: (200, stream(#"{"event":"approval.request","command":"git push"}"#)))
        HermesStub.answer("POST", "/v1/runs/run_1/approval", with: (503, ""))
        HermesStub.answer("GET", "/v1/runs/run_1", with: (404, "{}"))
        let reports = Reports()

        try await turn { _ in .approved }.run(input: "Push", history: [], report: reports.add)

        XCTAssertEqual(reports.all.last?.answer, HermesTurn.runGone)
        XCTAssertEqual(HermesStub.requests.count(where: { $0.path == "/v1/runs/run_1" }), 1)
    }

    func testAnAnswerWhoseReplyWasLost_isNotSentAgainOnceTheRunHasMovedOn() async throws {
        // Hermes took the answer, but this app never heard so; by the time
        // it looks, the run is waiting on something else.
        HermesStub.answer("GET", events, with: (200, stream(
            #"{"event":"approval.request","command":"git add ."}"#,
            #"{"event":"approval.request","command":"git push --force"}"#,
            #"{"event":"run.completed","output":"Done."}"#
        )))
        HermesStub.answer("POST", "/v1/runs/run_1/approval", with: (503, ""), (200, "{}"))
        HermesStub.answer("GET", "/v1/runs/run_1", with: (200, #"{"status":"waiting_for_approval","pending_approval":{"command":"git push --force"}}"#))
        let asked = Asked()

        try await turn { approval in
            await asked.note(approval)
            return approval.details == "git add ." ? .approved : .denied
        }.run(input: "Ship it", history: [], report: { _ in })

        let approvals = await asked.approvals
        XCTAssertEqual(approvals.map(\.details), ["git add .", "git push --force"], "The second request is shown and asked, not approved by a resend")
        XCTAssertEqual(
            HermesStub.requests.filter { $0.path.hasSuffix("/approval") }.map(\.body),
            [#"{"choice":"once"}"#, #"{"choice":"deny"}"#],
            "The approval of the first is not sent a second time"
        )
    }

    func testRequestsWithLongNames_areToldApart() {
        let long = String(repeating: "x", count: 300)
        let first = HermesAgentClient.approvalRequest(from: ["approval_id": long + "1", "command": "ls"])
        let second = HermesAgentClient.approvalRequest(from: ["approval_id": long + "2", "command": "ls"])
        XCTAssertFalse(first.isSame(as: second))
        XCTAssertTrue(first.isSame(as: first))
        // With no name on one side, what they ask decides.
        XCTAssertTrue(first.isSame(as: HermesAgentClient.approvalRequest(from: ["command": "ls"])))
        XCTAssertFalse(first.isSame(as: HermesAgentClient.approvalRequest(from: ["command": "rm"])))
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

            try await turn { _ in answer }.run(input: "Push", history: [], report: { _ in })

            XCTAssertEqual(HermesStub.requests.filter { $0.path.hasSuffix("/approval") }.map(\.body), [#"{"choice":"deny"}"#])
        }
    }

    // MARK: - Stop

    func testStoppingTheTurn_stopsTheRunInHermesAndEndsAsStopped() async throws {
        HermesStub.answer("GET", events, with: (200, stream(#"{"event":"approval.request","command":"sleep 600"}"#)))
        HermesStub.answer("POST", "/v1/runs/run_1/stop", with: (200, "{}"))
        let toldToStop = HermesStub.expectRequest(to: "/v1/runs/run_1/stop")
        let waiting = expectation(description: "The turn is waiting on the person")
        let running = Task {
            try await self.turn { _ in
                waiting.fulfill()
                // As the approvals do: the wait ends when the turn stops.
                while !Task.isCancelled {
                    await Task.yield()
                }
                return .withdrawn
            }.run(input: "Wait", history: [], report: { _ in })
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
        await fulfillment(of: [toldToStop], timeout: 10)
        XCTAssertTrue(HermesStub.requests.contains { $0.method == "POST" && $0.path == "/v1/runs/run_1/stop" })
        XCTAssertFalse(HermesStub.requests.contains { $0.path.hasSuffix("/approval") }, "A stopped turn answers nothing")
    }

    func testARunHermesSaysWasStoppedThere_endsAsStoppedWithWhatHadBeenAnswered() async throws {
        HermesStub.answer("GET", events, with: (200, stream(#"{"event":"message.delta","delta":"Half"}"#, #"{"event":"run.cancelled"}"#)))
        let reports = Reports()

        try await turn().run(input: "Go", history: [], report: reports.add)

        XCTAssertEqual(reports.all.last?.status, .cancelled)
        XCTAssertEqual(reports.all.last?.answer, "Half")
        // The engine ends such a turn as stopped, not as a failure.
        var progress = TurnProgress(agentName: nil)
        reports.all.forEach { progress.note($0) }
        let ending = progress.ending(in: "thread-1", thrown: nil)
        XCTAssertEqual(ending.outcome, .cancelled)
        XCTAssertEqual(ending.message.content, "Half\n\n_Stopped here._")
    }

    // MARK: - A stream that is lost

    func testWhenTheEventsAreLost_theRunIsReadBackUntilItEnds() async throws {
        // The stream ends with the run still going, twice; then Hermes says
        // it has completed.
        HermesStub.answer("GET", events, with: (200, stream(#"{"event":"message.delta","delta":"Working"}"#)), (500, ""))
        HermesStub.answer("GET", "/v1/runs/run_1", with: (200, #"{"status":"running"}"#), (200, #"{"status":"completed","output":"Finished."}"#))
        let reports = Reports()

        try await turn().run(input: "Go", history: [], report: reports.add)

        XCTAssertEqual(reports.all.last?.status, .completed)
        XCTAssertEqual(reports.all.last?.answer, "Finished.")
    }

    func testARunHermesNoLongerHas_endsFailedAndSaysSo() async throws {
        HermesStub.answer("GET", events, with: (500, ""))
        HermesStub.answer("GET", "/v1/runs/run_1", with: (404, "{}"))
        let reports = Reports()

        try await turn().run(input: "Go", history: [], report: reports.add)

        XCTAssertEqual(reports.all.last?.status, .failed)
        XCTAssertEqual(reports.all.last?.answer, HermesTurn.runGone)
    }

    func testWhenHermesCannotBeReached_theTurnGivesUpAndSaysTheRunMayStillBeGoing() async throws {
        HermesStub.answer("GET", events, with: (500, ""))
        HermesStub.answer("GET", "/v1/runs/run_1", with: (503, "{}"))
        let reports = Reports()

        try await turn().run(input: "Go", history: [], report: reports.add)

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
        }.run(input: "Push", history: [], report: { _ in })

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
        // A run that has ended has ended, whatever its last event was.
        XCTAssertEqual(
            HermesAgentClient.state(from: ["status": "completed", "last_event": "approval.request", "output": "Done."]).status,
            .completed(output: "Done.")
        )
        XCTAssertEqual(
            HermesAgentClient.state(from: ["status": "running", "last_event": "approval.request", "command": "ls"]).status,
            .waitingForApproval(HermesApprovalRequest(command: "ls"))
        )
        let long = String(repeating: "d", count: 2005)
        XCTAssertEqual(
            HermesAgentClient.approvalRequest(from: ["description": long]).description,
            String(repeating: "d", count: 2000) + "\n… and 5 more characters"
        )

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
        // Run last, after the connection the test makes has been removed.
        addTeardownBlock {
            for (key, value) in zip(keys, saved) {
                UserDefaults.standard.set(value, forKey: key)
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
        let model = CountingModel()
        let chat = ChatService(
            contextBuilder: ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4)),
            modelRouter: HeuristicModelRouter(availableModels: [ModelDescriptor(
                providerID: "openai", modelID: "gpt", maxContextTokens: 4096,
                supportsTools: false, supportsEmbeddings: false, costClass: .cheap
            )]),
            llmClients: ["openai": model],
            threadStore: ThreadRepository.shared,
            toolService: ToolService.shared,
            shouldAutoRefreshEnvironment: false,
            hermesAgent: { agent }
        )
        let reports = Reports()
        await ThreadService.shared.reloadForCurrentUser()
        let threadID = try await ThreadService.shared.createThread(title: "Hermes \(UUID().uuidString)").id
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await ThreadService.shared.deleteThread(threadId: threadID)
            await ThreadService.shared.reloadForCurrentUser()
            await DataEncryptionService.shared.lock()
        }

        try await chat.streamMessage(threadId: threadID, message: "Hello", onStateChange: reports.add)

        XCTAssertEqual(reports.all.last?.status, .completed)
        XCTAssertEqual(reports.all.last?.answer, "From Hermes.")
        XCTAssertEqual(HermesStub.requests.first?.session, threadID)

        // What follows a turn is made by the app's own models, and is not
        // made for a turn that went to Hermes, whichever provider is chosen
        // by the time it ends.
        try await ThreadRepository.shared.appendChatMessage(TurnProgress.message(in: threadID, role: "user", content: "Hello"))
        defaults.set("openai", forKey: keys[0])
        await chat.updateThreadSummary(threadId: threadID)
        XCTAssertEqual(model.calls, 0)
        await DataEncryptionService.shared.lock()
    }

    // MARK: - A run the app was closed on

    func testARun_tellsItsIdAsSoonAsItHasOneSoItCanBeFoundAgain() async throws {
        HermesStub.answer("GET", events, with: (200, stream(#"{"event":"run.completed","output":"Done."}"#)))
        let started = Started()

        try await turn().run(input: "Go", history: [], started: { await started.note($0) }, report: { _ in })

        let ids = await started.runIDs
        XCTAssertEqual(ids, ["run_1"])
    }

    func testARunPickedUp_isReadFirstAndFollowedToItsEnd() async throws {
        // Still going when it is picked up; its events then end it.
        HermesStub.answer("GET", "/v1/runs/run_1", with: (200, #"{"status":"running"}"#))
        HermesStub.answer("GET", events, with: (200, stream(
            #"{"event":"message.delta","delta":"and done"}"#,
            #"{"event":"run.completed","output":"Started before, and done."}"#
        )))
        let reports = Reports()

        try await turn().resume(runID: "run_1", report: reports.add)

        XCTAssertEqual(HermesStub.requests.map(\.path), ["/v1/runs/run_1", events], "No run is started, and where it stands is read first")
        XCTAssertEqual(reports.all.last?.status, .completed)
        XCTAssertEqual(reports.all.last?.answer, "Started before, and done.")
    }

    func testARunThatEndedWhileTheAppWasClosed_showsItsAnswerOrSaysWhereItIs() async throws {
        HermesStub.answer("GET", "/v1/runs/run_1", with: (200, #"{"status":"completed","output":"Done while away."}"#))
        let withAnswer = Reports()
        try await turn().resume(runID: "run_1", report: withAnswer.add)
        XCTAssertEqual(withAnswer.all.last?.answer, "Done while away.")

        HermesStub.answer("GET", "/v1/runs/run_1", with: (200, #"{"status":"completed"}"#))
        let without = Reports()
        try await turn().resume(runID: "run_1", report: without.add)
        XCTAssertEqual(without.all.last?.status, .completed)
        XCTAssertEqual(without.all.last?.answer, HermesTurn.noAnswerToShow)

        do {
            try await turn().resume(runID: "../other", report: { _ in })
            XCTFail("A run id that is not one is not looked for")
        } catch {
            XCTAssertEqual(error as? HermesAgentError, .cannotPickUp)
        }
    }

    @MainActor
    func testATurnTheAppClosedOnWhileHermesRanIt_isPickedUpWhenItsThreadIsOpened() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        await ThreadService.shared.reloadForCurrentUser()
        let threadID = try await ThreadService.shared.createThread(title: "Hermes \(UUID().uuidString)").id
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await ThreadService.shared.deleteThread(threadId: threadID)
            await ThreadService.shared.reloadForCurrentUser()
            await DataEncryptionService.shared.lock()
        }
        let store = ThreadRepository.shared
        // As the app left it: a turn recorded as running, with its run.
        let turnID = "turn-\(threadID)"
        try await store.beginTurn(id: turnID, userMessage: TurnProgress.message(in: threadID, role: "user", content: "Tidy the repo"))
        try await store.keepRun(AgentRun(provider: "hermes", runID: "run_1", agentName: "Hermes"), forTurn: turnID)
        let kept = try await store.runningTurns(threadID: threadID)
        XCTAssertEqual(kept.map(\.run), [AgentRun(provider: "hermes", runID: "run_1", agentName: "Hermes")])
        let stored = try await DatabaseManager.shared.dbQueue?.read { db in
            try Data.fetchOne(db, sql: "SELECT run_ciphertext FROM turns WHERE id = ?", arguments: [turnID])
        }
        XCTAssertNil(stored?.range(of: Data("run_1".utf8)), "The run is not readable in the database file")

        HermesStub.answer("GET", "/v1/runs/run_1", with: (200, #"{"status":"completed","output":"Done while away."}"#))
        let agent = client
        let engine = TurnEngine(chat: ChatService(
            contextBuilder: ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4)),
            modelRouter: HeuristicModelRouter(availableModels: []),
            llmClients: [:],
            threadStore: store,
            toolService: ToolService.shared,
            shouldAutoRefreshEnvironment: false,
            hermesAgent: { agent }
        ))

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
        XCTAssertEqual(messages.last?.metadata?["role_name"], AnyJSONValue("Hermes"))
        let left = try await store.runningTurns(threadID: threadID)
        XCTAssertEqual(left, [])
        let after = try await DatabaseManager.shared.dbQueue?.read { db in
            try Row.fetchOne(db, sql: "SELECT run_ciphertext FROM turns WHERE id = ?", arguments: [turnID])
        }
        XCTAssertNil(after?["run_ciphertext"] as Data?, "Once the turn has ended, its run is no longer kept")
    }

    @MainActor
    func testATurnWhoseAgentIsNoLongerConnected_isEndedAsInterrupted() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        await ThreadService.shared.reloadForCurrentUser()
        let threadID = try await ThreadService.shared.createThread(title: "Hermes \(UUID().uuidString)").id
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await ThreadService.shared.deleteThread(threadId: threadID)
            await ThreadService.shared.reloadForCurrentUser()
            await DataEncryptionService.shared.lock()
        }
        let store = ThreadRepository.shared
        let turnID = "turn-\(threadID)"
        try await store.beginTurn(id: turnID, userMessage: TurnProgress.message(in: threadID, role: "user", content: "Tidy the repo"))
        try await store.keepRun(AgentRun(provider: "hermes", runID: "run_1"), forTurn: turnID)
        let engine = TurnEngine(chat: ChatService(
            contextBuilder: ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4)),
            modelRouter: HeuristicModelRouter(availableModels: []),
            llmClients: [:],
            threadStore: store,
            toolService: ToolService.shared,
            shouldAutoRefreshEnvironment: false,
            hermesAgent: { nil }
        ))

        await engine.settleInterruptedTurns(threadID: threadID)

        XCTAssertNil(engine.running[threadID])
        let messages = try await store.loadChatMessages(threadID: threadID, limit: 10, before: nil)
        XCTAssertEqual(messages.last?.content, TurnProgress.interruptedNotice)
        XCTAssertTrue(HermesStub.requests.isEmpty)

        // A run is kept only with a turn that is still running.
        try await store.keepRun(AgentRun(provider: "hermes", runID: "run_2"), forTurn: turnID)
        let after = try await DatabaseManager.shared.dbQueue?.read { db in
            try Row.fetchOne(db, sql: "SELECT status, run_ciphertext FROM turns WHERE id = ?", arguments: [turnID])
        }
        XCTAssertEqual(after?["status"] as String?, "interrupted")
        XCTAssertNil(after?["run_ciphertext"] as Data?, "An ended turn keeps no run, and is given none")
    }

    @MainActor
    func testATurnStartedWithHermes_keepsItsRunWithTheNameItWasStartedUnder() async throws {
        let defaults = UserDefaults.standard
        let keys = ["llm_provider", "hermes_model_connections_converted.v1"].map(UserScope.scopedKey)
        let saved = keys.map { defaults.object(forKey: $0) }
        addTeardownBlock {
            for (key, value) in zip(keys, saved) {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        defaults.set("hermes", forKey: keys[0])
        defaults.set(true, forKey: keys[1])
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        await ThreadService.shared.reloadForCurrentUser()
        let threadID = try await ThreadService.shared.createThread(title: "Hermes \(UUID().uuidString)").id
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await ThreadService.shared.deleteThread(threadId: threadID)
            await ThreadService.shared.reloadForCurrentUser()
            await DataEncryptionService.shared.lock()
        }
        // Waiting on the person, so the run is under way when it is looked for.
        HermesStub.answer("GET", events, with: (200, stream(#"{"event":"approval.request","command":"git push"}"#)))
        HermesStub.answer("POST", "/v1/runs/run_1/stop", with: (200, "{}"))
        let asking = HermesStub.expectRequest(to: events)
        let agent = client
        let engine = TurnEngine(chat: ChatService(
            contextBuilder: ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4)),
            modelRouter: HeuristicModelRouter(availableModels: []),
            llmClients: [:],
            threadStore: ThreadRepository.shared,
            toolService: ToolService.shared,
            shouldAutoRefreshEnvironment: false,
            hermesAgent: { agent }
        ))

        try await engine.start(
            with: TurnProgress.message(in: threadID, role: "user", content: "Push it"),
            context: "Push it", roleID: nil, agentName: "Strix", attachments: nil
        )
        await fulfillment(of: [asking], timeout: 10)

        let turns = try await ThreadRepository.shared.runningTurns(threadID: threadID)
        XCTAssertEqual(turns.map(\.run), [AgentRun(provider: "hermes", runID: "run_1", agentName: "Strix")])

        let ended = expectation(description: "The turn has ended")
        ended.assertForOverFulfill = false
        let watching = engine.$endings.sink { endings in
            if endings[threadID] != nil { ended.fulfill() }
        }
        engine.stop(threadID: threadID)
        await fulfillment(of: [ended], timeout: 10)
        watching.cancel()
    }

    @MainActor
    func testAThreadOpenedTwiceAtOnce_picksItsTurnUpOnceAndDoesNotEndIt() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        await ThreadService.shared.reloadForCurrentUser()
        let threadID = try await ThreadService.shared.createThread(title: "Hermes \(UUID().uuidString)").id
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await ThreadService.shared.deleteThread(threadId: threadID)
            await ThreadService.shared.reloadForCurrentUser()
            await DataEncryptionService.shared.lock()
        }
        let store = ThreadRepository.shared
        let turnID = "turn-\(threadID)"
        try await store.beginTurn(id: turnID, userMessage: TurnProgress.message(in: threadID, role: "user", content: "Tidy the repo"))
        try await store.keepRun(AgentRun(provider: "hermes", runID: "run_1", agentName: "Hermes"), forTurn: turnID)
        // Waiting on the person, so the turn is still running when both
        // openers have had their turn.
        HermesStub.answer("GET", "/v1/runs/run_1", with: (200, #"{"status":"waiting_for_approval","pending_approval":{"command":"git push"}}"#))
        HermesStub.answer("POST", "/v1/runs/run_1/stop", with: (200, "{}"))
        let agent = client
        let engine = TurnEngine(chat: ChatService(
            contextBuilder: ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4)),
            modelRouter: HeuristicModelRouter(availableModels: []),
            llmClients: [:],
            threadStore: store,
            toolService: ToolService.shared,
            shouldAutoRefreshEnvironment: false,
            hermesAgent: { agent }
        ))

        async let first: Void = engine.settleInterruptedTurns(threadID: threadID)
        async let second: Void = engine.settleInterruptedTurns(threadID: threadID)
        _ = await (first, second)

        XCTAssertEqual(engine.running[threadID]?.turnID, turnID)
        let turns = try await store.runningTurns(threadID: threadID)
        XCTAssertEqual(turns.map(\.id), [turnID], "The turn picked up is still running, not ended as interrupted")
        let messages = try await store.loadChatMessages(threadID: threadID, limit: 10, before: nil)
        XCTAssertEqual(messages.map(\.content), ["Tidy the repo"])

        // Stopped, it ends under the name it was started with.
        let ended = expectation(description: "The turn has ended")
        ended.assertForOverFulfill = false
        let watching = engine.$endings.sink { endings in
            if endings[threadID] != nil { ended.fulfill() }
        }
        engine.stop(threadID: threadID)
        await fulfillment(of: [ended], timeout: 10)
        watching.cancel()
        XCTAssertEqual(engine.endings[threadID]?.outcome, .cancelled)
        XCTAssertEqual(engine.endings[threadID]?.messages.first?.metadata?["role_name"], AnyJSONValue("Hermes"))

        // Opened again once it has ended: it is not picked up a second time.
        HermesStub.reset()
        await engine.settleInterruptedTurns(threadID: threadID)
        XCTAssertNil(engine.running[threadID])
        XCTAssertTrue(HermesStub.requests.isEmpty)

        // A turn that fails ends under its name too.
        let progress = TurnProgress(agentName: "Hermes")
        let failed = progress.ending(in: threadID, thrown: URLError(.timedOut))
        XCTAssertEqual(failed.outcome, .failed)
        XCTAssertEqual(failed.message.metadata?["role_name"], AnyJSONValue("Hermes"))
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
