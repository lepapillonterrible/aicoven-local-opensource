@testable import AICoven
import GRDB
import XCTest

/// A coven chooses which of the person's connections its agents may use,
/// and whether to read only or to make changes too.
final class CovenConnectionsTests: XCTestCase {
    private func server(_ id: String, tools: [(name: String, readsOnly: Bool)]) -> MCPServerAccount {
        MCPServerAccount(
            id: id, name: "Server \(id)", serverUrl: "https://\(id).example.com/mcp", transport: .streamableHttp, authType: .none, status: .connected,
            cachedTools: tools.map { MCPToolDefinition(name: $0.name, description: nil, inputSchema: ["type": "object"], readOnlyHint: $0.readsOnly) },
            toolsCachedAt: Date(), createdAt: Date(), updatedAt: Date()
        )
    }

    // MARK: - The rules

    func testATool_belongsToItsConnectedAppOrToNone() {
        XCTAssertEqual(CovenConnectionRules.app(of: "github.readFile"), "github")
        XCTAssertEqual(CovenConnectionRules.app(of: "GitHub.create_pr"), "github")
        XCTAssertEqual(CovenConnectionRules.app(of: "google_drive.listFiles"), "google_drive")
        XCTAssertEqual(CovenConnectionRules.app(of: "google_sheets.readValues"), "google_drive", "One Google connection carries Drive and Sheets")
        for tool in ["web_search", "file.write", "shell.execute", "image.generate", "mcp.github.read", "githubby.read"] {
            XCTAssertNil(CovenConnectionRules.app(of: tool), tool)
        }

        for tool in ["github.writeFile", "github.write_file", "github.createBranch", "github.create_branch", "github.createPR", "github.create_pr", "google_drive.uploadFile", "google_drive.upload_file", "google_sheets.writeValues", "google_sheets.write_values"] {
            XCTAssertTrue(CovenConnectionRules.isWriteTool(tool), tool)
        }
        for tool in ["github.readFile", "github.listRepos", "github.searchCode", "github.getPR", "github.listPRFiles", "google_drive.listFiles", "google_drive.readFile", "google_sheets.readValues", "file.write"] {
            XCTAssertFalse(CovenConnectionRules.isWriteTool(tool), tool)
        }
        // Only the spellings the executor takes: anything else is no tool of its.
        for tool in ["github.create__pr", "googledrive.uploadFile", "GitHub.createPR", "github.createpr", "github.writefile_"] {
            XCTAssertFalse(CovenConnectionRules.isWriteTool(tool), tool)
        }
    }

    func testWhatACovensChoiceSaysOfATool() {
        // No choice (a personal thread, or a coven that has not chosen).
        XCTAssertEqual(CovenConnectionRules.decision(forAppTool: "github.createPR", in: nil), .allowed)
        XCTAssertEqual(CovenConnectionRules.decision(forToolMarkedReadOnly: false, ofMCPServer: "s", in: nil), .allowed)

        let choice = CovenConnections(apps: ["github": .readOnly], mcpServers: ["reads": .readOnly, "writes": .readWrite])
        XCTAssertEqual(CovenConnectionRules.decision(forAppTool: "github.readFile", in: choice), .allowed)
        XCTAssertEqual(CovenConnectionRules.decision(forAppTool: "github.create_pr", in: choice), .readOnly)
        XCTAssertEqual(CovenConnectionRules.decision(forAppTool: "google_drive.listFiles", in: choice), .notOn, "Not named: not used at all")
        XCTAssertEqual(CovenConnectionRules.decision(forAppTool: "web_search", in: choice), .allowed, "Not a connection's tool")
        XCTAssertEqual(CovenConnectionRules.decision(forAppTool: "github.createPR", in: CovenConnections(apps: ["github": .readWrite])), .allowed)
        XCTAssertEqual(CovenConnectionRules.decision(forAppTool: "github.readFile", in: CovenConnections()), .notOn, "A choice of nothing")

        XCTAssertEqual(CovenConnectionRules.decision(forToolMarkedReadOnly: true, ofMCPServer: "reads", in: choice), .allowed)
        XCTAssertEqual(CovenConnectionRules.decision(forToolMarkedReadOnly: false, ofMCPServer: "reads", in: choice), .readOnly, "Not marked: taken for one that changes things")
        XCTAssertEqual(CovenConnectionRules.decision(forToolMarkedReadOnly: false, ofMCPServer: "writes", in: choice), .allowed)
        XCTAssertEqual(CovenConnectionRules.decision(forToolMarkedReadOnly: true, ofMCPServer: "another", in: choice), .notOn)

        XCTAssertNil(CovenConnectionRules.refusal(.allowed, tool: "github.readFile", connection: "GitHub"))
        XCTAssertEqual(CovenConnectionRules.refusal(.notOn, tool: "github.readFile", connection: "GitHub")?.code, "connection_not_on")
        XCTAssertEqual(
            CovenConnectionRules.refusal(.readOnly, tool: "github.createPR", connection: "GitHub")?.message,
            "GitHub is on to read only in this coven, and 'github.createPR' changes something (or is not marked as read-only). The person can allow changes in this coven's Connections."
        )
    }

