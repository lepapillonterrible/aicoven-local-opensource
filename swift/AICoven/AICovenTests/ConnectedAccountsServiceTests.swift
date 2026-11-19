@testable import AICoven
import XCTest

/// Tokens kept in memory in place of the Keychain, by service and key.
/// Sendable by hand: `kept` is read and written under `lock`.
final class InMemoryTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [String: [String: String]] = [:]

    var all: [String: [String: String]] {
        lock.withLock { kept }
    }

    var store: ConnectedAccountsService.TokenStore {
        ConnectedAccountsService.TokenStore(
            save: { [self] key, value, service in lock.withLock { kept[service, default: [:]][key] = value } },
            load: { [self] key, service in lock.withLock { kept[service]?[key] } },
            delete: { [self] key, service in lock.withLock { kept[service]?[key] = nil } }
        )
    }
}

final class ConnectedAccountsServiceTests: XCTestCase {
    /// Who is signed in, as the test says. Sendable by hand: `id` is read
    /// and written under `lock`.
    private final class Who: @unchecked Sendable {
        private let lock = NSLock()
        private var signedIn: String

        init(_ id: String) {
            signedIn = id
        }

        var id: String {
            lock.withLock { signedIn }
        }

        func signIn(_ id: String) {
            lock.withLock { signedIn = id }
        }

        /// Who is signed in, and then at once another: the account changes
        /// as soon as it has been asked.
        func idAndThenSignIn(_ next: String) -> String {
            lock.withLock {
                let was = signedIn
                signedIn = next
                return was
            }
        }
    }

    private func defaultsOfThisTest() throws -> (UserDefaults, String) {
        let suite = "ConnectedAccountsServiceTests.\(UUID().uuidString)"
        return try (XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    func testATokenIsKeptUnderItsAccountsNames_andAnotherAccountNeitherReadsNorRemovesIt() async throws {
        let (defaults, suite) = try defaultsOfThisTest()
        defer { defaults.removePersistentDomain(forName: suite) }
        let who = Who("a")
        let tokens = InMemoryTokens()
        let service = ConnectedAccountsService(currentUser: { who.id }, defaults: defaults, tokens: tokens.store)

        let ofA = try await service.createMCPServer(name: "A's notes", serverUrl: "https://a.example/mcp", transport: .streamableHttp, authType: .bearer, token: "token-of-a")
        XCTAssertEqual(tokens.all, ["AICovenProviderKeys.a": ["mcp_server_token_\(ofA.id).a": "token-of-a"]], "As the Keychain names have always been spelled")
        let readByA = try await service.getMCPToken(forServerId: ofA.id)
        XCTAssertEqual(readByA, "token-of-a")

        who.signIn("b")
        let readByB = try await service.getMCPToken(forServerId: ofA.id)
        XCTAssertNil(readByB, "A's server is not B's, so B is given no token for it")
        try await service.deleteMCPServer(id: ofA.id)
        XCTAssertEqual(tokens.all["AICovenProviderKeys.a"]?.count, 1, "B removing it removes nothing of A's")

        who.signIn("a")
        let stillThere = try await service.getMCPToken(forServerId: ofA.id)
        XCTAssertEqual(stillThere, "token-of-a")
        try await service.deleteMCPServer(id: ofA.id)
        XCTAssertEqual(tokens.all["AICovenProviderKeys.a"], [:], "A removing it removes its token")
    }

    func testAConnectionBegunAsOneAccount_staysThatAccounts_thoughAnotherSignsInAtOnce() async throws {
        let (defaults, suite) = try defaultsOfThisTest()
        defer { defaults.removePersistentDomain(forName: suite) }
        let who = Who("a")
        let tokens = InMemoryTokens()
        // B signs in the moment the service has asked who is signed in.
        let service = ConnectedAccountsService(currentUser: { who.idAndThenSignIn("b") }, defaults: defaults, tokens: tokens.store)

        let ofA = try await service.createMCPServer(name: "A's notes", serverUrl: "https://a.example/mcp", transport: .streamableHttp, authType: .apiKey, token: "token-of-a")
        XCTAssertEqual(Array(tokens.all.keys), ["AICovenProviderKeys.a"], "The token is A's")

        // B, who is signed in from here on, has nothing of it.
        let servers = await service.getAllMCPServers()
        XCTAssertEqual(servers.map(\.id), [])
        let token = try await service.getMCPToken(forServerId: ofA.id)
        XCTAssertNil(token)

        // And it was kept as A's.
        let asA = ConnectedAccountsService(currentUser: { "a" }, defaults: defaults, tokens: tokens.store)
        let ofAAgain = await asA.getAllMCPServers()
        XCTAssertEqual(ofAAgain.map(\.id), [ofA.id])
        let tokenAgain = try await asA.getMCPToken(forServerId: ofA.id)
        XCTAssertEqual(tokenAgain, "token-of-a")
    }

    func testConnectionsAreTheSignedInAccounts_andAnotherAccountIsShownItsOwn() async throws {
        let (defaults, suite) = try defaultsOfThisTest()
        defer { defaults.removePersistentDomain(forName: suite) }
        let who = Who("a")
        let service = ConnectedAccountsService(currentUser: { who.id }, defaults: defaults, tokens: InMemoryTokens().store)

        let ofA = try await service.createMCPServer(name: "A's notes", serverUrl: "https://a.example/mcp", transport: .streamableHttp, authType: .none)
        var servers = await service.getAllMCPServers()
        XCTAssertEqual(servers.map(\.id), [ofA.id])

        // Another account signs in while the app runs.
        who.signIn("b")
        servers = await service.getAllMCPServers()
        XCTAssertEqual(servers.map(\.id), [], "A's server is not shown to B")
        let asB = await service.getMCPServer(id: ofA.id)
        XCTAssertNil(asB, "nor used by B")
        let cached = await service.cacheMCPTools([], forServerId: ofA.id)
        XCTAssertFalse(cached, "nor changed by B")
        let ofB = try await service.createMCPServer(name: "B's mail", serverUrl: "https://b.example/mcp", transport: .streamableHttp, authType: .none)

        who.signIn("a")
        servers = await service.getAllMCPServers()
        XCTAssertEqual(servers.map(\.id), [ofA.id], "B's server was not kept as A's")

        // What was kept is each account's own.
        let afterwards = ConnectedAccountsService(currentUser: { "b" }, defaults: defaults, tokens: InMemoryTokens().store)
        servers = await afterwards.getAllMCPServers()
        XCTAssertEqual(servers.map(\.id), [ofB.id])
        let accounts = await afterwards.getAllAccounts()
        XCTAssertEqual(accounts.count, 0)
    }
}
