@testable import AICoven
import XCTest

/// The Google tools read Docs, Sheets and Slides, are asked by id, and
/// ask Google only for what a call names.
final class GoogleToolsTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - What a call's arguments say

    func testAnIdIsReadAsGoogleGivesIt_andNothingElseIsOne() {
        XCTAssertTrue(GoogleToolArguments.isID("1AbC-dEf_0123456789"))
        XCTAssertTrue(GoogleToolArguments.isID(String(repeating: "a", count: 200)))
        for notOne in ["", String(repeating: "a", count: 201), "abc/def", "../about", "abc?alt=media", "abc#x", "abc def", "abc%2F", "abc:export", "äbc", "abc\n"] {
            XCTAssertFalse(GoogleToolArguments.isID(notOne), "\(notOne) does not read as an id")
        }

        XCTAssertEqual(GoogleToolArguments.id(["file_id", "fileId"], in: ["file_id": AnyJSONValue("abc")]), "abc")
        XCTAssertEqual(GoogleToolArguments.id(["file_id", "fileId"], in: ["fileId": AnyJSONValue("abc")]), "abc", "By this app's older name for it")
        XCTAssertEqual(GoogleToolArguments.id(["file_id", "fileId"], in: ["file_id": .null, "fileId": AnyJSONValue("abc")]), "abc", "One given as null is one left out")
        XCTAssertNil(GoogleToolArguments.id(["file_id", "fileId"], in: ["file_id": AnyJSONValue("../x"), "fileId": AnyJSONValue("abc")]), "The first that is there is the one read")
        XCTAssertNil(GoogleToolArguments.id(["file_id"], in: ["file_id": AnyJSONValue(42)]))
        XCTAssertNil(GoogleToolArguments.id(["file_id"], in: [:]))
    }

    func testAnAddressIsWrittenFromItsSteps_andAStepStaysOneStep() throws {
        XCTAssertEqual(
            try GoogleDriveToolService.address("sheets.googleapis.com", ["v4", "spreadsheets", "abc", "values", "Sheet 1!A1:B2"]).absoluteString,
            "https://sheets.googleapis.com/v4/spreadsheets/abc/values/Sheet%201%21A1%3AB2"
        )
        XCTAssertEqual(
            try GoogleDriveToolService.address("sheets.googleapis.com", ["v4", "spreadsheets", "abc", "values", "A1:B2"], verb: ":append").absoluteString,
            "https://sheets.googleapis.com/v4/spreadsheets/abc/values/A1%3AB2:append"
        )
        XCTAssertEqual(
            try GoogleDriveToolService.address("www.googleapis.com", ["drive", "v3", "files", "abc/../../about?x=1#y"]).absoluteString,
            "https://www.googleapis.com/drive/v3/files/abc%2F..%2F..%2Fabout%3Fx%3D1%23y",
            "What would be more steps, a query or a fragment is part of the one step"
        )
        XCTAssertThrowsError(try GoogleDriveToolService.address("www.googleapis.com", ["drive", "v3", "files", ".."]))
        XCTAssertThrowsError(try GoogleDriveToolService.address("www.googleapis.com", ["drive", "v3", "files", ""]))

        XCTAssertEqual(RequestPath.step("a b"), "a%20b")
        XCTAssertNil(RequestPath.step("."))
        XCTAssertEqual(RequestPath.path(of: []), "/")
        XCTAssertEqual(GitHubToolService.path(of: ["repos", "é"]), RequestPath.path(of: ["repos", "é"]), "GitHub's paths are written the same way")
    }

    // MARK: - The text of what Google answers

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testADocumentsText_isItsParagraphsAndItsTablesRowByRow() throws {
        let document = try object(#"""
        {"title": "Plan", "body": {"content": [
          {"sectionBreak": {}},
          {"paragraph": {"elements": [{"textRun": {"content": "Hello, "}}, {"textRun": {"content": "world\n"}}, {"inlineObjectElement": {}}]}},
          {"table": {"tableRows": [
            {"tableCells": [{"content": [{"paragraph": {"elements": [{"textRun": {"content": "Name\n"}}]}}]}, {"content": [{"paragraph": {"elements": [{"textRun": {"content": "Two\nlines\n"}}]}}]}]},
            {"tableCells": [{"content": [{"paragraph": {"elements": [{"textRun": {"content": "Ada\n"}}]}}]}, {"content": []}]}
          ]}},
          {"tableOfContents": {"content": [{"paragraph": {"elements": [{"textRun": {"content": "Contents\n"}}]}}]}},
          {"paragraph": {"elements": [{"textRun": {"content": "The end\n"}}]}}
        ]}}
        """#)
        XCTAssertEqual(GoogleWorkspaceText.text(ofDocument: document), "Hello, world\nName\tTwo lines\nAda\t\nContents\nThe end\n")
        XCTAssertEqual(GoogleWorkspaceText.title(of: document), "Plan")
        XCTAssertEqual(GoogleWorkspaceText.text(ofDocument: [:]), "")
        XCTAssertNil(GoogleWorkspaceText.title(of: ["title": ""]))
    }

    func testAPresentationsText_isWhatIsOnEachSlide() throws {
        let presentation = try object(#"""
        {"title": "Deck", "slides": [
          {"pageElements": [
            {"shape": {"text": {"textElements": [{"paragraphMarker": {}}, {"textRun": {"content": "Title\n"}}]}}},
            {"elementGroup": {"children": [{"shape": {"text": {"textElements": [{"textRun": {"content": "In a group"}}]}}}]}},
            {"table": {"tableRows": [{"tableCells": [{"text": {"textElements": [{"textRun": {"content": "A\n"}}]}}, {"text": {"textElements": [{"textRun": {"content": "B\n"}}]}}]}]}},
            {"image": {}}
          ]},
          {"pageElements": [{"image": {}}]},
          {}
        ]}
        """#)
        XCTAssertEqual(GoogleWorkspaceText.text(ofPresentation: presentation), "Slide 1:\nTitle\nIn a group\nA\tB\n\nSlide 2:\n(No text)\n\nSlide 3:\n(No text)")
        XCTAssertEqual(GoogleWorkspaceText.text(ofPresentation: [:]), "")
    }

    func testASpreadsheetsSheets_areToldWithTheirSizes() throws {
        let spreadsheet = try object(#"""
        {"properties": {"title": "Budget"}, "sheets": [
          {"properties": {"title": "2026", "gridProperties": {"rowCount": 1000, "columnCount": 26}}},
          {"properties": {"title": "Chart"}},
          {"properties": {}}
        ]}
        """#)
        XCTAssertEqual(GoogleWorkspaceText.sheets(ofSpreadsheet: spreadsheet), ["2026 (1000 rows, 26 columns)", "Chart"])
        XCTAssertEqual(GoogleWorkspaceText.title(of: spreadsheet), "Budget")
    }

    func testTextLongerThanATurnIsTold_isCutAndSaysSo() {
        let long = String(repeating: "a", count: GoogleToolArguments.longestText + 10)
        XCTAssertEqual(GoogleToolArguments.cut(long), String(repeating: "a", count: GoogleToolArguments.longestText) + AttachmentContext.cutMark)
        XCTAssertEqual(GoogleToolArguments.cut("short"), "short")
    }

    // MARK: - Calls, with Google answered by a script

    /// What Google was asked. Sendable by hand: `kept` is read and written
    /// under `lock`.
    private final class Asked: @unchecked Sendable {
        struct Request: Equatable {
            let method: String
            /// The host and the path as it was sent, percent signs and all.
            let address: String
            let query: [String: String]
            var authorization: String? = "Bearer TEST_TOKEN"
        }

        private let lock = NSLock()
        private var kept: [Request] = []

        var requests: [Request] {
            lock.withLock { kept }
        }

        func note(_ request: URLRequest) {
            let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            let noted = Request(
                method: request.httpMethod ?? "GET",
                address: (components?.host ?? "") + (components?.percentEncodedPath ?? ""),
                query: query,
                authorization: request.value(forHTTPHeaderField: "Authorization")
            )
            lock.withLock { kept.append(noted) }
        }
    }

    private struct World {
        let executor: ToolExecutionService
        let asked: Asked
        let defaults: UserDefaults
        let suite: String

        func call(_ tool: String, _ args: [String: AnyJSONValue], threadID: String? = nil) async -> ToolExecutionResult {
            await executor.execute(toolCall: ParsedToolCall(name: tool, args: args), agentType: "chat", threadID: threadID)
        }

        func forget() {
            defaults.removePersistentDomain(forName: suite)
        }
    }

    /// An executor with a Google account connected (in memory), the tools
    /// a chat turn is offered, and Google answered by `answer`.
    private func world(
        hasToolsPack: Bool = true,
        connections: CovenConnections? = nil,
        ask: @escaping @Sendable (ToolApproval) async -> ApprovalAnswer = { _ in .denied },
        answer: @escaping @Sendable (URLRequest) -> (status: Int, body: Data)
    ) async throws -> World {
        let suite = "GoogleToolsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let accounts = ConnectedAccountsService(currentUser: { "google-tests" }, defaults: defaults, tokens: InMemoryTokens().store)
        _ = try await accounts.createAccount(
            provider: .googleDrive,
            displayName: "ada@example.com",
            tokenBundle: OAuthTokenBundle(accessToken: "TEST_TOKEN", refreshToken: nil, tokenType: "Bearer", expiresAt: nil, scopes: [])
        )

        let asked = Asked()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { request in
            asked.note(request)
            let given = answer(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: given.status, httpVersion: "HTTP/1.1", headerFields: nil))
            return (response, given.body)
        }
        let google = GoogleDriveToolService(accounts: accounts, session: URLSession(configuration: config))
        let executor = ToolExecutionService(
            toolService: ToolService.shared,
            ask: ask,
            covenConnections: { _ in connections },
            connectedAccounts: accounts,
            googleDriveService: google,
            hasToolsPack: { hasToolsPack }
        )
        await executor.setWhitelist(for: "chat", tools: PromptTemplates.googleDriveTools)
        return World(executor: executor, asked: asked, defaults: defaults, suite: suite)
    }

    private func json(_ text: String) -> (status: Int, body: Data) {
        (200, Data(text.utf8))
    }

    func testListFiles_tellsEachFilesId_andSaysWhenThereAreMore() async throws {
        let world = try await world { [self] _ in
            json(#"{"files": [{"id": "doc1", "name": "Plan", "mimeType": "application/vnd.google-apps.document"}, {"id": "txt2", "name": "notes.txt", "mimeType": "text/plain"}], "nextPageToken": "more"}"#)
        }
        defer { world.forget() }

        let listed = await world.call("google_drive.listFiles", ["query": AnyJSONValue("name contains 'plan'"), "page_size": AnyJSONValue(500)])

        XCTAssertEqual(listed.contextBlock, """
        [Google Drive Files]
        Plan (application/vnd.google-apps.document), id: doc1
        notes.txt (text/plain), id: txt2
        (There are more files than these. A narrower query finds the rest.)
        """)
        XCTAssertEqual(world.asked.requests.map(\.address), ["www.googleapis.com/drive/v3/files"])
        XCTAssertEqual(world.asked.requests.first?.query["q"], "name contains 'plan'")
        XCTAssertEqual(world.asked.requests.first?.query["pageSize"], "100", "No more a page than Google gives")
        XCTAssertEqual(world.asked.requests.first?.authorization, "Bearer TEST_TOKEN")
    }

    func testReadFile_readsAFileAsItIs_andAGoogleFileAsText() async throws {
        let world = try await world { [self] request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("alt=media") { return (200, Data("plain text".utf8)) }
            if url.contains("/export") { return (200, Data("exported".utf8)) }
            if url.contains("/files/doc1") { return json(#"{"id": "doc1", "name": "Plan", "mimeType": "application/vnd.google-apps.document"}"#) }
            if url.contains("/files/sheet1") { return json(#"{"id": "sheet1", "name": "Budget", "mimeType": "application/vnd.google-apps.spreadsheet"}"#) }
            if url.contains("/files/folder1") { return json(#"{"id": "folder1", "name": "Work", "mimeType": "application/vnd.google-apps.folder"}"#) }
            return json(#"{"id": "txt2", "name": "notes.txt", "mimeType": "text/plain"}"#)
        }
        defer { world.forget() }

        let plain = await world.call("google_drive.readFile", ["file_id": AnyJSONValue("txt2")])
        XCTAssertEqual(plain.contextBlock, "[Google Drive File: txt2]\nplain text")
        let document = await world.call("google_drive.readFile", ["file_id": AnyJSONValue("doc1")])
        XCTAssertEqual(document.contextBlock, "[Google Drive File: doc1]\nexported")
        _ = await world.call("google_drive.readFile", ["file_id": AnyJSONValue("sheet1")])
        let folder = await world.call("google_drive.readFile", ["file_id": AnyJSONValue("folder1")])
        XCTAssertEqual(folder.error, "'Work' is a folder in Google Drive, which has no text to read.")
        // A format the call names is the one asked for, without looking first.
        _ = await world.call("google_drive.readFile", ["file_id": AnyJSONValue("doc1"), "export_format": AnyJSONValue("text/markdown")])
        _ = await world.call("google_drive.readFile", ["fileId": AnyJSONValue("doc1"), "export_mime_type": AnyJSONValue("text/html")])

        let files = "www.googleapis.com/drive/v3/files"
        XCTAssertEqual(world.asked.requests.map(\.address), [
            "\(files)/txt2", "\(files)/txt2",
            "\(files)/doc1", "\(files)/doc1/export",
            "\(files)/sheet1", "\(files)/sheet1/export",
            "\(files)/folder1",
            "\(files)/doc1/export", "\(files)/doc1/export",
        ])
        XCTAssertEqual(world.asked.requests[1].query, ["alt": "media"])
        XCTAssertEqual(world.asked.requests[3].query, ["mimeType": "text/plain"])
        XCTAssertEqual(world.asked.requests[5].query, ["mimeType": "text/csv"])
        XCTAssertEqual(world.asked.requests[7].query, ["mimeType": "text/markdown"])
        XCTAssertEqual(world.asked.requests[8].query, ["mimeType": "text/html"])
    }

    func testReadFile_saysWhenAFileIsNotText_andCutsTextThatIsTooLong() async throws {
        let long = String(repeating: "a", count: GoogleToolArguments.longestText + 5)
        let world = try await world { [self] request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/files/bin1"), url.contains("alt=media") { return (200, Data([0xFF, 0xFE, 0xFD])) }
            if url.contains("alt=media") { return (200, Data(long.utf8)) }
            return json(#"{"id": "x", "name": "x", "mimeType": "application/octet-stream"}"#)
        }
        defer { world.forget() }

        let binary = await world.call("google_drive.readFile", ["file_id": AnyJSONValue("bin1")])
        XCTAssertEqual(binary.status, "ok")
        XCTAssertEqual(binary.contextBlock, "[Google Drive File: bin1]\n[Binary file, 3 bytes - cannot display as text]")

        let cut = await world.call("google_drive.readFile", ["file_id": AnyJSONValue("big1")])
        XCTAssertEqual(cut.contextBlock, "[Google Drive File: big1]\n" + String(repeating: "a", count: GoogleToolArguments.longestText) + AttachmentContext.cutMark)
    }

    func testDocsSheetsAndSlides_areReadByIdAndToldAsText() async throws {
        let world = try await world { [self] request in
            let host = request.url?.host
            if host == "docs.googleapis.com" {
                return json(#"{"title": "Plan", "body": {"content": [{"paragraph": {"elements": [{"textRun": {"content": "Hello\n"}}]}}]}}"#)
            }
            if host == "slides.googleapis.com" {
                return json(#"{"title": "Deck", "slides": [{"pageElements": [{"shape": {"text": {"textElements": [{"textRun": {"content": "Title\n"}}]}}}]}]}"#)
            }
            if request.url?.path.contains("/values/") == true {
                return json(#"{"values": [["Name", "Total"], ["Ada", 3]]}"#)
            }
            return json(#"{"properties": {"title": "Budget"}, "sheets": [{"properties": {"title": "2026", "gridProperties": {"rowCount": 10, "columnCount": 2}}}]}"#)
        }
        defer { world.forget() }

        let document = await world.call("google_docs.read", ["document_id": AnyJSONValue("doc1")])
        XCTAssertEqual(document.contextBlock, "[Google Doc: Plan]\nHello\n")
        let slides = await world.call("google_slides.read", ["presentation_id": AnyJSONValue("deck1")])
        XCTAssertEqual(slides.contextBlock, "[Google Slides: Deck]\nSlide 1:\nTitle")
        XCTAssertEqual(slides.result?["slide_count"]?.value as? Int, 1)
        let sheet = await world.call("google_sheets.read", ["spreadsheet_id": AnyJSONValue("sheet1")])
        XCTAssertEqual(sheet.contextBlock, "[Google Sheet: Budget]\nSheets:\n- 2026 (10 rows, 2 columns)")
        let values = await world.call("google_sheets.readValues", ["spreadsheet_id": AnyJSONValue("sheet1"), "range": AnyJSONValue("My Sheet!A1:B2")])
        XCTAssertEqual(values.contextBlock, "[Google Sheets: My Sheet!A1:B2]\nName\tTotal\nAda\t3")

        XCTAssertEqual(world.asked.requests, [
            .init(method: "GET", address: "docs.googleapis.com/v1/documents/doc1", query: [:]),
            .init(method: "GET", address: "slides.googleapis.com/v1/presentations/deck1", query: [:]),
            .init(method: "GET", address: "sheets.googleapis.com/v4/spreadsheets/sheet1", query: ["fields": "properties.title,sheets.properties(title,gridProperties(rowCount,columnCount))"]),
            .init(method: "GET", address: "sheets.googleapis.com/v4/spreadsheets/sheet1/values/My%20Sheet%21A1%3AB2", query: [:]),
        ])
    }

    func testAnEmptyDocumentAndADeckWithNoSlides_saySo() async throws {
        let world = try await world { [self] _ in json("{}") }
        defer { world.forget() }

        let document = await world.call("google_docs.read", ["document_id": AnyJSONValue("doc1")])
        XCTAssertEqual(document.contextBlock, "[Google Doc: doc1]\n(The document is empty)")
        let slides = await world.call("google_slides.read", ["presentation_id": AnyJSONValue("deck1")])
        XCTAssertEqual(slides.contextBlock, "[Google Slides: deck1]\n(The presentation has no slides)")
        let sheet = await world.call("google_sheets.read", ["spreadsheet_id": AnyJSONValue("sheet1")])
        XCTAssertEqual(sheet.contextBlock, "[Google Sheet: sheet1]\nSheets:\n(None)")
    }

    func testACallThatNamesNoId_isToldSo_andNeitherGoogleNorThePersonIsAsked() async throws {
        let seen = Seen()
        let world = try await world(ask: { approval in
            await seen.note(approval)
            return .approved
        }, answer: { [self] _ in json("{}") })
        defer { world.forget() }

        for (tool, key, args) in [
            ("google_drive.readFile", "file_id", ["file_id": AnyJSONValue("../about")]),
            ("google_drive.readFile", "file_id", [:]),
            ("google_docs.read", "document_id", ["document_id": AnyJSONValue("abc/def")]),
            ("google_slides.read", "presentation_id", ["presentation_id": AnyJSONValue("abc?x")]),
            ("google_sheets.read", "spreadsheet_id", ["spreadsheet_id": AnyJSONValue("")]),
            ("google_sheets.readValues", "spreadsheet_id", ["spreadsheet_id": AnyJSONValue("abc def"), "range": AnyJSONValue("A1")]),
            ("google_sheets.writeValues", "spreadsheet_id", ["spreadsheet_id": AnyJSONValue("abc#"), "range": AnyJSONValue("A1"), "values": .array([.array([.string("x")])])]),
        ] as [(String, String, [String: AnyJSONValue])] {
            let result = await world.call(tool, args, threadID: "thread")
            XCTAssertEqual(result.errorType, "invalid_parameters", tool)
            XCTAssertEqual(result.field, key, tool)
            XCTAssertEqual(result.error, GoogleToolArguments.idMissing(key), tool)
        }
        let noRange = await world.call("google_sheets.readValues", ["spreadsheet_id": AnyJSONValue("abc"), "range": AnyJSONValue("")])
        XCTAssertEqual(noRange.field, "range")

        XCTAssertEqual(world.asked.requests, [])
        let approvals = await seen.approvals
        XCTAssertEqual(approvals.count, 0)
    }

    /// The approvals that were asked.
    private actor Seen {
        private(set) var approvals: [ToolApproval] = []

        func note(_ approval: ToolApproval) {
            approvals.append(approval)
        }
    }

    // MARK: - Who may use them

    func testTheNewToolsAreOfTheGoogleConnection_areOffered_andOnlyReading() {
        for tool in ["google_docs.read", "google_slides.read", "google_sheets.read"] {
            XCTAssertEqual(CovenConnectionRules.app(of: tool), "google_drive", tool)
            XCTAssertFalse(CovenConnectionRules.isWriteTool(tool), tool)
            XCTAssertTrue(PromptTemplates.googleDriveTools.contains(tool), tool)
            XCTAssertNotNil(PromptTemplates.toolDefinitions.first { $0.name == tool }, "\(tool) is described to models")
            XCTAssertEqual(CovenConnectionRules.decision(forAppTool: tool, in: CovenConnections(apps: ["google_drive": .readOnly])), .allowed, tool)
            XCTAssertEqual(CovenConnectionRules.decision(forAppTool: tool, in: CovenConnections(apps: ["github": .readWrite])), .notOn, tool)
        }
        XCTAssertEqual(PromptTemplates.toolDefinitions.first { $0.name == "google_drive.readFile" }?.parameters.map(\.name), ["file_id", "export_format"])
        // Every tool offered with the Google connection is one of its
        // tools under the coven's rule.
        for tool in PromptTemplates.googleDriveTools {
            XCTAssertEqual(CovenConnectionRules.app(of: tool), "google_drive", tool)
        }
    }

    func testACovenThatHasGoogleOff_orNoToolsPack_isNotGivenTheNewTools() async throws {
        let off = try await world(connections: CovenConnections(apps: ["github": .readWrite])) { [self] _ in json("{}") }
        defer { off.forget() }
        let unpaid = try await world(hasToolsPack: false) { [self] _ in json("{}") }
        defer { unpaid.forget() }

        for (tool, args) in [
            ("google_docs.read", ["document_id": AnyJSONValue("doc1")]),
            ("google_slides.read", ["presentation_id": AnyJSONValue("deck1")]),
            ("google_sheets.read", ["spreadsheet_id": AnyJSONValue("sheet1")]),
        ] as [(String, [String: AnyJSONValue])] {
            let refused = await off.call(tool, args, threadID: "thread")
            XCTAssertEqual(refused.errorType, "connection_not_on", tool)
            let locked = await unpaid.call(tool, args, threadID: "thread")
            XCTAssertEqual(locked.errorType, "entitlement_required", tool)
        }
        XCTAssertEqual(off.asked.requests, [])
        XCTAssertEqual(unpaid.asked.requests, [])
    }
}