    func testWhatATurnIsOffered_isWhatItsCovenLets() {
        let tools: Set = ["web_search", "file.write", "github.readFile", "github.createPR", "google_drive.listFiles", "google_sheets.writeValues"]
        let servers = [
            server("reads", tools: [("look", true), ("change", false)]),
            server("writes", tools: [("look", true), ("change", false)]),
            server("marks-none", tools: [("change", false)]),
            server("off", tools: [("look", true)]),
        ]

        let all = CovenConnectionRules.offered(tools: tools, servers: servers, in: nil)
        XCTAssertEqual(all.tools, tools)
        XCTAssertEqual(all.servers, servers)

        let choice = CovenConnections(apps: ["github": .readOnly], mcpServers: ["reads": .readOnly, "writes": .readWrite, "marks-none": .readOnly])
        let offered = CovenConnectionRules.offered(tools: tools, servers: servers, in: choice)
        XCTAssertEqual(offered.tools, ["web_search", "file.write", "github.readFile"], "GitHub to read; Google not on; the rest is no connection's")
        XCTAssertEqual(offered.servers.map(\.id), ["reads", "writes"], "One not on is left out, and one on to read that marks no tool as read-only")
        XCTAssertEqual(offered.servers[0].cachedTools?.map(\.name), ["look"], "On to read: only what it marks as read-only")
        XCTAssertEqual(offered.servers[1].cachedTools?.map(\.name), ["look", "change"])

        let nothing = CovenConnectionRules.offered(tools: tools, servers: servers, in: CovenConnections())
        XCTAssertEqual(nothing.tools, ["web_search", "file.write"])
        XCTAssertEqual(nothing.servers, [])
    }

    // MARK: - Kept with the coven

