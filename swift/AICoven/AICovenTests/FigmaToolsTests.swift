@testable import AICoven
import XCTest

/// Figma's tools read a file's structure and its comments and post a
/// comment, with the connected account's token.
final class FigmaToolsTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - What a call names

    func testAFileIsNamedByItsKeyOrItsLink() {
        XCTAssertEqual(FigmaToolService.fileKey("AbCdEfGhIjKl"), "AbCdEfGhIjKl")
        XCTAssertEqual(FigmaToolService.fileKey("  AbCd1234  "), "AbCd1234")
        for editor in ["design", "file", "board", "proto", "slides", "deck", "make"] {
            XCTAssertEqual(FigmaToolService.fileKey("https://www.figma.com/\(editor)/AbCdEfGhIjKl/Home-page?node-id=3-21&t=x"), "AbCdEfGhIjKl", editor)
        }
        XCTAssertEqual(FigmaToolService.fileKey("https://figma.com/design/AbCdEfGhIjKl"), "AbCdEfGhIjKl")
        for notOne in [
            "", "abc def", "abc/def", "../me", "abc?x=1", "äbcdefghij",
            "http://www.figma.com/design/AbCdEfGhIjKl/Home", "https://evil.example/design/AbCdEfGhIjKl/Home",
            "https://www.figma.com.evil.example/design/AbCdEfGhIjKl", "https://www.figma.com/files/project/123",
            "https://www.figma.com/design/short/Home", "https://www.figma.com/community/AbCdEfGhIjKl", "https://www.figma.com/design/",
        ] {
            XCTAssertNil(FigmaToolService.fileKey(notOne), "\(notOne) names no file")
        }

        for id in ["3:21", "0:1", "I5:2;1:8", "12:34;56:78;9:0"] {
            XCTAssertTrue(FigmaToolService.isNodeID(id), id)
        }
        for notOne in ["", "3-21", "3:21 ", "3:", ":21", "a:b", "3:21;", "3:21/..", "I", "3:21\n"] {
            XCTAssertFalse(FigmaToolService.isNodeID(notOne), "\(notOne) is no node's id")
        }
    }

    // MARK: - What a model is told

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testAFileIsToldAsAnOutline_andSaysWhatItLeftOut() throws {
        let document = try object(#"""
        {"id": "0:0", "name": "Document", "type": "DOCUMENT", "children": [
          {"id": "0:1", "name": "Page 1", "type": "CANVAS", "children": [
            {"id": "1:2", "name": "Home\nscreen", "type": "FRAME", "children": [{"id": "1:3", "name": "Title", "type": "TEXT"}]},
            {"id": "1:4", "type": "RECTANGLE"}
          ]},
          {"id": "0:2", "name": "Page 2", "type": "CANVAS"}
        ]}
        """#)
        var left = FigmaToolService.mostNodes
        let whole = FigmaToolService.outline(of: document, left: &left)
        XCTAssertEqual(whole.lines, [
            "- Document [0:0, DOCUMENT]",
            "  - Page 1 [0:1, CANVAS]",
            "    - Home screen [1:2, FRAME]",
            "      - Title [1:3, TEXT]",
            "    - (unnamed) [1:4, RECTANGLE]",
            "  - Page 2 [0:2, CANVAS]",
        ])
        XCTAssertEqual(whole.omitted, 0)
        XCTAssertEqual(left, FigmaToolService.mostNodes - 6)

        // Only three nodes may be told: the rest are counted where they were cut.
        left = 3
        let cut = FigmaToolService.outline(of: document, left: &left)
        XCTAssertEqual(cut.lines, [
            "- Document [0:0, DOCUMENT] (1 more under it not shown)",
            "  - Page 1 [0:1, CANVAS] (1 more under it not shown)",
            "    - Home screen [1:2, FRAME] (1 more under it not shown)",
        ])
        XCTAssertEqual(cut.omitted, 3)
    }

    func testCommentsAreToldNewestFirst_andAReplyIsResolvedWhenItsThreadIs() throws {
        let comments = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"""
        [
          {"id": "1", "message": "Too dark", "created_at": "2026-11-01T10:00:00Z", "user": {"handle": "Ada"}, "resolved_at": "2026-11-02T10:00:00Z", "client_meta": {"node_id": "1:2"}},
          {"id": "2", "parent_id": "1", "message": "Fixed", "created_at": "2026-11-01T11:00:00Z", "user": {"handle": "Grace"}},
          {"id": "3", "message": "Logo is\noff centre", "created_at": "2026-11-03T09:00:00Z", "user": {"handle": "Ada"}, "client_meta": {"x": 10, "y": 20}},
          {"id": "4", "parent_id": "3", "message": "Agreed", "created_at": "2026-11-03T10:00:00Z"}
        ]
        """#.utf8)) as? [[String: Any]])

        let open = FigmaToolService.told(comments: comments, includingResolved: false)
        XCTAssertEqual(open.lines, [
            "- [4] Someone, 2026-11-03T10:00:00Z (reply to 3): Agreed",
            "- [3] Ada, 2026-11-03T09:00:00Z: Logo is off centre",
        ])
        XCTAssertFalse(open.more)

        let all = FigmaToolService.told(comments: comments, includingResolved: true)
        XCTAssertEqual(all.lines.suffix(2), [
            "- [2] Grace, 2026-11-01T11:00:00Z (reply to 1, resolved): Fixed",
            "- [1] Ada, 2026-11-01T10:00:00Z (on node 1:2, resolved): Too dark",
        ])

        let many: [[String: Any]] = (0 ..< FigmaToolService.mostComments + 5).map { ["id": "\($0)", "message": "m", "created_at": String(format: "2026-01-01T00:%02d:%02dZ", $0 / 60, $0 % 60)] }
        let capped = FigmaToolService.told(comments: many, includingResolved: false)
        XCTAssertEqual(capped.lines.count, FigmaToolService.mostComments)
        XCTAssertTrue(capped.more)
        XCTAssertEqual(capped.lines.first?.hasPrefix("- [\(FigmaToolService.mostComments + 4)]"), true, "The newest are the ones told")
    }

    // MARK: - Calls, with Figma answered by a script

    /// What Figma was asked. Sendable by hand, under `lock`.
    private final class Asked: @unchecked Sendable {
        struct Request: Equatable {
            let method: String
            let url: String
            var token: String? = "figd_TEST"
            var sent = ""
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
            let noted = Request(method: request.httpMethod ?? "GET", url: request.url?.absoluteString ?? "", token: request.value(forHTTPHeaderField: "X-Figma-Token"), sent: String(decoding: data, as: UTF8.self))
            lock.withLock { kept.append(noted) }
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

    /// An executor with Figma connected (in memory), the Tools Pack
    /// bought, a person who approves (or not), and Figma answered by
    /// `answer` (status, body, headers).
    private func world(
        connected: Bool = true,
        approving: Bool = true,
        connections: CovenConnections? = nil,
        answer: @escaping @Sendable (URLRequest) -> (Int, String, [String: String])
    ) async throws -> World {
        let suite = "FigmaToolsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let accounts = ConnectedAccountsService(currentUser: { "figma-tests" }, defaults: defaults, tokens: InMemoryTokens().store, figmaIdentity: { _ in .init(id: "42", label: "ada@example.com") })
        if connected { _ = try await accounts.connectFigma(token: "figd_TEST") }

        let asked = Asked()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { request in
            asked.note(request)
            let (status, body, headers) = answer(request)
            return try (XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)), Data(body.utf8))
        }
        let seen = Seen()
        let executor = ToolExecutionService(
            toolService: ToolService.shared,
            ask: { approval in
                await seen.note(approval)
                return approving ? .approved : .denied
            },
            covenConnections: { _ in connections },
            connectedAccounts: accounts,
            hasToolsPack: { true },
            figmaSession: URLSession(configuration: config)
        )
        await executor.setWhitelist(for: "chat", tools: PromptTemplates.figmaTools)
        return World(executor: executor, accounts: accounts, asked: asked, seen: seen, defaults: defaults, suite: suite)
    }

    private let file = #"{"name": "Homepage", "document": {"id": "0:0", "name": "Document", "type": "DOCUMENT", "children": [{"id": "0:1", "name": "Page 1", "type": "CANVAS"}]}}"#

    func testReadFile_asksForTheFileNamed_andTellsItsOutline() async throws {
        let answer = file
        let world = try await world { request in
            request.url?.path.hasSuffix("/nodes") == true
                ? (200, #"{"name": "Homepage", "nodes": {"3:21": {"document": {"id": "3:21", "name": "Header", "type": "FRAME"}}}}"#, [:])
                : (200, answer, [:])
        }
        defer { world.forget() }

        let whole = await world.call("figma.readFile", ["file": AnyJSONValue("https://www.figma.com/design/AbCdEfGhIjKl/Homepage?node-id=3-21")])
        XCTAssertEqual(whole.status, "ok")
        XCTAssertEqual(whole.contextBlock, """
        [Figma File: Homepage]
        Read to 2 levels. Each line is a node: its name, then its id and kind.
        - Document [0:0, DOCUMENT]
          - Page 1 [0:1, CANVAS]
        """)

        let under = await world.call("figma.readFile", ["file": AnyJSONValue("AbCdEfGhIjKl"), "node": AnyJSONValue("3:21"), "depth": AnyJSONValue(9)])
        XCTAssertEqual(under.contextBlock, "[Figma File: Homepage]\nRead to 4 levels under node 3:21. Each line is a node: its name, then its id and kind.\n- Header [3:21, FRAME]")
        let shallow = await world.call("figma.readFile", ["file": AnyJSONValue("AbCdEfGhIjKl"), "depth": AnyJSONValue(0)])
        XCTAssertEqual(shallow.contextBlock?.contains("Read to 1 level."), true)

        XCTAssertEqual(world.asked.requests, [
            .init(method: "GET", url: "https://api.figma.com/v1/files/AbCdEfGhIjKl?depth=2"),
            .init(method: "GET", url: "https://api.figma.com/v1/files/AbCdEfGhIjKl/nodes?ids=3:21&depth=4"),
            .init(method: "GET", url: "https://api.figma.com/v1/files/AbCdEfGhIjKl?depth=1"),
        ], "The token goes in Figma's header, to Figma only")
    }

    func testACallThatNamesNoFileOrNode_isToldSo_andFigmaIsNotAsked() async throws {
        let world = try await world { _ in (200, "{}", [:]) }
        defer { world.forget() }

        for tool in ["figma.readFile", "figma.readComments", "figma.addComment"] {
            for file in [AnyJSONValue("https://evil.example/design/AbCdEfGhIjKl"), AnyJSONValue("../me"), AnyJSONValue(7), .null] {
                let refused = await world.call(tool, ["file": file, "message": AnyJSONValue("Hello")])
                XCTAssertEqual(refused.field, "file", "\(tool) \(file)")
            }
        }
        let node = await world.call("figma.readFile", ["file": AnyJSONValue("AbCdEfGhIjKl"), "node": AnyJSONValue("3-21")])
        XCTAssertEqual(node.field, "node")
        let message = await world.call("figma.addComment", ["file": AnyJSONValue("AbCdEfGhIjKl"), "message": AnyJSONValue("   ")])
        XCTAssertEqual(message.field, "message")
        let reply = await world.call("figma.addComment", ["file": AnyJSONValue("AbCdEfGhIjKl"), "message": AnyJSONValue("Hi"), "reply_to": AnyJSONValue("12/../3")])
        XCTAssertEqual(reply.field, "reply_to")

        XCTAssertEqual(world.asked.requests, [])
        let approvals = await world.seen.approvals
        XCTAssertEqual(approvals.count, 0)
    }

    func testReadComments_tellsTheOpenOnes_orAllOfThem() async throws {
        let world = try await world { _ in
            (200, #"{"comments": [{"id": "1", "message": "Too dark", "created_at": "2026-11-01T10:00:00Z", "user": {"handle": "Ada"}, "resolved_at": "2026-11-02T10:00:00Z"}, {"id": "3", "message": "Off centre", "created_at": "2026-11-03T09:00:00Z", "user": {"handle": "Ada"}}]}"#, [:])
        }
        defer { world.forget() }

        let open = await world.call("figma.readComments", ["file": AnyJSONValue("AbCdEfGhIjKl")])
        XCTAssertEqual(open.contextBlock, "[Figma Comments: AbCdEfGhIjKl]\n- [3] Ada, 2026-11-03T09:00:00Z: Off centre")
        let all = await world.call("figma.readComments", ["file": AnyJSONValue("AbCdEfGhIjKl"), "include_resolved": AnyJSONValue("yes")])
        XCTAssertEqual(all.result?["count"]?.value as? Int, 2)
        XCTAssertEqual(world.asked.requests.map(\.url), ["https://api.figma.com/v1/files/AbCdEfGhIjKl/comments", "https://api.figma.com/v1/files/AbCdEfGhIjKl/comments"])

        let none = try await self.world { _ in (200, "{}", [:]) }
        defer { none.forget() }
        let empty = await none.call("figma.readComments", ["file": AnyJSONValue("AbCdEfGhIjKl")])
        XCTAssertEqual(empty.contextBlock, "[Figma Comments: AbCdEfGhIjKl]\n(No comments)")
    }

    func testAComment_isPostedOnlyAfterThePersonApprovesIt_andSaysWhatItIs() async throws {
        let world = try await world { _ in (200, #"{"id": "99", "message": "The header overlaps the logo."}"#, [:]) }
        defer { world.forget() }

        let posted = await world.call("figma.addComment", ["file": AnyJSONValue("https://www.figma.com/design/AbCdEfGhIjKl/Home"), "message": AnyJSONValue(" The header overlaps the logo. "), "reply_to": AnyJSONValue("12")])
        XCTAssertEqual(posted.status, "ok")
        XCTAssertEqual(posted.contextBlock, "[Figma Comment Posted: AbCdEfGhIjKl]\nComment 99, in reply to 12.")
        let approvals = await world.seen.approvals
        XCTAssertEqual(approvals.map(\.question), ["Post this comment in Figma?"])
        XCTAssertEqual(approvals.first?.details.hasPrefix("File AbCdEfGhIjKl, in reply to comment 12\nPosted as you · "), true)
        XCTAssertEqual(approvals.first?.details.hasSuffix("\n\nThe header overlaps the logo."), true)
        XCTAssertEqual(world.asked.requests.map(\.method), ["POST"])
        XCTAssertEqual(world.asked.requests.first?.url, "https://api.figma.com/v1/files/AbCdEfGhIjKl/comments")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((world.asked.requests.first?.sent ?? "").utf8)) as? NSDictionary)
        XCTAssertEqual(sent, ["message": "The header overlaps the logo.", "comment_id": "12"] as NSDictionary)

        // Denied, or with no thread to ask in: nothing is sent.
        let denying = try await self.world(approving: false) { _ in (200, "{}", [:]) }
        defer { denying.forget() }
        let denied = await denying.call("figma.addComment", ["file": AnyJSONValue("AbCdEfGhIjKl"), "message": AnyJSONValue("Hi")])
        XCTAssertEqual(denied.status, "denied")
        let nowhere = await denying.call("figma.addComment", ["file": AnyJSONValue("AbCdEfGhIjKl"), "message": AnyJSONValue("Hi")], threadID: nil)
        XCTAssertNotEqual(nowhere.status, "ok")
        XCTAssertEqual(denying.asked.requests, [])
    }

    func testWhatFigmaWillNotDo_isToldAsWhatItIs_andARefusedTokenWaitsForANewOne() async throws {
        // Figma does not let this account see the file: the token is fine.
        let forbidden = try await world { request in
            request.url?.path == "/v1/me" ? (200, #"{"id": "42", "email": "ada@example.com"}"#, [:]) : (403, #"{"err": "Forbidden"}"#, [:])
        }
        defer { forbidden.forget() }
        var result = await forbidden.call("figma.readFile", ["file": AnyJSONValue("AbCdEfGhIjKl")])
        XCTAssertEqual(result.errorType, "figma_forbidden")
        XCTAssertEqual(forbidden.asked.requests.map(\.url), ["https://api.figma.com/v1/files/AbCdEfGhIjKl?depth=2", "https://api.figma.com/v1/me"])
        var connection = await forbidden.accounts.getConnectedAccount(for: .figma)
        XCTAssertNotNil(connection, "The connection is still good")

        // Figma no longer takes the token: the connection waits for a new one.
        let refused = try await world { _ in (403, "{}", [:]) }
        defer { refused.forget() }
        result = await refused.call("figma.readComments", ["file": AnyJSONValue("AbCdEfGhIjKl")])
        XCTAssertEqual(result.errorType, "figma_token_refused")
        XCTAssertEqual(result.error, "Figma refused the token. The person can give Figma a new token in Settings > Connected Apps.")
        connection = await refused.accounts.getConnectedAccount(for: .figma)
        XCTAssertNil(connection)
        let waiting = await refused.accounts.figmaAccountNeedingAToken()
        XCTAssertNotNil(waiting)
        let before = refused.asked.requests.count
        result = await refused.call("figma.readFile", ["file": AnyJSONValue("AbCdEfGhIjKl")])
        XCTAssertEqual(result.error, "Figma not connected. The person can connect it in Settings > Connected Apps.")
        XCTAssertEqual(refused.asked.requests.count, before, "A refused token is not sent again")

        // No such file; too many requests; a node Figma does not have.
        let missing = try await world { request in
            request.url?.path.hasSuffix("/nodes") == true ? (200, #"{"name": "Homepage", "nodes": {"3:21": null}}"#, [:]) : (404, "{}", [:])
        }
        defer { missing.forget() }
        result = await missing.call("figma.readFile", ["file": AnyJSONValue("AbCdEfGhIjKl")])
        XCTAssertEqual(result.errorType, "figma_not_found")
        result = await missing.call("figma.readFile", ["file": AnyJSONValue("AbCdEfGhIjKl"), "node": AnyJSONValue("3:21")])
        XCTAssertEqual(result.errorType, "figma_not_found")
        let limited = try await world { _ in (429, "{}", ["Retry-After": "30"]) }
        defer { limited.forget() }
        result = await limited.call("figma.readFile", ["file": AnyJSONValue("AbCdEfGhIjKl")])
        XCTAssertEqual(result.errorType, "figma_rate_limited")
        XCTAssertEqual(result.error, "Figma is limiting how often this account asks. Try again in 30 seconds.")
        XCTAssertTrue(result.isRetryable)
    }

    func testFigmasToolsAreOfferedWhereItIsConnected_andACommentIsAChange() async throws {
        XCTAssertEqual(PromptTemplates.figmaTools, ["figma.readFile", "figma.readComments", "figma.addComment"])
        for tool in PromptTemplates.figmaTools {
            XCTAssertNotNil(PromptTemplates.toolDefinitions.first { $0.name == tool }, "\(tool) is described to models")
            XCTAssertEqual(CovenConnectionRules.app(of: tool), "figma")
            XCTAssertEqual(CovenConnectionRules.isWriteTool(tool), tool == "figma.addComment", tool)
        }
        XCTAssertEqual(
            CovenConnectionRules.offered(tools: PromptTemplates.figmaTools, servers: [], in: CovenConnections(apps: ["figma": .readOnly])).tools,
            ["figma.readFile", "figma.readComments"]
        )

        // A coven that lets Figma only be read is refused a comment before anyone is asked.
        let readOnly = try await world(connections: CovenConnections(apps: ["figma": .readOnly])) { _ in (200, "{}", [:]) }
        defer { readOnly.forget() }
        let refused = await readOnly.call("figma.addComment", ["file": AnyJSONValue("AbCdEfGhIjKl"), "message": AnyJSONValue("Hi")])
        XCTAssertEqual(refused.errorType, "connection_read_only")
        XCTAssertEqual(readOnly.asked.requests, [])
        let approvals = await readOnly.seen.approvals
        XCTAssertEqual(approvals.count, 0)

        // Not connected: said so, and nothing asked.
        let unconnected = try await world(connected: false) { _ in (200, "{}", [:]) }
        defer { unconnected.forget() }
        for (tool, args) in [("figma.readFile", ["file": AnyJSONValue("AbCdEfGhIjKl")]), ("figma.addComment", ["file": AnyJSONValue("AbCdEfGhIjKl"), "message": AnyJSONValue("Hi")])] as [(String, [String: AnyJSONValue])] {
            let result = await unconnected.call(tool, args)
            XCTAssertEqual(result.error, "Figma not connected. The person can connect it in Settings > Connected Apps.", tool)
        }
        XCTAssertEqual(unconnected.asked.requests, [])
        let asked = await unconnected.seen.approvals
        XCTAssertEqual(asked.count, 0)
    }
}
