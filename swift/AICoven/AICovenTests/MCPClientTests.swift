@testable import AICoven
import XCTest

/// A server played from a script: what it was asked, and what it answers.
private final class ScriptedMCPServer: @unchecked Sendable {
    struct Asked {
        let httpMethod: String
        let headers: [String: String]
        let body: [String: Any]

        var method: String? {
            body["method"] as? String
        }

        var params: [String: Any] {
            body["params"] as? [String: Any] ?? [:]
        }

        var meta: [String: Any] {
            params["_meta"] as? [String: Any] ?? [:]
        }

        func header(_ name: String) -> String? {
            headers.first { $0.key.lowercased() == name.lowercased() }?.value
        }
    }

    /// An answer: its status, headers, and body; `$ID` in the body stands
    /// for the request's id.
    struct Answer {
        var status = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body = ""

        static func json(_ body: String, status: Int = 200, headers: [String: String] = [:]) -> Answer {
            Answer(status: status, headers: ["Content-Type": "application/json"].merging(headers) { _, new in new }, body: body)
        }

        static func result(_ result: String, headers: [String: String] = [:]) -> Answer {
            json(#"{"jsonrpc":"2.0","id":"$ID","result":\#(result)}"#, headers: headers)
        }

        static func error(_ code: Int, _ message: String, status: Int = 200, data: String? = nil) -> Answer {
            let extra = data.map { #","data":\#($0)"# } ?? ""
            return json(#"{"jsonrpc":"2.0","id":"$ID","error":{"code":\#(code),"message":"\#(message)"\#(extra)}}"#, status: status)
        }

        static func events(_ body: String) -> Answer {
            Answer(headers: ["Content-Type": "text/event-stream"], body: body)
        }

        static func status(_ status: Int) -> Answer {
            Answer(status: status, headers: [:], body: "")
        }
    }

    private let lock = NSLock()
    private var stored: [Asked] = []
    private let answer: @Sendable (Asked, Int) -> Answer

    init(answer: @escaping @Sendable (Asked, Int) -> Answer) {
        self.answer = answer
    }

    var asked: [Asked] {
        lock.withLock { stored }
    }

    /// The methods asked for, in order (`DELETE` for the end of a session).
    var methods: [String] {
        asked.map { $0.method ?? $0.httpMethod }
    }

    func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { [self] request in
            var data = Data()
            // URLProtocol hands a request's body over as a stream.
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
            let asked = Asked(httpMethod: request.httpMethod ?? "GET", headers: request.allHTTPHeaderFields ?? [:], body: body)
            let index = lock.withLock {
                stored.append(asked)
                return stored.count - 1
            }
            let given = answer(asked, index)
            let filled = given.body.replacingOccurrences(of: "$ID", with: body["id"] as? String ?? "")
            let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: given.status, httpVersion: "HTTP/1.1", headerFields: given.headers))
            return (response, Data(filled.utf8))
        }
        return URLSession(configuration: config)
    }
}