    func testAChoice_isKeptAsItWasMade_andWhatIsNotAnAccessIsNoGrant() throws {
        let choice = CovenConnections(apps: ["github": .readOnly], mcpServers: ["server-1": .readWrite])
        let stored = try JSONEncoder().encode(CovenSettings(budgetCaps: ["monthly": 5], connections: choice))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        XCTAssertEqual((json["connections"] as? [String: Any])?["apps"] as? [String: String], ["github": "read_only"])
        XCTAssertEqual((json["connections"] as? [String: Any])?["mcp_servers"] as? [String: String], ["server-1": "read_write"])
        let read = try JSONDecoder().decode(CovenSettings.self, from: stored)
        XCTAssertEqual(read.connections, choice)
        XCTAssertEqual(read.budgetCaps, ["monthly": 5])

        // Settings kept before there was a choice: none made.
        let before = try JSONDecoder().decode(CovenSettings.self, from: Data(#"{"auto_route_enabled":true}"#.utf8))
        XCTAssertNil(before.connections)
        XCTAssertEqual(before.autoRouteEnabled, true)

        let odd = try JSONDecoder().decode(CovenConnections.self, from: Data(#"{"apps":{"github":"admin","google_drive":"read_write"},"mcp_servers":"all"}"#.utf8))
        XCTAssertEqual(odd, CovenConnections(apps: ["google_drive": .readWrite]), "What does not read as an access is left out")
    }

    func testAThreadsConnections_areItsCovensChoice() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        await MainActor.run { DatabaseManager.shared.configureIfNeeded() }
        await ThreadService.shared.reloadForCurrentUser()
        let coven = try await CovenService.shared.createCoven(name: "Connections \(UUID().uuidString)")
        let personal = try await ThreadService.shared.createThread(title: "Personal \(UUID().uuidString)").id
        let inCoven = try await ThreadService.shared.createThread(title: "In a coven \(UUID().uuidString)", covenId: coven.id).id
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await ThreadService.shared.deleteThread(threadId: personal)
            try? await ThreadService.shared.deleteThread(threadId: inCoven)
            try? await CovenService.shared.deleteCoven(id: coven.id)
            await ThreadService.shared.reloadForCurrentUser()
            await DataEncryptionService.shared.lock()
        }

        let ofPersonal = await CovenService.shared.connections(forThread: personal)
        XCTAssertNil(ofPersonal, "A personal thread is in no coven")
        let beforeAChoice = await CovenService.shared.connections(forThread: inCoven)
        XCTAssertNil(beforeAChoice, "A coven that has made no choice uses everything connected, as before")

        let choice = CovenConnections(apps: ["github": .readOnly], mcpServers: ["server-1": .readWrite])
        try await CovenService.shared.setConnections(choice, forCoven: coven.id)
        let chosen = await CovenService.shared.connections(forThread: inCoven)
        XCTAssertEqual(chosen, choice)
        let stillNone = await CovenService.shared.connections(forThread: personal)
        XCTAssertNil(stillNone)
        let kept = try await CovenService.shared.loadCovens().first { $0.id == coven.id }
        XCTAssertEqual(kept?.name, coven.name, "The rest of the coven as it was")
        XCTAssertEqual(kept?.settings?.connections, choice)

        try await CovenService.shared.setConnections(CovenConnections(), forCoven: coven.id)
        let nothingOn = await CovenService.shared.connections(forThread: inCoven)
        XCTAssertEqual(nothingOn, CovenConnections(), "A choice of nothing is a choice")

        try await CovenService.shared.setConnections(nil, forCoven: coven.id)
        let takenAway = await CovenService.shared.connections(forThread: inCoven)
        XCTAssertNil(takenAway)

        let unknown = await CovenService.shared.connections(forThread: "no-such-thread-\(UUID().uuidString)")
        XCTAssertEqual(unknown, CovenConnections(), "What cannot be checked is not allowed")
        do {
            try await CovenService.shared.setConnections(choice, forCoven: "no-such-coven")
            XCTFail("There is no such coven")
        } catch {}

        // An agent run's own thread is kept without a chat thread's stored
        // form and carries no coven: it is a personal one.
        let ofARun = try await ThreadRepository.shared.createThread(title: "A run \(UUID().uuidString)").id
        addTeardownBlock { try? await ThreadRepository.shared.deleteThread(id: ofARun, for: UserScope.currentUserID) }
        let forTheRun = await CovenService.shared.connections(forThread: ofARun)
        XCTAssertNil(forTheRun)

        // While the data is locked nothing is said of any thread, not
        // even that it has no coven.
        await DataEncryptionService.shared.lock()
        for thread in [ofARun, personal, inCoven] {
            let whileLocked = await CovenService.shared.connections(forThread: thread)
            XCTAssertEqual(whileLocked, CovenConnections(), "Nothing is on")
        }
    }

    func testACovensOtherSettings_areKeptAsStored_andSettingsThatCannotBeReadGrantNothing() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        await MainActor.run { DatabaseManager.shared.configureIfNeeded() }
        await ThreadService.shared.reloadForCurrentUser()
        let coven = try await CovenService.shared.createCoven(name: "Settings \(UUID().uuidString)")
        let thread = try await ThreadService.shared.createThread(title: "In it \(UUID().uuidString)", covenId: coven.id).id
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await ThreadService.shared.deleteThread(threadId: thread)
            try? await CovenService.shared.deleteCoven(id: coven.id)
            await ThreadService.shared.reloadForCurrentUser()
            await DataEncryptionService.shared.lock()
        }
        let found = await MainActor.run { DatabaseManager.shared.dbQueue }
        let queue = try XCTUnwrap(found)
        func store(_ settings: String?) async throws {
            try await queue.write { db in try db.execute(sql: "UPDATE covens SET settings = ? WHERE id = ?", arguments: [settings, coven.id]) }
        }
        func stored() async throws -> [String: Any]? {
            let text = try await queue.read { db in try String.fetchOne(db, sql: "SELECT settings FROM covens WHERE id = ?", arguments: [coven.id]) }
            return try text.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
        }

        // Other settings, one this app does not know of included.
        try await store(#"{"budget_caps":{"monthly":5},"auto_route_enabled":true,"something_newer":{"a":1}}"#)
        let choice = CovenConnections(apps: ["github": .readOnly])
        try await CovenService.shared.setConnections(choice, forCoven: coven.id)
        var kept = try await stored()
        XCTAssertEqual(kept?["budget_caps"] as? [String: Int], ["monthly": 5])
        XCTAssertEqual(kept?["auto_route_enabled"] as? Bool, true)
        XCTAssertEqual(kept?["something_newer"] as? [String: Int], ["a": 1], "Kept as stored, known to this app or not")
        XCTAssertEqual((kept?["connections"] as? [String: Any])?["apps"] as? [String: String], ["github": "read_only"])
        try await CovenService.shared.setConnections(nil, forCoven: coven.id)
        kept = try await stored()
        XCTAssertNil(kept?["connections"])
        XCTAssertEqual(kept?["budget_caps"] as? [String: Int], ["monthly": 5])

        // A choice that is not one: nothing is on, rather than everything.
        for unreadable in [#"{"connections":[],"budget_caps":{"monthly":5}}"#, #"{"connections":"all"}"#, "not settings at all", "[1,2]", ""] {
            try await store(unreadable)
            let granted = await CovenService.shared.connections(forThread: thread)
            XCTAssertEqual(granted, CovenConnections(), unreadable)
        }
        // Settings that cannot be read are not written over.
        try await store("not settings at all")
        do {
            try await CovenService.shared.setConnections(choice, forCoven: coven.id)
            XCTFail("They cannot be read")
        } catch {
            XCTAssertEqual(error as? CovenRepositoryError, .settingsUnreadable)
        }
        let untouched = try await queue.read { db in try String.fetchOne(db, sql: "SELECT settings FROM covens WHERE id = ?", arguments: [coven.id]) }
        XCTAssertEqual(untouched, "not settings at all")

        // No settings at all, or a null choice: none made.
        for none in [nil, #"{"connections":null}"#, "{}"] as [String?] {
            try await store(none)
            let granted = await CovenService.shared.connections(forThread: thread)
            XCTAssertNil(granted, none ?? "nil")
        }
        await DataEncryptionService.shared.lock()
    }
}
