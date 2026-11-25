@testable import AICoven
import GRDB
import XCTest

/// What the person writes for their agents and for Strix is kept sealed
/// with their account's key, never as text on disk.
@MainActor
final class InstructionsAtRestTests: XCTestCase {
    private let secret = "Never mention the Henderson account."

    override func setUp() async throws {
        try await super.setUp()
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
    }

    override func tearDown() async throws {
        await DataEncryptionService.shared.lock()
        try await super.tearDown()
    }

    private func coven() async throws -> String {
        let coven = try await CovenService.shared.createCoven(name: "Instructions \(UUID().uuidString)")
        addTeardownBlock { try? await CovenService.shared.deleteCoven(id: coven.id) }
        return coven.id
    }

    private func row(of agent: String) async throws -> Row? {
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        return try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT system_prompt, system_prompt_ciphertext FROM roles WHERE id = ?", arguments: [agent])
        }
    }

    func testAnAgentsInstructions_areSealedOnDisk_andReadBack() async throws {
        let account = UserScope.currentUserID
        let scout = try await RoleService.shared.createAgent(
            inCoven: coven(),
            AgentSaving(
                name: "Scout", iconSymbol: "magnifyingglass", iconTint: nil, description: "", instructions: secret,
                provider: "anthropic", model: "claude-x", providerAccountId: nil, temperature: nil, maxTokens: nil, mostSteps: nil
            ),
            as: account
        )
        XCTAssertEqual(scout.systemPrompt, secret)
        let stored = try await row(of: scout.id)
        XCTAssertNil(stored?["system_prompt"] as String?, "No text on disk")
        let sealed: Data = try XCTUnwrap(stored?["system_prompt_ciphertext"])
        XCTAssertNil(String(data: sealed, encoding: .utf8).flatMap { $0.contains("Henderson") ? $0 : nil })
        let read = try await RoleService.shared.getRole(roleId: scout.id)
        XCTAssertEqual(read.systemPrompt, secret)

        // Saved again from the form: still sealed, and the new text reads back.
        var edited = AgentSaving(
            name: "Scout", iconSymbol: "magnifyingglass", iconTint: nil, description: "", instructions: "Be brief.",
            provider: "anthropic", model: "claude-x", providerAccountId: nil, temperature: nil, maxTokens: nil, mostSteps: nil
        )
        _ = try await RoleService.shared.saveAgent(scout.id, edited, as: account)
        let resaved = try await row(of: scout.id)
        XCTAssertNil(resaved?["system_prompt"] as String?)
        let reread = try await RoleService.shared.getRole(roleId: scout.id)
        XCTAssertEqual(reread.systemPrompt, "Be brief.")
        edited.instructions = ""
        _ = try await RoleService.shared.saveAgent(scout.id, edited, as: account)
        let emptied = try await row(of: scout.id)
        XCTAssertNil(emptied?["system_prompt_ciphertext"] as Data?, "Emptied instructions are none")
    }

    func testWithoutTheKey_nothingSealedIsWrittenOver_andWhatCannotBeOpenedIsKeptBySavingNone() async throws {
        let account = UserScope.currentUserID
        let agent = { (instructions: String) in
            AgentSaving(
                name: "Scout", iconSymbol: "magnifyingglass", iconTint: nil, description: "", instructions: instructions,
                provider: "anthropic", model: "claude-x", providerAccountId: nil, temperature: nil, maxTokens: nil, mostSteps: nil
            )
        }
        let scout = try await RoleService.shared.createAgent(inCoven: coven(), agent(secret), as: account)
        let made = try await row(of: scout.id)
        let sealed: Data = try XCTUnwrap(made?["system_prompt_ciphertext"])

        // Instructions that cannot be opened (another key sealed them) read as
        // none, and a save that gives none leaves them as they are.
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        try await queue.write { db in
            try db.execute(sql: "UPDATE roles SET system_prompt_ciphertext = ? WHERE id = ?", arguments: [Data("not this key's".utf8), scout.id])
        }
        let unreadable = try await RoleService.shared.getRole(roleId: scout.id)
        XCTAssertNil(unreadable.systemPrompt)
        _ = try await RoleService.shared.saveAgent(scout.id, agent(""), as: account)
        let kept: Data? = try await row(of: scout.id)?["system_prompt_ciphertext"]
        XCTAssertEqual(kept, Data("not this key's".utf8), "Not written over with none")
        try await queue.write { db in
            try db.execute(sql: "UPDATE roles SET system_prompt_ciphertext = ? WHERE id = ?", arguments: [sealed, scout.id])
        }

        // With the data locked, a save is refused, also one that gives none.
        await DataEncryptionService.shared.lock()
        do {
            _ = try await RoleService.shared.saveAgent(scout.id, agent(""), as: account)
            XCTFail("Nothing is saved without the key")
        } catch RepositoryError.dataLocked {}
        let still: Data? = try await row(of: scout.id)?["system_prompt_ciphertext"]
        XCTAssertEqual(still, sealed)
    }

    func testStrixsSealedInstructions_areNeitherWrittenOverWithoutTheKey_norBySavingNone() async throws {
        let account = UserScope.currentUserID
        let key = UserScope.scopedKey("strix_settings.v1", for: account)
        let before = UserDefaults.standard.data(forKey: key)
        addTeardownBlock { UserDefaults.standard.set(before, forKey: key) }
        let strix = { (instructions: String) in
            AgentSaving(
                name: "Strix", iconSymbol: "sparkles", iconTint: nil, description: "", instructions: instructions,
                provider: "", model: "", providerAccountId: nil, temperature: nil, maxTokens: nil, mostSteps: nil, needsConnection: false
            )
        }
        // Sealed instructions that cannot be opened are kept by a save that gives none.
        var settings = LocalStrixSettings()
        settings.systemPromptSealed = Data("not this key's".utf8)
        try UserDefaults.standard.set(JSONEncoder().encode(settings), forKey: key)
        _ = try await StrixSettingsService.shared.save(strix(""), as: account)
        XCTAssertEqual(StrixSettingsService.stored(of: account)?.systemPromptSealed, Data("not this key's".utf8))

        // Without the key, nothing is saved.
        await DataEncryptionService.shared.lock()
        do {
            _ = try await StrixSettingsService.shared.save(strix(""), as: account)
            XCTFail("Nothing is saved without the key")
        } catch RepositoryError.dataLocked {}
        XCTAssertEqual(StrixSettingsService.stored(of: account)?.systemPromptSealed, Data("not this key's".utf8))
    }

    func testAnIconOrAnUpdate_doesNotWriteOlderTextBack() async throws {
        let account = UserScope.currentUserID
        let covenID = try await coven()
        let id = UUID().uuidString
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        try await queue.write { [secret] db in
            try db.execute(
                sql: "INSERT INTO roles (id, coven_id, name, system_prompt, user_id, created_at, updated_at) VALUES (?, ?, 'Old', ?, ?, ?, ?)",
                arguments: [id, covenID, secret, account, Date(), Date()]
            )
        }
        try await CovenRepository.shared.setIcon(symbol: "leaf", tint: .moss, forRole: id)
        let sealedFirst = try await row(of: id)
        XCTAssertNil(sealedFirst?["system_prompt"] as String?, "Sealed before the icon was written")
        XCTAssertNotNil(sealedFirst?["system_prompt_ciphertext"] as Data?)
        let read = try await RoleService.shared.getRole(roleId: id)
        XCTAssertEqual(read.systemPrompt, secret)
    }

    func testInstructionsStoredAsTextBefore_areNotGivenWithoutTheKey() async throws {
        let account = UserScope.currentUserID
        let covenID = try await coven()
        let id = UUID().uuidString
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        try await queue.write { [secret] db in
            try db.execute(
                sql: "INSERT INTO roles (id, coven_id, name, system_prompt, user_id, created_at, updated_at) VALUES (?, ?, 'Old', ?, ?, ?, ?)",
                arguments: [id, covenID, secret, account, Date(), Date()]
            )
        }
        await DataEncryptionService.shared.lock()
        let agents = try await RoleService.shared.loadRoles(covenId: covenID)
        XCTAssertNil(agents.first { $0.id == id }?.systemPrompt, "Read only as it would be once sealed")
    }

    func testInstructionsStoredAsTextBefore_areSealedWhenTheirAccountReadsThem() async throws {
        let account = UserScope.currentUserID
        let covenID = try await coven()
        let id = UUID().uuidString
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        try await queue.write { [secret] db in
            try db.execute(
                sql: "INSERT INTO roles (id, coven_id, name, system_prompt, user_id, created_at, updated_at) VALUES (?, ?, 'Old', ?, ?, ?, ?)",
                arguments: [id, covenID, secret, account, Date(), Date()]
            )
        }
        let agents = try await RoleService.shared.loadRoles(covenId: covenID)
        XCTAssertEqual(agents.first { $0.id == id }?.systemPrompt, secret)
        let stored = try await row(of: id)
        XCTAssertNil(stored?["system_prompt"] as String?, "The text is taken out")
        XCTAssertNotNil(stored?["system_prompt_ciphertext"] as Data?)
        let read = try await RoleService.shared.getRole(roleId: id)
        XCTAssertEqual(read.systemPrompt, secret)
    }

    func testStrixsInstructions_areSealedInItsSettings_andReadBack() async throws {
        let account = UserScope.currentUserID
        let key = UserScope.scopedKey("strix_settings.v1", for: account)
        let before = UserDefaults.standard.data(forKey: key)
        addTeardownBlock { UserDefaults.standard.set(before, forKey: key) }

        // Settings saved as text before are sealed when they are next opened.
        try UserDefaults.standard.set(JSONEncoder().encode(LocalStrixSettings(systemPrompt: secret)), forKey: key)
        let opened = await StrixSettingsService.shared.instructions(of: account)
        XCTAssertEqual(opened, secret)
        let raw = try XCTUnwrap(UserDefaults.standard.data(forKey: key))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("Henderson"), "No text left in the preferences")
        XCTAssertNotNil(StrixSettingsService.stored(of: account)?.systemPromptSealed)

        // Saved from the form: sealed too, and given back opened.
        let saved = try await StrixSettingsService.shared.save(
            AgentSaving(
                name: "Strix", iconSymbol: "sparkles", iconTint: nil, description: "", instructions: secret,
                provider: "", model: "", providerAccountId: nil, temperature: nil, maxTokens: nil, mostSteps: nil, needsConnection: false
            ),
            as: account
        )
        XCTAssertEqual(saved.systemPrompt, secret)
        XCTAssertFalse(try String(decoding: XCTUnwrap(UserDefaults.standard.data(forKey: key)), as: UTF8.self).contains("Henderson"))
        let loaded = try await StrixSettingsService.shared.loadPersonalStrix()
        XCTAssertEqual(loaded.systemPrompt, secret)
    }
}
