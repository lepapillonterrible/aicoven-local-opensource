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

        // Text in a table in a cell of a table, however deep, is still the document's text.
        var content: [[String: Any]] = [["paragraph": ["elements": [["textRun": ["content": "Deep down\n"]]]]]]
        for level in 0 ..< 20 {
            content = level.isMultiple(of: 2)
                ? [["table": ["tableRows": [["tableCells": [["content": content]]]]]]]
                : [["tableOfContents": ["content": content]]]
        }
        XCTAssertEqual(GoogleWorkspaceText.text(ofDocument: ["body": ["content": content]]).trimmingCharacters(in: .whitespacesAndNewlines), "Deep down")
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

        // Text in a group in a group, however deep, is still the slide's text.
        var element: [String: Any] = ["shape": ["text": ["textElements": [["textRun": ["content": "Deep down"]]]]]]
        for _ in 0 ..< 40 {
            element = ["elementGroup": ["children": [element]]]
        }
        XCTAssertEqual(GoogleWorkspaceText.text(ofPresentation: ["slides": [["pageElements": [element]]]]), "Slide 1:\nDeep down")
    }

    func testTheFormatACallNames_isTheFirstNameThatIsThere_andMustSaySomething() {
        XCTAssertEqual(GoogleToolArguments.exportFormat(in: [:]), .leftOut)
        XCTAssertEqual(GoogleToolArguments.exportFormat(in: ["export_format": .null]), .leftOut)
        XCTAssertEqual(GoogleToolArguments.exportFormat(in: ["export_format": AnyJSONValue("text/csv"), "export_mime_type": AnyJSONValue("text/html")]), .named("text/csv"))
        XCTAssertEqual(GoogleToolArguments.exportFormat(in: ["export_format": .null, "export_mime_type": AnyJSONValue("text/html")]), .named("text/html"), "The older name, where the cloud app's is not there")
        XCTAssertEqual(GoogleToolArguments.exportFormat(in: ["export_format": AnyJSONValue(""), "export_mime_type": AnyJSONValue("text/html")]), .unreadable("export_format"), "A format that is there and says nothing is not made up for")
        XCTAssertEqual(GoogleToolArguments.exportFormat(in: ["export_mime_type": AnyJSONValue(7)]), .unreadable("export_mime_type"))
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
            /// What was sent with it, as text.
            var body = ""

            /// What was sent with it, read as JSON.
            var sent: NSDictionary? {
                (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? NSDictionary
            }
        }

        private let lock = NSLock()
        private var kept: [Request] = []

        var requests: [Request] {
            lock.withLock { kept }
        }

        func note(_ request: URLRequest) {
            let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            var data = request.httpBody ?? Data()
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
            let noted = Request(
                method: request.httpMethod ?? "GET",
                address: (components?.host ?? "") + (components?.percentEncodedPath ?? ""),
                query: query,
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                body: String(decoding: data, as: UTF8.self)
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

        // A format that is named and says nothing is told so; Google is not asked.
        let unsaid = await world.call("google_drive.readFile", ["file_id": AnyJSONValue("doc1"), "export_format": AnyJSONValue(""), "export_mime_type": AnyJSONValue("text/html")])
        XCTAssertEqual(unsaid.errorType, "invalid_parameters")
        XCTAssertEqual(unsaid.field, "export_format")
        XCTAssertEqual(world.asked.requests.count, 9)
    }

    func testReadFile_saysWhenAFileIsNotText_andCutsTextThatIsTooLong() async throws {
        let long = String(repeating: "a", count: GoogleToolArguments.longestText + 5)
        let world = try await world { [self] request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/files/bin1"), url.contains("alt=media") { return (200, Data([0xFF, 0xFE, 0xFD])) }
            if url.contains("alt=media") { return (200, Data(long.utf8)) }
            if url.contains("/files/huge1") { return json(#"{"id": "huge1", "name": "film.mov", "mimeType": "video/quicktime", "size": "734003200"}"#) }
            return json(#"{"id": "x", "name": "x", "mimeType": "application/octet-stream", "size": "20005"}"#)
        }
        defer { world.forget() }

        let binary = await world.call("google_drive.readFile", ["file_id": AnyJSONValue("bin1")])
        XCTAssertEqual(binary.status, "ok")
        XCTAssertEqual(binary.contextBlock, "[Google Drive File: bin1]\n[Binary file, 3 bytes - cannot display as text]")

        let cut = await world.call("google_drive.readFile", ["file_id": AnyJSONValue("long1")])
        XCTAssertEqual(cut.contextBlock, "[Google Drive File: long1]\n" + String(repeating: "a", count: GoogleToolArguments.longestText) + AttachmentContext.cutMark)

        // A file too large to hold is not fetched.
        let before = world.asked.requests.count
        let huge = await world.call("google_drive.readFile", ["file_id": AnyJSONValue("huge1")])
        XCTAssertEqual(huge.status, "error")
        XCTAssertEqual(huge.error?.hasPrefix("'film.mov' is "), true)
        XCTAssertEqual(huge.error?.contains("too large to read here"), true)
        XCTAssertEqual(world.asked.requests.count, before + 1, "Only what it is was asked, not its bytes")
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
            ("google_sheets.updateValues", "spreadsheet_id", ["spreadsheet_id": AnyJSONValue("abc#"), "range": AnyJSONValue("A1"), "values": .array([.array([.string("x")])])]),
            ("google_sheets.batchUpdate", "spreadsheet_id", ["spreadsheet_id": AnyJSONValue("a/b"), "requests": .array([.dictionary(["addSheet": .dictionary([:])])])]),
            ("google_slides.update", "presentation_id", ["requests": .array([.dictionary(["createSlide": .dictionary([:])])])]),
            ("google_docs.update", "document_id", ["document_id": AnyJSONValue("../x"), "content": AnyJSONValue("x")]),
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

    // MARK: - Writing, which asks first

    /// A world whose person approves (or not) and is remembered.
    private func writingWorld(approving: Bool = true, connections: CovenConnections? = nil) async throws -> (World, Seen) {
        let seen = Seen()
        let world = try await world(connections: connections, ask: { approval in
            await seen.note(approval)
            return approving ? .approved : .denied
        }, answer: { [self] _ in json(#"{"id": "new1", "name": "plan.txt"}"#) })
        return (world, seen)
    }

    func testValuesAreWrittenAsTheyWereGiven_byTheCloudsNameOrTheOldOne() async throws {
        let (world, seen) = try await writingWorld()
        defer { world.forget() }
        let values: AnyJSONValue = .array([.array([.string("Name"), .string("Total")]), .array([.string("Ada"), .int(3)]), .array([.bool(true), .null, .double(1.5)])])

        let written = await world.call("google_sheets.updateValues", ["spreadsheet_id": AnyJSONValue("s1"), "range": AnyJSONValue("My Sheet!A1"), "values": values], threadID: "thread")
        XCTAssertEqual(written.status, "ok")
        XCTAssertEqual(written.contextBlock, "[Google Sheets Updated: My Sheet!A1]\nSent 3 rows", "Google's answer here does not say what it wrote")
        // This app's older name for it, and exactly as written.
        let old = await world.call("google_sheets.writeValues", ["spreadsheet_id": AnyJSONValue("s1"), "range": AnyJSONValue("A1"), "values": .array([.array([.string("=1+1")])]), "value_input_option": AnyJSONValue("RAW")], threadID: "thread")
        XCTAssertEqual(old.status, "ok")
        XCTAssertEqual(old.tool, "google_sheets.updateValues")

        let approvals = await seen.approvals
        XCTAssertEqual(approvals.map(\.details), [
            "My Sheet!A1 in spreadsheet s1\n3 rows, entered as if typed (formulas are worked out)\n\nName\tTotal\nAda\t3\nTRUE\t\t1.5",
            "A1 in spreadsheet s1\n1 row, entered exactly as written\n\n=1+1",
        ])
        XCTAssertEqual(world.asked.requests.map(\.method), ["PUT", "PUT"])
        XCTAssertEqual(world.asked.requests.map(\.address), ["sheets.googleapis.com/v4/spreadsheets/s1/values/My%20Sheet%21A1", "sheets.googleapis.com/v4/spreadsheets/s1/values/A1"])
        XCTAssertEqual(world.asked.requests.map(\.query), [["valueInputOption": "USER_ENTERED"], ["valueInputOption": "RAW"]])
        XCTAssertEqual(world.asked.requests.first?.sent?["values"] as? NSArray, [["Name", "Total"], ["Ada", 3], [true, "", 1.5]] as NSArray, "Text as text, a number as a number, an empty cell for null")
    }

    func testWhatGoogleSaysItWrote_isWhatTheModelIsTold() async throws {
        let world = try await world(ask: { _ in .approved }, answer: { [self] _ in
            json(#"{"spreadsheetId": "s1", "updatedRange": "Sheet1!A1:A1", "updatedRows": 1, "updatedColumns": 1, "updatedCells": 1}"#)
        })
        defer { world.forget() }

        // Two rows are sent; the second has no cells, so one row is written.
        let written = await world.call("google_sheets.updateValues", ["spreadsheet_id": AnyJSONValue("s1"), "range": AnyJSONValue("A1"), "values": .array([.array([.string("x")]), .array([])])], threadID: "thread")

        XCTAssertEqual(written.contextBlock, "[Google Sheets Updated: Sheet1!A1:A1]\nWrote 1 row (1 cell)")
        XCTAssertEqual(written.result?["updated_rows"]?.value as? Int, 1)
    }

    func testAListGivenAsJSONInText_isReadAsWhatItSays() {
        // As a model writes it when it has been told a list holds text.
        XCTAssertEqual(
            GoogleToolArguments.requests(in: ["requests": .array([.string(#"{"addSheet": {"properties": {"title": "Summary"}}}"#), .dictionary(["createSlide": .dictionary([:])])])]),
            [["addSheet": .dictionary(["properties": .dictionary(["title": .string("Summary")])])], ["createSlide": .dictionary([:])]]
        )
        XCTAssertEqual(GoogleToolArguments.requests(in: ["requests": .string(#" [{"createSlide": {}}]"#)]), [["createSlide": .dictionary([:])]])
        XCTAssertEqual(
            GoogleToolArguments.rows(in: ["values": .array([.string(#"["Name", "Total"]"#), .array([.string("Ada"), .int(3)])])]),
            [[.string("Name"), .string("Total")], [.string("Ada"), .int(3)]]
        )
        XCTAssertEqual(GoogleToolArguments.rows(in: ["values": .string(#"[["a", 1], [true, null]]"#)]), [[.string("a"), .int(1)], [.bool(true), .null]])

        // A whole number is read exactly, however large; one with a fraction stays one.
        XCTAssertEqual(GoogleToolArguments.rows(in: ["values": .string("[[9007199254740993, -9223372036854775808, 1.5, 3.0]]")]), [[.int(9_007_199_254_740_993), .int(Int.min), .double(1.5), .double(3.0)]])
        XCTAssertEqual(
            GoogleToolArguments.requests(in: ["requests": .array([.string(#"{"deleteSheet": {"sheetId": 9007199254740993}}"#)])]),
            [["deleteSheet": .dictionary(["sheetId": .int(9_007_199_254_740_993)])]]
        )

        // A number too large to be one is neither a cell nor part of a request.
        XCTAssertNil(GoogleToolArguments.rows(in: ["values": .array([.array([.double(.infinity)])])]))
        XCTAssertNil(GoogleToolArguments.requests(in: ["requests": .array([.dictionary(["resize": .dictionary(["width": .double(.infinity)])])])]))
        XCTAssertNil(GoogleToolArguments.requests(in: ["requests": .array([.dictionary(["resize": .double(.nan)])])]))

        // Text that is not JSON for a list or an object is not one.
        XCTAssertNil(GoogleToolArguments.requests(in: ["requests": .array([.string("addSheet")])]))
        XCTAssertNil(GoogleToolArguments.requests(in: ["requests": .array([.string("[1, 2]")])]), "A request is an object")
        XCTAssertNil(GoogleToolArguments.requests(in: ["requests": .string(#"{"createSlide": {}}"#)]), "Requests are a list")
        XCTAssertNil(GoogleToolArguments.requests(in: ["requests": .string("[{")]))
        XCTAssertNil(GoogleToolArguments.rows(in: ["values": .array([.string("a,b")])]))
        XCTAssertNil(GoogleToolArguments.rows(in: ["values": .string(#"{"a": 1}"#)]))
        // A cell that is text stays text, whatever it looks like.
        XCTAssertEqual(GoogleToolArguments.rows(in: ["values": .array([.array([.string("[1]"), .string("{}")])])]), [[.string("[1]"), .string("{}")]])
    }

    func testValuesThatAreNotRowsOfCells_orAnOptionGoogleDoesNotHave_areNotAskedAbout() async throws {
        let (world, seen) = try await writingWorld()
        defer { world.forget() }

        for values in [.string("a,b"), .array([]), .array([.string("a")]), .array([.array([.dictionary([:])])]), .array([.array([.array([])])]), .null] as [AnyJSONValue] {
            let refused = await world.call("google_sheets.updateValues", ["spreadsheet_id": AnyJSONValue("s1"), "range": AnyJSONValue("A1"), "values": values], threadID: "thread")
            XCTAssertEqual(refused.field, "values", "\(values)")
        }
        let option = await world.call("google_sheets.updateValues", ["spreadsheet_id": AnyJSONValue("s1"), "range": AnyJSONValue("A1"), "values": .array([.array([.int(1)])]), "value_input_option": AnyJSONValue("FORMULA")], threadID: "thread")
        XCTAssertEqual(option.field, "value_input_option")

        XCTAssertEqual(world.asked.requests, [])
        let approvals = await seen.approvals
        XCTAssertEqual(approvals.count, 0)
    }

    func testASheetOrADeckIsChangedWithGooglesOwnRequests_shownAsTheyAreSent() async throws {
        let (world, seen) = try await writingWorld()
        defer { world.forget() }
        let addSheet: AnyJSONValue = .array([.dictionary(["addSheet": .dictionary(["properties": .dictionary(["title": .string("Summary")])])])])
        let slides: AnyJSONValue = .array([.dictionary(["createSlide": .dictionary([:])]), .dictionary(["deleteObject": .dictionary(["objectId": .string("p2")])])])

        let sheet = await world.call("google_sheets.batchUpdate", ["spreadsheet_id": AnyJSONValue("s1"), "requests": addSheet], threadID: "thread")
        XCTAssertEqual(sheet.contextBlock, "[Google Spreadsheet Changed: s1]\n1 change made.")
        let deck = await world.call("google_slides.update", ["presentation_id": AnyJSONValue("deck1"), "requests": slides], threadID: "thread")
        XCTAssertEqual(deck.contextBlock, "[Google Presentation Changed: deck1]\n2 changes made.")

        let approvals = await seen.approvals
        XCTAssertEqual(approvals.map(\.question), ["Change this Google Sheet?", "Change this Google Slides presentation?"])
        XCTAssertEqual(approvals.first?.details.hasPrefix("Spreadsheet s1\n1 change, as Google is asked to make it:\n\n"), true)
        XCTAssertEqual(approvals.first?.details.contains("\"title\" : \"Summary\""), true)
        XCTAssertEqual(world.asked.requests.map(\.method), ["POST", "POST"])
        XCTAssertEqual(world.asked.requests.map(\.address), ["sheets.googleapis.com/v4/spreadsheets/s1:batchUpdate", "slides.googleapis.com/v1/presentations/deck1:batchUpdate"])
        XCTAssertEqual(world.asked.requests.first?.sent, ["requests": [["addSheet": ["properties": ["title": "Summary"]]]]] as NSDictionary)
        XCTAssertEqual(world.asked.requests.last?.sent, ["requests": [["createSlide": [:] as [String: Any]], ["deleteObject": ["objectId": "p2"]]]] as NSDictionary)

        // Requests that are not a list of objects are told so; no one is asked.
        for requests in [.array([]), .array([.int(1)]), .array([.dictionary([:])]), .dictionary(["addSheet": .dictionary([:])]), .string("addSheet"), .null] as [AnyJSONValue] {
            let refused = await world.call("google_sheets.batchUpdate", ["spreadsheet_id": AnyJSONValue("s1"), "requests": requests], threadID: "thread")
            XCTAssertEqual(refused.field, "requests", "\(requests)")
            let refusedDeck = await world.call("google_slides.update", ["presentation_id": AnyJSONValue("deck1"), "requests": requests], threadID: "thread")
            XCTAssertEqual(refusedDeck.field, "requests", "\(requests)")
        }
        let after = await seen.approvals
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(world.asked.requests.count, 2)
    }

    func testTextIsAddedToADocumentAtTheEndOrAtAPosition_orItIsChangedWithRequests() async throws {
        let (world, seen) = try await writingWorld()
        defer { world.forget() }

        let atEnd = await world.call("google_docs.update", ["document_id": AnyJSONValue("doc1"), "content": AnyJSONValue("Next steps"), "requests": .null], threadID: "thread")
        XCTAssertEqual(atEnd.contextBlock, "[Google Document Changed: doc1]\n1 change made.")
        _ = await world.call("google_docs.update", ["document_id": AnyJSONValue("doc1"), "content": AnyJSONValue("Title\n"), "index": AnyJSONValue(1)], threadID: "thread")
        _ = await world.call("google_docs.update", ["document_id": AnyJSONValue("doc1"), "content": AnyJSONValue("ignored"), "requests": .array([.dictionary(["deleteContentRange": .dictionary(["range": .dictionary(["startIndex": .int(1), "endIndex": .int(5)])])])])], threadID: "thread")

        let approvals = await seen.approvals
        XCTAssertEqual(approvals.map(\.question), ["Add this text to the Google Doc?", "Add this text to the Google Doc?", "Change this Google Doc?"])
        XCTAssertEqual(approvals[0].details.hasPrefix("Document doc1\nAt the end · "), true)
        XCTAssertEqual(approvals[1].details.hasPrefix("Document doc1\nAt position 1 · "), true)
        XCTAssertEqual(approvals[2].details.contains("deleteContentRange"), true, "Requests, where they are given, are what is asked and shown")
        XCTAssertEqual(approvals[2].details.contains("ignored"), false)

        XCTAssertEqual(Set(world.asked.requests.map(\.address)), ["docs.googleapis.com/v1/documents/doc1:batchUpdate"])
        XCTAssertEqual(world.asked.requests[0].sent, ["requests": [["insertText": ["text": "Next steps", "endOfSegmentLocation": [:] as [String: Any]]]]] as NSDictionary)
        XCTAssertEqual(world.asked.requests[1].sent, ["requests": [["insertText": ["text": "Title\n", "location": ["index": 1]]]]] as NSDictionary)
        XCTAssertEqual(world.asked.requests[2].sent, ["requests": [["deleteContentRange": ["range": ["startIndex": 1, "endIndex": 5]]]]] as NSDictionary)

        // Neither text nor requests; a position that is none; requests that are none.
        let nothing = await world.call("google_docs.update", ["document_id": AnyJSONValue("doc1")], threadID: "thread")
        XCTAssertEqual(nothing.field, "content")
        let empty = await world.call("google_docs.update", ["document_id": AnyJSONValue("doc1"), "content": AnyJSONValue("")], threadID: "thread")
        XCTAssertEqual(empty.field, "content")
        for index in [AnyJSONValue(0), AnyJSONValue(-2), AnyJSONValue("start"), AnyJSONValue(1.5)] {
            let refused = await world.call("google_docs.update", ["document_id": AnyJSONValue("doc1"), "content": AnyJSONValue("x"), "index": index], threadID: "thread")
            XCTAssertEqual(refused.field, "index", "\(index)")
        }
        let badRequests = await world.call("google_docs.update", ["document_id": AnyJSONValue("doc1"), "content": AnyJSONValue("x"), "requests": .array([])], threadID: "thread")
        XCTAssertEqual(badRequests.field, "requests", "Requests that are there and are none are not made up for with the text")
        let after = await seen.approvals
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(world.asked.requests.count, 3)
    }

    func testAnUploadCanNameItsFolders_andADeniedChangeSendsNothing() async throws {
        let (world, seen) = try await writingWorld()
        defer { world.forget() }

        let uploaded = await world.call("google_drive.uploadFile", ["name": AnyJSONValue("plan.txt"), "content": AnyJSONValue("Plan"), "parents": .array([.string("folder1")])], threadID: "thread")
        XCTAssertEqual(uploaded.status, "ok")
        XCTAssertEqual(world.asked.requests.first?.body.contains(#""parents":["folder1"]"#), true)
        let approvals = await seen.approvals
        XCTAssertEqual(approvals.first?.details.hasPrefix("plan.txt\nIn folder folder1\ntext/plain · "), true)
        for parents in [.string("folder1"), .array([.string("../x")]), .array([.int(1)])] as [AnyJSONValue] {
            let refused = await world.call("google_drive.uploadFile", ["name": AnyJSONValue("plan.txt"), "content": AnyJSONValue("Plan"), "parents": parents], threadID: "thread")
            XCTAssertEqual(refused.field, "parents", "\(parents)")
        }
        XCTAssertEqual(world.asked.requests.count, 1)

        let (denying, _) = try await writingWorld(approving: false)
        defer { denying.forget() }
        for (tool, args) in changes {
            let denied = await denying.call(tool, args, threadID: "thread")
            XCTAssertEqual(denied.status, "denied", tool)
            // With no thread there is no one to ask.
            let nowhere = await denying.call(tool, args)
            XCTAssertNotEqual(nowhere.status, "ok", tool)
        }
        XCTAssertEqual(denying.asked.requests, [])
    }

    /// One call of each tool that changes something in Google.
    private var changes: [(String, [String: AnyJSONValue])] {
        [
            ("google_sheets.updateValues", ["spreadsheet_id": AnyJSONValue("s1"), "range": AnyJSONValue("A1"), "values": .array([.array([.int(1)])])]),
            ("google_sheets.batchUpdate", ["spreadsheet_id": AnyJSONValue("s1"), "requests": .array([.dictionary(["addSheet": .dictionary([:])])])]),
            ("google_slides.update", ["presentation_id": AnyJSONValue("deck1"), "requests": .array([.dictionary(["createSlide": .dictionary([:])])])]),
            ("google_docs.update", ["document_id": AnyJSONValue("doc1"), "content": AnyJSONValue("x")]),
            ("google_drive.uploadFile", ["name": AnyJSONValue("plan.txt"), "content": AnyJSONValue("Plan")]),
        ]
    }

    func testACovenThatLetsGoogleBeReadOnly_isRefusedEveryChange_andNoOneIsAsked() async throws {
        let (world, seen) = try await writingWorld(connections: CovenConnections(apps: ["google_drive": .readOnly]))
        defer { world.forget() }

        for (tool, args) in changes {
            XCTAssertTrue(CovenConnectionRules.isWriteTool(tool), tool)
            XCTAssertTrue(PromptTemplates.googleDriveTools.contains(tool), tool)
            XCTAssertNotNil(PromptTemplates.toolDefinitions.first { $0.name == tool }, "\(tool) is described to models")
            let refused = await world.call(tool, args, threadID: "thread")
            XCTAssertEqual(refused.errorType, "connection_read_only", tool)
        }
        // By its old name too.
        let old = await world.call("google_sheets.writeValues", changes[0].1, threadID: "thread")
        XCTAssertEqual(old.errorType, "connection_read_only")
        XCTAssertFalse(PromptTemplates.googleDriveTools.contains("google_sheets.writeValues"))
        XCTAssertEqual(ToolNames.offeredName(of: "google_sheets.writeValues"), "google_sheets.updateValues")
        // What a read-only coven is offered has none of them.
        let offered = CovenConnectionRules.offered(tools: PromptTemplates.googleDriveTools, servers: [], in: CovenConnections(apps: ["google_drive": .readOnly])).tools
        XCTAssertEqual(offered, ["google_drive.listFiles", "google_drive.readFile", "google_docs.read", "google_slides.read", "google_sheets.read", "google_sheets.readValues"])

        XCTAssertEqual(world.asked.requests, [])
        let approvals = await seen.approvals
        XCTAssertEqual(approvals.count, 0)
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
            XCTAssertNotEqual(ChatService.friendlyToolName(tool), tool, "\(tool) is named for the person")
            XCTAssertFalse(ChatService.friendlyToolSummary(for: tool).contains(tool), tool)
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
