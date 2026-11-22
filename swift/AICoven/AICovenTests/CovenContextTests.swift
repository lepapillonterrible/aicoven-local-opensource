@testable import AICoven
import GRDB
import XCTest

/// What every agent of a scope is told ("Every agent here knows…"): kept
/// encrypted for each coven of an account and for Strix, and added to the
/// instructions of a turn where the thread is.
@MainActor
final class CovenContextTests: XCTestCase {
    private let store = CovenContextRepository.shared

    override func setUp() async throws {
        try await super.setUp()
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        await ThreadService.shared.reloadForCurrentUser()
        // Strix's is one for the account: each test starts with none.
        try await store.setContext("", forCoven: nil, as: account)
    }

    override func tearDown() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        try? await store.setContext("", forCoven: nil, as: account)
        await DataEncryptionService.shared.lock()
        try await super.tearDown()
    }

    private var account: String {
        UserScope.currentUserID
    }

    /// A coven of the signed-in account's, deleted when the test ends.
    private func newCoven() async throws -> String {
        let coven = try await CovenService.shared.createCoven(name: "Knows \(UUID().uuidString)")
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await CovenService.shared.deleteCoven(id: coven.id)
        }
        return coven.id
    }

    func testEachScopeHasItsOwnText_keptTrimmedAndNoLongerThanTheLongest() async throws {
        let work = try await newCoven()
        let home = try await newCoven()
        let none = try await store.context(ofCoven: work, as: account)
        XCTAssertEqual(none, "", "Nothing is kept until something is")

        let kept = try await store.setContext("  We ship on Fridays.\n", forCoven: work, as: account)
        XCTAssertEqual(kept, "We ship on Fridays.")
        try await store.setContext("Strix plans the week.", forCoven: nil, as: account)

        let works = try await store.context(ofCoven: work, as: account)
        XCTAssertEqual(works, "We ship on Fridays.")
        let homes = try await store.context(ofCoven: home, as: account)
        XCTAssertEqual(homes, "", "Another coven's is its own")
        let strixs = try await store.context(ofCoven: nil, as: account)
        XCTAssertEqual(strixs, "Strix plans the week.")

        // Saved again, it is replaced; cut at the longest; and an empty text keeps nothing.
        let long = try await store.setContext(String(repeating: "a", count: 2500), forCoven: work, as: account)
        XCTAssertEqual(long.count, CovenContextRepository.longest)
        let longNow = try await store.context(ofCoven: work, as: account)
        XCTAssertEqual(longNow.count, CovenContextRepository.longest)
        try await store.setContext("   \n", forCoven: work, as: account)
        let cleared = try await store.context(ofCoven: work, as: account)
        XCTAssertEqual(cleared, "")
        let strixsStill = try await store.context(ofCoven: nil, as: account)
        XCTAssertEqual(strixsStill, "Strix plans the week.")
    }

    func testItIsReadAndKeptOnlyAsTheAccountSignedIn_withItsOwnKey() async throws {
        let coven = try await newCoven()
        try await store.setContext("Ours", forCoven: coven, as: account)

        func refused(_ what: String, with expected: RepositoryError, _ body: () async throws -> Void) async {
            do {
                try await body()
                XCTFail(what)
            } catch {
                XCTAssertEqual(error as? RepositoryError, expected, what)
            }
        }
        await refused("Read as an account that is not signed in", with: .accountChanged) {
            _ = try await self.store.context(ofCoven: coven, as: "someone-who-signed-out")
        }
        await refused("Kept as an account that is not signed in", with: .accountChanged) {
            try await self.store.setContext("Theirs", forCoven: coven, as: "someone-who-signed-out")
        }
        await refused("Cleared as an account that is not signed in", with: .accountChanged) {
            try await self.store.setContext("", forCoven: coven, as: "someone-who-signed-out")
        }

        // What is in memory for a moment after a switch from another account: that account's key.
        await DataEncryptionService.shared.unlockForTestingEphemeral(ownedBy: "someone-who-signed-out")
        await refused("Read with another account's key", with: .dataLocked) {
            _ = try await self.store.context(ofCoven: coven, as: self.account)
        }
        await refused("Kept with another account's key", with: .dataLocked) {
            try await self.store.setContext("Sealed with another's key", forCoven: coven, as: self.account)
        }
        await refused("Cleared with another account's key", with: .dataLocked) {
            try await self.store.setContext("", forCoven: coven, as: self.account)
        }
        await DataEncryptionService.shared.lock()
        await refused("Cleared while the data is locked", with: .dataLocked) {
            try await self.store.setContext("", forCoven: coven, as: self.account)
        }
        await refused("Read while the data is locked", with: .dataLocked) {
            _ = try await self.store.context(ofCoven: coven, as: self.account)
        }

        // Under a key that cannot open it, it is not taken for nothing.
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        do {
            _ = try await store.context(ofCoven: coven, as: account)
            XCTFail("Read what the key cannot open")
        } catch {
            guard case CovenContextError.unreadable = error else { return XCTFail("\(type(of: error))") }
        }
        // And it can be written over.
        try await store.setContext("Ours again", forCoven: coven, as: account)
        let again = try await store.context(ofCoven: coven, as: account)
        XCTAssertEqual(again, "Ours again")
    }

    func testACovensTextIsKeptOnlyForACovenOfTheAccount_andGoesWithItsCoven() async throws {
        do {
            try await store.setContext("For a coven that is not there", forCoven: "no-such-coven-\(UUID().uuidString)", as: account)
            XCTFail("Kept a text for a coven that is not there")
        } catch {}

        // Whatever writes the row: not without an account, and not for another account's coven.
        let rows = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let theirs = "their-coven-\(UUID().uuidString)"
        let mine = try await newCoven()
        let account = account
        try await rows.write { db in
            try db.execute(
                sql: "INSERT INTO covens (id, name, created_at, updated_at, user_id) VALUES (?, ?, ?, ?, ?)",
                arguments: [theirs, "Theirs", Date(), Date(), "someone-else"]
            )
        }
        addTeardownBlock {
            try? await rows.write { db in try db.execute(sql: "DELETE FROM covens WHERE id = ?", arguments: [theirs]) }
        }
        func refusedRow(_ what: String, _ sql: String, _ arguments: StatementArguments) async {
            do {
                try await rows.write { db in try db.execute(sql: sql, arguments: arguments) }
                XCTFail(what)
            } catch {}
        }
        let insert = "INSERT INTO coven_context (user_id, coven_id, text_ciphertext, updated_at) VALUES (?, ?, ?, ?)"
        await refusedRow("Stored a row with no account", insert, [" ", "", Data("x".utf8), Date()])
        await refusedRow("Stored a row for another account's coven", insert, [account, theirs, Data("x".utf8), Date()])
        try await store.setContext("Mine", forCoven: mine, as: account)
        await refusedRow(
            "Moved a row to another account's coven",
            "UPDATE coven_context SET coven_id = ? WHERE user_id = ? AND coven_id = ?", [theirs, account, mine]
        )
        await refusedRow(
            "Gave a row to no account",
            "UPDATE coven_context SET user_id = '' WHERE user_id = ? AND coven_id = ?", [account, mine]
        )

        let coven = try await newCoven()
        let other = try await newCoven()
        try await store.setContext("Goes with its coven", forCoven: coven, as: account)
        try await store.setContext("Another coven's", forCoven: other, as: account)
        try await CovenService.shared.deleteCoven(id: coven)

        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let left = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM coven_context WHERE coven_id = ?", arguments: [coven])
        }
        XCTAssertEqual(left, 0)
        let others = try await store.context(ofCoven: other, as: account)
        XCTAssertEqual(others, "Another coven's")
    }

    // MARK: - What a turn is told

    private func thread(inCoven coven: String?) async throws -> String {
        let id = try await ThreadService.shared.createThread(title: "Knows \(UUID().uuidString)", covenId: coven).id
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await ThreadService.shared.deleteThread(threadId: id)
        }
        return id
    }

    func testATurnIsToldWhatEveryAgentWhereItsThreadIsKnows() async throws {
        let builder = ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4))
        let coven = try await newCoven()
        let inCoven = try await thread(inCoven: coven)
        let personal = try await thread(inCoven: nil)
        try await store.setContext("We ship on Fridays.", forCoven: coven, as: account)
        try await store.setContext("Strix plans the week.", forCoven: nil, as: account)

        func told(_ thread: String?) async throws -> [String] {
            try await builder.buildContext(threadID: thread, userMessage: "Hello", maxContextTokens: 8000, toolConfig: .noTools)
                .filter { $0.role == .system }.map(\.content)
        }
        let toldInCoven = try await told(inCoven)
        XCTAssertTrue(toldInCoven.contains("## Coven Context\nWe ship on Fridays."), "As a part of the agent's instructions")
        XCTAssertFalse(toldInCoven.contains { $0.contains("Strix plans the week.") })
        let toldPersonally = try await told(personal)
        XCTAssertTrue(toldPersonally.contains("## Coven Context\nStrix plans the week."))
        XCTAssertFalse(toldPersonally.contains { $0.contains("We ship on Fridays.") })
        let toldWithNoThread = try await told(nil)
        XCTAssertTrue(toldWithNoThread.contains("## Coven Context\nStrix plans the week."))

        // A thread that cannot be placed is told no scope's.
        let toldUnplaced = try await told("no-such-thread-\(UUID().uuidString)")
        XCTAssertFalse(toldUnplaced.contains { $0.contains("## Coven Context") })

        // Where nothing is kept, nothing is added.
        try await store.setContext("", forCoven: coven, as: account)
        let toldNothing = try await told(inCoven)
        XCTAssertFalse(toldNothing.contains { $0.contains("## Coven Context") })

        // Nor where what is kept cannot be opened, in a thread that can still be placed: the turn
        // goes on without it. (Only the kept text is made unreadable: it is sealed for another use.)
        try await store.setContext("Kept.", forCoven: coven, as: account)
        let unopenable = try await DataEncryptionService.shared.encrypt(Data("Kept.".utf8), purpose: "something-else")
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let account = account
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE coven_context SET text_ciphertext = ? WHERE user_id = ? AND coven_id = ?",
                arguments: [unopenable, account, coven]
            )
        }
        do {
            _ = try await store.context(ofCoven: coven, as: account)
            XCTFail("Read what the key cannot open")
        } catch {
            guard case CovenContextError.unreadable = error else { return XCTFail("\(type(of: error))") }
        }
        let placed = await builder.scope(ofThread: inCoven, for: account)
        XCTAssertEqual(placed, .coven(coven), "The thread itself is still placed")
        let toldUnreadable = try await told(inCoven)
        XCTAssertFalse(toldUnreadable.contains { $0.contains("## Coven Context") })
        XCTAssertFalse(toldUnreadable.isEmpty, "The turn is still told the rest")
    }
}
