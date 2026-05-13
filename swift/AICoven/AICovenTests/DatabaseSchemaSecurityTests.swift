import GRDB
import XCTest
@testable import AICoven

@MainActor
final class DatabaseSchemaSecurityTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        DatabaseManager.shared.configureIfNeeded()
    }

    func testUserScopedTablesRejectMissingUserID() async throws {
        let dbQueue = try XCTUnwrap(DatabaseManager.shared.dbQueue)

        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO threads (id, title, created_at, user_id) VALUES (?, ?, ?, NULL)",
                arguments: ["phase2-null-thread-\(UUID().uuidString)", "Null user", Date()]
            )
        })

        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO memory_chunks (id, scope, pii_flag, created_at, text_ciphertext, user_id) VALUES (?, ?, ?, ?, ?, '')",
                arguments: ["phase2-null-memory-\(UUID().uuidString)", "test", false, Date(), Data("secret".utf8)]
            )
        })
    }

    func testMessagesMustBelongToSameUserAsThread() async throws {
        let dbQueue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let threadID = "phase2-thread-\(UUID().uuidString)"

        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO threads (id, title, created_at, user_id) VALUES (?, ?, ?, ?)",
                arguments: [threadID, "Owner thread", Date(), "owner-a"]
            )
        }

        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO messages (id, thread_id, role, created_at, content_ciphertext, user_id) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: ["phase2-message-\(UUID().uuidString)", threadID, "user", Date(), Data("hello".utf8), "owner-b"]
            )
        })
    }

    func testRolesMustBelongToSameUserAsCoven() async throws {
        let dbQueue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let covenID = "phase2-coven-\(UUID().uuidString)"

        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO covens (id, name, created_at, updated_at, user_id) VALUES (?, ?, ?, ?, ?)",
                arguments: [covenID, "Owner coven", Date(), Date(), "owner-a"]
            )
        }

        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO roles (id, coven_id, name, created_at, updated_at, user_id) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: ["phase2-role-\(UUID().uuidString)", covenID, "Role", Date(), Date(), "owner-b"]
            )
        })
    }
}
