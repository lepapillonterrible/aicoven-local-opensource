@testable import AICoven
import XCTest

/// Linear is connected with a personal API key, and an agent can read an
/// issue with it.
final class LinearTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    /// What Linear was asked. Sendable by hand, under `lock`.
    private final class Asked: @unchecked Sendable {
        struct Request {
            let method: String
            let url: String
            let authorization: String?
            let body: [String: Any]
        }

        private let lock = NSLock()
        private var kept: [Request] = []

        var requests: [Request] {
            lock.withLock { kept }
        }

        func note(_ request: URLRequest) {
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
            let noted = Request(
                method: request.httpMethod ?? "GET",
                url: request.url?.absoluteString ?? "",
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                body: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            )
            lock.withLock { kept.append(noted) }
        }
    }

    private func session(keeping asked: Asked, answer: @escaping @Sendable (URLRequest) -> (Int, String, [String: String])) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { request in
            asked.note(request)
            let (status, body, headers) = answer(request)
            return try (XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)), Data(body.utf8))
        }
        return URLSession(configuration: config)
    }

    // MARK: - Asking Linear

    func testAKeysOwnerIsAskedOfLinear_withTheKeyBareInItsHeader() async throws {
        let asked = Asked()
        let who = try await LinearToolService.identity(key: "lin_api_TEST", session: session(keeping: asked) { _ in
            (200, #"{"data": {"viewer": {"id": "u1", "name": "Ada", "email": "ada@example.com"}}}"#, [:])
        })

        XCTAssertEqual(who.id, "u1")
        XCTAssertEqual(who.label, "ada@example.com")
        let request = try XCTUnwrap(asked.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, "https://api.linear.app/graphql")
        XCTAssertEqual(request.authorization, "lin_api_TEST", "A personal key goes bare, not after Bearer")
        XCTAssertEqual(request.body["query"] as? String, "query { viewer { id name email } }")
        XCTAssertEqual(asked.requests.count, 1)

        let byName = try await LinearToolService.identity(key: "k", session: session(keeping: Asked()) { _ in (200, #"{"data": {"viewer": {"id": "u1", "name": "Ada", "email": ""}}}"#, [:]) })
        XCTAssertEqual(byName.label, "Ada")
    }

    func testWhatLinearAnswersWhenItWillNot() async {
        func failure(_ status: Int, _ body: String, headers: [String: String] = [:]) async -> LinearError? {
            do {
                _ = try await LinearToolService.ask("query { viewer { id } }", key: "k", session: session(keeping: Asked()) { _ in (status, body, headers) })
                return nil
            } catch {
                return error as? LinearError
            }
        }
        var why = await failure(401, "{}")
        XCTAssertEqual(why, .keyRefused)
        why = await failure(400, #"{"errors": [{"message": "Authentication required", "extensions": {"type": "authentication error", "code": "AUTHENTICATION_ERROR"}}]}"#)
        XCTAssertEqual(why, .keyRefused, "Linear's own word for a key it does not take, whatever the status")
        why = await failure(429, "{}", headers: ["Retry-After": "30"])
        XCTAssertEqual(why, .rateLimited(retryAfter: 30))
        why = await failure(200, #"{"errors": [{"message": "Slow down", "extensions": {"code": "RATELIMITED"}}]}"#)
        XCTAssertEqual(why, .rateLimited(retryAfter: nil))
        why = await failure(200, #"{"data": {"viewer": null}, "errors": [{"message": "Field 'x' is not defined", "extensions": {"code": "GRAPHQL_VALIDATION_FAILED"}}]}"#)
        XCTAssertEqual(why, .refused(message: "Field 'x' is not defined"), "Errors beside data are read first")
        why = await failure(200, #"{"errors": [{"message": "\#(String(repeating: "x", count: 400))"}]}"#)
        XCTAssertEqual(why, .refused(message: String(repeating: "x", count: LinearToolService.mostOfAMessage)))
        why = await failure(500, "oops")
        XCTAssertEqual(why, .notAnswered(status: 500))
        why = await failure(200, #"{"data": null}"#)
        XCTAssertEqual(why, .invalidResponse)
    }

    // MARK: - What a call names, and what a model is told

    func testAnIssueIsNamedByItsIdentifierItsIdOrItsLink() {
        XCTAssertEqual(LinearToolService.issueReference("ENG-12"), "ENG-12")
        XCTAssertEqual(LinearToolService.issueReference(" eng-12 "), "ENG-12")
        XCTAssertEqual(LinearToolService.issueReference("https://linear.app/acme/issue/ENG-12/fix-the-header"), "ENG-12")
        XCTAssertEqual(LinearToolService.issueReference("9D3B6F0E-2C7A-4B1D-8E5F-0A1B2C3D4E5F"), "9d3b6f0e-2c7a-4b1d-8e5f-0a1b2c3d4e5f")
        for notOne in ["", "ENG", "12", "ENG-", "-12", "ENG 12", "ENG-12; DROP", "http://linear.app/acme/issue/ENG-12", "https://evil.example/acme/issue/ENG-12", "https://linear.app/acme/project/ENG-12", "https://linear.app/acme/issue/"] {
            XCTAssertNil(LinearToolService.issueReference(notOne), "\(notOne) names no issue")
        }
    }

    func testAnIssueIsToldWithWhereItStandsAndItsLatestComments() throws {
        let issue = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"""
        {"id": "i1", "identifier": "ENG-12", "title": "Header overlaps\nthe logo", "url": "https://linear.app/acme/issue/ENG-12", "priority": 2, "dueDate": "2026-12-01",
         "description": "  At 320pt the header\ncovers the logo.  ",
         "state": {"name": "In Progress"}, "assignee": {"name": "Ada"}, "team": {"name": "Engineering"},
         "comments": {"nodes": [{"body": "On it.\nToday.", "createdAt": "2026-11-19T10:00:00Z", "user": {"name": "Ada"}}, {"body": "Thanks", "createdAt": "2026-11-19T11:00:00Z"}]}}
        """#.utf8)) as? [String: Any])

        XCTAssertEqual(LinearToolService.told(issue: issue), """
        [Linear Issue: ENG-12] Header overlaps the logo
        URL: https://linear.app/acme/issue/ENG-12
        State: In Progress · Assignee: Ada · Team: Engineering · Priority: High · Due: 2026-12-01

        Description:
        At 320pt the header
        covers the logo.

        Comments (the latest 2):
        - Ada, 2026-11-19T10:00:00Z: On it. Today.
        - Someone, 2026-11-19T11:00:00Z: Thanks
        """)
        XCTAssertEqual(LinearToolService.told(issue: ["identifier": "ENG-1"]), "[Linear Issue: ENG-1] (untitled)\nState: (none) · Assignee: (no one)\n\nDescription:\n(none)")
        XCTAssertEqual([0, 1, 2, 3, 4, 9].map(LinearToolService.priorityName), ["None", "Urgent", "High", "Medium", "Low", "None"])

        // A long comment is told to its limit, the mark that it was cut included.
        let long = LinearToolService.told(issue: ["identifier": "ENG-1", "comments": ["nodes": [["body": String(repeating: "a", count: 2001), "createdAt": "t"]]]])
        let line = try XCTUnwrap(long.split(separator: "\n").last)
        XCTAssertEqual(line.dropFirst("- Someone, t: ".count).count, LinearToolService.mostOfAComment)
        XCTAssertTrue(line.hasSuffix("a…"))
        let whole = LinearToolService.told(issue: ["identifier": "ENG-1", "comments": ["nodes": [["body": String(repeating: "a", count: 2000), "createdAt": "t"]]]])
        XCTAssertFalse(whole.hasSuffix("…"))
    }

    // MARK: - Connecting, and the tool

    private struct World {
        let executor: ToolExecutionService
        let accounts: ConnectedAccountsService
        let tokens: InMemoryTokens
        let asked: Asked
        let checking: Checking
        let defaults: UserDefaults
        let suite: String

        func call(_ tool: String, _ args: [String: AnyJSONValue], threadID: String? = "thread") async -> ToolExecutionResult {
            await executor.execute(toolCall: ParsedToolCall(name: tool, args: args), agentType: "chat", threadID: threadID)
        }

        func forget() {
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private func world(
        connected: Bool = true,
        hasToolsPack: Bool = true,
        connections: CovenConnections? = nil,
        answer: @escaping @Sendable (URLRequest) -> (Int, String, [String: String]) = { _ in (200, "{}", [:]) }
    ) async throws -> World {
        let suite = "LinearTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let tokens = InMemoryTokens()
        let checking = Checking()
        let accounts = ConnectedAccountsService(currentUser: { "linear-tests" }, defaults: defaults, tokens: tokens.store, tokenIdentity: { provider, token in
            await checking.happens(for: provider)
            guard token != "wrong" else { throw ConnectedAccountsService.TokenRefusal.refused }
            return .init(id: token.hasSuffix("other") ? "u2" : "u1", label: provider == .linear ? "ada@linear.example" : "ada@figma.example")
        })
        if connected { _ = try await accounts.connect(.linear, token: "lin_api_TEST") }
        let asked = Asked()
        let executor = ToolExecutionService(
            toolService: ToolService.shared,
            covenConnections: { _ in connections },
            connectedAccounts: accounts,
            hasToolsPack: { hasToolsPack },
            figmaSession: session(keeping: asked, answer: answer)
        )
        await executor.setWhitelist(for: "chat", tools: PromptTemplates.linearTools)
        return World(executor: executor, accounts: accounts, tokens: tokens, asked: asked, checking: checking, defaults: defaults, suite: suite)
    }

    /// What happens while an app is asked whose a token is, where a test
    /// says something does.
    private actor Checking {
        private var during: [ConnectedAppProvider: @Sendable () async -> Void] = [:]

        func during(_ provider: ConnectedAppProvider, _ happens: @escaping @Sendable () async -> Void) {
            during[provider] = happens
        }

        func happens(for provider: ConnectedAppProvider) async {
            let happens = during.removeValue(forKey: provider)
            await happens?()
        }
    }

    func testLinearConnectsWithAKey_besideFigma_eachItsOwnConnection() async throws {
        let world = try await world(connected: false)
        defer { world.forget() }

        let figma = try await world.accounts.connect(.figma, token: "figd_one")
        let linear = try await world.accounts.connect(.linear, token: "  lin_api_one ")
        XCTAssertEqual(linear.provider, .linear)
        XCTAssertEqual(linear.displayName, "ada@linear.example")
        XCTAssertEqual(linear.metadata, ["linear_user_id": "u1", "source": "pasted_token"])
        let both = await world.accounts.getAllAccounts()
        XCTAssertEqual(both.map(\.id), [figma.id, linear.id], "Connecting one app leaves the other's connection")
        let key = try await world.accounts.getAccessToken(forAccountId: linear.id)
        XCTAssertEqual(key, "lin_api_one")
        XCTAssertEqual(world.tokens.all["AICovenProviderKeys.linear-tests"]?.count, 2)

        // A key Linear does not take; a new key from another Linear account; an app that signs in.
        for (token, replacing, why) in [("wrong", nil, ConnectedAccountsService.TokenRefusal.refused), ("lin_api_other", linear.id, .otherAccount), ("lin_api_one", figma.id, .changed)] {
            do {
                _ = try await world.accounts.connect(.linear, token: token, replacing: replacing)
                XCTFail("Not taken: \(token)")
            } catch {
                XCTAssertEqual(error as? ConnectedAccountsService.TokenRefusal, why, token)
            }
        }
        do {
            _ = try await world.accounts.connect(.github, token: "ghp_x")
            XCTFail("GitHub signs in")
        } catch {
            XCTAssertEqual(error as? ConnectedAccountsService.TokenRefusal, .notAToken)
        }
        let after = await world.accounts.getAllAccounts()
        XCTAssertEqual(after.map(\.id), [figma.id, linear.id])

        // Linear is disconnected while a new Figma token is being checked:
        // the Figma token is kept all the same. One app's connection is
        // not the other's.
        let accounts = world.accounts
        await world.checking.during(.figma) { await accounts.disconnectAccount(id: linear.id) }
        let renewed = try await world.accounts.connect(.figma, token: "figd_two", replacing: figma.id)
        XCTAssertEqual(renewed.id, figma.id)
        let figmaToken = try await world.accounts.getAccessToken(forAccountId: figma.id)
        XCTAssertEqual(figmaToken, "figd_two")
        let linearNow = await world.accounts.getConnectedAccount(for: .linear)
        XCTAssertNil(linearNow)
        // The same app's connection disconnected meanwhile does call it off.
        await world.checking.during(.figma) { await accounts.disconnectAccount(id: figma.id) }
        do {
            _ = try await world.accounts.connect(.figma, token: "figd_three", replacing: figma.id)
            XCTFail("Figma was disconnected while its token was checked")
        } catch {
            XCTAssertEqual(error as? ConnectedAccountsService.TokenRefusal, .changed)
        }
    }

    func testGetIssue_asksForTheIssueNamed_andTellsIt() async throws {
        let world = try await world { _ in
            (200, #"{"data": {"issue": {"id": "i1", "identifier": "ENG-12", "title": "Header overlaps the logo", "url": "https://linear.app/acme/issue/ENG-12", "priority": 0, "state": {"name": "Todo"}, "comments": {"nodes": []}}}}"#, [:])
        }
        defer { world.forget() }

        let result = await world.call("linear.getIssue", ["issue": AnyJSONValue("https://linear.app/acme/issue/eng-12/header")])

        XCTAssertEqual(result.status, "ok")
        XCTAssertEqual(result.contextBlock, "[Linear Issue: ENG-12] Header overlaps the logo\nURL: https://linear.app/acme/issue/ENG-12\nState: Todo · Assignee: (no one) · Priority: None\n\nDescription:\n(none)")
        let request = try XCTUnwrap(world.asked.requests.first)
        XCTAssertEqual(request.authorization, "lin_api_TEST")
        XCTAssertEqual(request.body["variables"] as? NSDictionary, ["id": "ENG-12"] as NSDictionary)
        XCTAssertEqual(request.body["query"] as? String, LinearToolService.issueQuery)
        XCTAssertEqual(world.asked.requests.count, 1)
    }

    func testWhatLinearWillNotDo_isToldAsWhatItIs_andARefusedKeyWaitsForANewOne() async throws {
        let missing = try await world { _ in (200, #"{"data": {"issue": null}}"#, [:]) }
        defer { missing.forget() }
        var result = await missing.call("linear.getIssue", ["issue": AnyJSONValue("ENG-404")])
        XCTAssertEqual(result.errorType, "linear_not_found")

        let unknown = try await world { _ in (200, #"{"errors": [{"message": "Entity not found: Issue", "extensions": {"code": "INPUT_ERROR"}}]}"#, [:]) }
        defer { unknown.forget() }
        result = await unknown.call("linear.getIssue", ["issue": AnyJSONValue("ENG-404")])
        XCTAssertEqual(result.errorType, "linear_not_found")

        let limited = try await world { _ in (429, "{}", ["Retry-After": "12"]) }
        defer { limited.forget() }
        result = await limited.call("linear.getIssue", ["issue": AnyJSONValue("ENG-12")])
        XCTAssertEqual(result.errorType, "linear_rate_limited")
        XCTAssertEqual(result.error, "Linear is limiting how often this account asks. Try again in 12 seconds.")

        // A key Linear no longer takes: the connection waits for a new one, and is not asked with again.
        let refused = try await world { _ in (401, "{}", [:]) }
        defer { refused.forget() }
        result = await refused.call("linear.getIssue", ["issue": AnyJSONValue("ENG-12")])
        XCTAssertEqual(result.errorType, "linear_key_refused")
        let waiting = await refused.accounts.accountWaitingForAToken(for: .linear)
        XCTAssertNotNil(waiting)
        result = await refused.call("linear.getIssue", ["issue": AnyJSONValue("ENG-12")])
        XCTAssertEqual(result.error, ToolExecutionService.linearNotConnected)
        XCTAssertEqual(refused.asked.requests.count, 1)

        // A call whose turn was stopped says so, also where it would
        // otherwise say that Linear is not connected.
        let stoppedWorld = try await world(connected: false)
        defer { stoppedWorld.forget() }
        let stopping = Task { await stoppedWorld.call("linear.getIssue", ["issue": AnyJSONValue("ENG-12")]) }
        stopping.cancel()
        let stopped = await stopping.value
        XCTAssertEqual(stopped.errorType, "cancelled")
        XCTAssertEqual(stopped.error, "Stopped before the issue was read.")

        // What names no issue is told so, and Linear is not asked.
        let unasked = try await world()
        defer { unasked.forget() }
        for issue in [AnyJSONValue("the header bug"), AnyJSONValue(12), .null] {
            result = await unasked.call("linear.getIssue", ["issue": issue])
            XCTAssertEqual(result.field, "issue", "\(issue)")
        }
        XCTAssertEqual(unasked.asked.requests.count, 0)
    }

    func testLinearIsUnderACovensChoiceAndTheToolsPack_andSaysWhatItsSheetSays() async throws {
        XCTAssertEqual(CovenConnectionRules.app(of: "linear.getIssue"), "linear")
        XCTAssertFalse(CovenConnectionRules.isWriteTool("linear.getIssue"))
        XCTAssertTrue(ConnectedAppProvider.linear.connectsWithToken)
        XCTAssertNotNil(PromptTemplates.toolDefinitions.first { $0.name == "linear.getIssue" })
        XCTAssertEqual(ChatService.friendlyToolName("linear.getIssue"), "Linear")

        let off = try await world(connections: CovenConnections(apps: ["figma": .readWrite]))
        defer { off.forget() }
        var result = await off.call("linear.getIssue", ["issue": AnyJSONValue("ENG-12")])
        XCTAssertEqual(result.errorType, "connection_not_on")
        XCTAssertEqual(result.error?.hasPrefix("Linear is not turned on in this coven"), true)
        let unpaid = try await world(hasToolsPack: false)
        defer { unpaid.forget() }
        result = await unpaid.call("linear.getIssue", ["issue": AnyJSONValue("ENG-12")])
        XCTAssertEqual(result.errorType, "entitlement_required")
        let unconnected = try await world(connected: false)
        defer { unconnected.forget() }
        result = await unconnected.call("linear.getIssue", ["issue": AnyJSONValue("ENG-12")])
        XCTAssertEqual(result.error, ToolExecutionService.linearNotConnected)
        XCTAssertEqual(off.asked.requests.count + unpaid.asked.requests.count + unconnected.asked.requests.count, 0)

        typealias Refusal = ConnectedAccountsService.TokenRefusal
        XCTAssertEqual(AppTokenSheet.message(for: Refusal.refused, in: .linear), "Linear didn't accept this key. Check that it's copied whole and hasn't been revoked.")
        XCTAssertEqual(AppTokenSheet.message(for: Refusal.otherAccount, in: .linear), "This key belongs to a different Linear account. Create one from the account being replaced.")
        XCTAssertEqual(AppTokenSheet.message(for: Refusal.changed, in: .linear), "This Linear connection changed while the key was checked. Close this and try again.")
        XCTAssertEqual(AppTokenSheet.message(for: URLError(.timedOut), in: .linear), "Linear didn't answer. Try again.")
        XCTAssertTrue(AppTokenSheet.Texts.linear.scopes.isEmpty)
        XCTAssertNotNil(AppTokenSheet.Texts.linear.reach)
    }
}
