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

    func testAnMCPServersWholeAddress_isKeptInTheKeychain_andThePreferencesKeepOnlyWhatIsShown() async throws {
        let (defaults, suite) = try defaultsOfThisTest()
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokens = InMemoryTokens()
        let address = "https://actions.example.com/mcp/sk-secret-path-key/sse?api_key=secret-query"
        let service = ConnectedAccountsService(currentUser: { "a" }, defaults: defaults, tokens: tokens.store)
        let made = try await service.createMCPServer(name: "Actions", serverUrl: address, transport: .streamableHttp, authType: .none)

        let stored = try XCTUnwrap(defaults.data(forKey: UserScope.scopedKey("mcp_servers", for: "a")))
        let text = String(decoding: stored, as: UTF8.self)
        XCTAssertFalse(text.contains("secret"), "Nothing of the address past its host is in the preferences")
        XCTAssertTrue(tokens.all.values.contains { $0.values.contains(address) }, "The whole address is in the Keychain")
        XCTAssertEqual(made.shownAddress, "https://actions.example.com/…")

        // Read back whole, by a service that starts afresh.
        let again = ConnectedAccountsService(currentUser: { "a" }, defaults: defaults, tokens: tokens.store)
        let read = await again.getMCPServer(id: made.id)
        XCTAssertEqual(read?.serverUrl, address)

        // Removed with the server.
        try await again.deleteMCPServer(id: made.id)
        XCTAssertFalse(tokens.all.values.contains { $0.values.contains(address) })
    }

    func testAnMCPServerKeptInThePreferencesBefore_isMovedToTheKeychain_andStillWorks() async throws {
        let (defaults, suite) = try defaultsOfThisTest()
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokens = InMemoryTokens()
        let address = "https://mcp.example.com/k/secret-in-path"
        let old = MCPServerAccount(
            id: "s1", name: "Old", serverUrl: address, transport: .streamableHttp, authType: .none, status: .connected,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let key = UserScope.scopedKey("mcp_servers", for: "a")
        try defaults.set(encoder.encode([old]), forKey: key)

        let service = ConnectedAccountsService(currentUser: { "a" }, defaults: defaults, tokens: tokens.store)
        let read = await service.getMCPServer(id: "s1")
        XCTAssertEqual(read?.serverUrl, address)
        let text = try String(decoding: XCTUnwrap(defaults.data(forKey: key)), as: UTF8.self)
        XCTAssertFalse(text.contains("secret"), "Moved out of the preferences as it is read")
        XCTAssertEqual(MCPServerAccount.shown("https://mcp.example.com"), "https://mcp.example.com")
        XCTAssertEqual(MCPServerAccount.shown("https://user:pass@mcp.example.com:8443/"), "https://mcp.example.com:8443")
    }

    /// Tokens kept in memory that can refuse to be read or written, as a
    /// locked Keychain does. Sendable by hand, under `lock`.
    private final class FlakyTokens: @unchecked Sendable {
        private let lock = NSLock()
        let kept = InMemoryTokens()
        private var reads = true
        private var writes = true

        func refuse(reads: Bool, writes: Bool) {
            lock.withLock {
                self.reads = !reads
                self.writes = !writes
            }
        }

        var store: ConnectedAccountsService.TokenStore {
            let inner = kept.store
            return ConnectedAccountsService.TokenStore(
                save: { [self] key, value, service in
                    guard lock.withLock({ writes }) else { throw NSError(domain: "Keychain", code: -25308) }
                    try inner.save(key, value, service)
                },
                load: { [self] key, service in lock.withLock { reads } ? inner.load(key, service) : nil },
                delete: inner.delete
            )
        }
    }

    func testAnAddressTheKeychainCannotReadNow_isNeitherUsedNorWrittenOver_andComesBackLater() async throws {
        let (defaults, suite) = try defaultsOfThisTest()
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokens = FlakyTokens()
        let address = "https://actions.example.com/mcp/sk-secret-path-key/sse"
        let made = try await ConnectedAccountsService(currentUser: { "a" }, defaults: defaults, tokens: tokens.store)
            .createMCPServer(name: "Actions", serverUrl: address, transport: .streamableHttp, authType: .none)

        // The Keychain is locked as a service starts afresh: the server is not
        // given with a short address, and a save of another keeps it as stored.
        tokens.refuse(reads: true, writes: false)
        let locked = ConnectedAccountsService(currentUser: { "a" }, defaults: defaults, tokens: tokens.store)
        let listed = await locked.getAllMCPServers()
        XCTAssertFalse(listed.contains { $0.id == made.id }, "Not given with an address that is not its own")
        _ = try await locked.createMCPServer(name: "Other", serverUrl: "https://other.example/mcp", transport: .streamableHttp, authType: .none)
        XCTAssertTrue(tokens.kept.all.values.contains { $0.values.contains(address) }, "The whole address is not written over")

        // Readable again: given whole.
        tokens.refuse(reads: false, writes: false)
        let back = await locked.getMCPServer(id: made.id)
        XCTAssertEqual(back?.serverUrl, address)
    }

    func testAKeychainThatRefusesAWrite_neverPutsAMovedAddressBackInThePreferences() async throws {
        let (defaults, suite) = try defaultsOfThisTest()
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokens = FlakyTokens()
        let address = "https://actions.example.com/mcp/sk-secret-path-key/sse"
        let service = ConnectedAccountsService(currentUser: { "a" }, defaults: defaults, tokens: tokens.store)
        let made = try await service.createMCPServer(name: "Actions", serverUrl: address, transport: .streamableHttp, authType: .none)

        tokens.refuse(reads: false, writes: true)
        _ = await service.cacheMCPTools([], forServerId: made.id)
        let key = UserScope.scopedKey("mcp_servers", for: "a")
        XCTAssertFalse(try String(decoding: XCTUnwrap(defaults.data(forKey: key)), as: UTF8.self).contains("secret"))

        // One the Keychain never held is kept whole rather than lost.
        let fresh = try await service.createMCPServer(name: "New", serverUrl: "https://new.example/k/fresh-secret", transport: .streamableHttp, authType: .none)
        XCTAssertTrue(try String(decoding: XCTUnwrap(defaults.data(forKey: key)), as: UTF8.self).contains("fresh-secret"))
        XCTAssertEqual(MCPServerAccount.shown("http://[::1]:8080/x"), "http://[::1]:8080/…")
        _ = fresh
    }

    func testATokenIsKeptUnderItsAccountsNames_andAnotherAccountNeitherReadsNorRemovesIt() async throws {
        let (defaults, suite) = try defaultsOfThisTest()
        defer { defaults.removePersistentDomain(forName: suite) }
        let who = Who("a")
        let tokens = InMemoryTokens()
        let service = ConnectedAccountsService(currentUser: { who.id }, defaults: defaults, tokens: tokens.store)

        let ofA = try await service.createMCPServer(name: "A's notes", serverUrl: "https://a.example/mcp", transport: .streamableHttp, authType: .bearer, token: "token-of-a")
        XCTAssertEqual(
            tokens.all,
            ["AICovenProviderKeys.a": ["mcp_server_token_\(ofA.id).a": "token-of-a", "mcp_server_address_\(ofA.id).a": "https://a.example/mcp"]],
            "As the Keychain names have always been spelled, the address beside the token"
        )
        let readByA = try await service.getMCPToken(forServerId: ofA.id)
        XCTAssertEqual(readByA, "token-of-a")

        who.signIn("b")
        let readByB = try await service.getMCPToken(forServerId: ofA.id)
        XCTAssertNil(readByB, "A's server is not B's, so B is given no token for it")
        try await service.deleteMCPServer(id: ofA.id)
        XCTAssertEqual(tokens.all["AICovenProviderKeys.a"]?.count, 2, "B removing it removes nothing of A's")

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

    func testASignInThatEndsAsAnotherAccount_isKeptForNobody() async throws {
        let (defaults, suite) = try defaultsOfThisTest()
        defer { defaults.removePersistentDomain(forName: suite) }
        let who = Who("a")
        let tokens = InMemoryTokens()
        let service = ConnectedAccountsService(currentUser: { who.id }, defaults: defaults, tokens: tokens.store)
        let bundle = OAuthTokenBundle(accessToken: "token-of-a", refreshToken: nil, tokenType: "Bearer", expiresAt: nil, scopes: ["repo"])

        // A begins signing in with GitHub; B is signed in by the time GitHub answers.
        let startedBy = await service.signedInAccount()
        who.signIn("b")
        do {
            _ = try await service.createAccount(provider: .github, displayName: "octocat", tokenBundle: bundle, startedBy: startedBy)
            XCTFail("A's sign-in was kept as B's")
        } catch ConnectedAccountError.accountChanged {}
        XCTAssertEqual(tokens.all, [:], "No token was kept, for either")
        let ofB = await service.getAllAccounts()
        XCTAssertEqual(ofB.map(\.displayName), [])
        who.signIn("a")
        let ofA = await service.getAllAccounts()
        XCTAssertEqual(ofA.map(\.displayName), [])

        // One that ends as the account that began it is kept.
        let again = await service.signedInAccount()
        _ = try await service.createAccount(provider: .github, displayName: "octocat", tokenBundle: bundle, startedBy: again)
        let kept = await service.getAllAccounts()
        XCTAssertEqual(kept.map(\.displayName), ["octocat"])
        XCTAssertEqual(Array(tokens.all.keys), ["AICovenProviderKeys.a"])
    }

    func testConnectionsAreTheSignedInAccounts_andAnotherAccountIsShownItsOwn() async throws {
        let (defaults, suite) = try defaultsOfThisTest()
        defer { defaults.removePersistentDomain(forName: suite) }
        let who = Who("a")
        let tokens = InMemoryTokens()
        let service = ConnectedAccountsService(currentUser: { who.id }, defaults: defaults, tokens: tokens.store)

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
        let afterwards = ConnectedAccountsService(currentUser: { "b" }, defaults: defaults, tokens: tokens.store)
        servers = await afterwards.getAllMCPServers()
        XCTAssertEqual(servers.map(\.id), [ofB.id])
        let accounts = await afterwards.getAllAccounts()
        XCTAssertEqual(accounts.count, 0)
    }
}
