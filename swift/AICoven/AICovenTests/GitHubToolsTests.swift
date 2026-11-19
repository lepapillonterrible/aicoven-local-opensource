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
        XCTAssertEqual(read(["owner": AnyJSONValue("Octo"), "repo": AnyJSONValue(" octo/site.io ")]), "octo/site.io", "Both, where they agree")
        XCTAssertEqual(read(["repo": AnyJSONValue("octo_org/my-site_2")]), "octo_org/my-site_2")

        XCTAssertNil(read(["owner": AnyJSONValue("someone"), "repo": AnyJSONValue("octo/site")]), "Two owners is no repository")
        XCTAssertNil(read(["repo": AnyJSONValue("site")]), "A name with no owner")
        XCTAssertNil(read(["owner": AnyJSONValue("octo")]))
        XCTAssertNil(read([:]))
        XCTAssertNil(read(["repo": AnyJSONValue(42)]))
        for notOne in ["octo/site/extra", "octo/", "/site", "../site", "octo/..", "octo/.", "octo/si te", "octo/site?x=1", "octo/site#x", "octo/si%2Fte", "öcto/site"] {
            XCTAssertNil(read(["repo": AnyJSONValue(notOne)]), "\(notOne) does not read as a repository")
        }
        XCTAssertNil(read(["owner": AnyJSONValue("octo/x"), "repo": AnyJSONValue("site")]))
    }

    func testNumbersAreReadAsNumbersOrDigits_andPagesStayWithinWhatGitHubTakes() {
        XCTAssertEqual(GitHubToolArguments.pullNumber(in: ["pull_number": AnyJSONValue(7)]), 7)
        XCTAssertEqual(GitHubToolArguments.pullNumber(in: ["pull_number": AnyJSONValue("7")]), 7)
        XCTAssertEqual(GitHubToolArguments.pullNumber(in: ["number": AnyJSONValue(7.0)]), 7)
        XCTAssertNil(GitHubToolArguments.pullNumber(in: ["pull_number": AnyJSONValue(0)]))
        XCTAssertNil(GitHubToolArguments.pullNumber(in: ["pull_number": AnyJSONValue(-3)]))
        XCTAssertNil(GitHubToolArguments.pullNumber(in: ["pull_number": AnyJSONValue(7.5)]))
        XCTAssertNil(GitHubToolArguments.pullNumber(in: ["pull_number": AnyJSONValue("7/files")]))
        XCTAssertNil(GitHubToolArguments.pullNumber(in: [:]))

        XCTAssertEqual(GitHubToolArguments.page(in: [:]), 1)
        XCTAssertEqual(GitHubToolArguments.page(in: ["page": AnyJSONValue(3)]), 3)
        XCTAssertEqual(GitHubToolArguments.page(in: ["page": AnyJSONValue(0)]), 1)
        XCTAssertEqual(GitHubToolArguments.perPage(in: [:], standard: 30), 30)
        XCTAssertEqual(GitHubToolArguments.perPage(in: ["per_page": AnyJSONValue(500)], standard: 30), 100)
        XCTAssertEqual(GitHubToolArguments.perPage(in: ["per_page": AnyJSONValue("5")], standard: 30), 5)
        XCTAssertEqual(GitHubToolArguments.perPage(in: ["per_page": AnyJSONValue(-1)], standard: 30), 1)
    }

    func testTwoToolsAreCalledByTheCloudsNames_andTheirOldNamesAreThoseTools() {
        XCTAssertEqual(GitHubToolArguments.offeredName(of: "github.getPR"), "github.getPullRequest")
        XCTAssertEqual(GitHubToolArguments.offeredName(of: "github.listPRFiles"), "github.listPullRequestFiles")
        XCTAssertEqual(GitHubToolArguments.offeredName(of: "github.readFile"), "github.readFile")
        XCTAssertEqual(GitHubToolArguments.offeredName(of: "file.read"), "file.read")

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
                path: components?.percentEncodedPath ?? "",
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

    func testAWriteNamesItsRepositoryTheSameWay_andAPathThatClimbsOutIsNotSentThoughApproved() async throws {
        let seen = Seen()
        let world = try await world(ask: { approval in
            await seen.note(approval)
            return .approved
        }, answer: { _ in (201, "{}") })
        defer { world.forget() }

        let written = await world.call(
            "github.writeFile",
            ["repo": AnyJSONValue("octo/site"), "path": AnyJSONValue("docs/new.md"), "content": AnyJSONValue("hello"), "message": AnyJSONValue("Add a page")],
            threadID: "thread"
        )
        XCTAssertEqual(written.status, "ok")
        let first = await seen.approvals.first
        XCTAssertEqual(first?.details.hasPrefix("docs/new.md in octo/site, on the default branch"), true, "The person is asked about the repository the call named")
        XCTAssertEqual(world.asked.requests.map(\.method), ["PUT"])
        XCTAssertEqual(world.asked.requests.map(\.path), ["/repos/octo/site/contents/docs/new.md"])

        // A path that would reach another part of GitHub's API is not sent,
        // whatever was approved.
        let climbing = await world.call(
            "github.writeFile",
            ["repo": AnyJSONValue("octo/site"), "path": AnyJSONValue("../collaborators/someone"), "content": AnyJSONValue("x"), "message": AnyJSONValue("x")],
            threadID: "thread"
        )
        XCTAssertEqual(climbing.status, "error")
        XCTAssertEqual(world.asked.requests.count, 1)
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

        // As before: a query alone, the first page.
        _ = await world.call("github.searchCode", ["query": AnyJSONValue("ContentView")])
        XCTAssertEqual(world.asked.requests.last?.query, ["q": "ContentView", "page": "1", "per_page": "30"])
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
