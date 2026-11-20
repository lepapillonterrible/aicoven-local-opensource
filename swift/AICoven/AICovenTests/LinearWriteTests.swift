@testable import AICoven
import XCTest

/// An agent comments on a Linear issue, or changes one, only after the
/// person has approved exactly what.
final class LinearWriteTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - What a call asks to change

    func testWhatIsAskedToChange_isReadFromTheArguments() {
        typealias Asked = LinearToolService.Asked
        func read(_ args: [String: AnyJSONValue]) -> Asked? {
            try? LinearToolService.asked(in: args).get()
        }
        func refusedField(_ args: [String: AnyJSONValue]) -> String? {
            if case let .failure(refusal) = LinearToolService.asked(in: args) { return refusal.field }
            return nil
        }
        XCTAssertEqual(read(["status": AnyJSONValue(" In Progress ")]), Asked(status: "In Progress"))
        XCTAssertEqual(
            read(["title": AnyJSONValue("New"), "description": AnyJSONValue(""), "priority": AnyJSONValue("2"), "due_date": AnyJSONValue("2026-12-01"), "assignee": AnyJSONValue("ada@example.com"), "status": .null]),
            Asked(title: "New", description: "", priority: 2, dueDate: "2026-12-01", assignee: "ada@example.com"),
            "A description may be emptied; null is left out"
        )
        XCTAssertEqual(read(["priority": AnyJSONValue(0)]), Asked(priority: 0))
        XCTAssertEqual(read(["priority": AnyJSONValue(3.0)]), Asked(priority: 3))

        XCTAssertEqual(refusedField([:]), "status", "Nothing to change")
        XCTAssertEqual(refusedField(["status": .null, "title": .null]), "status")
        XCTAssertEqual(refusedField(["title": AnyJSONValue("  ")]), "title")
        XCTAssertEqual(refusedField(["title": AnyJSONValue("New\n- Status: Todo → Done")]), "title", "A title is one line")
        XCTAssertEqual(LinearToolService.named(["identifier": "ENG-1", "title": "Two\nlines"]), "ENG-1: Two lines")
        XCTAssertEqual(LinearToolService.named(["identifier": "ENG-1", "title": ""]), "ENG-1: (untitled)")
        XCTAssertEqual(refusedField(["status": AnyJSONValue(3)]), "status")
        for priority in [AnyJSONValue(5), AnyJSONValue(-1), AnyJSONValue("high"), AnyJSONValue(true), AnyJSONValue(1.5)] {
            XCTAssertEqual(refusedField(["priority": priority]), "priority", "\(priority)")
        }
        for due in ["tomorrow", "2026-13-01", "2026-12-32", "26-12-01", "2026-12-01T10:00:00Z"] {
            XCTAssertEqual(refusedField(["due_date": AnyJSONValue(due)]), "due_date", due)
        }
    }

    func testAStatusAndAnAssigneeAreFoundByNameAmongTheTeams() {
        let states: [[String: Any]] = [["id": "s1", "name": "Todo"], ["id": "s2", "name": "In Progress"], ["name": "No id"]]
        XCTAssertEqual(try? LinearToolService.state(named: "in progress", among: states, team: "Eng").get().id, "s2")
        guard case let .failure(noState) = LinearToolService.state(named: "Done", among: states, team: "Eng") else { return XCTFail("No such status") }
        XCTAssertEqual(noState.message, "No status 'Done' in team Eng. Statuses: Todo, In Progress")

        let members: [[String: Any]] = [["id": "u1", "name": "Ada", "email": "ada@example.com"], ["id": "u2", "name": "Ada", "email": "ada2@example.com"], ["id": "u3", "name": "Grace"]]
        XCTAssertEqual(try? LinearToolService.member(matching: "GRACE", among: members, team: "Eng").get().id, "u3")
        XCTAssertEqual(try? LinearToolService.member(matching: "Ada2@Example.com", among: members, team: "Eng").get().id, "u2")
        guard case let .failure(two) = LinearToolService.member(matching: "Ada", among: members, team: "Eng") else { return XCTFail("Two Adas") }
        XCTAssertEqual(two.message, "'Ada' matches 2 members of team Eng; give one member's name or email.")
        guard case let .failure(none) = LinearToolService.member(matching: "Linus", among: members, team: "Eng") else { return XCTFail("No Linus") }
        XCTAssertEqual(none.field, "assignee")
    }

    // MARK: - Calls, with Linear answered by a script

    /// What Linear was asked: each request's query and variables. Sendable
    /// by hand, under `lock`.
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [(query: String, variables: [String: Any])] = []

        var requests: [(query: String, variables: [String: Any])] {
            lock.withLock { kept }
        }

        /// What each request was for, by the first of these words in it.
        var kinds: [String] {
            requests.map { request in
                ["commentCreate", "issueUpdate", "states(", "members(", "viewer", "issue(id"].first { request.query.contains($0) } ?? "?"
            }
        }

        func note(_ query: String, _ variables: [String: Any]) {
            lock.withLock { kept.append((query, variables)) }
        }
    }

    /// The approvals that were asked.
    private actor Seen {
        private(set) var approvals: [ToolApproval] = []

        func note(_ approval: ToolApproval) {
            approvals.append(approval)
        }
    }

    private struct World {
        let executor: ToolExecutionService
        let accounts: ConnectedAccountsService
        let asked: Asked
        let seen: Seen
        let defaults: UserDefaults
        let suite: String

        func call(_ tool: String, _ args: [String: AnyJSONValue], threadID: String? = "thread") async -> ToolExecutionResult {
            await executor.execute(toolCall: ParsedToolCall(name: tool, args: args), agentType: "chat", threadID: threadID)
        }

        func forget() {
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private static let issue = #"{"id": "i1", "identifier": "ENG-12", "title": "Header overlaps the logo", "url": "https://linear.app/acme/issue/ENG-12", "priority": 0, "dueDate": null, "state": {"id": "s1", "name": "Todo"}, "assignee": null, "team": {"id": "t1", "name": "Eng"}, "comments": {"nodes": []}}"#

    /// Linear as these tests need it: one issue, a team with two states
    /// and two members, and mutations that succeed; `overriding` answers
    /// a kind of request another way (status, body), `failing` fails one
    /// without an answer, and `whileAsked` runs while the person is asked.
    private func world(
        approving: Bool = true,
        connections: CovenConnections? = nil,
        overriding: [String: (Int, String)] = [:],
        failing: [String: URLError.Code] = [:],
        whileAsked: (@Sendable (ConnectedAccountsService) async -> Void)? = nil
    ) async throws -> World {
        let suite = "LinearWriteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let accounts = ConnectedAccountsService(currentUser: { "linear-write-tests" }, defaults: defaults, tokens: InMemoryTokens().store, tokenIdentity: { _, _ in .init(id: "u1", label: "ada@example.com") })
        _ = try await accounts.connect(.linear, token: "lin_api_TEST")

        let asked = Asked()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { request in
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                stream.close()
            }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let query = body["query"] as? String ?? ""
            asked.note(query, body["variables"] as? [String: Any] ?? [:])
            let answers: [(String, String)] = [
                ("commentCreate", #"{"data": {"commentCreate": {"success": true, "comment": {"url": "https://linear.app/acme/issue/ENG-12#comment-9"}}}}"#),
                ("issueUpdate", #"{"data": {"issueUpdate": {"success": true, "issue": {"identifier": "ENG-12", "url": "https://linear.app/acme/issue/ENG-12", "title": "t", "state": {"name": "In Progress"}}}}}"#),
                ("states(", #"{"data": {"team": {"states": {"nodes": [{"id": "s1", "name": "Todo"}, {"id": "s2", "name": "In Progress"}], "pageInfo": {"hasNextPage": false}}}}}"#),
                ("members(", #"{"data": {"team": {"members": {"nodes": [{"id": "u1", "name": "Ada", "email": "ada@example.com"}, {"id": "u2", "name": "Grace", "email": "grace@example.com"}], "pageInfo": {"hasNextPage": false}}}}}"#),
                ("viewer", #"{"data": {"viewer": {"id": "u1", "email": "ada@example.com"}}}"#),
                ("issue(id", #"{"data": {"issue": \#(Self.issue)}}"#),
            ]
            let kind = answers.first { query.contains($0.0) }
            if let code = kind.flatMap({ failing[$0.0] }) { throw URLError(code) }
            let (status, answer) = kind.flatMap { overriding[$0.0] } ?? (200, kind?.1 ?? "{}")
            return try (XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)), Data(answer.utf8))
        }
        let seen = Seen()
        let executor = ToolExecutionService(
            toolService: ToolService.shared,
            ask: { approval in
                await seen.note(approval)
                await whileAsked?(accounts)
                return approving ? .approved : .denied
            },
            covenConnections: { _ in connections },
            connectedAccounts: accounts,
            hasToolsPack: { true },
            appSession: URLSession(configuration: config)
        )
        await executor.setWhitelist(for: "chat", tools: PromptTemplates.linearTools)
        return World(executor: executor, accounts: accounts, asked: asked, seen: seen, defaults: defaults, suite: suite)
    }

    func testAComment_isPostedToTheIssueOnceThePersonApprovesIt() async throws {
        let world = try await world()
        defer { world.forget() }

        let posted = await world.call("linear.addComment", ["issue": AnyJSONValue("eng-12"), "body": AnyJSONValue(" Fixed in the linked pull request. ")])

        XCTAssertEqual(posted.status, "ok")
        XCTAssertEqual(posted.contextBlock, "[Linear Comment Posted: ENG-12]\nhttps://linear.app/acme/issue/ENG-12#comment-9")
        let approvals = await world.seen.approvals
        XCTAssertEqual(approvals.map(\.question), ["Comment on this Linear issue?"])
        XCTAssertEqual(approvals.first?.details.hasPrefix("ENG-12: Header overlaps the logo\nPosted as you · "), true)
        XCTAssertEqual(approvals.first?.details.hasSuffix("\n\nFixed in the linked pull request."), true)
        XCTAssertEqual(world.asked.kinds, ["issue(id", "commentCreate"], "The issue is read, then the comment posted to its id")
        XCTAssertEqual(world.asked.requests.last?.variables as NSDictionary?, ["issueId": "i1", "body": "Fixed in the linked pull request."] as NSDictionary)
    }

    func testAnIssueIsChanged_withEachChangeShownFromWhatToWhat() async throws {
        let world = try await world()
        defer { world.forget() }

        let changed = await world.call("linear.updateIssue", [
            "issue": AnyJSONValue("ENG-12"), "status": AnyJSONValue("in progress"), "assignee": AnyJSONValue("grace@example.com"),
            "title": AnyJSONValue("Header covers the logo"), "priority": AnyJSONValue(2), "due_date": AnyJSONValue("2026-12-01"), "description": AnyJSONValue("At 320pt."),
        ])

        XCTAssertEqual(changed.status, "ok")
        let lines = [
            "- Status: Todo → In Progress",
            "- Assignee: (no one) → Grace",
            "- Title: Header overlaps the logo → Header covers the logo",
            "- Priority: None → High",
            "- Due: (none) → 2026-12-01",
            "- Description: replaced",
        ].joined(separator: "\n")
        XCTAssertEqual(changed.contextBlock, "[Linear Issue Changed: ENG-12]\n\(lines)\nhttps://linear.app/acme/issue/ENG-12")
        let approvals = await world.seen.approvals
        XCTAssertEqual(approvals.map(\.question), ["Change this Linear issue?"])
        XCTAssertEqual(approvals.first?.details, "ENG-12: Header overlaps the logo\n\(lines)\n\nNew description:\nAt 320pt.")
        XCTAssertEqual(world.asked.kinds, ["issue(id", "states(", "members(", "issueUpdate"])
        let sent = try XCTUnwrap(world.asked.requests.last?.variables)
        XCTAssertEqual(sent["id"] as? String, "i1")
        XCTAssertEqual(sent["input"] as? NSDictionary, ["stateId": "s2", "assigneeId": "u2", "title": "Header covers the logo", "priority": 2, "dueDate": "2026-12-01", "description": "At 320pt."] as NSDictionary)

        // A change that needs no name looked up asks Linear for none.
        let titled = try await self.world()
        defer { titled.forget() }
        _ = await titled.call("linear.updateIssue", ["issue": AnyJSONValue("ENG-12"), "title": AnyJSONValue("New")])
        XCTAssertEqual(titled.asked.kinds, ["issue(id", "issueUpdate"])
        let onlyTitle = await titled.seen.approvals
        XCTAssertEqual(onlyTitle.first?.details, "ENG-12: Header overlaps the logo\n- Title: Header overlaps the logo → New")
    }

    func testWhatIsNotAChange_orNamesNoStatusOrMember_isToldSo_andNoOneIsAsked() async throws {
        let world = try await world()
        defer { world.forget() }

        var result = await world.call("linear.updateIssue", ["issue": AnyJSONValue("ENG-12")])
        XCTAssertEqual(result.field, "status")
        result = await world.call("linear.updateIssue", ["issue": AnyJSONValue("ENG-12"), "priority": AnyJSONValue(9)])
        XCTAssertEqual(result.field, "priority")
        result = await world.call("linear.addComment", ["issue": AnyJSONValue("ENG-12"), "body": AnyJSONValue("  ")])
        XCTAssertEqual(result.field, "body")
        result = await world.call("linear.addComment", ["issue": AnyJSONValue("the header bug"), "body": AnyJSONValue("Hi")])
        XCTAssertEqual(result.field, "issue")
        XCTAssertEqual(world.asked.requests.count, 0, "Nothing is asked of Linear for what cannot be read")

        result = await world.call("linear.updateIssue", ["issue": AnyJSONValue("ENG-12"), "status": AnyJSONValue("Done")])
        XCTAssertEqual(result.error, "No status 'Done' in team Eng. Statuses: Todo, In Progress")
        result = await world.call("linear.updateIssue", ["issue": AnyJSONValue("ENG-12"), "assignee": AnyJSONValue("Linus")])
        XCTAssertEqual(result.field, "assignee")
        XCTAssertFalse(world.asked.kinds.contains("issueUpdate"))
        let approvals = await world.seen.approvals
        XCTAssertEqual(approvals.count, 0)
    }

    func testADeniedChange_orOneInACovenThatOnlyReadsLinear_sendsNothing() async throws {
        let denying = try await world(approving: false)
        defer { denying.forget() }
        var result = await denying.call("linear.addComment", ["issue": AnyJSONValue("ENG-12"), "body": AnyJSONValue("Hi")])
        XCTAssertEqual(result.status, "denied")
        result = await denying.call("linear.updateIssue", ["issue": AnyJSONValue("ENG-12"), "title": AnyJSONValue("New")])
        XCTAssertEqual(result.status, "denied")
        result = await denying.call("linear.addComment", ["issue": AnyJSONValue("ENG-12"), "body": AnyJSONValue("Hi")], threadID: nil)
        XCTAssertNotEqual(result.status, "ok")
        XCTAssertEqual(Set(denying.asked.kinds), ["issue(id"], "The issue was read; nothing was changed")

        let readOnly = try await world(connections: CovenConnections(apps: ["linear": .readOnly]))
        defer { readOnly.forget() }
        for (tool, args) in [("linear.addComment", ["issue": AnyJSONValue("ENG-12"), "body": AnyJSONValue("Hi")]), ("linear.updateIssue", ["issue": AnyJSONValue("ENG-12"), "title": AnyJSONValue("New")])] as [(String, [String: AnyJSONValue])] {
            XCTAssertTrue(CovenConnectionRules.isWriteTool(tool))
            XCTAssertNotNil(PromptTemplates.toolDefinitions.first { $0.name == tool })
            result = await readOnly.call(tool, args)
            XCTAssertEqual(result.errorType, "connection_read_only", tool)
        }
        XCTAssertEqual(readOnly.asked.requests.count, 0)
        let approvals = await readOnly.seen.approvals
        XCTAssertEqual(approvals.count, 0)
        XCTAssertEqual(
            CovenConnectionRules.offered(tools: PromptTemplates.linearTools, servers: [], in: CovenConnections(apps: ["linear": .readOnly])).tools,
            ["linear.getIssue"]
        )
    }

    func testWhatLinearAnswersToAChange() async throws {
        // Linear says it did not do it.
        let refusing = try await world(overriding: ["commentCreate": (200, #"{"data": {"commentCreate": {"success": false}}}"#)])
        defer { refusing.forget() }
        var result = await refusing.call("linear.addComment", ["issue": AnyJSONValue("ENG-12"), "body": AnyJSONValue("Hi")])
        XCTAssertEqual(result.errorType, "linear_refused")
        XCTAssertEqual(result.error, "Linear did not do it: Linear did not add the comment")

        // Its answer cannot be read: the change may have been made.
        let unread = try await world(overriding: ["issueUpdate": (200, "not json")])
        defer { unread.forget() }
        result = await unread.call("linear.updateIssue", ["issue": AnyJSONValue("ENG-12"), "title": AnyJSONValue("New")])
        XCTAssertEqual(result.errorType, "linear_unconfirmed")
        XCTAssertFalse(result.isRetryable)

        // It refuses the change but takes the key: the connection stands.
        let forbidden = try await world(overriding: ["issueUpdate": (403, "{}")])
        defer { forbidden.forget() }
        result = await forbidden.call("linear.updateIssue", ["issue": AnyJSONValue("ENG-12"), "title": AnyJSONValue("New")])
        XCTAssertEqual(result.errorType, "linear_forbidden")
        let still = await forbidden.accounts.getConnectedAccount(for: .linear)
        XCTAssertNotNil(still)

        // An answer that did not come may be a change made; a refusal is not.
        XCTAssertTrue(ToolExecutionService.linearMayHaveBeenCarriedOut(URLError(.timedOut)))
        XCTAssertFalse(ToolExecutionService.linearMayHaveBeenCarriedOut(LinearError.keyRefused))
    }

    func testAChangeApprovedAfterItsConnectionWent_isNotMade() async throws {
        // Linear is disconnected while the person is asked.
        let gone = try await world(whileAsked: { accounts in
            guard let account = await accounts.getConnectedAccount(for: .linear) else { return }
            try? await accounts.deleteAccount(id: account.id)
        })
        defer { gone.forget() }
        for (tool, args) in [("linear.addComment", ["issue": AnyJSONValue("ENG-12"), "body": AnyJSONValue("Hi")]), ("linear.updateIssue", ["issue": AnyJSONValue("ENG-12"), "title": AnyJSONValue("New")])] as [(String, [String: AnyJSONValue])] {
            let result = await gone.call(tool, args)
            // The first finds it gone once approved; the second finds none to start with.
            XCTAssertNotEqual(result.status, "ok", tool)
        }
        XCTAssertEqual(gone.asked.kinds, ["issue(id"], "Only the first call read the issue; nothing was changed")

        let first = try await world(whileAsked: { accounts in
            guard let account = await accounts.getConnectedAccount(for: .linear) else { return }
            try? await accounts.deleteAccount(id: account.id)
        })
        defer { first.forget() }
        let result = await first.call("linear.addComment", ["issue": AnyJSONValue("ENG-12"), "body": AnyJSONValue("Hi")])
        XCTAssertEqual(result.errorType, "linear_connection_changed")
    }

    func testAChangeWhoseAnswerDidNotCome_orThatWasStoppedWhileAsked_mayHaveBeenMade() async throws {
        let lost = try await world(failing: ["commentCreate": .networkConnectionLost])
        defer { lost.forget() }
        var result = await lost.call("linear.addComment", ["issue": AnyJSONValue("ENG-12"), "body": AnyJSONValue("Hi")])
        XCTAssertEqual(result.errorType, "linear_unconfirmed")
        XCTAssertFalse(result.isRetryable)

        // The request was cancelled under way: it is not told as not made.
        let stopped = try await world(failing: ["issueUpdate": .cancelled])
        defer { stopped.forget() }
        result = await stopped.call("linear.updateIssue", ["issue": AnyJSONValue("ENG-12"), "title": AnyJSONValue("New")])
        XCTAssertEqual(result.errorType, "cancelled")
        XCTAssertEqual(result.error?.contains("may have been made"), true)

        // An answer that does not say whether it was done, and one that
        // says the server failed, leave the change unknown too.
        for (kind, answer) in [("commentCreate", (200, #"{"data": {}}"#)), ("commentCreate", (200, #"{"data": {"commentCreate": {"comment": null}}}"#)), ("commentCreate", (502, "Bad Gateway")), ("commentCreate", (500, #"{"errors": [{"message": "Internal server error"}]}"#))] as [(String, (Int, String))] {
            let unsure = try await world(overriding: [kind: answer])
            defer { unsure.forget() }
            result = await unsure.call("linear.addComment", ["issue": AnyJSONValue("ENG-12"), "body": AnyJSONValue("Hi")])
            XCTAssertEqual(result.errorType, "linear_unconfirmed", answer.1)
            XCTAssertFalse(result.isRetryable, answer.1)
            XCTAssertEqual(result.toldToAModel, "[Tool Error: linear.addComment]\n\(ToolExecutionService.linearUnconfirmed)", "An agent is told to look before asking again")
        }

        // Linear says the change was made and does not tell the issue: it was made.
        let untold = try await world(overriding: ["issueUpdate": (200, #"{"data": {"issueUpdate": {"success": true}}}"#)])
        defer { untold.forget() }
        result = await untold.call("linear.updateIssue", ["issue": AnyJSONValue("ENG-12"), "title": AnyJSONValue("New")])
        XCTAssertEqual(result.status, "ok")
        XCTAssertEqual(result.contextBlock, "[Linear Issue Changed: ENG-12]\n- Title: Header overlaps the logo → New\nhttps://linear.app/acme/issue/ENG-12")

        // A request that never left (no network) changed nothing, and may be made again.
        let offline = try await world(failing: ["issueUpdate": .notConnectedToInternet])
        defer { offline.forget() }
        result = await offline.call("linear.updateIssue", ["issue": AnyJSONValue("ENG-12"), "title": AnyJSONValue("New")])
        XCTAssertEqual(result.errorType, "linear_failed")
        XCTAssertTrue(result.isRetryable)
    }

    func testWhatAModelIsToldOfAResult() {
        XCTAssertEqual(ToolExecutionResult.success(tool: "t", result: [:], contextBlock: "found").toldToAModel, "found")
        XCTAssertNil(ToolExecutionResult.success(tool: "t", result: [:]).toldToAModel)
        XCTAssertEqual(ToolExecutionResult.error(tool: "t", message: "It failed.").toldToAModel, "[Tool Error: t]\nIt failed.")
        XCTAssertEqual(ToolExecutionResult.validationError(tool: "t", message: "No 'x'.", field: "x").toldToAModel, "[Tool Error: t]\nNo 'x'.")
        XCTAssertEqual(ToolExecutionResult.denied(tool: "t", reason: "No.").toldToAModel, "[Tool Permission Denied: t]\nNo.")
    }

    /// A session whose every request is answered by `answer`, given the
    /// request's variables.
    private func session(answering answer: @escaping @Sendable ([String: Any]) -> String) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { request in
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                stream.close()
            }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let said = answer(body["variables"] as? [String: Any] ?? [:])
            return try (XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)), Data(said.utf8))
        }
        return URLSession(configuration: config)
    }

    func testATeamsStatesAreReadPageByPage_andNotWithoutEnd() async throws {
        // Two pages: the second is asked for after the first's cursor.
        let twoPages = session { variables in
            variables["after"] as? String == "c1"
                ? #"{"data": {"team": {"states": {"nodes": [{"id": "s2", "name": "Done"}], "pageInfo": {"hasNextPage": false}}}}}"#
                : #"{"data": {"team": {"states": {"nodes": [{"id": "s1", "name": "Todo"}], "pageInfo": {"hasNextPage": true, "endCursor": "c1"}}}}}"#
        }
        let states = try await LinearToolService.states(ofTeam: "t1", key: "lin_api_TEST", session: twoPages)
        XCTAssertEqual(states.compactMap { $0["name"] as? String }, ["Todo", "Done"])

        // A page that says there is more and gives no cursor is no answer.
        let noCursor = session { _ in #"{"data": {"team": {"members": {"nodes": [], "pageInfo": {"hasNextPage": true}}}}}"# }
        do {
            _ = try await LinearToolService.members(ofTeam: "t1", key: "lin_api_TEST", session: noCursor)
            XCTFail("More, with no cursor")
        } catch {
            guard case LinearError.invalidResponse = error else { return XCTFail("\(error)") }
        }

        // A page that cannot be read whole is no page: the name looked
        // for, or a second of it, may be in what is not seen.
        for page in [
            #"{"nodes": [{"id": "s1", "name": "Todo"}]}"#,
            #"{"nodes": [{"id": "s1", "name": "Todo"}], "pageInfo": {}}"#,
            #"{"pageInfo": {"hasNextPage": false}}"#,
            #"{"nodes": [{"id": "s1"}], "pageInfo": {"hasNextPage": false}}"#,
            #"{"nodes": ["Todo"], "pageInfo": {"hasNextPage": false}}"#,
        ] {
            let unreadable = session { _ in #"{"data": {"team": {"states": \#(page)}}}"# }
            do {
                _ = try await LinearToolService.states(ofTeam: "t1", key: "lin_api_TEST", session: unreadable)
                XCTFail("Read as a whole page: \(page)")
            } catch {
                guard case LinearError.invalidResponse = error else { return XCTFail("\(error)") }
            }
        }

        // Pages that never end are not followed for ever, and a name is
        // not looked for among a part of them.
        let pages = Counter()
        let endless = session { _ in
            pages.add()
            return #"{"data": {"team": {"states": {"nodes": [{"id": "s1", "name": "Todo"}], "pageInfo": {"hasNextPage": true, "endCursor": "c"}}}}}"#
        }
        do {
            _ = try await LinearToolService.states(ofTeam: "t1", key: "lin_api_TEST", session: endless)
            XCTFail("Pages without end")
        } catch {
            guard case LinearError.refused = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(pages.count, LinearToolService.mostPages)
    }

    /// A count kept under a lock. Sendable by hand.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var kept = 0

        var count: Int {
            lock.withLock { kept }
        }

        func add() {
            lock.withLock { kept += 1 }
        }
    }
}
