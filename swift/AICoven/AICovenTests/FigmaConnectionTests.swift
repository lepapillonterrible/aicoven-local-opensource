@testable import AICoven
import XCTest

/// Figma is connected with a personal access token, which is checked with
/// Figma, kept in the Keychain, and belongs to one Figma account.
final class FigmaConnectionTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Who a token belongs to

    /// What Figma was asked. Sendable by hand: `kept` is read and written
    /// under `lock`.
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [URLRequest] = []

        var requests: [URLRequest] {
            lock.withLock { kept }
        }

        func note(_ request: URLRequest) {
            lock.withLock { kept.append(request) }
        }
    }

    private func session(keeping asked: Asked, status: Int, body: String, headers: [String: String] = [:]) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { request in
            asked.note(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
            return (response, Data(body.utf8))
        }
        return URLSession(configuration: config)
    }

    func testATokensOwnerIsAskedOfFigma_withTheTokenInFigmasHeaderOnly() async throws {
        let asked = Asked()
        let who = try await FigmaToolService.identity(token: "figd_TEST", session: session(keeping: asked, status: 200, body: #"{"id": "42", "email": "ada@example.com", "handle": "Ada"}"#))

        XCTAssertEqual(who, .init(id: "42", label: "ada@example.com"))
        let request = try XCTUnwrap(asked.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.figma.com/v1/me")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Figma-Token"), "figd_TEST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(asked.requests.count, 1)

        let byHandle = try await FigmaToolService.identity(token: "t", session: session(keeping: Asked(), status: 200, body: #"{"id": "42", "email": "", "handle": "Ada"}"#))
        XCTAssertEqual(byHandle.label, "Ada")
        let unnamed = try await FigmaToolService.identity(token: "t", session: session(keeping: Asked(), status: 200, body: #"{"id": "42"}"#))
        XCTAssertEqual(unnamed.label, "Figma")
    }

    func testWhatFigmaAnswersToATokenItDoesNotTake() async {
        func refusal(_ status: Int, _ body: String = "{}", headers: [String: String] = [:]) async -> FigmaError? {
            do {
                _ = try await FigmaToolService.identity(token: "t", session: session(keeping: Asked(), status: status, body: body, headers: headers))
                return nil
            } catch {
                return error as? FigmaError
            }
        }
        var answer = await refusal(401)
        XCTAssertEqual(answer, .tokenRefused)
        answer = await refusal(403)
        XCTAssertEqual(answer, .tokenRefused)
        answer = await refusal(429, headers: ["Retry-After": "30"])
        XCTAssertEqual(answer, .rateLimited(retryAfter: 30))
        answer = await refusal(429)
        XCTAssertEqual(answer, .rateLimited(retryAfter: nil))
        answer = await refusal(500)
        XCTAssertEqual(answer, .notAnswered(status: 500))
        answer = await refusal(200, #"{"email": "ada@example.com"}"#)
        XCTAssertEqual(answer, .invalidResponse, "An answer that names no user")
        answer = await refusal(200, "not json")
        XCTAssertEqual(answer, .invalidResponse)
    }

    // MARK: - Connecting

    /// Figma, as the connection is told of it: who each token belongs to,
    /// and which tokens it was asked about. Sendable by hand: all of it is
    /// read and written under `lock`.
    private final class Figma: @unchecked Sendable {
        private let lock = NSLock()
        private var owners: [String: FigmaToolService.Identity] = [:]
        private var asked: [String] = []
        private var whileAsked: (@Sendable () async -> Void)?
        private var failure: FigmaError?

        var tokensAskedAbout: [String] {
            lock.withLock { asked }
        }

        func takes(_ token: String, of id: String, _ label: String) {
            lock.withLock { owners[token] = .init(id: id, label: label) }
        }

        func fails(_ error: FigmaError?) {
            lock.withLock { failure = error }
        }

        /// What happens while Figma is next asked, before it answers.
        func duringTheNextQuestion(_ happens: @escaping @Sendable () async -> Void) {
            lock.withLock { whileAsked = happens }
        }

        func identity(_ token: String) async throws -> FigmaToolService.Identity {
            let happens: (@Sendable () async -> Void)? = lock.withLock {
                asked.append(token)
                defer { whileAsked = nil }
                return whileAsked
            }
            await happens?()
            return try lock.withLock {
                if let failure { throw failure }
                guard let owner = owners[token] else { throw FigmaError.tokenRefused }
                return owner
            }
        }
    }

    /// Who is signed in to the app. Sendable by hand, under `lock`.
    private final class Who: @unchecked Sendable {
        private let lock = NSLock()
        private var signedIn = "a"
        private var asksUntilCalledOff: Int?

        /// Who is signed in. (Where a test says so, the task that asks for
        /// the nth time from now is called off as it asks.)
        var id: String {
            let callOff: Bool = lock.withLock {
                guard let left = asksUntilCalledOff else { return false }
                asksUntilCalledOff = left > 1 ? left - 1 : nil
                return left == 1
            }
            if callOff { withUnsafeCurrentTask { $0?.cancel() } }
            return lock.withLock { signedIn }
        }

        func callOffTheTaskThatAsks(nth: Int) {
            lock.withLock { asksUntilCalledOff = nth }
        }

        func signIn(_ id: String) {
            lock.withLock { signedIn = id }
        }
    }

    private struct World {
        let service: ConnectedAccountsService
        let figma: Figma
        let tokens: InMemoryTokens
        let who: Who
        let defaults: UserDefaults
        let suite: String

        func forget() {
            defaults.removePersistentDomain(forName: suite)
        }

        /// The tokens kept for the account signed in as `user`, by name.
        func kept(for user: String = "a") -> [String: String] {
            tokens.all["AICovenProviderKeys.\(user)"] ?? [:]
        }
    }

    private func world() throws -> World {
        let suite = "FigmaConnectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let figma = Figma()
        let tokens = InMemoryTokens()
        let who = Who()
        let service = ConnectedAccountsService(currentUser: { who.id }, defaults: defaults, tokens: tokens.store, figmaIdentity: { try await figma.identity($0) })
        return World(service: service, figma: figma, tokens: tokens, who: who, defaults: defaults, suite: suite)
    }

    func testATokenFigmaAccepts_connectsFigma_andIsKeptInTheKeychainOnly() async throws {
        let world = try world()
        defer { world.forget() }
        world.figma.takes("figd_one", of: "42", "ada@example.com")

        let account = try await world.service.connectFigma(token: "  figd_one\n")

        XCTAssertEqual(account.provider, .figma)
        XCTAssertEqual(account.status, .connected)
        XCTAssertEqual(account.displayName, "ada@example.com")
        XCTAssertEqual(account.metadata, ["figma_user_id": "42", "source": "personal_access_token"])
        XCTAssertEqual(world.figma.tokensAskedAbout, ["figd_one"], "Asked about the token without the space around it")
        let connected = await world.service.getConnectedAccount(for: .figma)
        XCTAssertEqual(connected?.id, account.id)
        let token = try await world.service.getAccessToken(forAccountId: account.id)
        XCTAssertEqual(token, "figd_one")
        XCTAssertEqual(Array(world.kept().keys), ["connected_account_token_\(account.id).a"])
        // What is kept with the list of accounts has nothing of the token.
        let listed = try XCTUnwrap(world.defaults.data(forKey: "a.connected_accounts"))
        XCTAssertFalse(String(decoding: listed, as: UTF8.self).contains("figd_one"))
    }

    func testWhatIsNoToken_orIsRefused_isNotKept_andFigmaIsNotAskedAboutWhatIsNoToken() async throws {
        let world = try world()
        defer { world.forget() }

        func refusal(_ token: String) async -> ConnectedAccountsService.FigmaTokenRefusal? {
            do {
                _ = try await world.service.connectFigma(token: token)
                return nil
            } catch {
                return error as? ConnectedAccountsService.FigmaTokenRefusal
            }
        }
        var why = await refusal("   ")
        XCTAssertEqual(why, .notAToken)
        why = await refusal(String(repeating: "a", count: FigmaToolService.longestToken + 1))
        XCTAssertEqual(why, .notAToken)
        XCTAssertEqual(world.figma.tokensAskedAbout, [], "Figma is not sent what is no token")

        why = await refusal("figd_wrong")
        XCTAssertEqual(why, .refused)
        // Figma does not answer: the error is Figma's, and nothing is kept.
        world.figma.fails(.notAnswered(status: 503))
        do {
            _ = try await world.service.connectFigma(token: "figd_one")
            XCTFail("Figma did not answer")
        } catch {
            XCTAssertEqual(error as? FigmaError, .notAnswered(status: 503))
        }

        let accounts = await world.service.getAllAccounts()
        XCTAssertEqual(accounts.count, 0)
        XCTAssertEqual(world.kept(), [:])
    }

    func testConnectingAgain_putsTheEarlierConnectionDownWithItsToken() async throws {
        let world = try world()
        defer { world.forget() }
        world.figma.takes("figd_one", of: "42", "ada@example.com")
        world.figma.takes("figd_two", of: "77", "grace@example.com")

        let first = try await world.service.connectFigma(token: "figd_one")
        let second = try await world.service.connectFigma(token: "figd_two")

        let accounts = await world.service.getAllAccounts()
        XCTAssertEqual(accounts.map(\.id), [second.id], "One Figma connection")
        XCTAssertEqual(Array(world.kept().keys), ["connected_account_token_\(second.id).a"], "The earlier token is gone")
        XCTAssertNotEqual(first.id, second.id)
    }

    func testANewTokenForAConnection_mustBeOfTheSameFigmaAccount() async throws {
        let world = try world()
        defer { world.forget() }
        world.figma.takes("figd_one", of: "42", "ada@example.com")
        world.figma.takes("figd_new", of: "42", "ada@new.example.com")
        world.figma.takes("figd_other", of: "77", "grace@example.com")
        var account = try await world.service.connectFigma(token: "figd_one")
        // Figma has refused its token: it waits for a new one.
        account.status = .error
        await world.service.updateAccount(account)
        let waiting = await world.service.figmaAccountNeedingAToken()
        XCTAssertEqual(waiting?.id, account.id)
        let none = await world.service.getConnectedAccount(for: .figma)
        XCTAssertNil(none, "A connection that waits for a token is not used")

        do {
            _ = try await world.service.connectFigma(token: "figd_other", replacing: account.id)
            XCTFail("Another Figma account's token")
        } catch {
            XCTAssertEqual(error as? ConnectedAccountsService.FigmaTokenRefusal, .otherAccount)
        }
        var kept = try await world.service.getTokenBundle(forAccountId: account.id)
        XCTAssertEqual(kept.accessToken, "figd_one", "The token it had is still the one kept")

        let renewed = try await world.service.connectFigma(token: "figd_new", replacing: account.id)
        XCTAssertEqual(renewed.id, account.id)
        XCTAssertEqual(renewed.status, .connected)
        XCTAssertEqual(renewed.displayName, "ada@new.example.com")
        kept = try await world.service.getTokenBundle(forAccountId: account.id)
        XCTAssertEqual(kept.accessToken, "figd_new")
        let stillWaiting = await world.service.figmaAccountNeedingAToken()
        XCTAssertNil(stillWaiting)

        do {
            _ = try await world.service.connectFigma(token: "figd_new", replacing: "gone")
            XCTFail("No such connection")
        } catch {
            XCTAssertEqual(error as? ConnectedAccountsService.FigmaTokenRefusal, .changed)
        }
    }

    func testATokenCheckedWhileAnotherAccountSignsIn_isKeptForNoOne() async throws {
        let world = try world()
        defer { world.forget() }
        world.figma.takes("figd_one", of: "42", "ada@example.com")
        world.figma.duringTheNextQuestion { world.who.signIn("b") }

        do {
            _ = try await world.service.connectFigma(token: "figd_one")
            XCTFail("The account changed while Figma was asked")
        } catch {
            XCTAssertEqual(error as? ConnectedAccountsService.FigmaTokenRefusal, .changed)
        }

        XCTAssertEqual(world.tokens.all.values.flatMap(\.keys), [], "No token is kept, under either account")
        let ofB = await world.service.getAllAccounts()
        XCTAssertEqual(ofB.count, 0)
        world.who.signIn("a")
        let ofA = await world.service.getAllAccounts()
        XCTAssertEqual(ofA.count, 0)
    }

    func testATokenWhoseCheckWasOvertaken_isNotKept() async throws {
        let world = try world()
        defer { world.forget() }
        world.figma.takes("figd_one", of: "42", "ada@example.com")
        world.figma.takes("figd_two", of: "42", "ada@example.com")

        // While Figma is asked about the first token, the person gives a
        // second, which is taken.
        let newer = Newer()
        world.figma.duringTheNextQuestion {
            await newer.note(try? world.service.connectFigma(token: "figd_two"))
        }
        do {
            _ = try await world.service.connectFigma(token: "figd_one")
            XCTFail("A newer token was given meanwhile")
        } catch {
            XCTAssertEqual(error as? ConnectedAccountsService.FigmaTokenRefusal, .changed)
        }
        let taken = await newer.account
        let second = try XCTUnwrap(taken)
        let kept = try await world.service.getTokenBundle(forAccountId: second.id)
        XCTAssertEqual(kept.accessToken, "figd_two", "The newer token is the one kept")
        let accounts = await world.service.getAllAccounts()
        XCTAssertEqual(accounts.map(\.id), [second.id])

        // While Figma is asked about a new token for the connection, the
        // person disconnects it: it is not connected again.
        var account = second
        account.status = .error
        await world.service.updateAccount(account)
        world.figma.takes("figd_three", of: "42", "ada@example.com")
        world.figma.duringTheNextQuestion {
            await world.service.disconnectAccount(id: second.id)
        }
        do {
            _ = try await world.service.connectFigma(token: "figd_three", replacing: second.id)
            XCTFail("It was disconnected meanwhile")
        } catch {
            XCTAssertEqual(error as? ConnectedAccountsService.FigmaTokenRefusal, .changed)
        }
        let after = await world.service.getAllAccounts()
        XCTAssertEqual(after.map(\.status), [.disconnected])
        XCTAssertEqual(world.kept(), [:], "No token is kept for a connection that was disconnected")
        // Nor is a disconnected connection given a token afterwards.
        do {
            _ = try await world.service.connectFigma(token: "figd_three", replacing: second.id)
            XCTFail("A disconnected connection takes no new token")
        } catch {
            XCTAssertEqual(error as? ConnectedAccountsService.FigmaTokenRefusal, .changed)
        }
        XCTAssertEqual(world.kept(), [:])
    }

    /// The connection a newer token made.
    private actor Newer {
        private(set) var account: ConnectedAccount?

        func note(_ account: ConnectedAccount?) {
            self.account = account
        }
    }

    func testAClosedSheetsToken_isNotKept() async throws {
        let world = try world()
        defer { world.forget() }
        world.figma.takes("figd_one", of: "42", "ada@example.com")

        // The check is called off while Figma is asked (the question is
        // asked within the check's own task).
        world.figma.duringTheNextQuestion { withUnsafeCurrentTask { $0?.cancel() } }
        let checking = Task { try await world.service.connectFigma(token: "figd_one") }
        do {
            _ = try await checking.value
            XCTFail("The check was called off")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        var accounts = await world.service.getAllAccounts()
        XCTAssertEqual(accounts.count, 0)
        XCTAssertEqual(world.kept(), [:])

        // Called off later still: after Figma answered, while the service
        // asks once more who is signed in (its second ask), which is the
        // last thing it waits for.
        world.who.callOffTheTaskThatAsks(nth: 2)
        let late = Task { try await world.service.connectFigma(token: "figd_one") }
        do {
            _ = try await late.value
            XCTFail("The check was called off")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        accounts = await world.service.getAllAccounts()
        XCTAssertEqual(accounts.count, 0)
        XCTAssertEqual(world.kept(), [:])
    }

    func testATokenThatIsPasted_isNotRefreshed_andItsConnectionIsLeftAsItIs() async throws {
        let world = try world()
        defer { world.forget() }
        world.figma.takes("figd_one", of: "42", "ada@example.com")
        let account = try await world.service.connectFigma(token: "figd_one")
        let bundle = try await world.service.getTokenBundle(forAccountId: account.id)

        do {
            _ = try await world.service.refreshAccessToken(forAccount: account, currentBundle: bundle)
            XCTFail("A pasted token is not refreshed")
        } catch ConnectedAccountError.refreshNotSupported(provider: .figma) {
            // As it should be.
        }

        let after = await world.service.getConnectedAccount(for: .figma)
        XCTAssertEqual(after?.status, .connected, "It is not marked as refused")
    }

    // MARK: - What the person is told, and who may use it

    func testWhatTheSheetSaysOfATokenThatWasNotTaken() {
        typealias Refusal = ConnectedAccountsService.FigmaTokenRefusal
        XCTAssertEqual(FigmaTokenSheet.message(for: Refusal.refused), "Figma didn't accept this token. Check that it's copied whole and hasn't expired.")
        XCTAssertEqual(FigmaTokenSheet.message(for: Refusal.notAToken), FigmaTokenSheet.message(for: Refusal.refused))
        XCTAssertEqual(FigmaTokenSheet.message(for: Refusal.otherAccount), "This token belongs to a different Figma account. Create one from the account being replaced.")
        XCTAssertEqual(FigmaTokenSheet.message(for: Refusal.changed), "This Figma connection changed while the token was checked. Close this and try again.")
        XCTAssertEqual(FigmaTokenSheet.message(for: FigmaError.notAnswered(status: 500)), "Figma didn't answer. Try again.")
        XCTAssertEqual(FigmaTokenSheet.message(for: URLError(.notConnectedToInternet)), "Figma didn't answer. Try again.")
        XCTAssertEqual(FigmaTokenSheet.scopes.map(\.0), ["current_user:read", "file_content:read", "file_comments:read", "file_comments:write"])
    }

    func testFigmaIsAConnectedApp_underACovensChoiceAndTheToolsPack() async {
        XCTAssertEqual(ConnectedAppProvider.allCases, [.github, .googleDrive, .figma])
        XCTAssertTrue(ConnectedAppProvider.figma.connectsWithToken)
        XCTAssertFalse(ConnectedAppProvider.github.connectsWithToken)
        XCTAssertFalse(ConnectedAppProvider.googleDrive.connectsWithToken)
        XCTAssertEqual(ConnectedAppProvider.figma.rawValue, "figma")

        XCTAssertEqual(CovenConnectionRules.app(of: "figma.readFile"), "figma")
        XCTAssertNil(CovenConnectionRules.app(of: "figmatic.readFile"))
        XCTAssertEqual(CovenConnectionRules.decision(forAppTool: "figma.readFile", in: CovenConnections(apps: ["github": .readWrite])), .notOn)
        XCTAssertEqual(CovenConnectionRules.decision(forAppTool: "figma.readFile", in: CovenConnections(apps: ["figma": .readOnly])), .allowed)
        XCTAssertEqual(CovenConnections.everything(apps: ConnectedAppProvider.allCases.map(\.rawValue), mcpServers: []).apps["figma"], .readWrite)

        // A tool of Figma's is refused where the coven has Figma off, in
        // Figma's name, and where the Tools Pack was not bought.
        let off = ToolExecutionService(toolService: ToolService.shared, covenConnections: { _ in CovenConnections(apps: ["github": .readOnly]) }, hasToolsPack: { true })
        await off.setWhitelist(for: "chat", tools: ["figma.readFile"])
        let refused = await off.execute(toolCall: ParsedToolCall(name: "figma.readFile", args: [:]), agentType: "chat", threadID: "thread")
        XCTAssertEqual(refused.errorType, "connection_not_on")
        XCTAssertEqual(refused.error?.hasPrefix("Figma is not turned on in this coven"), true)

        let unpaid = ToolExecutionService(toolService: ToolService.shared, hasToolsPack: { false })
        await unpaid.setWhitelist(for: "chat", tools: ["figma.readFile"])
        let locked = await unpaid.execute(toolCall: ParsedToolCall(name: "figma.readFile", args: [:]), agentType: "chat", threadID: "thread")
        XCTAssertEqual(locked.errorType, "entitlement_required")

        XCTAssertEqual(ChatService.friendlyToolName("figma.readFile"), "Figma")
    }
}