/// The MCP client speaks the current revision of the protocol and falls
/// back to the earlier ones' handshake, as the specification describes.
final class MCPClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func account(url: String = "https://mcp.example.com/mcp", auth: MCPAuthType = .none, tools: [MCPToolDefinition]? = nil) -> MCPServerAccount {
        MCPServerAccount(
            id: "server", name: "Example", serverUrl: url, transport: .streamableHttp, authType: auth, status: .connected,
            cachedTools: tools, toolsCachedAt: nil, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func client(_ server: ScriptedMCPServer, eras: MCPEraCache = MCPEraCache(), token: String? = nil, auth: MCPAuthType = .none) -> MCPClient {
        MCPClient(server: account(auth: auth), token: token, session: server.session(), eras: eras)
    }

    private static let discovered = #"{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"ttlMs":0,"cacheScope":"private"}"#

    /// A server of the current revision, with two pages of tools and one
    /// tool to call.
    private func modernServer(call: ScriptedMCPServer.Answer = .result(#"{"resultType":"complete","content":[{"type":"text","text":"Sunny"}],"isError":false}"#)) -> ScriptedMCPServer {
        ScriptedMCPServer { asked, _ in
            switch asked.method {
            case "server/discover":
                .result(Self.discovered)
            case "tools/list" where asked.params["cursor"] == nil:
                .result(#"""
                {"resultType":"complete","nextCursor":"page-2","ttlMs":0,"cacheScope":"private","tools":[
                  {"name":"get_weather","description":"Weather for a place","inputSchema":{"type":"object","properties":{"location":{"type":"string"}},"required":["location"]},"annotations":{"readOnlyHint":true}},
                  {"description":"No name: left out"},
                  {"name":"send_note","description":"Sends a note","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":false,"destructiveHint":true}}
                ]}
                """#)
            case "tools/list":
                .result(#"{"resultType":"complete","ttlMs":0,"cacheScope":"private","tools":[{"name":"ping_it"}]}"#)
            case "tools/call":
                call
            default:
                .error(-32601, "Method not found", status: 404)
            }
        }
    }

    // MARK: - The current revision

    func testACurrentServersTools_areListedOverEveryPage_withEachRequestSayingItsVersion() async throws {
        let server = modernServer()
        let eras = MCPEraCache()

        let tools = try await client(server, eras: eras).discoverTools()

        XCTAssertEqual(tools.map(\.name), ["get_weather", "send_note", "ping_it"], "Both pages; the tool with no name left out")
        XCTAssertEqual(tools.map(\.readOnlyHint), [true, false, false], "Only a tool the server marks reads only")
        XCTAssertEqual(tools[2].inputSchema, ["type": "object"], "A tool listed without a schema takes no arguments")
        XCTAssertEqual(tools[0].description, "Weather for a place")
        XCTAssertEqual(server.methods, ["server/discover", "tools/list", "tools/list"], "No handshake")
        for asked in server.asked {
            XCTAssertEqual(asked.httpMethod, "POST")
            XCTAssertEqual(asked.header("Accept"), "application/json, text/event-stream")
            XCTAssertEqual(asked.header("Content-Type"), "application/json")
            XCTAssertEqual(asked.header("MCP-Protocol-Version"), "2026-07-28")
            XCTAssertEqual(asked.header("Mcp-Method"), asked.method)
            XCTAssertNil(asked.header("Mcp-Name"))
            XCTAssertNil(asked.header("Mcp-Session-Id"))
            XCTAssertEqual(asked.body["jsonrpc"] as? String, "2.0")
            XCTAssertNotNil(asked.body["id"] as? String)
            XCTAssertEqual(asked.meta["io.modelcontextprotocol/protocolVersion"] as? String, "2026-07-28")
            XCTAssertEqual((asked.meta["io.modelcontextprotocol/clientInfo"] as? [String: Any])?["name"] as? String, "AICoven Local")
            XCTAssertNotNil((asked.meta["io.modelcontextprotocol/clientInfo"] as? [String: Any])?["version"] as? String)
            XCTAssertEqual((asked.meta["io.modelcontextprotocol/clientCapabilities"] as? [String: Any])?.count, 0, "No optional capabilities")
        }
        XCTAssertEqual(server.asked[2].params["cursor"] as? String, "page-2")
        XCTAssertEqual(eras.era(of: "https://mcp.example.com/mcp"), .modern)
    }

    func testACallToACurrentServer_namesTheToolAndItsMarkedArgumentsInHeaders() async throws {
        let server = modernServer()
        let eras = MCPEraCache()
        eras.note(.modern, for: "https://mcp.example.com/mcp")
        let tool = MCPToolDefinition(name: "météo", description: nil, inputSchema: [
            "type": "object",
            "properties": [
                "region": ["type": "string", "x-mcp-header": "Region"],
                "days": ["type": "integer", "x-mcp-header": "Days"],
                "detailed": ["type": "boolean", "x-mcp-header": "Detailed"],
                "place": ["type": "string", "x-mcp-header": "Place"],
                "note": ["type": "string"],
                "missing": ["type": "string", "x-mcp-header": "Missing"],
                "list": ["type": "array", "x-mcp-header": "List"],
                "bad": ["type": "string", "x-mcp-header": "Not A Token"],
            ],
        ])

        let content = try await client(server, eras: eras).callTool(
            name: "météo",
            arguments: ["region": "us-west1", "days": 3, "detailed": true, "place": "Zürich", "note": "x", "list": ["a"], "bad": "y"],
            tool: tool
        )

        XCTAssertEqual(content, [MCPContentItem(type: "text", text: "Sunny")])
        XCTAssertEqual(server.methods, ["tools/call"], "A server already known to be current is not asked again what it speaks")
        let asked = try XCTUnwrap(server.asked.first)
        XCTAssertEqual(asked.header("Mcp-Method"), "tools/call")
        XCTAssertEqual(asked.header("Mcp-Name"), "=?base64?\(Data("météo".utf8).base64EncodedString())?=", "A name that is not plain ASCII is wrapped")
        XCTAssertEqual(asked.header("Mcp-Param-Region"), "us-west1")
        XCTAssertEqual(asked.header("Mcp-Param-Days"), "3")
        XCTAssertEqual(asked.header("Mcp-Param-Detailed"), "true")
        XCTAssertEqual(asked.header("Mcp-Param-Place"), "=?base64?\(Data("Zürich".utf8).base64EncodedString())?=")
        XCTAssertNil(asked.header("Mcp-Param-Missing"), "An argument not given has no header")
        XCTAssertNil(asked.header("Mcp-Param-List"), "Nor one that is a list")
        XCTAssertNil(asked.headers.keys.first { $0.lowercased().contains("not a token") })
        XCTAssertEqual(asked.params["name"] as? String, "météo")
        XCTAssertEqual((asked.params["arguments"] as? [String: Any])?["region"] as? String, "us-west1")
        XCTAssertEqual((asked.params["arguments"] as? [String: Any])?["days"] as? Int, 3)
        XCTAssertEqual(asked.meta["io.modelcontextprotocol/protocolVersion"] as? String, "2026-07-28")
    }

    func testAnAnswerSentAsEvents_isReadPastWhatComesBeforeIt() async throws {
        let eras = MCPEraCache()
        eras.note(.modern, for: "https://mcp.example.com/mcp")
        let stream = [
            ": keep-alive",
            "",
            "event: message",
            #"data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":1}}"#,
            "",
            #"data: {"jsonrpc":"2.0","id":"someone-elses","result":{"content":[{"type":"text","text":"Not this"}]}}"#,
            "",
            "id: 7",
            #"data: {"jsonrpc":"2.0","id":"$ID","result":{"resultType":"complete","#,
            #"data: "content":[{"type":"text","text":"Sunny"},{"type":"image","data":"AAAA","mimeType":"image/png"}]}}"#,
            "",
            #"data: {"jsonrpc":"2.0","id":"$ID","result":{"content":[{"type":"text","text":"Too late"}]}}"#,
            "",
        ].joined(separator: "\r\n")
        let server = modernServer(call: .events(stream))

        let content = try await client(server, eras: eras).callTool(name: "get_weather", arguments: ["location": "Lisbon"])

        XCTAssertEqual(content.map(\.shown), ["Sunny", "[image content, not shown]"], "The answer to this request, its data over two lines")
        XCTAssertEqual(server.asked.first?.header("Mcp-Name"), "get_weather")
    }

    func testWhatAToolAnswers_isReadAsTextOrAsItsStructuredContent_andItsOwnErrorIsItsOwn() async throws {
        let eras = MCPEraCache()
        eras.note(.modern, for: "https://mcp.example.com/mcp")

        let structured = modernServer(call: .result(#"{"resultType":"complete","content":[],"structuredContent":{"temperature":21,"unit":"C"}}"#))
        let read = try await client(structured, eras: eras).callTool(name: "get_weather", arguments: [:])
        XCTAssertEqual(read.map(\.shown), [#"{"temperature":21,"unit":"C"}"#])

        let failing = modernServer(call: .result(#"{"resultType":"complete","content":[{"type":"text","text":"No such city."}],"isError":true}"#))
        do {
            _ = try await client(failing, eras: eras).callTool(name: "get_weather", arguments: [:])
            XCTFail("The tool reported an error")
        } catch {
            XCTAssertEqual(error as? MCPClientError, .toolFailed("No such city."))
        }

        let asking = modernServer(call: .result(#"{"resultType":"input_required","requestState":"opaque"}"#))
        do {
            _ = try await client(asking, eras: eras).callTool(name: "get_weather", arguments: [:])
            XCTFail("It asked for input")
        } catch {
            XCTAssertEqual(error as? MCPClientError, .needsInput)
        }

        let odd = modernServer(call: .result(#"{"resultType":"something_else"}"#))
        do {
            _ = try await client(odd, eras: eras).callTool(name: "get_weather", arguments: [:])
            XCTFail("Not a result type the protocol has")
        } catch {
            XCTAssertEqual(error as? MCPClientError, .invalidResponse("result type something_else"))
        }

        let refusing = modernServer(call: .error(-32602, String(repeating: "Unknown tool. ", count: 40), status: 400))
        do {
            _ = try await client(refusing, eras: eras).callTool(name: "nope", arguments: [:])
            XCTFail("The server refused the request")
        } catch let MCPClientError.serverError(code, message) {
            XCTAssertEqual(code, -32602)
            XCTAssertEqual(message.count, 300, "What the server said, no more than 300 characters of it")
        }
    }

    func testACurrentServerOfOtherVersions_isSaidToSpeakThem() async {
        let newer = ScriptedMCPServer { _, _ in
            .error(-32022, "Unsupported protocol version", status: 400, data: #"{"supported":["2027-01-15"],"requested":"2026-07-28"}"#)
        }
        let eras = MCPEraCache()
        do {
            _ = try await client(newer, eras: eras).discoverTools()
            XCTFail("No version in common")
        } catch {
            XCTAssertEqual(error as? MCPClientError, .unsupportedVersion(supported: ["2027-01-15"]))
            XCTAssertEqual(error.localizedDescription, "This MCP server speaks versions of the protocol this app does not: 2027-01-15.")
        }
        XCTAssertEqual(newer.methods, ["server/discover"], "It is a current server: no handshake is tried")
        XCTAssertNil(eras.era(of: "https://mcp.example.com/mcp"), "Nothing is settled by a failure")

        let listing = ScriptedMCPServer { _, _ in .result(#"{"resultType":"complete","supportedVersions":["2027-01-15"]}"#) }
        do {
            _ = try await client(listing).discoverTools()
            XCTFail("No version in common")
        } catch {
            XCTAssertEqual(error as? MCPClientError, .unsupportedVersion(supported: ["2027-01-15"]))
        }
    }

    // MARK: - Earlier revisions

    /// A server of an earlier revision: it wants `initialize` first and
    /// gives a session.
    private func legacyServer(
        refusingDiscoverWith refusal: ScriptedMCPServer.Answer = .json(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"Bad Request: Server not initialized"}}"#, status: 400),
        version: String = "2025-06-18",
        sessions: [String] = ["session-1", "session-2"],
        losingTheSessionAt lost: Int? = nil
    ) -> ScriptedMCPServer {
        let given = OSAllocatedUnfairLockBox(0)
        return ScriptedMCPServer { asked, index in
            if asked.httpMethod == "DELETE" { return .status(405) }
            switch asked.method {
            case "server/discover":
                return refusal
            case "initialize":
                let session = sessions[min(given.next(), sessions.count - 1)]
                return .result(#"{"protocolVersion":"\#(version)","capabilities":{"tools":{}},"serverInfo":{"name":"Old","version":"1"}}"#, headers: ["Mcp-Session-Id": session])
            case "notifications/initialized":
                return .status(202)
            case "tools/list":
                if index == lost { return .status(404) }
                return .result(#"{"tools":[{"name":"get_weather","inputSchema":{"type":"object"}}]}"#)
            case "tools/call":
                if index == lost { return .status(404) }
                return .result(#"{"content":[{"type":"text","text":"Rain"}]}"#)
            default:
                return .error(-32601, "Method not found")
            }
        }
    }

    func testAnEarlierServer_isGreetedFirstAndThenAskedWithItsSessionAndVersion() async throws {
        let server = legacyServer()
        let eras = MCPEraCache()
        let client = client(server, eras: eras)

        let tools = try await client.discoverTools()
        let content = try await client.callTool(name: "get_weather", arguments: ["location": "Lisbon"])
        await client.disconnect()

        XCTAssertEqual(tools.map(\.name), ["get_weather"])
        XCTAssertEqual(tools.first?.readOnlyHint, false, "Not marked: taken for one that changes things")
        XCTAssertEqual(content.map(\.shown), ["Rain"], "A result that does not say its type is whole")
        XCTAssertEqual(server.methods, ["server/discover", "initialize", "notifications/initialized", "tools/list", "tools/call", "DELETE"])

        let greeting = server.asked[1]
        XCTAssertEqual(greeting.params["protocolVersion"] as? String, "2025-11-25", "The newest of the earlier ones")
        XCTAssertEqual((greeting.params["capabilities"] as? [String: Any])?.count, 0)
        XCTAssertEqual((greeting.params["clientInfo"] as? [String: Any])?["name"] as? String, "AICoven Local")
        XCTAssertNil(greeting.header("Mcp-Session-Id"))
        XCTAssertNil(greeting.header("MCP-Protocol-Version"))
        XCTAssertNil(greeting.header("Mcp-Method"), "Not the current revision's headers")
        XCTAssertNil(greeting.params["_meta"])

        let ready = server.asked[2]
        XCTAssertNil(ready.body["id"], "A notification has no id")
        for asked in server.asked[2...] {
            XCTAssertEqual(asked.header("Mcp-Session-Id"), "session-1")
            XCTAssertEqual(asked.header("MCP-Protocol-Version"), "2025-06-18", "The version the server answered with")
            XCTAssertNil(asked.header("Mcp-Method"))
        }
        XCTAssertEqual(server.asked[4].params["name"] as? String, "get_weather")
        XCTAssertNil(server.asked[4].params["_meta"])
        XCTAssertEqual(server.asked[5].httpMethod, "DELETE", "The session is ended, whether or not the server ends sessions")
        XCTAssertEqual(eras.era(of: "https://mcp.example.com/mcp"), .legacy)

        // The next client for this server greets it at once.
        let again = legacyServer()
        _ = try await self.client(again, eras: eras).discoverTools()
        XCTAssertEqual(again.methods, ["initialize", "notifications/initialized", "tools/list"])
    }

    func testAnEarlierServerThatDoesNotKnowTheQuestion_isGreetedToo() async throws {
        for refusal: ScriptedMCPServer.Answer in [.error(-32601, "Method not found"), .status(404), .status(405), .error(-32602, "Invalid params", status: 400)] {
            let server = legacyServer(refusingDiscoverWith: refusal, version: "2025-11-25")
            let tools = try await client(server).discoverTools()
            XCTAssertEqual(tools.map(\.name), ["get_weather"])
            XCTAssertEqual(Array(server.methods.prefix(2)), ["server/discover", "initialize"])
            XCTAssertEqual(server.asked.last?.header("MCP-Protocol-Version"), "2025-11-25")
        }
    }

    func testASessionTheServerHasLost_isStartedAnewOnceAndTheRequestMadeAgain() async throws {
        // The call (the fifth request) finds its session gone.
        let server = legacyServer(losingTheSessionAt: 4)
        let client = client(server)
        _ = try await client.discoverTools()

        let content = try await client.callTool(name: "get_weather", arguments: [:])

        XCTAssertEqual(content.map(\.shown), ["Rain"])
        XCTAssertEqual(
            server.methods,
            ["server/discover", "initialize", "notifications/initialized", "tools/list", "tools/call", "initialize", "notifications/initialized", "tools/call"]
        )
        XCTAssertNil(server.asked[5].header("Mcp-Session-Id"), "A new session is asked for without the old one's id")
        XCTAssertEqual(server.asked[7].header("Mcp-Session-Id"), "session-2")
    }

    func testAServerOfNoVersionInCommon_orOfTheOldTransport_isSaidSo() async {
        let ancient = legacyServer(version: "2023-01-01")
        do {
            _ = try await client(ancient).discoverTools()
            XCTFail("No version in common")
        } catch {
            XCTAssertEqual(error as? MCPClientError, .unsupportedVersion(supported: ["2023-01-01"]))
        }
        XCTAssertEqual(ancient.methods, ["server/discover", "initialize"], "It is not told the client is ready")

        // An address that takes no POST at all: the old transport's.
        let old = ScriptedMCPServer { _, _ in .status(405) }
        do {
            _ = try await client(old).discoverTools()
            XCTFail("It speaks the old transport")
        } catch {
            XCTAssertEqual(error as? MCPClientError, .oldTransport)
            XCTAssertEqual(error.localizedDescription, "This MCP server speaks only the older SSE transport, which this app does not speak yet.")
        }
    }

    // MARK: - Refused, unreachable, and who asks

    func testARefusedOrUnreachableServer_isSaidSoWithoutItsAnswer() async {
        let eras = MCPEraCache()
        let locked = ScriptedMCPServer { _, _ in .json(#"{"detail":"token abc123 is not valid"}"#, status: 401) }
        do {
            _ = try await client(locked, eras: eras).discoverTools()
            XCTFail("It refused the token")
        } catch {
            XCTAssertEqual(error as? MCPClientError, .refused(status: 401))
            XCTAssertEqual(
                error.localizedDescription,
                "The MCP server refused the connection (HTTP 401). Retrying will not help: check this server's token in Settings > Connected Apps > MCP Servers and run Test."
            )
        }
        XCTAssertEqual(locked.methods, ["server/discover"], "Not taken for an earlier server")
        XCTAssertNil(eras.era(of: "https://mcp.example.com/mcp"))

        let down = ScriptedMCPServer { _, _ in .status(503) }
        do {
            _ = try await client(down).discoverTools()
            XCTFail("It is down")
        } catch {
            XCTAssertEqual(error as? MCPClientError, .refused(status: 503))
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await MCPClient(server: account(), token: nil, session: URLSession(configuration: config), eras: MCPEraCache()).discoverTools()
            XCTFail("It cannot be reached")
        } catch {
            XCTAssertEqual(error as? MCPClientError, .notReached)
        }

        do {
            _ = try await MCPClient(server: account(url: "file:///etc/hosts"), token: nil, session: URLSession(configuration: config), eras: MCPEraCache()).discoverTools()
            XCTFail("Not an address a server is at")
        } catch {
            XCTAssertEqual(error as? MCPClientError, .invalidURL)
        }
    }

    func testTheServersToken_isSentAsItsConnectionSays() async throws {
        let bearer = modernServer()
        _ = try await client(bearer, token: "TOKEN", auth: .bearer).discoverTools()
        XCTAssertEqual(bearer.asked.map { $0.header("Authorization") }, ["Bearer TOKEN", "Bearer TOKEN", "Bearer TOKEN"])
        XCTAssertNil(bearer.asked.first?.header("X-Api-Key"))

        let key = modernServer()
        _ = try await client(key, token: "TOKEN", auth: .apiKey).discoverTools()
        XCTAssertEqual(key.asked.first?.header("X-Api-Key"), "TOKEN")
        XCTAssertNil(key.asked.first?.header("Authorization"))

        let none = modernServer()
        _ = try await client(none, token: "TOKEN", auth: .none).discoverTools()
        XCTAssertNil(none.asked.first?.header("Authorization"))
        XCTAssertNil(none.asked.first?.header("X-Api-Key"))
    }

    // MARK: - Pieces

    func testEvents_areReadByTheirDataLinesWhateverTheLineEnds() {
        var reader = MCPEventReader()
        var events: [String] = []
        for byte in Array(": comment\ndata: one\ndata:two\n\nevent: message\nid: 3\ndata:  three\r\n\r\n\ndata: four".utf8) {
            if let event = reader.take(byte) { events.append(event) }
        }
        XCTAssertEqual(events, ["one\ntwo", " three"], "One leading space is the separator's; an empty event is none")
        XCTAssertEqual(reader.finish(), "four", "What the stream ended in")
        XCTAssertNil(reader.finish())
    }

    func testAHeadersValue_isPlainWhereItCanBe() {
        XCTAssertEqual(MCPClient.headerValue("get_weather"), "get_weather")
        XCTAssertEqual(MCPClient.headerValue("us west 1"), "us west 1")
        XCTAssertEqual(MCPClient.headerValue(""), "")
        XCTAssertEqual(MCPClient.headerValue(" padded "), "=?base64?\(Data(" padded ".utf8).base64EncodedString())?=")
        XCTAssertEqual(MCPClient.headerValue("line\nbreak"), "=?base64?\(Data("line\nbreak".utf8).base64EncodedString())?=")
        XCTAssertEqual(MCPClient.headerValue("=?base64?abc?="), "=?base64?\(Data("=?base64?abc?=".utf8).base64EncodedString())?=", "What reads as the wrapped form is wrapped")
        XCTAssertEqual(MCPClient.parameterHeaders(for: ["region": "eu"], schema: nil), [:])
        XCTAssertEqual(MCPClient.parameterHeaders(for: ["half": 0.5], schema: ["properties": ["half": ["x-mcp-header": "Half"]]]), ["Mcp-Param-Half": "0.5"])
    }

    func testAToolKeptByTheApp_keepsWhetherItOnlyReads() throws {
        let listed = try JSONDecoder().decode(MCPToolDefinition.self, from: Data(#"{"name":"read_it","annotations":{"readOnlyHint":true}}"#.utf8))
        XCTAssertTrue(listed.readOnlyHint)
        let kept = try JSONDecoder().decode(MCPToolDefinition.self, from: JSONEncoder().encode(listed))
        XCTAssertEqual(kept, listed)
        XCTAssertTrue(kept.readOnlyHint, "Read back from what was kept, where the mark is beside the name")

        // Kept before the mark was: not marked.
        let before = try JSONDecoder().decode(MCPToolDefinition.self, from: Data(#"{"name":"old","description":"d","inputSchema":{"type":"object"}}"#.utf8))
        XCTAssertFalse(before.readOnlyHint)
        let odd = try JSONDecoder().decode(MCPToolDefinition.self, from: Data(#"{"name":"odd","annotations":{"readOnlyHint":"yes"},"inputSchema":"none"}"#.utf8))
        XCTAssertFalse(odd.readOnlyHint, "Only true counts")
        XCTAssertEqual(odd.inputSchema, ["type": "object"])
    }
}

/// A counter the scripted server shares across its answers.
private final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int

    init(_ value: Int) {
        self.value = value
    }

    /// The value, then one more for the next asker.
    func next() -> Int {
        lock.withLock {
            defer { value += 1 }
            return value
        }
    }
}
