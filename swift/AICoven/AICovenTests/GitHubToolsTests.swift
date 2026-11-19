@testable import AICoven
import XCTest

/// The GitHub tools take a repository as the cloud app names it, are
/// called by the cloud app's names, and ask GitHub only for what a call
/// names.
final class GitHubToolsTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - What a call's arguments say

    func testARepositoryIsReadAsOneArgument_orAsOwnerAndRepoApart() {
        func read(_ args: [String: AnyJSONValue]) -> String? {
            GitHubToolArguments.repository(in: args)?.fullName
        }
        XCTAssertEqual(read(["repo": AnyJSONValue("octo/site")]), "octo/site", "As the cloud app names it")
        XCTAssertEqual(read(["owner": AnyJSONValue("octo"), "repo": AnyJSONValue("site")]), "octo/site", "As this app's tools took it")
        XCTAssertEqual(read(["owner": AnyJSONValue("Octo"), "repo": AnyJSONValue("octo/site.io")]), "octo/site.io", "Both, where they agree")
        XCTAssertEqual(read(["owner": .null, "repo": AnyJSONValue("octo/site")]), "octo/site", "An owner given as null is one left out")
        XCTAssertEqual(read(["repo": AnyJSONValue("octo_org/my-site_2")]), "octo_org/my-site_2")

        XCTAssertNil(read(["owner": AnyJSONValue("someone"), "repo": AnyJSONValue("octo/site")]), "Two owners is no repository")
        XCTAssertNil(read(["repo": AnyJSONValue("site")]), "A name with no owner")
        XCTAssertNil(read(["owner": AnyJSONValue("octo")]))
        XCTAssertNil(read([:]))
        XCTAssertNil(read(["repo": AnyJSONValue(42)]))
        XCTAssertNil(read(["owner": AnyJSONValue(42), "repo": AnyJSONValue("octo/site")]), "An owner that is not text")
        XCTAssertNil(read(["owner": AnyJSONValue(""), "repo": AnyJSONValue("octo/site")]))
        XCTAssertNil(read(["owner": .null, "repo": AnyJSONValue("site")]))
        for notOne in ["octo/site/extra", "octo/", "/site", "../site", "octo/..", "octo/.", "octo/si te", " octo/site", "octo/site ", "octo/site\n", "octo/site?x=1", "octo/site#x", "octo/si%2Fte", "öcto/site"] {
            XCTAssertNil(read(["repo": AnyJSONValue(notOne)]), "\(notOne) does not read as a repository")
        }
        XCTAssertNil(read(["owner": AnyJSONValue("octo/x"), "repo": AnyJSONValue("site")]))
        XCTAssertNil(read(["owner": AnyJSONValue(" octo"), "repo": AnyJSONValue("site")]), "Nothing is trimmed")
        // The Kelvin sign compares equal to K when case is ignored, and is no letter of a name.
        XCTAssertNil(read(["owner": AnyJSONValue("\u{212A}"), "repo": AnyJSONValue("K/site")]), "An owner beside a full name is a name too")
        XCTAssertNil(read(["owner": AnyJSONValue("\u{212A}"), "repo": AnyJSONValue("site")]))
    }

    func testNumbersAreReadAsNumbersOrDigits_andPagesStayWithinWhatGitHubTakes() {
        XCTAssertEqual(GitHubToolArguments.pullNumber(in: ["pull_number": AnyJSONValue(7)]), 7)
        XCTAssertEqual(GitHubToolArguments.pullNumber(in: ["pull_number": AnyJSONValue("7")]), 7)
        XCTAssertEqual(GitHubToolArguments.pullNumber(in: ["number": AnyJSONValue(7.0)]), 7)
        XCTAssertNil(GitHubToolArguments.pullNumber(in: ["pull_number": AnyJSONValue(0)]))
        XCTAssertNil(GitHubToolArguments.pullNumber(in: ["pull_number": AnyJSONValue(-3)]))
        XCTAssertNil(GitHubToolArguments.pullNumber(in: ["pull_number": AnyJSONValue(7.5)]))
        XCTAssertNil(GitHubToolArguments.pullNumber(in: ["pull_number": AnyJSONValue("7/files")]))
        for notDigits in ["+7", " 7", "7 ", "-7", "", "٧"] {
            XCTAssertNil(GitHubToolArguments.pullNumber(in: ["pull_number": AnyJSONValue(notDigits)]), "'\(notDigits)' is not digits")
        }
        XCTAssertNil(GitHubToolArguments.pullNumber(in: [:]))

        XCTAssertEqual(GitHubToolArguments.page(in: [:]), 1)
        XCTAssertEqual(GitHubToolArguments.page(in: ["page": AnyJSONValue(3)]), 3)
        XCTAssertEqual(GitHubToolArguments.page(in: ["page": AnyJSONValue(0)]), 1)
        XCTAssertEqual(GitHubToolArguments.perPage(in: [:], standard: 30), 30)
        XCTAssertEqual(GitHubToolArguments.perPage(in: ["per_page": AnyJSONValue(500)], standard: 30), 100)
        XCTAssertEqual(GitHubToolArguments.perPage(in: ["per_page": AnyJSONValue("5")], standard: 30), 5)
        XCTAssertEqual(GitHubToolArguments.perPage(in: ["per_page": AnyJSONValue(-1)], standard: 30), 1)
        XCTAssertEqual(GitHubToolArguments.perPage(in: ["per_page": AnyJSONValue(1_000_000_000.0)], standard: 30), 100, "A large whole number is still a number")
        XCTAssertEqual(GitHubToolArguments.perPage(in: ["per_page": AnyJSONValue(Double.infinity)], standard: 30), 30, "What is no whole number is nothing asked for")
        XCTAssertEqual(GitHubToolArguments.page(in: ["page": AnyJSONValue(true)]), 1)
    }

    func testTwoToolsAreCalledByTheCloudsNames_andTheirOldNamesAreThoseTools() {
        XCTAssertEqual(ToolNames.offeredName(of: "github.getPR"), "github.getPullRequest")
        XCTAssertEqual(ToolNames.offeredName(of: "github.listPRFiles"), "github.listPullRequestFiles")
        XCTAssertEqual(ToolNames.offeredName(of: "github.readFile"), "github.readFile")
        XCTAssertEqual(ToolNames.offeredName(of: "file.read"), "file.read")

        for tool in ["github.getRepo", "github.getPullRequest", "github.listPullRequestFiles"] {
            XCTAssertTrue(PromptTemplates.githubTools.contains(tool))
            XCTAssertNotNil(PromptTemplates.toolDefinitions.first { $0.name == tool }, "\(tool) is described to models")
        }
        XCTAssertFalse(PromptTemplates.githubTools.contains("github.getPR"))
        // Every GitHub tool that is of a repository is told to name it in
        // one argument, and none is told of `owner`.
        for definition in PromptTemplates.toolDefinitions where definition.name.hasPrefix("github.") {
            XCTAssertFalse(definition.parameters.contains { $0.name == "owner" }, definition.name)
            if definition.name != "github.listRepos" {
                XCTAssertTrue(definition.parameters.contains { $0.name == "repo" }, definition.name)
            }
        }
        // A tool that changes something still counts as one under the
        // coven's rule, and no reading tool does.
        for tool in PromptTemplates.githubTools {
            XCTAssertEqual(CovenConnectionRules.isWriteTool(tool), ["github.writeFile", "github.createBranch", "github.createPR"].contains(tool), tool)
            XCTAssertEqual(CovenConnectionRules.app(of: tool), "github")
        }
    }

    // MARK: - The path of a request

    func testAStepOfAPathStaysOneStep_whateverItHolds() {
        XCTAssertEqual(GitHubToolService.path(of: ["repos", "octo", "site"]), "/repos/octo/site")
        XCTAssertEqual(
            GitHubToolService.path(of: ["repos", "octo", "site", "contents", "My File?.md", "a#b", "é", "50%", "x&y=z", "a+b"]),
            "/repos/octo/site/contents/My%20File%3F.md/a%23b/%C3%A9/50%25/x%26y%3Dz/a%2Bb"
        )
        XCTAssertEqual(GitHubToolService.path(of: ["contents", "..%2F..", "%2e%2e"]), "/contents/..%252F../%252e%252e", "What is already written with a percent sign is taken as it reads")
        XCTAssertNil(GitHubToolService.path(of: ["repos", "octo", "site", "contents", ".."]), "No climbing out")
        XCTAssertNil(GitHubToolService.path(of: ["repos", "octo", "site", "contents", "."]))
        XCTAssertNil(GitHubToolService.path(of: ["repos", "", "site"]))

        XCTAssertEqual(GitHubToolService.steps(of: "/src/app/"), ["src", "app"])
        XCTAssertEqual(GitHubToolService.steps(of: "README.md"), ["README.md"])
        XCTAssertEqual(GitHubToolService.steps(of: ""), [], "The top of a repository")
        XCTAssertEqual(GitHubToolService.steps(of: "/"), [])
        XCTAssertEqual(GitHubToolService.steps(of: "feature/new"), ["feature", "new"], "A branch's name can have slashes")
        XCTAssertNil(GitHubToolService.path(of: ["contents"] + GitHubToolService.steps(of: "docs/../../../user")))
        XCTAssertNil(GitHubToolService.path(of: ["contents"] + GitHubToolService.steps(of: "docs//file")))
    }

    // MARK: - Calls, with GitHub answered by a script

    /// What GitHub was asked. Sendable by hand: `kept` is read and written
    /// under `lock`.
    private final class Asked: @unchecked Sendable {
        struct Request: Equatable {
            let method: String
            /// The path as it was sent, percent signs and all.
            let path: String
            let query: [String: String]
            let authorization: String?
            /// What was sent with it, where that was JSON.
            var sent: [String: String] = [:]
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
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let noted = Request(
                method: request.httpMethod ?? "GET",
                path: components?.percentEncodedPath ?? "",
                query: query,
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                sent: body.compactMapValues { $0 as? String }
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

    /// An executor with a GitHub account connected (in memory), the Tools
    /// Pack bought, the tools a chat turn is offered, and GitHub answered
    /// by `answer`.
    private func world(
        ask: @escaping @Sendable (ToolApproval) async -> ApprovalAnswer = { _ in .denied },
        answer: @escaping @Sendable (URLRequest) -> (status: Int, body: String)
    ) async throws -> World {
        let suite = "GitHubToolsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let accounts = ConnectedAccountsService(currentUser: { "github-tests" }, defaults: defaults, tokens: InMemoryTokens().store)
        _ = try await accounts.createAccount(
            provider: .github,
            displayName: "octocat",
            tokenBundle: OAuthTokenBundle(accessToken: "TEST_TOKEN", refreshToken: nil, tokenType: "Bearer", expiresAt: nil, scopes: ["repo"])
        )

        let asked = Asked()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { request in
            asked.note(request)
            let given = answer(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: given.status, httpVersion: "HTTP/1.1", headerFields: nil))
            return (response, Data(given.body.utf8))
        }
        let github = GitHubToolService(accounts: accounts, session: URLSession(configuration: config))
        let executor = ToolExecutionService(
            toolService: ToolService.shared,
            ask: ask,
            connectedAccounts: accounts,
            githubService: github,
            hasToolsPack: { true }
        )
        await executor.setWhitelist(for: "chat", tools: PromptTemplates.githubTools)
        return World(executor: executor, asked: asked, defaults: defaults, suite: suite)
    }

    func testGetRepo_asksForTheRepositoryNamed_andTellsItsDefaultBranch() async throws {
        let world = try await world { _ in (200, #"{"full_name": "octo/site", "default_branch": "trunk", "description": "The site", "private": true}"#) }
        defer { world.forget() }

        let result = await world.call("github.getRepo", ["repo": AnyJSONValue("octo/site")])

        XCTAssertEqual(result.status, "ok")
        XCTAssertEqual(world.asked.requests, [.init(method: "GET", path: "/repos/octo/site", query: [:], authorization: "Bearer TEST_TOKEN")])
        XCTAssertEqual(result.contextBlock, "[GitHub Repo: octo/site]\nDefault branch: trunk\nDescription: The site")
        XCTAssertEqual(result.result?["default_branch"]?.value as? String, "trunk")
    }

    func testACallThatNamesNoRepository_isToldSo_andGitHubIsNotAsked() async throws {
        let world = try await world { _ in (200, "{}") }
        defer { world.forget() }

        for (tool, args) in [
            ("github.getRepo", [:]),
            ("github.readFile", ["repo": AnyJSONValue("../other"), "path": AnyJSONValue("README.md")]),
            ("github.listFiles", ["repo": AnyJSONValue("site")]),
            ("github.getPullRequest", ["repo": AnyJSONValue("octo/site/pulls"), "pull_number": AnyJSONValue(1)]),
            ("github.listPullRequestFiles", ["owner": AnyJSONValue("octo"), "pull_number": AnyJSONValue(1)]),
            ("github.searchCode", ["query": AnyJSONValue("x"), "repo": AnyJSONValue("not a repo")]),
        ] as [(String, [String: AnyJSONValue])] {
            let result = await world.call(tool, args)
            XCTAssertEqual(result.errorType, "invalid_parameters", tool)
            XCTAssertEqual(result.error, GitHubToolArguments.repositoryMissing, tool)
        }
        XCTAssertEqual(world.asked.requests, [])
    }

    func testAFilesPath_isSentAsThatPath_andOneThatClimbsOutIsNotSent() async throws {
        // "hello\n" in base64.
        let world = try await world { _ in (200, #"{"encoding": "base64", "content": "aGVsbG8K"}"#) }
        defer { world.forget() }

        let read = await world.call("github.readFile", ["repo": AnyJSONValue("octo/site"), "path": AnyJSONValue("docs/My File?.md"), "ref": AnyJSONValue("feature/new")])
        XCTAssertEqual(read.status, "ok")
        XCTAssertEqual(read.contextBlock, "[GitHub File: octo/site/docs/My File?.md]\nhello\n")
        XCTAssertEqual(world.asked.requests, [.init(method: "GET", path: "/repos/octo/site/contents/docs/My%20File%3F.md", query: ["ref": "feature/new"], authorization: "Bearer TEST_TOKEN")])

        for climbing in ["docs/../../../user", "../collaborators/someone", "./x", "docs//x"] {
            let refused = await world.call("github.readFile", ["owner": AnyJSONValue("octo"), "repo": AnyJSONValue("site"), "path": AnyJSONValue(climbing)])
            XCTAssertEqual(refused.status, "error", climbing)
        }
        XCTAssertEqual(world.asked.requests.count, 1, "Nothing more was asked of GitHub")
    }

    /// A world whose person approves (or not) and is remembered, and whose
    /// GitHub answers a look at a file with `looked` and a write with 201.
    private func writingWorld(approving: Bool = true, looked: (status: Int, body: String)) async throws -> (World, Seen) {
        let seen = Seen()
        let world = try await world(ask: { approval in
            await seen.note(approval)
            return approving ? .approved : .denied
        }, answer: { request in
            request.httpMethod == "GET" ? looked : (201, "{}")
        })
        return (world, seen)
    }

    func testWritingAFileThatIsNotThere_looksFirst_asksAboutANewFile_andSendsNoSha() async throws {
        let (world, seen) = try await writingWorld(looked: (404, #"{"message": "Not Found"}"#))
        defer { world.forget() }

        let written = await world.call(
            "github.writeFile",
            ["repo": AnyJSONValue("octo/site"), "branch": AnyJSONValue("docs"), "path": AnyJSONValue("docs/new.md"), "content": AnyJSONValue("hello"), "commit_message": AnyJSONValue("Add a page")],
            threadID: "thread"
        )

        XCTAssertEqual(written.status, "ok")
        XCTAssertEqual(written.contextBlock, "[GitHub File Written: octo/site/docs/new.md]\nA new file.\nCommit message: Add a page")
        let approvals = await seen.approvals
        XCTAssertEqual(approvals.count, 1)
        XCTAssertEqual(approvals.first?.details.hasPrefix("docs/new.md in octo/site, on docs\nCommit message: Add a page\nA new file · "), true)
        XCTAssertEqual(world.asked.requests.map(\.method), ["GET", "PUT"])
        XCTAssertEqual(world.asked.requests.map(\.path), ["/repos/octo/site/contents/docs/new.md", "/repos/octo/site/contents/docs/new.md"])
        XCTAssertEqual(world.asked.requests.first?.query, ["ref": "docs"], "The file is looked for on the branch it is written to")
        // "hello" in base64.
        XCTAssertEqual(world.asked.requests.last?.sent, ["message": "Add a page", "content": "aGVsbG8=", "branch": "docs"])
    }

    func testWritingAFileThatIsThere_asksAboutReplacingIt_andSendsItsSha() async throws {
        let (world, seen) = try await writingWorld(looked: (200, #"{"type": "file", "sha": "abc123", "encoding": "none", "content": ""}"#))
        defer { world.forget() }

        // The commit message by the name this app's tool had.
        let written = await world.call(
            "github.writeFile",
            ["owner": AnyJSONValue("octo"), "repo": AnyJSONValue("site"), "path": AnyJSONValue("README.md"), "content": AnyJSONValue("hello"), "message": AnyJSONValue("Update"), "sha": AnyJSONValue("")],
            threadID: "thread"
        )

        XCTAssertEqual(written.status, "ok")
        XCTAssertEqual(written.contextBlock, "[GitHub File Written: octo/site/README.md]\nReplaced the file that was there.\nCommit message: Update")
        let approvals = await seen.approvals
        XCTAssertEqual(approvals.first?.details.hasPrefix("README.md in octo/site, on the default branch\nCommit message: Update\nReplaces the file that is there · "), true)
        XCTAssertEqual(world.asked.requests.first?.query, [:], "On the default branch")
        XCTAssertEqual(world.asked.requests.last?.sent, ["message": "Update", "content": "aGVsbG8=", "sha": "abc123"])
    }

    func testAShaTheCallNames_isSentAsItIs_withoutLooking_andADeniedWriteSendsNothing() async throws {
        let (world, seen) = try await writingWorld(looked: (500, "{}"))
        defer { world.forget() }

        let written = await world.call(
            "github.writeFile",
            ["repo": AnyJSONValue("octo/site"), "path": AnyJSONValue("README.md"), "content": AnyJSONValue("hello"), "commit_message": AnyJSONValue("Update"), "sha": AnyJSONValue("fromthecall")],
            threadID: "thread"
        )
        XCTAssertEqual(written.status, "ok")
        XCTAssertEqual(world.asked.requests.map(\.method), ["PUT"])
        XCTAssertEqual(world.asked.requests.last?.sent["sha"], "fromthecall")
        let approvals = await seen.approvals
        XCTAssertEqual(approvals.first?.details.contains("Replaces the file that is there"), true)

        let (denying, _) = try await writingWorld(approving: false, looked: (404, "{}"))
        defer { denying.forget() }
        let denied = await denying.call(
            "github.writeFile",
            ["repo": AnyJSONValue("octo/site"), "path": AnyJSONValue("README.md"), "content": AnyJSONValue("hello"), "commit_message": AnyJSONValue("Update")],
            threadID: "thread"
        )
        XCTAssertEqual(denied.status, "denied")
        XCTAssertEqual(denying.asked.requests.map(\.method), ["GET"], "It was looked at, and not written")
    }

    func testAWriteThatCannotLookFirst_orThatNamesNoFile_isNotAskedAbout() async throws {
        // A folder is at the path.
        let (folder, askedOfFolder) = try await writingWorld(looked: (200, #"[{"name": "a.md", "type": "file", "sha": "x"}]"#))
        defer { folder.forget() }
        let onAFolder = await folder.call(
            "github.writeFile",
            ["repo": AnyJSONValue("octo/site"), "path": AnyJSONValue("docs"), "content": AnyJSONValue("x"), "message": AnyJSONValue("x")],
            threadID: "thread"
        )
        XCTAssertEqual(onAFolder.status, "error")
        XCTAssertEqual(onAFolder.error?.contains("'docs' is a folder, not a file."), true)

        // GitHub will not say what is there.
        let (refusing, askedOfRefusing) = try await writingWorld(looked: (403, #"{"message": "Resource not accessible"}"#))
        defer { refusing.forget() }
        let unseen = await refusing.call(
            "github.writeFile",
            ["repo": AnyJSONValue("octo/site"), "path": AnyJSONValue("README.md"), "content": AnyJSONValue("x"), "message": AnyJSONValue("x")],
            threadID: "thread"
        )
        XCTAssertEqual(unseen.status, "error")
        XCTAssertEqual(unseen.error?.hasPrefix("Could not look at 'README.md' before writing it: "), true)

        // A path that is none, or that would reach another part of
        // GitHub's API, is refused before anything is asked of anyone.
        for path in ["../collaborators/someone", "docs/../../x", "docs//x", "", "/", "."] {
            let refused = await refusing.call(
                "github.writeFile",
                ["repo": AnyJSONValue("octo/site"), "path": AnyJSONValue(path), "content": AnyJSONValue("x"), "message": AnyJSONValue("x"), "sha": AnyJSONValue("abc")],
                threadID: "thread"
            )
            XCTAssertEqual(refused.errorType, "invalid_parameters", path)
            XCTAssertEqual(refused.field, "path", path)
        }
        // An empty commit message is none, and the other name is then read.
        let empty = await refusing.call("github.writeFile", ["repo": AnyJSONValue("octo/site"), "path": AnyJSONValue("a.md"), "content": AnyJSONValue("x"), "commit_message": AnyJSONValue("")], threadID: "thread")
        XCTAssertEqual(empty.error, "Missing required arguments: 'path', 'content', 'commit_message'")
        // With no thread there is no one to ask: nothing is looked up.
        let nowhere = await refusing.call("github.writeFile", ["repo": AnyJSONValue("octo/site"), "path": AnyJSONValue("a.md"), "content": AnyJSONValue("x"), "commit_message": AnyJSONValue(""), "message": AnyJSONValue("Add")])
        XCTAssertNotEqual(nowhere.status, "ok")
        XCTAssertNotEqual(nowhere.errorType, "invalid_parameters", "The other name's message was read")
        // No commit message by either name.
        let unsaid = await refusing.call("github.writeFile", ["repo": AnyJSONValue("octo/site"), "path": AnyJSONValue("a.md"), "content": AnyJSONValue("x")], threadID: "thread")
        XCTAssertEqual(unsaid.error, "Missing required arguments: 'path', 'content', 'commit_message'")

        XCTAssertEqual(folder.asked.requests.map(\.method), ["GET"])
        XCTAssertEqual(refusing.asked.requests.map(\.method), ["GET"])
        let approvalsOfFolder = await askedOfFolder.approvals
        let approvalsOfRefusing = await askedOfRefusing.approvals
        XCTAssertEqual(approvalsOfFolder.count + approvalsOfRefusing.count, 0, "The person was asked nothing")
    }

    func testABranchIsMadeFromTheArgumentsTheCloudNames_andANameThatIsNoneIsNotAskedAbout() async throws {
        // The person says no each time, so nothing is asked of GitHub.
        let (world, seen) = try await writingWorld(approving: false, looked: (500, "{}"))
        defer { world.forget() }

        _ = await world.call("github.createBranch", ["repo": AnyJSONValue("octo/site"), "base_ref": AnyJSONValue("main"), "new_branch": AnyJSONValue("fix/it")], threadID: "thread")
        _ = await world.call("github.createBranch", ["repo": AnyJSONValue("octo/site"), "base_branch": AnyJSONValue("release/2"), "branch": AnyJSONValue("fix-2")], threadID: "thread")
        var approvals = await seen.approvals
        XCTAssertEqual(approvals.map(\.details), ["fix/it in octo/site\nFrom main", "fix-2 in octo/site\nFrom release/2"])

        for (base, new, field) in [("../../user", "fix", "base_ref"), ("main", "../x", "new_branch"), ("main", "a//b", "new_branch"), ("", "fix", "base_ref"), ("main", "/", "new_branch")] {
            let refused = await world.call("github.createBranch", ["repo": AnyJSONValue("octo/site"), "base_ref": AnyJSONValue(base), "new_branch": AnyJSONValue(new)], threadID: "thread")
            XCTAssertEqual(refused.errorType, "invalid_parameters", "\(base) \(new)")
            XCTAssertEqual(refused.field, field, "\(base) \(new)")
        }
        let unnamed = await world.call("github.createBranch", ["repo": AnyJSONValue("octo/site"), "new_branch": AnyJSONValue("fix")], threadID: "thread")
        XCTAssertEqual(unnamed.error, "Missing required arguments: 'base_ref', 'new_branch'")

        approvals = await seen.approvals
        XCTAssertEqual(approvals.count, 2, "Only the two that named branches were asked about")
        XCTAssertEqual(world.asked.requests, [])
    }

    func testModelsAreToldTheWriteArgumentsAsTheCloudNamesThem() throws {
        let write = try XCTUnwrap(PromptTemplates.toolDefinitions.first { $0.name == "github.writeFile" })
        XCTAssertEqual(write.parameters.filter(\.required).map(\.name), ["repo", "path", "content", "commit_message"])
        XCTAssertEqual(write.parameters.filter { !$0.required }.map(\.name), ["branch", "sha"])
        let branch = try XCTUnwrap(PromptTemplates.toolDefinitions.first { $0.name == "github.createBranch" })
        XCTAssertEqual(branch.parameters.map(\.name), ["repo", "base_ref", "new_branch"])
    }

    /// The approvals that were asked.
    private actor Seen {
        private(set) var approvals: [ToolApproval] = []

        func note(_ approval: ToolApproval) {
            approvals.append(approval)
        }
    }

    func testAPullRequestToolCalledByItsOldName_isTheToolAsItIsNamedNow() async throws {
        let world = try await world { request in
            request.url?.path.hasSuffix("/files") == true
                ? (200, #"[{"filename": "a.swift", "status": "modified", "additions": 2, "deletions": 1, "patch": "@@ -1 +1,2 @@"}]"#)
                : (200, #"{"title": "Fix it", "state": "open", "html_url": "https://github.com/octo/site/pull/7", "head": {"ref": "fix"}, "base": {"ref": "main"}, "additions": 2, "deletions": 1, "changed_files": 1, "body": ""}"#)
        }
        defer { world.forget() }

        // The old name and arguments, though only the new name is allowed.
        let old = await world.call("github.getPR", ["owner": AnyJSONValue("octo"), "repo": AnyJSONValue("site"), "number": AnyJSONValue("7")])
        XCTAssertEqual(old.status, "ok")
        XCTAssertEqual(old.tool, "github.getPullRequest")
        XCTAssertEqual(old.contextBlock?.hasPrefix("[GitHub PR #7: Fix it]\nState: open\nBranch: fix → main"), true)

        let new = await world.call("github.getPullRequest", ["repo": AnyJSONValue("octo/site"), "pull_number": AnyJSONValue(7)])
        XCTAssertEqual(new.contextBlock, old.contextBlock)

        let files = await world.call("github.listPRFiles", ["repo": AnyJSONValue("octo/site"), "pull_number": AnyJSONValue(7), "page": AnyJSONValue(3), "per_page": AnyJSONValue(500)])
        XCTAssertEqual(files.status, "ok")
        XCTAssertEqual(files.tool, "github.listPullRequestFiles")
        XCTAssertEqual(files.contextBlock?.hasPrefix("[GitHub PR #7 Files (1 on page 3)]\n\nmodified: a.swift (+2 -1)"), true)

        XCTAssertEqual(world.asked.requests.map(\.path), ["/repos/octo/site/pulls/7", "/repos/octo/site/pulls/7", "/repos/octo/site/pulls/7/files"])
        XCTAssertEqual(world.asked.requests.last?.query, ["page": "3", "per_page": "100"], "The page asked for, and no more a page than GitHub gives")

        // A tool the agent is not allowed is not allowed by its old name
        // either.
        await world.executor.setWhitelist(for: "chat", tools: ["github.readFile"])
        let refused = await world.call("github.getPR", ["repo": AnyJSONValue("octo/site"), "pull_number": AnyJSONValue(7)])
        XCTAssertEqual(refused.errorType, "permission_denied")
        XCTAssertEqual(world.asked.requests.count, 3)
    }

    func testASearch_canBeKeptToARepositoryAndPaged_andSaysWhereEachResultIs() async throws {
        let world = try await world { _ in
            (200, #"{"total_count": 12, "items": [{"path": "Sources/A.swift", "repository": {"full_name": "octo/site"}}, {"path": "B.swift"}]}"#)
        }
        defer { world.forget() }

        let result = await world.call("github.searchCode", ["query": AnyJSONValue("ContentView extension:swift"), "repo": AnyJSONValue("octo/site"), "page": AnyJSONValue(2), "per_page": AnyJSONValue(5)])

        XCTAssertEqual(result.status, "ok")
        XCTAssertEqual(world.asked.requests, [.init(
            method: "GET",
            path: "/search/code",
            query: ["q": "ContentView extension:swift repo:octo/site", "page": "2", "per_page": "5"],
            authorization: "Bearer TEST_TOKEN"
        )])
        XCTAssertEqual(result.contextBlock, "[GitHub Code Search: ContentView extension:swift repo:octo/site]\nocto/site: Sources/A.swift\nB.swift\n(Page 2, 2 of 12 results)")

        // As before: a query alone, sent as it was written, the first page.
        // A repository given as null is one left out.
        let alone = await world.call("github.searchCode", ["query": AnyJSONValue(" ContentView "), "repo": .null])
        XCTAssertEqual(alone.status, "ok")
        XCTAssertEqual(world.asked.requests.last?.query, ["q": " ContentView ", "page": "1", "per_page": "30"])
    }

    func testASearchGitHubDidNotFinish_saysThereMayBeMore() async throws {
        let world = try await world { _ in (200, #"{"total_count": 1, "incomplete_results": true, "items": [{"path": "A.swift", "repository": {"full_name": "octo/site"}}]}"#) }
        defer { world.forget() }

        let result = await world.call("github.searchCode", ["query": AnyJSONValue("ContentView")])

        XCTAssertEqual(result.contextBlock, "[GitHub Code Search: ContentView]\nocto/site: A.swift\n(Page 1, 1 of 1 results; GitHub did not finish looking, so there may be more)")
    }

    // MARK: - Telling one call from another

    func testACallIsToldFromAnotherByAllItsArguments_andAQueryAloneIsItsQuery() {
        func signature(_ tool: String, _ arguments: [String: AnyJSONValue]) -> String {
            ChatService.repeatSignature(tool: tool, input: .dictionary(arguments))
        }
        func signature(_ arguments: [String: AnyJSONValue]) -> String {
            signature("github.listPullRequestFiles", arguments)
        }
        XCTAssertEqual(signature("web_search", ["query": AnyJSONValue("  Swift   Concurrency? ")]), "web_search|swift concurrency", "A query alone, loosely read, as it has been")
        XCTAssertEqual(signature("web_search", ["q": AnyJSONValue("swift")]), "web_search|swift")
        XCTAssertEqual(ChatService.repeatSignature(tool: "Shell.Execute", input: .string(" ls  -la ")), "shell.execute|ls -la")
        XCTAssertEqual(ChatService.repeatSignature(tool: "current_time", input: nil), "current_time|")

        let first = signature(["repo": AnyJSONValue("octo/site"), "pull_number": AnyJSONValue(7), "page": AnyJSONValue(1)])
        let second = signature(["page": AnyJSONValue(2), "pull_number": AnyJSONValue(7), "repo": AnyJSONValue("octo/site")])
        XCTAssertEqual(first, #"github.listpullrequestfiles|{"page":1,"pull_number":7,"repo":"octo/site"}"#)
        XCTAssertNotEqual(first, second, "The second page is not the first again")
        XCTAssertEqual(second, signature(["repo": AnyJSONValue("octo/site"), "pull_number": AnyJSONValue(7), "page": AnyJSONValue(2)]), "In whatever order the arguments came")
        XCTAssertNotEqual(signature("github.searchCode", ["query": AnyJSONValue("swift"), "page": AnyJSONValue(1)]), signature("github.searchCode", ["query": AnyJSONValue("swift"), "page": AnyJSONValue(2)]))

        // Arguments are told apart exactly: a path's case and spaces are part of it.
        let paths = ["A.md", "a.md", "A.MD", "A .md", "A  .md"].map { signature("github.readFile", ["repo": AnyJSONValue("octo/site"), "path": AnyJSONValue($0)]) }
        XCTAssertEqual(Set(paths).count, paths.count)
    }

    func testListFiles_tellsAFolderFromAFile_andTheTopOfARepositoryIsItsContents() async throws {
        let world = try await world { _ in (200, #"[{"name": "Sources", "type": "dir"}, {"name": "README.md", "type": "file"}]"#) }
        defer { world.forget() }

        let top = await world.call("github.listFiles", ["repo": AnyJSONValue("octo/site")])
        XCTAssertEqual(top.contextBlock, "[GitHub Files: octo/site/]\nSources/\nREADME.md")
        _ = await world.call("github.listFiles", ["repo": AnyJSONValue("octo/site"), "path": AnyJSONValue("/Sources/App/")])
        XCTAssertEqual(world.asked.requests.map(\.path), ["/repos/octo/site/contents", "/repos/octo/site/contents/Sources/App"])
    }
}
