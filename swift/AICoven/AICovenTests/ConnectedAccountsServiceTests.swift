@testable import AICoven
import XCTest

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
    }

    func testConnectionsAreTheSignedInAccounts_andAnotherAccountIsShownItsOwn() async throws {
        let suite = "ConnectedAccountsServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let who = Who("a")
        let service = ConnectedAccountsService(currentUser: { who.id }, defaults: defaults)

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
        let afterwards = ConnectedAccountsService(currentUser: { "b" }, defaults: defaults)
        servers = await afterwards.getAllMCPServers()
        XCTAssertEqual(servers.map(\.id), [ofB.id])
        let accounts = await afterwards.getAllAccounts()
        XCTAssertEqual(accounts.count, 0)
    }
}
