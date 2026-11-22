@testable import AICoven
import GRDB
import XCTest

/// An agent is saved as the agent form shows it, in one write, as the
/// account that pressed Save.
@MainActor
final class AgentStoreTests: XCTestCase {
    private var covenID = ""

    private var account: String {
        UserScope.currentUserID
    }

    override func setUp() async throws {
        try await super.setUp()
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        let coven = try await CovenService.shared.createCoven(name: "Agents \(UUID().uuidString)")
        covenID = coven.id
    }

    override func tearDown() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        try? await CovenService.shared.deleteCoven(id: covenID)
        await DataEncryptionService.shared.lock()
        try await super.tearDown()
    }

    private func scout(
        tint: IconTint? = .moss, description: String = "Reads code", instructions: String = "You review code.",
        temperature: Double? = 0.2, maxTokens: Int? = 900, mostSteps: Int? = 12
    ) -> AgentSaving {
        AgentSaving(
            name: "Scout", iconSymbol: "magnifyingglass", iconTint: tint, description: description, instructions: instructions,
            provider: "anthropic", model: "claude-sonnet-4-6", providerAccountId: "acct",
            temperature: temperature, maxTokens: maxTokens, mostSteps: mostSteps
        )
    }

    /// An agent's settings as they are stored, read apart from the store's own reading.
    private func storedSettings(of id: String) async throws -> [String: Any] {
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let text = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT settings FROM roles WHERE id = ?", arguments: [id])
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(text).utf8)) as? [String: Any])
    }

    /// Whether two readings of an agent are of the same agent as stored:
    /// all of it but its dates, which the store keeps to the millisecond.
    private func assertSame(_ one: Role, _ other: Role, _ message: String = "", line: UInt = #line) {
        XCTAssertEqual(one.id, other.id, message, line: line)
        XCTAssertEqual(one.covenId, other.covenId, message, line: line)
        XCTAssertEqual(one.name, other.name, message, line: line)
        XCTAssertEqual(one.description, other.description, message, line: line)
        XCTAssertEqual(one.systemPrompt, other.systemPrompt, message, line: line)
        XCTAssertEqual([one.provider, one.model, one.providerAccountId], [other.provider, other.model, other.providerAccountId], message, line: line)
        XCTAssertEqual(one.temperature, other.temperature, message, line: line)
        XCTAssertEqual(one.maxTokens, other.maxTokens, message, line: line)
        XCTAssertEqual(one.settings, other.settings, message, line: line)
    }

    private func store(settings: String, of id: String) async throws {
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        try await queue.write { db in
            try db.execute(sql: "UPDATE roles SET settings = ? WHERE id = ?", arguments: [settings, id])
        }
    }

    func testANewAgentIsMadeAsTheFormShowsIt() async throws {
        let made = try await RoleService.shared.createAgent(inCoven: covenID, scout(), as: account)

        let read = try await RoleService.shared.getRole(roleId: made.id)
        assertSame(read, made)
        XCTAssertEqual(read.covenId, covenID)
        XCTAssertEqual(read.name, "Scout")
        XCTAssertEqual(read.description, "Reads code")
        XCTAssertEqual(read.systemPrompt, "You review code.")
        XCTAssertEqual([read.provider, read.model, read.providerAccountId], ["anthropic", "claude-sonnet-4-6", "acct"])
        XCTAssertEqual(read.temperature, 0.2)
        XCTAssertEqual(read.maxTokens, 900)
        XCTAssertEqual(read.settings?.autonomousMaxSteps, 12)
        XCTAssertEqual(read.iconSymbol, "magnifyingglass")
        XCTAssertEqual(read.iconTintValue, .moss)
    }

    func testANewAgentWithNoTintChosen_takesTheFirstNoneOfItsCovensAgentsWears() async throws {
        let first = try await RoleService.shared.createAgent(inCoven: covenID, scout(tint: nil), as: account)
        let second = try await RoleService.shared.createAgent(inCoven: covenID, scout(tint: nil), as: account)

        XCTAssertEqual(first.iconTintValue, IconTint.allCases[0])
        XCTAssertEqual(second.iconTintValue, IconTint.allCases[1])
        XCTAssertEqual(second.iconSymbol, "magnifyingglass", "The symbol is the one chosen")
    }

    func testSavingWritesWhatTheFormShows_andLeavesTheRestOfTheSettingsAsStored() async throws {
        let made = try await RoleService.shared.createAgent(inCoven: covenID, scout(), as: account)
        // What other parts of the app keep in an agent's settings, and a key this app does not know.
        try await store(
            settings: #"{"allowed_tools":["web_search"],"autonomous_max_steps":12,"collaborator_role_ids":["r2"],"from_the_cloud":{"kept":true},"icon_symbol":"magnifyingglass","icon_tint":"moss"}"#,
            of: made.id
        )
        var edited = scout(tint: .sky, description: "", instructions: "", temperature: 1.1, maxTokens: 4000, mostSteps: 40)
        edited.name = "  Ranger  "
        edited.iconSymbol = "map"
        edited.provider = "OpenAI"
        edited.model = "gpt-4o"
        edited.providerAccountId = "other"

        let saved = try await RoleService.shared.saveAgent(made.id, edited, as: account)

        let read = try await RoleService.shared.getRole(roleId: made.id)
        assertSame(read, saved, "What is given back is what was written")
        XCTAssertEqual(read.name, "Ranger")
        XCTAssertNil(read.description, "An emptied field clears what was stored")
        XCTAssertNil(read.systemPrompt)
        XCTAssertEqual([read.provider, read.model, read.providerAccountId], ["openai", "gpt-4o", "other"])
        XCTAssertEqual(read.temperature, 1.1)
        XCTAssertEqual(read.maxTokens, 4000)
        let settings = try await storedSettings(of: made.id)
        XCTAssertEqual(settings["autonomous_max_steps"] as? Int, 40)
        XCTAssertEqual(settings["icon_symbol"] as? String, "map")
        XCTAssertEqual(settings["icon_tint"] as? String, "sky")
        XCTAssertEqual(settings["allowed_tools"] as? [String], ["web_search"])
        XCTAssertEqual(settings["collaborator_role_ids"] as? [String], ["r2"])
        XCTAssertEqual((settings["from_the_cloud"] as? [String: Any])?["kept"] as? Bool, true)
        XCTAssertEqual(settings.count, 6, "Nothing is added")
    }

    func testASettingTheFormDidNotShow_andATintNotChosen_stayAsStored() async throws {
        let made = try await RoleService.shared.createAgent(inCoven: covenID, scout(), as: account)

        let saved = try await RoleService.shared.saveAgent(
            made.id, scout(tint: nil, temperature: nil, maxTokens: nil, mostSteps: nil), as: account
        )

        XCTAssertEqual(saved.temperature, 0.2)
        XCTAssertEqual(saved.maxTokens, 900)
        XCTAssertEqual(saved.settings?.autonomousMaxSteps, 12)
        XCTAssertEqual(saved.iconTintValue, .moss)
    }

    func testAnAgentOfThePersonsOwn_isSavedWithNoModel() async throws {
        var hermes = scout(temperature: nil, maxTokens: nil, mostSteps: nil)
        hermes.provider = "hermes"
        hermes.model = ""
        do {
            _ = try await RoleService.shared.createAgent(inCoven: covenID, hermes, as: account)
            XCTFail("An agent a model answers for needs a model")
        } catch CovenRepositoryError.agentIncomplete {}

        hermes.needsModel = false
        let made = try await RoleService.shared.createAgent(inCoven: covenID, hermes, as: account)
        XCTAssertEqual(made.provider, "hermes")
        XCTAssertEqual(made.model, "")
    }

    func testNothingIsSavedOrMadeAsAnotherAccount() async throws {
        let made = try await RoleService.shared.createAgent(inCoven: covenID, scout(), as: account)
        var edited = scout()
        edited.name = "Ranger"

        // Whoever pressed Save is no longer signed in.
        do {
            _ = try await RoleService.shared.saveAgent(made.id, edited, as: "someone-else")
            XCTFail("Nothing is saved as an account that is not signed in")
        } catch RepositoryError.accountChanged {}
        do {
            _ = try await RoleService.shared.createAgent(inCoven: covenID, edited, as: "someone-else")
            XCTFail("Nothing is made as an account that is not signed in")
        } catch RepositoryError.accountChanged {}

        let agents = try await RoleService.shared.loadRoles(covenId: covenID)
        XCTAssertEqual(agents.map(\.name), ["Scout"], "Nothing was made or renamed")

        // An agent that is another account's is not found.
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let coven = covenID
        try await queue.write { db in
            try db.execute(sql: "UPDATE covens SET user_id = 'someone-else' WHERE id = ?", arguments: [coven])
            try db.execute(sql: "UPDATE roles SET user_id = 'someone-else' WHERE id = ?", arguments: [made.id])
        }
        addTeardownBlock {
            try? await queue.write { db in
                try db.execute(sql: "DELETE FROM covens WHERE id = ?", arguments: [coven])
            }
        }
        do {
            _ = try await RoleService.shared.saveAgent(made.id, edited, as: account)
            XCTFail("Another account's agent is not saved")
        } catch CovenRepositoryError.roleNotFound {}
        let stored = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM roles WHERE id = ?", arguments: [made.id])
        }
        XCTAssertEqual(stored, "Scout")
        do {
            _ = try await RoleService.shared.createAgent(inCoven: coven, edited, as: account)
            XCTFail("An agent is made only in a coven of the account's")
        } catch CovenRepositoryError.covenNotFound {}
    }

    func testAnAgentWhoseSettingsCannotBeRead_isNotWrittenOver() async throws {
        let made = try await RoleService.shared.createAgent(inCoven: covenID, scout(), as: account)
        try await store(settings: "not settings", of: made.id)
        var edited = scout()
        edited.name = "Ranger"

        do {
            _ = try await RoleService.shared.saveAgent(made.id, edited, as: account)
            XCTFail("Settings that cannot be read are not written over")
        } catch CovenRepositoryError.roleSettingsUnreadable {}

        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let row = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT name, settings FROM roles WHERE id = ?", arguments: [made.id])
        }
        XCTAssertEqual(row?["name"], "Scout", "Nothing of the agent is changed")
        XCTAssertEqual(row?["settings"], "not settings")
    }

    func testWhatIsNotAnAgentIsNotSaved() async throws {
        let made = try await RoleService.shared.createAgent(inCoven: covenID, scout(), as: account)
        var nameless = scout()
        nameless.name = "  "
        var notASymbol = scout()
        notASymbol.iconSymbol = "not a symbol!"

        do {
            _ = try await RoleService.shared.saveAgent(made.id, nameless, as: account)
            XCTFail("An agent needs a name")
        } catch CovenRepositoryError.agentIncomplete {}
        do {
            _ = try await RoleService.shared.saveAgent(made.id, notASymbol, as: account)
            XCTFail("A face needs a symbol's name")
        } catch CovenRepositoryError.notASymbol {}
        do {
            _ = try await RoleService.shared.createAgent(inCoven: covenID, notASymbol, as: account)
            XCTFail("A face needs a symbol's name")
        } catch CovenRepositoryError.notASymbol {}
        do {
            _ = try await RoleService.shared.createAgent(inCoven: "no-such-coven", scout(), as: account)
            XCTFail("An agent is made only in a coven of the account's")
        } catch CovenRepositoryError.covenNotFound {}

        let read = try await RoleService.shared.getRole(roleId: made.id)
        assertSame(read, made)
        let agents = try await RoleService.shared.loadRoles(covenId: covenID)
        XCTAssertEqual(agents.count, 1, "And none was made")
    }
}
