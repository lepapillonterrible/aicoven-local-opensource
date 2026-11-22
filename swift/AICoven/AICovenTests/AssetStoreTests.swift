@testable import AICoven
import GRDB
import XCTest

/// The account's assets: kept encrypted with their files, each in a coven
/// of the account's or with Strix, and read only as the account signed in.
@MainActor
final class AssetStoreTests: XCTestCase {
    private let store = AssetRepository.shared

    private var account: String {
        UserScope.currentUserID
    }

    override func setUp() async throws {
        try await super.setUp()
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        try await removeAll()
    }

    override func tearDown() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        try await removeAll()
        await DataEncryptionService.shared.lock()
        try await super.tearDown()
    }

    private func removeAll() async throws {
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let account = account
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM assets WHERE user_id IN (?, 'someone-else')", arguments: [account])
        }
    }

    /// A coven of the signed-in account's, deleted when the test ends.
    private func newCoven() async throws -> String {
        let coven = try await CovenService.shared.createCoven(name: "Assets \(UUID().uuidString)")
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await CovenService.shared.deleteCoven(id: coven.id)
        }
        return coven.id
    }

    /// A row of `threads` that is `owner`'s, with a message, removed when
    /// the test ends.
    private func newThread(of owner: String) async throws -> (thread: String, message: String) {
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let thread = UUID().uuidString, message = UUID().uuidString
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO threads (id, user_id, created_at, updated_at) VALUES (?, ?, ?, ?)", arguments: [thread, owner, Date(), Date()]
            )
            try db.execute(
                sql: "INSERT INTO messages (id, thread_id, user_id, role, created_at, content_ciphertext) VALUES (?, ?, ?, 'assistant', ?, ?)",
                arguments: [message, thread, owner, Date(), Data([1])]
            )
        }
        addTeardownBlock {
            try? await queue.write { db in try db.execute(sql: "DELETE FROM threads WHERE id = ?", arguments: [thread]) }
        }
        return (thread, message)
    }

    private func file(_ name: String, _ text: String = "bytes") -> AssetRepository.NewFile {
        AssetRepository.NewFile(name: name, data: Data(text.utf8))
    }

    private func expect(_ expected: AssetError, _ what: String, _ work: () async throws -> Void) async {
        do {
            try await work()
            XCTFail(what)
        } catch let error as AssetError {
            XCTAssertEqual(error, expected, what)
        } catch {
            XCTFail("\(what): \(type(of: error))")
        }
    }

    // MARK: - Making and reading

    func testAnAssetIsKeptAsADraftWithItsFiles_andItsBytesAreReadBack() async throws {
        let made = try await store.create(
            type: .chart, title: "  Q3 \n revenue ", details: " By region. \n", files: [file("q3.csv", "a,b\n1,2"), file("q3.png", "png")],
            inCoven: nil, as: account
        )
        XCTAssertEqual(made.title, "Q3 revenue")
        XCTAssertEqual(made.details, "By region.")
        XCTAssertEqual(made.status, .draft)
        XCTAssertNil(made.madeByAgentID, "The person's own")

        let listed = try await store.assets(inCoven: nil, as: account)
        XCTAssertEqual(listed.map(\.id), [made.id])
        XCTAssertEqual(listed[0].title, "Q3 revenue")
        XCTAssertEqual(listed[0].details, "By region.")
        XCTAssertEqual(listed[0].type, .chart)
        XCTAssertEqual(listed[0].status, .draft)
        XCTAssertEqual(listed[0].files, made.files)
        XCTAssertEqual(listed[0].files.map(\.name), ["q3.csv", "q3.png"], "In the order they were given")
        XCTAssertEqual(listed[0].files.map(\.sizeBytes), [7, 3])
        XCTAssertEqual(listed[0].files.map(\.mimeType), ["text/csv", "image/png"])

        let bytes = try await store.data(ofFile: listed[0].files[0].id, as: account)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "a,b\n1,2")
    }

    func testAssetsAreListedLastChangedFirst() async throws {
        let first = try await store.create(type: .image, title: "First", files: [file("a.png")], inCoven: nil, as: account)
        let second = try await store.create(type: .image, title: "Second", files: [], inCoven: nil, as: account)
        var listed = try await store.assets(inCoven: nil, as: account)
        XCTAssertEqual(listed.map(\.title), ["Second", "First"], "Of two changed at once, the one made later")

        // Each last changed at a time of its own, well before now.
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        try await queue.write { db in
            try db.execute(sql: "UPDATE assets SET updated_at = ? WHERE id = ?", arguments: [Date(timeIntervalSinceNow: -60), first.id])
            try db.execute(sql: "UPDATE assets SET updated_at = ? WHERE id = ?", arguments: [Date(timeIntervalSinceNow: -120), second.id])
        }
        listed = try await store.assets(inCoven: nil, as: account)
        XCTAssertEqual(listed.map(\.title), ["First", "Second"])
        try await queue.write { db in
            try db.execute(sql: "UPDATE assets SET updated_at = ? WHERE id = ?", arguments: [Date(timeIntervalSinceNow: -180), first.id])
        }
        listed = try await store.assets(inCoven: nil, as: account)
        XCTAssertEqual(listed.map(\.title), ["Second", "First"])

        let changedAt = try await store.move(first.id, to: .proposed, as: account)
        listed = try await store.assets(inCoven: nil, as: account)
        XCTAssertEqual(listed.map(\.title), ["First", "Second"])
        XCTAssertEqual(listed[0].status, .proposed)
        XCTAssertEqual(listed[0].updatedAt.timeIntervalSince1970, changedAt.timeIntervalSince1970, accuracy: 0.002)
        XCTAssertEqual(listed[1].id, second.id)
    }

    func testNothingAnAssetSaysIsKeptInTheClear() async throws {
        _ = try await store.create(
            type: .report, title: "Secret plans", details: "The launch is in March.", files: [file("ada-notes.md", "Buy the competitor.")],
            inCoven: nil, as: account
        )
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let account = account
        let rows: [Row] = try await queue.read { db in
            let assets = try Row.fetchAll(db, sql: "SELECT * FROM assets WHERE user_id = ?", arguments: [account])
            let files = try Row.fetchAll(
                db, sql: "SELECT asset_files.* FROM asset_files JOIN assets ON assets.id = asset_id WHERE user_id = ?", arguments: [account]
            )
            return assets + files
        }
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            for (column, stored) in row {
                let value: Data = switch stored.storage {
                case let .blob(data): data
                case let .string(text): Data(text.utf8)
                default: Data()
                }
                for clear in ["Secret", "launch", "March", "ada", "notes.md", "competitor"] {
                    XCTAssertNil(value.range(of: Data(clear.utf8)), "\(clear) in \(column)")
                }
            }
        }
    }

    func testWhatIsGivenIsKeptTidy_andWhatIsNoAssetIsRefused() async throws {
        let long = String(repeating: "t", count: AssetRepository.longestTitle + 50)
        let made = try await store.create(
            type: AssetType(rawValue: "wireframe_v2"), title: long, files: [file("../../etc/passwd"), file("C:\\Users\\ada\\plan.md"), file(" \n ")],
            inCoven: nil, as: account
        )
        XCTAssertEqual(made.title.count, AssetRepository.longestTitle)
        XCTAssertEqual(made.files.map(\.name), ["passwd", "plan.md", "file"], "A file's name never says where to put it")
        XCTAssertEqual(made.type.displayName, "Wireframe V2")

        await expect(.noTitle, "An asset has a title") {
            _ = try await self.store.create(type: .image, title: " \n ", files: [], inCoven: nil, as: self.account)
        }
        for name in ["", "Design Mockup", "design-mockup", "9lives", "../x", String(repeating: "a", count: 65)] {
            await expect(.notAType, "\(name) is no type's name") {
                _ = try await self.store.create(type: AssetType(rawValue: name), title: "T", files: [], inCoven: nil, as: self.account)
            }
        }
        await expect(.tooLong, "What says what it is has a longest") {
            let details = String(repeating: "d", count: AssetRepository.longestDetails + 1)
            _ = try await self.store.create(type: .image, title: "T", details: details, files: [], inCoven: nil, as: self.account)
        }
        await expect(.tooManyFiles, "An asset has only so many files") {
            let files = (0 ... AssetRepository.mostFiles).map { self.file("\($0).txt") }
            _ = try await self.store.create(type: .image, title: "T", files: files, inCoven: nil, as: self.account)
        }
        await expect(.fileTooLarge(name: "big.bin"), "A file has a largest size") {
            let big = AssetRepository.NewFile(name: "/tmp/big.bin", data: Data(count: AssetRepository.largestFile + 1))
            _ = try await self.store.create(type: .image, title: "T", files: [big], inCoven: nil, as: self.account)
        }
        let listed = try await store.assets(inCoven: nil, as: account)
        XCTAssertEqual(listed.map(\.id), [made.id], "Nothing of what was refused was kept")
    }

    func testAScopeKeepsNoMoreAssetsThanItMay() async throws {
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let account = account
        try await queue.write { db in
            for _ in 0 ..< AssetRepository.most {
                try db.execute(
                    sql: """
                    INSERT INTO assets (id, user_id, coven_id, type, status, title_ciphertext, details_ciphertext, created_at, updated_at)
                    VALUES (?, ?, '', 'image', 'draft', x'00', x'00', ?, ?)
                    """,
                    arguments: [UUID().uuidString, account, Date(), Date()]
                )
            }
        }
        await expect(.tooMany, "Strix keeps only so many") {
            _ = try await self.store.create(type: .image, title: "One more", files: [], inCoven: nil, as: self.account)
        }
        // Another scope has its own count.
        let coven = try await newCoven()
        _ = try await store.create(type: .image, title: "In the coven", files: [], inCoven: coven, as: account)
    }

    // MARK: - Where an asset is kept

    func testEachScopeHasItsOwnAssets_andACovenThatIsDeletedTakesItsAssetsAndTheirFiles() async throws {
        let coven = try await newCoven()
        let strixs = try await store.create(type: .image, title: "Strix's", files: [file("s.png")], inCoven: nil, as: account)
        let covens = try await store.create(type: .image, title: "The coven's", files: [file("c.png")], inCoven: coven, as: account)
        XCTAssertEqual(covens.covenID, coven)

        var inStrix = try await store.assets(inCoven: nil, as: account)
        let inCoven = try await store.assets(inCoven: coven, as: account)
        XCTAssertEqual(inStrix.map(\.id), [strixs.id])
        XCTAssertEqual(inCoven.map(\.id), [covens.id])

        try await CovenService.shared.deleteCoven(id: coven)
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let left = try await queue.read { db in
            try (
                Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets WHERE id = ?", arguments: [covens.id]) ?? -1,
                Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_files WHERE asset_id = ?", arguments: [covens.id]) ?? -1
            )
        }
        XCTAssertEqual(left.0, 0, "The coven's assets go with it")
        XCTAssertEqual(left.1, 0, "And their files with them")
        inStrix = try await store.assets(inCoven: nil, as: account)
        XCTAssertEqual(inStrix.map(\.id), [strixs.id], "Strix's stay")
    }

    func testAnAssetIsKeptOnlyInACovenOfTheSameAccount() async throws {
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let theirs = UUID().uuidString
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO covens (id, name, created_at, updated_at, user_id) VALUES (?, ?, ?, ?, ?)",
                arguments: [theirs, "Theirs", Date(), Date(), "someone-else"]
            )
        }
        addTeardownBlock {
            try? await queue.write { db in try db.execute(sql: "DELETE FROM covens WHERE id = ?", arguments: [theirs]) }
        }
        for coven in [theirs, "no-such-coven"] {
            await expect(.noSuchCoven, "An asset is not kept in a coven that is not the account's") {
                _ = try await self.store.create(type: .image, title: "Not here", files: [self.file("x.png")], inCoven: coven, as: self.account)
            }
        }
        // The store itself refuses such a row, whoever writes it.
        let account = account
        for (what, sql, arguments) in [
            ("in another account's coven", "INSERT INTO assets (id, user_id, coven_id, type, status, title_ciphertext, details_ciphertext, created_at, updated_at) VALUES ('a-row', ?, ?, 'image', 'draft', x'00', x'00', 0, 0)", [account, theirs]),
            ("for no account", "INSERT INTO assets (id, user_id, coven_id, type, status, title_ciphertext, details_ciphertext, created_at, updated_at) VALUES ('a-row', ' ', '', 'image', 'draft', x'00', x'00', 0, 0)", []),
        ] as [(String, String, StatementArguments)] {
            do {
                try await queue.write { db in try db.execute(sql: sql, arguments: arguments) }
                XCTFail("A row \(what) is refused")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
            }
        }
        let mine = try await store.create(type: .image, title: "Mine", files: [], inCoven: nil, as: account)
        do {
            try await queue.write { db in try db.execute(sql: "UPDATE assets SET coven_id = ? WHERE id = ?", arguments: [theirs, mine.id]) }
            XCTFail("Nor is one moved there")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
        }
        let kept = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets WHERE coven_id IN (?, 'no-such-coven') OR id = 'a-row'", arguments: [theirs])
        }
        XCTAssertEqual(kept, 0)
    }

    func testWhereItCameFromIsKeptOnlyForAThreadOfTheAccounts_andTheAssetStaysWhenTheThreadGoes() async throws {
        let mine = try await newThread(of: account)
        let theirs = try await newThread(of: "someone-else")
        let other = try await newThread(of: account)

        let made = try await store.create(
            type: .chart, title: "From a thread", files: [file("c.png")], inCoven: nil, madeBy: "agent-1",
            inThread: mine.thread, fromMessage: mine.message, as: account
        )
        XCTAssertEqual(made.threadID, mine.thread)
        XCTAssertEqual(made.sourceMessageID, mine.message)
        XCTAssertEqual(made.madeByAgentID, "agent-1")

        let holding = AttachmentStore.holdingThreadID(for: account)
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let account = account
        try await queue.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO threads (id, user_id, created_at, updated_at) VALUES (?, ?, ?, ?)", arguments: [holding, account, Date(), Date()]
            )
        }
        for (thread, message, what) in [
            (theirs.thread, nil, "another account's thread"),
            ("no-such-thread", nil, "a thread that is not there"),
            (holding, nil, "the row unsent files wait under"),
            (mine.thread, other.message, "a message of another thread"),
            (mine.thread, "no-such-message", "a message that is not there"),
        ] as [(String, String?, String)] {
            await expect(.noSuchThread, "Not kept as coming from \(what)") {
                _ = try await self.store.create(
                    type: .chart, title: "Not kept", files: [], inCoven: nil, inThread: thread, fromMessage: message, as: self.account
                )
            }
        }
        // A thread is of one place: an asset kept elsewhere does not come from it.
        let coven = try await newCoven()
        let covenThread = try await ThreadService.shared.createThread(title: "In the coven", covenId: coven)
        addTeardownBlock { try? await ThreadService.shared.deleteThread(threadId: covenThread.id) }
        await expect(.noSuchThread, "Not kept with Strix as coming from a coven's thread") {
            _ = try await self.store.create(type: .chart, title: "Not kept", files: [], inCoven: nil, inThread: covenThread.id, as: self.account)
        }
        await expect(.noSuchThread, "Not kept in a coven as coming from a thread in none") {
            _ = try await self.store.create(type: .chart, title: "Not kept", files: [], inCoven: coven, inThread: mine.thread, as: self.account)
        }
        let inCoven = try await store.create(type: .chart, title: "The coven's", files: [], inCoven: coven, inThread: covenThread.id, as: account)
        XCTAssertEqual(inCoven.threadID, covenThread.id)

        await expect(.noSuchThread, "A message is one of a thread") {
            _ = try await self.store.create(type: .chart, title: "Not kept", files: [], inCoven: nil, fromMessage: mine.message, as: self.account)
        }

        try await queue.write { db in try db.execute(sql: "DELETE FROM threads WHERE id = ?", arguments: [mine.thread]) }
        let listed = try await store.assets(inCoven: nil, as: account)
        XCTAssertEqual(listed.map(\.id), [made.id], "It stays when its thread is gone")
        XCTAssertEqual(listed.first?.files.count, 1)
    }

    // MARK: - Whose it is

    func testAnAssetIsReadAndChangedOnlyAsItsOwnAccount() async throws {
        let made = try await store.create(type: .image, title: "Mine", files: [file("m.png")], inCoven: nil, as: account)
        let fileID = try XCTUnwrap(made.files.first?.id)

        // As an account that is not signed in: nothing.
        for work in [
            { _ = try await self.store.assets(inCoven: nil, as: "someone-else") },
            { _ = try await self.store.data(ofFile: fileID, as: "someone-else") },
            { _ = try await self.store.move(made.id, to: .proposed, as: "someone-else") },
            // Nothing is said of what it gave, either.
            { _ = try await self.store.create(type: AssetType(rawValue: ""), title: "", files: [], inCoven: nil, as: "someone-else") },
        ] {
            do {
                try await work()
                XCTFail("Nothing is done as an account that is not signed in")
            } catch RepositoryError.accountChanged {}
        }

        // Another account's asset is not there for this one.
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        try await queue.write { db in
            try db.execute(sql: "UPDATE assets SET user_id = 'someone-else' WHERE id = ?", arguments: [made.id])
        }
        let listed = try await store.assets(inCoven: nil, as: account)
        XCTAssertEqual(listed.count, 0)
        await expect(.noSuchAsset, "Its file is not this account's to read") {
            _ = try await self.store.data(ofFile: fileID, as: self.account)
        }
        await expect(.noSuchAsset, "Nor is it this account's to move") {
            _ = try await self.store.move(made.id, to: .proposed, as: self.account)
        }
        let status = try await queue.read { db in try String.fetchOne(db, sql: "SELECT status FROM assets WHERE id = ?", arguments: [made.id]) }
        XCTAssertEqual(status, "draft")
    }

    func testNothingIsReadMadeOrChangedWhileTheDataIsLocked() async throws {
        let made = try await store.create(type: .image, title: "Kept", files: [file("k.png")], inCoven: nil, as: account)
        let fileID = try XCTUnwrap(made.files.first?.id)
        await DataEncryptionService.shared.lock()

        for work in [
            { _ = try await self.store.assets(inCoven: nil, as: self.account) },
            { _ = try await self.store.data(ofFile: fileID, as: self.account) },
            { _ = try await self.store.move(made.id, to: .proposed, as: self.account) },
            { _ = try await self.store.create(type: .image, title: "More", files: [], inCoven: nil, as: self.account) },
        ] {
            do {
                try await work()
                XCTFail("Nothing is done while the account's data is locked")
            } catch RepositoryError.dataLocked {}
        }

        await DataEncryptionService.shared.unlockForTestingEphemeral()
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let account = account
        let kept = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, status FROM assets WHERE user_id = ?", arguments: [account])
        }
        XCTAssertEqual(kept.map { $0["id"] as String }, [made.id], "As it was")
        XCTAssertEqual(kept.map { $0["status"] as String }, ["draft"])
    }

    func testAnAssetTheKeyCannotOpenIsListedAsUnreadable_andItsBytesAreNotRead() async throws {
        let old = try await store.create(
            type: .image, title: "Old", details: "Under another key.", files: [file("old.png")], inCoven: nil, madeBy: "agent-1", as: account
        )
        let oldFile = try XCTUnwrap(old.files.first?.id)
        // The account's key is another now.
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        let new = try await store.create(type: .image, title: "New", files: [file("new.png")], inCoven: nil, as: account)

        let listed = try await store.assets(inCoven: nil, as: account)
        XCTAssertEqual(listed.map(\.id), [new.id, old.id], "The rest is still read")
        let unreadable = try XCTUnwrap(listed.last)
        XCTAssertTrue(unreadable.isUnreadable)
        XCTAssertEqual(unreadable.title, "")
        XCTAssertEqual(unreadable.details, "")
        XCTAssertEqual(unreadable.files, [])
        XCTAssertEqual(unreadable.type, .image, "What is kept as it is, is still told")
        XCTAssertEqual(unreadable.madeByAgentID, "agent-1")
        XCTAssertFalse(listed[0].isUnreadable)

        await expect(.unreadable, "Its bytes cannot be opened") {
            _ = try await self.store.data(ofFile: oldFile, as: self.account)
        }
        // It can still be put out of the way.
        try await store.move(old.id, to: .archived, as: account)
    }

    func testAnAssetOfWhichOnlyAFileCannotBeOpenedIsUnreadableToo() async throws {
        let made = try await store.create(type: .image, title: "Whole", files: [file("a.png"), file("b.png")], inCoven: nil, as: account)
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        try await queue.write { db in
            try db.execute(sql: "UPDATE asset_files SET meta_ciphertext = x'0102' WHERE id = ?", arguments: [made.files[0].id])
        }
        let listed = try await store.assets(inCoven: nil, as: account)
        XCTAssertEqual(listed.map(\.isUnreadable), [true])
        XCTAssertEqual(listed.first?.files, [], "Not listed with some of its files as if they were all")
    }

    // MARK: - Status

    func testAnAssetMovesOnlyAsThePersonMay_decidedAgainstTheAssetAsItIs() async throws {
        let empty = try await store.create(type: .report, title: "No file yet", files: [], inCoven: nil, as: account)
        await expect(.needsAFile, "An asset with no file is not proposed") {
            _ = try await self.store.move(empty.id, to: .proposed, as: self.account)
        }
        try await store.move(empty.id, to: .archived, as: account)

        let made = try await store.create(type: .report, title: "Report", files: [file("r.md")], inCoven: nil, as: account)
        await expect(.notAllowed, "A draft is not approved unproposed") {
            _ = try await self.store.move(made.id, to: .approved, as: self.account)
        }
        try await store.move(made.id, to: .proposed, as: account)
        await expect(.notAllowed, "It is proposed once") {
            _ = try await self.store.move(made.id, to: .proposed, as: self.account)
        }
        try await store.move(made.id, to: .draft, as: account)
        try await store.move(made.id, to: .proposed, as: account)
        try await store.move(made.id, to: .approved, as: account)
        await expect(.notAllowed, "What is approved is not sent back") {
            _ = try await self.store.move(made.id, to: .draft, as: self.account)
        }
        try await store.move(made.id, to: .archived, as: account)
        await expect(.notAllowed, "What is archived comes back as a draft, not approved") {
            _ = try await self.store.move(made.id, to: .approved, as: self.account)
        }
        try await store.move(made.id, to: .draft, as: account)
        await expect(.noSuchAsset, "There is no such asset") {
            _ = try await self.store.move("no-such-asset", to: .archived, as: self.account)
        }

        let listed = try await store.assets(inCoven: nil, as: account)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: listed.map { ($0.id, $0.status) }), [empty.id: .archived, made.id: .draft])
    }

    func testAStatusThisVersionDoesNotKnowIsReadAsADraft() async throws {
        let made = try await store.create(type: .report, title: "From later", files: [file("r.md")], inCoven: nil, as: account)
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        try await queue.write { db in
            try db.execute(sql: "UPDATE assets SET status = 'superseded' WHERE id = ?", arguments: [made.id])
        }
        let listed = try await store.assets(inCoven: nil, as: account)
        XCTAssertEqual(listed.map(\.status), [.draft], "Nothing takes a draft for reviewed")
    }

    // MARK: - The rules by themselves

    func testTheMovesOfAStatus() {
        let allowed: [AssetStatus: Set<AssetStatus>] = [
            .draft: [.proposed, .archived],
            .proposed: [.approved, .draft, .archived],
            .approved: [.archived],
            .archived: [.draft],
        ]
        for from in AssetStatus.allCases {
            for to in AssetStatus.allCases {
                XCTAssertEqual(from.canMove(to: to), allowed[from]?.contains(to) == true, "\(from) to \(to)")
            }
        }
    }

    func testAFilesNameAsItIsKept() {
        XCTAssertEqual(AssetFile.keptName("chart.png"), "chart.png")
        XCTAssertEqual(AssetFile.keptName("/Users/ada/Desktop/chart.png"), "chart.png")
        XCTAssertEqual(AssetFile.keptName("..\\..\\boot.ini"), "boot.ini")
        XCTAssertEqual(AssetFile.keptName("a/b/"), "b")
        XCTAssertEqual(AssetFile.keptName("line\nbreak\u{0}.txt"), "linebreak.txt")
        XCTAssertEqual(AssetFile.keptName(".."), "file")
        XCTAssertEqual(AssetFile.keptName(""), "file")
        XCTAssertEqual(AssetFile.keptName(String(repeating: "n", count: 300)).count, 255)
    }

    func testATypesNameAndWords() {
        XCTAssertTrue(AssetType.designMockup.isName)
        XCTAssertEqual(AssetType.designMockup.displayName, "Design Mockup")
        XCTAssertEqual(AssetType.implementationBrief.iconSystemName, "doc.text")
        XCTAssertEqual(AssetType(rawValue: "moodboard").iconSystemName, "shippingbox", "A type the app has no icon for still has one")
        XCTAssertTrue(AssetType.offered.allSatisfy(\.isName))
    }
}
