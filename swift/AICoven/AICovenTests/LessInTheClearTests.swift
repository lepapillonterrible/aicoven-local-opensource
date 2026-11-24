@testable import AICoven
import GRDB
import XCTest

/// What is kept in the clear says no more than it must: a proposal's tags
/// are the page it would go on, deleted text is overwritten, and a coven
/// keeps its id and its account.
@MainActor
final class LessInTheClearTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
    }

    override func tearDown() async throws {
        await DataEncryptionService.shared.lock()
        try await super.tearDown()
    }

    func testAProposalsTags_areKeptAsThePageItWouldGoOn() {
        XCTAssertEqual(MemoryProposalRepository.storedTags(["preference"]), #"["page:facts"]"#, "A word a model chose says nothing more")
        XCTAssertEqual(MemoryProposalRepository.storedTags(["person"]), #"["page:people"]"#, "Who's who stays Who's who")
        XCTAssertEqual(MemoryProposalRepository.storedTags(["coven:policy"]), #"["page:how"]"#)
        XCTAssertEqual(MemoryProposalRepository.storedTags(["page:purpose"]), #"["page:purpose"]"#)
        XCTAssertNil(MemoryProposalRepository.storedTags([]))
    }

    func testAStoredProposal_keepsOnlyItsPageInTheClear() async throws {
        let account = UserScope.currentUserID
        let stored = try await MemoryProposalRepository.shared.insertProposal(
            eventId: nil, covenId: nil, proposedContent: "Allergic to peanuts", proposedTags: ["allergy"], scope: "user", sourceMessageId: nil, proposedBy: "agent", as: account
        )
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        addTeardownBlock { try? await queue.write { db in try db.execute(sql: "DELETE FROM memory_proposals WHERE id = ?", arguments: [stored.id]) } }
        let row = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT proposed_tags, proposed_content FROM memory_proposals WHERE id = ?", arguments: [stored.id])
        }
        XCTAssertEqual(row?["proposed_tags"], #"["page:facts"]"#)
        XCTAssertEqual(row?["proposed_content"], "", "The text itself is sealed")
    }

    func testWhatIsDeletedIsOverwritten_andTheFileIsCompactedOnce() async throws {
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let on = try await queue.read { db in try Int.fetchOne(db, sql: "PRAGMA secure_delete") }
        XCTAssertEqual(on, 1)
        // The compaction is recorded once it has been done, and only then.
        await DatabaseManager.shared.compaction?.value
        let done = try await queue.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM upkeep_done WHERE name = ?)", arguments: [DatabaseManager.compacted]) ?? false
        }
        XCTAssertTrue(done)
    }

    func testRecordingsLeftByARunThatEndedEarly_areRemoved_andNothingElse() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("left-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        for name in ["voice-note-1.m4a", "voice-note-2.m4a", "other.m4a", "voice-note-3.txt"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        VoiceCaptureService.removeLeftRecordings(in: folder)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(left, ["other.m4a", "voice-note-3.txt"])
    }

    func testACovenKeepsItsIdAndItsAccount_whateverWrites() async throws {
        let coven = try await CovenService.shared.createCoven(name: "Kept \(UUID().uuidString)")
        addTeardownBlock { try? await CovenService.shared.deleteCoven(id: coven.id) }
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        for sql in [
            "UPDATE covens SET user_id = 'someone-else' WHERE id = ?",
            "UPDATE covens SET id = 'another-\(UUID().uuidString)' WHERE id = ?",
        ] {
            do {
                try await queue.write { db in try db.execute(sql: sql, arguments: [coven.id]) }
                XCTFail("Refused: \(sql)")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
            }
        }
        // Nor is it replaced by another account's row with its id.
        do {
            try await queue.write { db in
                try db.execute(
                    sql: "INSERT OR REPLACE INTO covens (id, user_id, name, created_at, updated_at) VALUES (?, 'someone-else', 'Theirs', ?, ?)",
                    arguments: [coven.id, Date(), Date()]
                )
            }
            XCTFail("A replacing insert is refused too")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
        }
        // Its other columns change as before.
        try await queue.write { db in try db.execute(sql: "UPDATE covens SET name = 'Renamed' WHERE id = ?", arguments: [coven.id]) }
    }
}
