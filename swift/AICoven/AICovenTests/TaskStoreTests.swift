@testable import AICoven
import GRDB
import XCTest

/// The account's tasks: kept with their titles encrypted, each in a coven
/// of the account's or with Strix, and read and changed only as the
/// account signed in.
@MainActor
final class TaskStoreTests: XCTestCase {
    private let store = TaskRepository.shared

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
            try db.execute(sql: "DELETE FROM tasks WHERE user_id IN (?, 'someone-else')", arguments: [account])
        }
    }

    /// A coven of the signed-in account's, deleted when the test ends.
    private func newCoven() async throws -> String {
        let coven = try await CovenService.shared.createCoven(name: "Tasks \(UUID().uuidString)")
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await CovenService.shared.deleteCoven(id: coven.id)
        }
        return coven.id
    }

    private func expect(_ expected: TaskError, _ what: String, _ work: () async throws -> Void) async {
        do {
            try await work()
            XCTFail(what)
        } catch let error as TaskError {
            XCTAssertEqual(error, expected, what)
        } catch {
            XCTFail("\(what): \(type(of: error))")
        }
    }

    private func day(_ written: String) throws -> TaskDueDate {
        try XCTUnwrap(TaskDueDate(rawValue: written))
    }

    /// What is stored of a task but which writing of it it is, as text.
    private func stored(_ id: String) async throws -> [String] {
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        return try await queue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM tasks WHERE id = ?", arguments: [id]) else { return [] }
            return [
                "title_ciphertext", "status", "stage", "due_date", "due_time", "pin_period", "pin_expires_at", "updated_at",
                "thread_id", "lead_agent_id", "handoff_turn_id",
            ].map {
                (row[$0] as DatabaseValue).description
            }
        }
    }

    /// Rows written as the store writes them, `count` of them, with the
    /// sealed title of `like`: many at once, without sealing each.
    private func insert(_ count: Int, status: String, like id: String, inCoven coven: String = "", changed: Date = Date()) async throws {
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let account = account
        try await queue.write { db in
            let title = try XCTUnwrap(Data.fetchOne(db, sql: "SELECT title_ciphertext FROM tasks WHERE id = ?", arguments: [id]))
            for _ in 0 ..< count {
                try db.execute(
                    sql: """
                    INSERT INTO tasks (id, user_id, coven_id, title_ciphertext, status, stage, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, 'backlog', ?, ?)
                    """,
                    arguments: [UUID().uuidString, account, coven, title, status, changed, changed]
                )
            }
        }
    }

    /// A clock that tells a later second each time it is asked.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var told = Date(timeIntervalSince1970: 1_800_000_000)

        func next() -> Date {
            lock.lock()
            defer { lock.unlock() }
            told += 1
            return told
        }
    }

    // MARK: - Making and reading

    func testATaskIsKeptOpenAtTheStartOfTheBoard_andReadBack() async throws {
        let due = try XCTUnwrap(TaskDue(date: day("2027-03-01"), time: "09:30"))
        let made = try await store.create(title: "  Book \n the venue ", due: due, inCoven: nil, as: account)
        XCTAssertEqual(made.title, "Book the venue")
        XCTAssertEqual(made.status, .open)
        XCTAssertEqual(made.stage, .backlog)
        XCTAssertEqual(made.due, due)
        XCTAssertNil(made.pin)
        XCTAssertNil(made.covenID, "Strix's")
        XCTAssertFalse(made.isFinished)

        let listing = try await store.tasks(inCoven: nil, as: account)
        XCTAssertEqual(listing.finished, 0)
        XCTAssertEqual(listing.tasks.count, 1)
        let read = try XCTUnwrap(listing.tasks.first)
        XCTAssertEqual(read.id, made.id)
        XCTAssertEqual(read.title, "Book the venue")
        XCTAssertEqual(read.due, due)
        XCTAssertEqual(read.status, .open)
        XCTAssertEqual(read.stage, .backlog)
        XCTAssertFalse(read.isUnreadable)

        let plain = try await store.create(title: "No day", inCoven: nil, as: account)
        XCTAssertNil(plain.due)
    }

    func testOpenTasksComeFirst_eachPartLastChangedFirst() async throws {
        let clock = Clock()
        let store = TaskRepository(now: { clock.next() })
        let first = try await store.create(title: "First", inCoven: nil, as: account)
        let second = try await store.create(title: "Second", inCoven: nil, as: account)
        let third = try await store.create(title: "Third", inCoven: nil, as: account)
        let fourth = try await store.create(title: "Fourth", inCoven: nil, as: account)
        var listing = try await store.tasks(inCoven: nil, as: account)
        XCTAssertEqual(listing.tasks.map(\.title), ["Fourth", "Third", "Second", "First"])

        try await store.change(first.id, TaskChange(stage: .inProgress), as: account)
        try await store.change(third.id, TaskChange(status: .done), as: account)
        try await store.change(fourth.id, TaskChange(status: .closed), as: account)
        listing = try await store.tasks(inCoven: nil, as: account)
        XCTAssertEqual(listing.tasks.map(\.title), ["First", "Second", "Fourth", "Third"], "Open ones first; within each, the one last changed first")
        XCTAssertEqual(listing.tasks.map(\.status), [.open, .open, .closed, .done])
        XCTAssertEqual(listing.tasks.map(\.isFinished), [false, false, true, true])
        XCTAssertEqual(listing.finished, 2)
        XCTAssertEqual(listing.tasks.first?.stage, .inProgress)
        _ = second

        // Of two changed in the same moment, the one made later comes first,
        // whichever was written first.
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        try await queue.write { db in
            try db.execute(sql: "UPDATE tasks SET updated_at = ?", arguments: [Date(timeIntervalSince1970: 0)])
            try db.execute(sql: "UPDATE tasks SET created_at = ? WHERE id = ?", arguments: [Date(timeIntervalSince1970: 2_000_000_000), first.id])
            try db.execute(sql: "UPDATE tasks SET created_at = ? WHERE id = ?", arguments: [Date(timeIntervalSince1970: 2_000_000_000), third.id])
        }
        listing = try await store.tasks(inCoven: nil, as: account)
        XCTAssertEqual(listing.tasks.map(\.title), ["First", "Second", "Third", "Fourth"])
    }

    func testAPinThatRanOutWhileItsChangeWaitedIsNotKept() async throws {
        // The clock is asked in the write itself: here it has moved on past the pin's end by then.
        let clock = Clock()
        let made = try await store.create(title: "Call the bank", inCoven: nil, as: account)
        let gate = Gate()
        let store = TaskRepository(at: { step in if step == .beforeWriting { await gate.wait() } }, now: { clock.next() })
        let ends = clock.next().addingTimeInterval(2)
        let account = account
        let pinning = Task { try await store.change(made.id, TaskChange(pin: .to(TaskPin(period: .today, expiresAt: ends))), as: account) }
        await gate.heard(arrivals: 1)
        for _ in 0 ..< 5 {
            _ = clock.next()
        }
        await gate.letThrough()
        do {
            try await pinning.value
            XCTFail("A pin ends at a time still to come when it is written")
        } catch TaskError.pinEnded {}
        let raw = try await stored(made.id)
        XCTAssertEqual(Array(raw[5 ... 6]), ["NULL", "NULL"])
    }

    func testAListingGivesEveryOpenTask_andOnlyTheFinishedOnesLastChanged_withHowManyThereAre() async throws {
        let open = try await store.create(title: "Still to do", inCoven: nil, as: account)
        let old = Date(timeIntervalSince1970: 1000)
        try await insert(TaskRepository.mostFinishedListed, status: "done", like: open.id, changed: old)
        try await insert(3, status: "open", like: open.id, changed: old)
        let latest = try await store.create(title: "Just closed", inCoven: nil, as: account)
        try await store.change(latest.id, TaskChange(status: .closed), as: account)

        let listing = try await store.tasks(inCoven: nil, as: account)
        XCTAssertEqual(listing.finished, TaskRepository.mostFinishedListed + 1, "Counted whether listed or not")
        XCTAssertEqual(listing.tasks.count(where: { !$0.isFinished }), 4, "Every open one")
        let finished = listing.tasks.filter(\.isFinished)
        XCTAssertEqual(finished.count, TaskRepository.mostFinishedListed)
        XCTAssertEqual(finished.first?.id, latest.id, "The ones last changed")
        XCTAssertEqual(listing.tasks.prefix(4).map(\.isFinished), [false, false, false, false])

        // A finished task that is not among them is listed too where it is asked for by name
        // (its details are on screen), after the others; one that is listed already is listed once.
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let account = account
        let unlisted = try await queue.read { db in
            try String.fetchOne(
                db, sql: "SELECT id FROM tasks WHERE user_id = ? AND status = 'done' AND id NOT IN (\(finished.map { "'\($0.id)'" }.joined(separator: ",")))",
                arguments: [account]
            )
        }
        let named = try XCTUnwrap(unlisted)
        let withIt = try await store.tasks(inCoven: nil, alsoListing: named, as: account)
        XCTAssertEqual(withIt.tasks.filter(\.isFinished).count, TaskRepository.mostFinishedListed + 1)
        XCTAssertEqual(withIt.tasks.last?.id, named)
        XCTAssertEqual(withIt.finished, listing.finished)
        let already = try await store.tasks(inCoven: nil, alsoListing: latest.id, as: account)
        XCTAssertEqual(already.tasks.map(\.id), listing.tasks.map(\.id))
        // Not one of another place, nor one that is not there.
        let coven = try await newCoven()
        let elsewhere = try await store.tasks(inCoven: coven, alsoListing: named, as: account)
        XCTAssertEqual(elsewhere.tasks.count, 0)
        let none = try await store.tasks(inCoven: nil, alsoListing: "no-such-task", as: account)
        XCTAssertEqual(none.tasks.count, listing.tasks.count)
    }

    func testNothingATaskSaysIsKeptInTheClear() async throws {
        let made = try await store.create(title: "Cancel the Lisbon offsite", inCoven: nil, as: account)
        try await store.change(made.id, TaskChange(title: "Postpone the Lisbon offsite"), as: account)
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let dump = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM tasks WHERE id = ?", arguments: [made.id])
                .flatMap { row in row.databaseValues.map { value in
                    (Data.fromDatabaseValue(value).map { String(decoding: $0, as: UTF8.self) } ?? "") + value.description
                } }
                .joined(separator: " ")
        }
        XCTAssertFalse(dump.isEmpty)
        for word in ["Lisbon", "offsite", "Cancel", "Postpone"] {
            XCTAssertFalse(dump.contains(word), word)
        }
    }

    func testATitleIsKeptTidy_andATaskWithNoneIsRefused() async throws {
        XCTAssertEqual(TaskRepository.keptTitle("  Send \t the\n\ninvoice  "), "Send the invoice")
        XCTAssertEqual(TaskRepository.keptTitle(String(repeating: "a", count: 300)).count, TaskRepository.longestTitle)
        XCTAssertEqual(TaskRepository.keptTitle(String(repeating: "a", count: 199) + " b"), String(repeating: "a", count: 199), "Not left ending in a space")

        await expect(.noTitle, "A task has a title") { _ = try await self.store.create(title: " \n ", inCoven: nil, as: self.account) }
        let made = try await store.create(title: "Kept", inCoven: nil, as: account)
        let before = try await stored(made.id)
        await expect(.noTitle, "And keeps one") { try await self.store.change(made.id, TaskChange(title: "  "), as: self.account) }
        await expect(.noSuchTask, "No such task") { try await self.store.change("no-such-task", TaskChange(status: .done), as: self.account) }
        let after = try await stored(made.id)
        XCTAssertEqual(after, before)
    }

    // MARK: - Whose it is, and where

    func testEachScopeHasItsOwnTasks_andACovenThatIsDeletedTakesItsTasks() async throws {
        let coven = try await newCoven()
        let strixs = try await store.create(title: "Strix's", inCoven: nil, as: account)
        let covens = try await store.create(title: "The coven's", inCoven: coven, as: account)
        XCTAssertEqual(covens.covenID, coven)

        let ofStrix = try await store.tasks(inCoven: nil, as: account)
        let ofCoven = try await store.tasks(inCoven: coven, as: account)
        XCTAssertEqual(ofStrix.tasks.map(\.id), [strixs.id])
        XCTAssertEqual(ofCoven.tasks.map(\.id), [covens.id])
        XCTAssertEqual(ofCoven.tasks.first?.covenID, coven)

        try await CovenService.shared.deleteCoven(id: coven)
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let left = try await queue.read { db in try String.fetchAll(db, sql: "SELECT id FROM tasks WHERE id IN (?, ?)", arguments: [strixs.id, covens.id]) }
        XCTAssertEqual(left, [strixs.id], "The coven's go with it; Strix's stay")
    }

    func testATaskIsKeptOnlyInACovenOfTheSameAccount() async throws {
        let coven = try await newCoven()
        await expect(.noSuchCoven, "No such coven") { _ = try await self.store.create(title: "Nowhere", inCoven: "no-such-coven", as: self.account) }

        // Whoever writes: a row for a coven that is not its account's is refused by the database.
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        // A coven's columns as they are now, to write a whole row of one by.
        let columns = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('covens')").joined(separator: ", ")
        }
        XCTAssertTrue(columns.contains("user_id"))
        let made = try await store.create(title: "In the coven", inCoven: coven, as: account)
        for sql in [
            "INSERT INTO tasks (id, user_id, coven_id, title_ciphertext, status, stage, created_at, updated_at) "
                + "VALUES ('t-x', 'someone-else', '\(coven)', x'01', 'open', 'backlog', '2026-01-01', '2026-01-01')",
            "INSERT INTO tasks (id, user_id, coven_id, title_ciphertext, status, stage, created_at, updated_at) "
                + "VALUES ('t-y', ' ', '', x'01', 'open', 'backlog', '2026-01-01', '2026-01-01')",
            "UPDATE tasks SET user_id = 'someone-else' WHERE id = '\(made.id)'",
            "UPDATE tasks SET coven_id = 'no-such-coven' WHERE id = '\(made.id)'",
            // Nor does the coven leave its tasks behind by changing hands, or its id,
            // or by being replaced outright with another account's row.
            "UPDATE covens SET user_id = 'someone-else' WHERE id = '\(coven)'",
            "UPDATE covens SET id = 'another-id' WHERE id = '\(coven)'",
            "INSERT OR REPLACE INTO covens (\(columns)) SELECT \(columns.replacingOccurrences(of: "user_id", with: "'someone-else'")) "
                + "FROM covens WHERE id = '\(coven)'",
        ] {
            do {
                try await queue.write { db in try db.execute(sql: sql) }
                XCTFail("Refused: \(sql.prefix(40))")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
            }
        }
        // The coven is still the account's, with its task; and replaced by a row of the same account it keeps it.
        try await queue.write { db in try db.execute(sql: "INSERT OR REPLACE INTO covens (\(columns)) SELECT \(columns) FROM covens WHERE id = ?", arguments: [coven]) }
        let kept = try await store.tasks(inCoven: coven, as: account)
        XCTAssertEqual(kept.tasks.map(\.id), [made.id])
    }

    func testATaskIsReadAndChangedOnlyAsItsOwnAccount() async throws {
        let made = try await store.create(title: "Mine", inCoven: nil, as: account)
        for work in [
            { _ = try await self.store.tasks(inCoven: nil, as: "someone-else") },
            { try await self.store.change(made.id, TaskChange(status: .done), as: "someone-else") },
            // Nothing is said of what it gave, either.
            { _ = try await self.store.create(title: "", inCoven: nil, as: "someone-else") },
        ] {
            do {
                try await work()
                XCTFail("Nothing is done as an account that is not signed in")
            } catch RepositoryError.accountChanged {}
        }

        // Another account's task is not there for this one.
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        try await queue.write { db in try db.execute(sql: "UPDATE tasks SET user_id = 'someone-else' WHERE id = ?", arguments: [made.id]) }
        let listing = try await store.tasks(inCoven: nil, as: account)
        XCTAssertEqual(listing, TaskListing(tasks: [], finished: 0))
        await expect(.noSuchTask, "Nor is it this account's to change") {
            try await self.store.change(made.id, TaskChange(status: .done), as: self.account)
        }
        let status = try await queue.read { db in try String.fetchOne(db, sql: "SELECT status FROM tasks WHERE id = ?", arguments: [made.id]) }
        XCTAssertEqual(status, "open")
    }

    func testNothingIsReadMadeOrChangedWhileTheDataIsLocked() async throws {
        let made = try await store.create(title: "Kept", inCoven: nil, as: account)
        let before = try await stored(made.id)
        await DataEncryptionService.shared.lock()

        for work in [
            { _ = try await self.store.tasks(inCoven: nil, as: self.account) },
            { try await self.store.change(made.id, TaskChange(status: .done), as: self.account) },
            { _ = try await self.store.create(title: "More", inCoven: nil, as: self.account) },
        ] {
            do {
                try await work()
                XCTFail("Nothing is done while the account's data is locked")
            } catch RepositoryError.dataLocked {}
        }

        await DataEncryptionService.shared.unlockForTestingEphemeral()
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let account = account
        let kept = try await queue.read { db in try String.fetchAll(db, sql: "SELECT id FROM tasks WHERE user_id = ?", arguments: [account]) }
        XCTAssertEqual(kept, [made.id])
        let after = try await stored(made.id)
        XCTAssertEqual(after, before, "As it was")
    }

    func testATaskTheKeyCannotOpenIsListedAsUnreadable_andCanBeClosedOrNamedAnew() async throws {
        let old = try await store.create(title: "Old", inCoven: nil, as: account)
        // The account's key is another now.
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        let new = try await store.create(title: "New", inCoven: nil, as: account)

        var listing = try await store.tasks(inCoven: nil, as: account)
        XCTAssertEqual(Set(listing.tasks.map(\.id)), [old.id, new.id], "The rest is still read")
        let unreadable = try XCTUnwrap(listing.tasks.first { $0.id == old.id })
        XCTAssertTrue(unreadable.isUnreadable)
        XCTAssertEqual(unreadable.title, "")
        XCTAssertEqual(unreadable.status, .open, "What is kept as it is, is still told")

        try await store.change(old.id, TaskChange(status: .closed), as: account)
        try await store.change(old.id, TaskChange(title: "Named anew"), as: account)
        listing = try await store.tasks(inCoven: nil, as: account)
        let renamed = try XCTUnwrap(listing.tasks.first { $0.id == old.id })
        XCTAssertFalse(renamed.isUnreadable)
        XCTAssertEqual(renamed.title, "Named anew")
        XCTAssertEqual(renamed.status, .closed)
    }

    // MARK: - Changing

    func testAChangeSetsWhatItNames_andNothingElse() async throws {
        let clock = Clock()
        let store = TaskRepository(now: { clock.next() })
        let made = try await store.create(title: "Draft the brief", inCoven: nil, as: account)
        func read() async throws -> TaskItem {
            let listing = try await store.tasks(inCoven: nil, as: account)
            return try XCTUnwrap(listing.tasks.first { $0.id == made.id })
        }

        let due = try XCTUnwrap(TaskDue(date: day("2027-01-15"), time: "17:00"))
        try await store.change(made.id, TaskChange(due: .to(due)), as: account)
        var task = try await read()
        XCTAssertEqual(task.due, due)
        XCTAssertEqual(task.title, "Draft the brief")
        XCTAssertEqual(task.stage, .backlog)
        XCTAssertGreaterThan(task.updatedAt, made.updatedAt)

        try await store.change(made.id, TaskChange(title: " Draft  the launch brief ", stage: .review), as: account)
        task = try await read()
        XCTAssertEqual(task.title, "Draft the launch brief")
        XCTAssertEqual(task.stage, .review)
        XCTAssertEqual(task.due, due, "What it does not name stays")

        let dayOnly = try XCTUnwrap(TaskDue(date: day("2027-01-16")))
        try await store.change(made.id, TaskChange(due: .to(dayOnly)), as: account)
        task = try await read()
        XCTAssertEqual(task.due, dayOnly, "A day given without a time has none")
        try await store.change(made.id, TaskChange(due: .cleared), as: account)
        task = try await read()
        XCTAssertNil(task.due)

        // A change that names nothing writes nothing.
        let before = try await stored(made.id)
        try await store.change(made.id, TaskChange(), as: account)
        let after = try await stored(made.id)
        XCTAssertEqual(after, before)
    }

    func testAPinIsForAnOpenTask_endsInTimeToCome_andIsNoChangeToTheTask() async throws {
        let clock = Clock()
        let store = TaskRepository(now: { clock.next() })
        let made = try await store.create(title: "Call the bank", inCoven: nil, as: account)
        func read() async throws -> TaskItem {
            let listing = try await store.tasks(inCoven: nil, as: account)
            return try XCTUnwrap(listing.tasks.first { $0.id == made.id })
        }
        let tonight = TaskPin(period: .today, expiresAt: clock.next().addingTimeInterval(3600))
        let sunday = TaskPin(period: .week, expiresAt: clock.next().addingTimeInterval(86400 * 3))

        try await store.change(made.id, TaskChange(pin: .to(tonight)), as: account)
        var task = try await read()
        XCTAssertEqual(task.pin, tonight)
        XCTAssertEqual(task.updatedAt, made.updatedAt, "A list ordered by when a task was changed does not move for a pin")
        try await store.change(made.id, TaskChange(pin: .to(sunday)), as: account)
        task = try await read()
        XCTAssertEqual(task.pin, sunday)
        try await store.change(made.id, TaskChange(pin: .cleared), as: account)
        task = try await read()
        XCTAssertNil(task.pin)
        XCTAssertEqual(task.updatedAt, made.updatedAt)

        await expect(.pinEnded, "A pin ends in time to come") {
            try await store.change(made.id, TaskChange(pin: .to(TaskPin(period: .today, expiresAt: Date(timeIntervalSince1970: 1_800_000_000)))), as: self.account)
        }

        // Finishing a task takes its pin; a finished task is given none; opened again it has none.
        try await store.change(made.id, TaskChange(pin: .to(tonight)), as: account)
        try await store.change(made.id, TaskChange(status: .done), as: account)
        var raw = try await stored(made.id)
        XCTAssertEqual(Array(raw[5 ... 6]), ["NULL", "NULL"], "Not kept either")
        task = try await read()
        XCTAssertNil(task.pin)
        XCTAssertGreaterThan(task.updatedAt, made.updatedAt)
        await expect(.finished, "A finished task is not pinned") {
            try await store.change(made.id, TaskChange(pin: .to(tonight)), as: self.account)
        }
        await expect(.finished, "Nor in the change that finishes it") {
            try await store.change(made.id, TaskChange(status: .closed, pin: .to(tonight)), as: self.account)
        }
        try await store.change(made.id, TaskChange(status: .open), as: account)
        task = try await read()
        XCTAssertNil(task.pin)
        XCTAssertEqual(task.status, .open)
        // Opened and pinned in one change.
        try await store.change(made.id, TaskChange(status: .done), as: account)
        try await store.change(made.id, TaskChange(status: .open, pin: .to(sunday)), as: account)
        task = try await read()
        XCTAssertEqual(task.pin, sunday)
        raw = try await stored(made.id)
        XCTAssertEqual(raw[5], "\"week\"")
    }

    func testPinsThatHaveRunOutAreKeptForTodayOrCleared_andOnlyThose() async throws {
        let clock = Clock()
        let store = TaskRepository(now: { clock.next() })
        func make(_ title: String, _ pin: TaskPin? = nil, done: Bool = false) async throws -> TaskItem {
            let made = try await store.create(title: title, inCoven: nil, as: account)
            if let pin { try await store.change(made.id, TaskChange(pin: .to(pin)), as: account) }
            if done { try await store.change(made.id, TaskChange(status: .done), as: account) }
            return made
        }
        let soon = clock.next().addingTimeInterval(30)
        let far = soon.addingTimeInterval(86400)
        let yesterdays = try await make("Yesterday's", TaskPin(period: .today, expiresAt: soon))
        let another = try await make("Another of yesterday's", TaskPin(period: .today, expiresAt: soon))
        let todays = try await make("Today's", TaskPin(period: .today, expiresAt: far))
        let weeks = try await make("Last week's", TaskPin(period: .week, expiresAt: soon))
        let unpinned = try await make("Not pinned")
        // The clock moves on past the first pins' end.
        for _ in 0 ..< 40 {
            _ = clock.next()
        }
        func read() async throws -> [String: TaskItem] {
            let listing = try await store.tasks(inCoven: nil, as: account)
            return Dictionary(uniqueKeysWithValues: listing.tasks.map { ($0.id, $0) })
        }
        let before = try await read()
        let everyone = [yesterdays.id, another.id, todays.id, weeks.id, unpinned.id, "no-such-task", yesterdays.id]

        // Kept for today: only what was pinned for a day that is over.
        let until = clock.next().addingTimeInterval(3600)
        let kept = try await store.answerLapsedPins(of: [yesterdays.id, todays.id, weeks.id, unpinned.id, "no-such-task", yesterdays.id], keepUntil: until, as: account)
        XCTAssertEqual(kept, [yesterdays.id])
        var after = try await read()
        XCTAssertEqual(after[yesterdays.id]?.pin, TaskPin(period: .today, expiresAt: until))
        XCTAssertEqual(after[yesterdays.id]?.updatedAt, before[yesterdays.id]?.updatedAt, "A pin is no change to the task")
        XCTAssertEqual(after[todays.id]?.pin, before[todays.id]?.pin, "One that has not run out is left")
        XCTAssertEqual(after[weeks.id]?.pin, before[weeks.id]?.pin, "A week's is not asked about")
        XCTAssertNil(after[unpinned.id]?.pin)

        // Cleared: again only those; one kept a moment ago has not run out now.
        let cleared = try await store.answerLapsedPins(of: everyone, keepUntil: nil, as: account)
        XCTAssertEqual(cleared, [another.id])
        after = try await read()
        XCTAssertNil(after[another.id]?.pin)
        XCTAssertNotNil(after[yesterdays.id]?.pin)
        XCTAssertNotNil(after[weeks.id]?.pin)

        // Nothing to answer for; a time to keep until that has passed; another account.
        let none = try await store.answerLapsedPins(of: [], keepUntil: nil, as: account)
        XCTAssertEqual(none, [])
        await expect(.pinEnded, "Kept until a time still to come") {
            _ = try await store.answerLapsedPins(of: everyone, keepUntil: Date(timeIntervalSince1970: 1_800_000_000), as: self.account)
        }
        do {
            _ = try await store.answerLapsedPins(of: everyone, keepUntil: nil, as: "someone-else")
            XCTFail("Nothing is done as an account that is not signed in")
        } catch RepositoryError.accountChanged {}
    }

    func testAnAnswerForPinsWrittenAfterTheDataWasLockedIsPutBack() async throws {
        let clock = Clock()
        let made = try await store.create(title: "Yesterday's", inCoven: nil, as: account)
        let writer = TaskRepository(now: { clock.next() })
        try await writer.change(made.id, TaskChange(pin: .to(TaskPin(period: .today, expiresAt: clock.next().addingTimeInterval(10)))), as: account)
        for _ in 0 ..< 20 {
            _ = clock.next()
        }
        let before = try await stored(made.id)

        let late = TaskRepository(at: { step in if step == .beforeWriting { await DataEncryptionService.shared.lock() } }, now: { clock.next() })
        for until in [clock.next().addingTimeInterval(3600), nil] {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            do {
                _ = try await late.answerLapsedPins(of: [made.id], keepUntil: until, as: account)
                XCTFail("Nothing is answered once the account's data is locked")
            } catch RepositoryError.dataLocked {}
            let after = try await stored(made.id)
            XCTAssertEqual(after, before, "Its pin as it stood")
        }
    }

    // MARK: - Its thread, its lead agent, the turn it is handed over in

    /// A thread of the signed-in account's in a coven (or in none),
    /// deleted when the test ends.
    private func newThread(inCoven coven: String?) async throws -> String {
        let thread = try await ThreadService.shared.createThread(title: "Task \(UUID().uuidString)", covenId: coven).id
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await DatabaseManager.shared.dbQueue?.write { db in try db.execute(sql: "DELETE FROM threads WHERE id = ?", arguments: [thread]) }
        }
        return thread
    }

    /// Rows written as the app writes them: an agent of a coven, and a turn of a thread.
    private func insertAgent(_ id: String, inCoven coven: String, of owner: String) async throws {
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO roles (id, coven_id, name, created_at, updated_at, user_id) VALUES (?, ?, 'Scout', ?, ?, ?)",
                arguments: [id, coven, Date(), Date(), owner]
            )
        }
        addTeardownBlock {
            try? await queue.write { db in try db.execute(sql: "DELETE FROM roles WHERE id = ?", arguments: [id]) }
        }
    }

    private func insertTurn(_ id: String, inThread thread: String, status: String) async throws {
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let account = account
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO turns (id, user_id, thread_id, status, started_at) VALUES (?, ?, ?, ?, ?)", arguments: [id, account, thread, status, Date()]
            )
        }
    }

    private func read(_ id: String, inCoven coven: String?) async throws -> TaskItem {
        let listing = try await store.tasks(inCoven: coven, as: account)
        return try XCTUnwrap(listing.tasks.first { $0.id == id })
    }

    func testATaskIsGivenAThreadOnce_andOnlyAThreadOfItsOwnPlace() async throws {
        let coven = try await newCoven()
        let covens = try await store.create(title: "The coven's", inCoven: coven, as: account)
        let strixs = try await store.create(title: "Strix's", inCoven: nil, as: account)
        let covenThread = try await newThread(inCoven: coven), strixThread = try await newThread(inCoven: nil)
        let before = try await stored(covens.id)

        await expect(.noSuchThread, "A thread of another place") {
            try await self.store.change(covens.id, TaskChange(threadID: strixThread), as: self.account)
        }
        await expect(.noSuchThread, "Nor Strix's task a coven's thread") {
            try await self.store.change(strixs.id, TaskChange(threadID: covenThread), as: self.account)
        }
        await expect(.noSuchThread, "No such thread") {
            try await self.store.change(covens.id, TaskChange(threadID: "no-such-thread"), as: self.account)
        }
        await expect(.noSuchThread, "Not the row the account's unsent files wait under") {
            try await self.store.change(strixs.id, TaskChange(threadID: AttachmentStore.holdingThreadID(for: self.account)), as: self.account)
        }
        await expect(.noSuchTask, "No such task") {
            try await self.store.change("no-such-task", TaskChange(threadID: covenThread), as: self.account)
        }
        let unchanged = try await stored(covens.id)
        XCTAssertEqual(unchanged, before)

        try await store.change(covens.id, TaskChange(threadID: covenThread), as: account)
        try await store.change(strixs.id, TaskChange(threadID: strixThread), as: account)
        var task = try await read(covens.id, inCoven: coven)
        XCTAssertEqual(task.threadID, covenThread)
        XCTAssertGreaterThanOrEqual(task.updatedAt, covens.updatedAt)
        let strixTask = try await read(strixs.id, inCoven: nil)
        XCTAssertEqual(strixTask.threadID, strixThread)

        // It keeps the thread it has; given the same again, nothing is refused.
        let another = try await newThread(inCoven: coven)
        await expect(.hasThread, "Given once") { try await self.store.change(covens.id, TaskChange(threadID: another), as: self.account) }
        try await store.change(covens.id, TaskChange(threadID: covenThread), as: account)

        // Whoever writes: a thread that is not the task's account's is refused by the database.
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        do {
            try await queue.write { db in try db.execute(sql: "UPDATE tasks SET thread_id = 'no-such-thread' WHERE id = ?", arguments: [strixs.id]) }
            XCTFail("Refused by the database")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
        }

        // A thread that is deleted leaves its task with no thread, and no hand-off.
        try await insertTurn("turn-of-\(covenThread)", inThread: covenThread, status: "completed")
        try await store.change(covens.id, TaskChange(handoffTurnID: "turn-of-\(covenThread)"), as: account)
        try await queue.write { db in try db.execute(sql: "DELETE FROM threads WHERE id = ?", arguments: [covenThread]) }
        task = try await read(covens.id, inCoven: coven)
        XCTAssertNil(task.threadID)
        XCTAssertNil(task.handoff)
        // And can be given another.
        try await store.change(covens.id, TaskChange(threadID: another), as: account)
    }

    func testATasksLeadAgentIsAnAgentOfItsCoven() async throws {
        let coven = try await newCoven(), other = try await newCoven()
        let made = try await store.create(title: "Led", inCoven: coven, as: account)
        let strixs = try await store.create(title: "Strix's", inCoven: nil, as: account)
        let scout = "scout-\(UUID().uuidString)", elsewhere = "elsewhere-\(UUID().uuidString)"
        try await insertAgent(scout, inCoven: coven, of: account)
        try await insertAgent(elsewhere, inCoven: other, of: account)

        await expect(.noSuchAgent, "An agent of another coven") {
            try await self.store.change(made.id, TaskChange(leadAgentID: .to(elsewhere)), as: self.account)
        }
        await expect(.noSuchAgent, "No such agent") {
            try await self.store.change(made.id, TaskChange(leadAgentID: .to("no-such-agent")), as: self.account)
        }
        await expect(.noSuchAgent, "Strix's tasks have no agent to name") {
            try await self.store.change(strixs.id, TaskChange(leadAgentID: .to(scout)), as: self.account)
        }

        try await store.change(made.id, TaskChange(leadAgentID: .to(scout)), as: account)
        var task = try await read(made.id, inCoven: coven)
        XCTAssertEqual(task.leadAgentID, scout)
        try await store.change(made.id, TaskChange(leadAgentID: .cleared), as: account)
        task = try await read(made.id, inCoven: coven)
        XCTAssertNil(task.leadAgentID)

        // An agent that is deleted leaves its tasks with no lead agent.
        try await store.change(made.id, TaskChange(leadAgentID: .to(scout)), as: account)
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        try await queue.write { db in try db.execute(sql: "DELETE FROM roles WHERE id = ?", arguments: [scout]) }
        task = try await read(made.id, inCoven: coven)
        XCTAssertNil(task.leadAgentID)
    }

    func testATaskIsHandedOverInATurnOfItsThread_andSaysHowThatTurnStands() async throws {
        let made = try await store.create(title: "Handed over", inCoven: nil, as: account)
        let thread = try await newThread(inCoven: nil), other = try await newThread(inCoven: nil)
        try await insertTurn("turn-1-\(thread)", inThread: thread, status: "running")
        try await insertTurn("turn-2-\(other)", inThread: other, status: "completed")

        await expect(.noSuchTurn, "A task with no thread has no turn") {
            try await self.store.change(made.id, TaskChange(handoffTurnID: "turn-1-\(thread)"), as: self.account)
        }
        // Given its thread and the turn in one change.
        await expect(.noSuchTurn, "A turn of another thread") {
            try await self.store.change(made.id, TaskChange(threadID: thread, handoffTurnID: "turn-2-\(other)"), as: self.account)
        }
        var task = try await read(made.id, inCoven: nil)
        XCTAssertNil(task.threadID, "Nothing of a change that was refused is kept")
        try await store.change(made.id, TaskChange(threadID: thread, handoffTurnID: "turn-1-\(thread)"), as: account)
        task = try await read(made.id, inCoven: nil)
        XCTAssertEqual(task.threadID, thread)
        XCTAssertEqual(task.handoff, TaskHandoff(turnID: "turn-1-\(thread)", outcome: .running, hasRun: false))

        // As the turn goes on, the task says so: read from the turn as it is stored.
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        try await queue.write { db in
            try db.execute(sql: "UPDATE turns SET status = 'completed', run_ciphertext = x'01' WHERE id = ?", arguments: ["turn-1-\(thread)"])
        }
        task = try await read(made.id, inCoven: nil)
        XCTAssertEqual(task.handoff, TaskHandoff(turnID: "turn-1-\(thread)", outcome: .completed, hasRun: true))
        await expect(.noSuchTurn, "No such turn") { try await self.store.change(made.id, TaskChange(handoffTurnID: "no-such-turn"), as: self.account) }

        // A later turn of the thread takes its place.
        try await insertTurn("turn-3-\(thread)", inThread: thread, status: "failed")
        try await store.change(made.id, TaskChange(handoffTurnID: "turn-3-\(thread)"), as: account)
        task = try await read(made.id, inCoven: nil)
        XCTAssertEqual(task.handoff?.outcome, .failed)
    }

    func testAPlaceKeepsNoMoreOpenTasksThanItMay_countedAsATaskIsMadeOrOpenedAgain() async throws {
        let coven = try await newCoven()
        let first = try await store.create(title: "First", inCoven: nil, as: account)
        let finished = try await store.create(title: "Finished", inCoven: nil, as: account)
        try await store.change(finished.id, TaskChange(status: .done), as: account)
        try await insert(TaskRepository.mostOpen - 1, status: "open", like: first.id)
        try await insert(5, status: "closed", like: first.id)

        await expect(.tooMany, "As many open tasks as it may") { _ = try await self.store.create(title: "One more", inCoven: nil, as: self.account) }
        await expect(.tooMany, "Opened again, it would be one more") {
            try await self.store.change(finished.id, TaskChange(status: .open), as: self.account)
        }
        // Another place has room of its own; and a task that is finished makes room.
        _ = try await store.create(title: "In the coven", inCoven: coven, as: account)
        try await store.change(first.id, TaskChange(status: .closed), as: account)
        try await store.change(finished.id, TaskChange(status: .open), as: account)
        await expect(.tooMany, "Full again") { _ = try await self.store.create(title: "One more", inCoven: nil, as: self.account) }
    }

    func testAStatusThisVersionDoesNotKnowIsReadAsClosed() async throws {
        let made = try await store.create(title: "From later", inCoven: nil, as: account)
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE tasks SET status = 'snoozed', stage = 'shipping', due_date = '2027-02-30', pin_period = 'month' WHERE id = ?",
                arguments: [made.id]
            )
        }
        let listing = try await store.tasks(inCoven: nil, as: account)
        XCTAssertEqual(listing.finished, 1, "Nothing takes it for a task still to do")
        let read = try XCTUnwrap(listing.tasks.first)
        XCTAssertEqual(read.status, .closed)
        XCTAssertEqual(read.stage, .backlog)
        XCTAssertNil(read.due, "A day that does not exist is no day")
        XCTAssertNil(read.pin)

        // Times that do not read as times do not stop the listing: the rest is still read.
        let other = try await store.create(title: "Read all the same", inCoven: nil, as: account)
        try await queue.write { db in
            try db.execute(
                sql: """
                UPDATE tasks SET status = 'open', pin_period = 'today', pin_expires_at = 'soon', created_at = 'once', updated_at = 'lately'
                WHERE id = ?
                """,
                arguments: [made.id]
            )
        }
        let again = try await store.tasks(inCoven: nil, as: account)
        XCTAssertEqual(Set(again.tasks.map(\.id)), [made.id, other.id])
        let odd = try XCTUnwrap(again.tasks.first { $0.id == made.id })
        XCTAssertNil(odd.pin, "No end, no pin")
        XCTAssertEqual(odd.updatedAt, .distantPast)
        XCTAssertEqual(odd.createdAt, .distantPast)
        XCTAssertEqual(odd.title, "From later")
    }

    // MARK: - A write that lands after the data was locked

    func testATaskWrittenAfterTheDataWasLockedIsTakenBack() async throws {
        // Locked once everything was sealed, before the write has its turn.
        let late = TaskRepository(at: { step in if step == .beforeWriting { await DataEncryptionService.shared.lock() } })
        do {
            _ = try await late.create(title: "Too late", inCoven: nil, as: account)
            XCTFail("Nothing is made once the account's data is locked")
        } catch RepositoryError.dataLocked {}
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let account = account
        let kept = try await queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks WHERE user_id = ?", arguments: [account]) }
        XCTAssertEqual(kept, 0)
    }

    func testAChangeWrittenAfterTheDataWasLockedIsPutBack() async throws {
        let due = try XCTUnwrap(TaskDue(date: day("2027-05-05"), time: "08:00"))
        let made = try await store.create(title: "As it stood", due: due, inCoven: nil, as: account)
        let pin = TaskPin(period: .today, expiresAt: Date().addingTimeInterval(3600))
        try await store.change(made.id, TaskChange(pin: .to(pin)), as: account)
        let before = try await stored(made.id)

        let late = TaskRepository(at: { step in if step == .beforeWriting { await DataEncryptionService.shared.lock() } })
        for change in [
            TaskChange(title: "Rejected", status: .done, stage: .review, due: .cleared),
            TaskChange(pin: .cleared),
        ] {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            // Sealed under the key of this session, which the lock then ends.
            do {
                try await late.change(made.id, change, as: account)
                XCTFail("Nothing is changed once the account's data is locked")
            } catch RepositoryError.dataLocked {}
            let after = try await stored(made.id)
            XCTAssertEqual(after, before, "Its title, status, stage, due day, pin and when it was changed, as they were")
        }
    }

    func testAThreadAnAgentOrATurnGivenAfterTheDataWasLockedIsTakenBack() async throws {
        let coven = try await newCoven()
        let covens = try await store.create(title: "The coven's", inCoven: coven, as: account)
        let strixs = try await store.create(title: "Strix's", inCoven: nil, as: account)
        let scout = "scout-\(UUID().uuidString)"
        try await insertAgent(scout, inCoven: coven, of: account)
        // A thread in no coven that needs no key to be placed: a row with nothing sealed in it.
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let thread = UUID().uuidString, account = account
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO threads (id, user_id, created_at, updated_at) VALUES (?, ?, ?, ?)", arguments: [thread, account, Date(), Date()])
        }
        addTeardownBlock {
            try? await queue.write { db in try db.execute(sql: "DELETE FROM threads WHERE id = ?", arguments: [thread]) }
        }
        try await insertTurn("turn-\(thread)", inThread: thread, status: "running")
        let before = try await [stored(covens.id), stored(strixs.id)]

        let late = TaskRepository(at: { step in if step == .beforeWriting { await DataEncryptionService.shared.lock() } })
        for (id, change) in [
            (covens.id, TaskChange(leadAgentID: .to(scout))),
            (strixs.id, TaskChange(threadID: thread, handoffTurnID: "turn-\(thread)")),
        ] {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            do {
                try await late.change(id, change, as: account)
                XCTFail("Nothing is changed once the account's data is locked")
            } catch RepositoryError.dataLocked {}
        }
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        let after = try await [stored(covens.id), stored(strixs.id)]
        XCTAssertEqual(after, before, "No lead agent, thread or turn of theirs, and changed when they were")
    }

    /// Holds whoever comes to it until the test lets them through, and
    /// tells the test who has come.
    private actor Gate {
        private var held: [CheckedContinuation<Void, Never>] = []
        private(set) var arrivals = 0
        private var noted = 0
        private var hearing: [(arrivals: Int, noted: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                held.append(continuation)
                arrivals += 1
                tell()
            }
        }

        /// Something happened that the test waits to hear of.
        func note() {
            noted += 1
            tell()
        }

        private func tell() {
            for heard in hearing where arrivals >= heard.arrivals && noted >= heard.noted {
                heard.continuation.resume()
            }
            hearing.removeAll { arrivals >= $0.arrivals && noted >= $0.noted }
        }

        /// Returns once this many have come to wait and this many things were noted.
        func heard(arrivals wanted: Int = 0, noted wantedNoted: Int = 0) async {
            if arrivals >= wanted, noted >= wantedNoted { return }
            await withCheckedContinuation { hearing.append((wanted, wantedNoted, $0)) }
        }

        func letThrough() {
            held.forEach { $0.resume() }
            held = []
        }
    }

    func testAChangeAskedBeforeTheDataWasLockedIsNotMadeAfterItIsUnlockedAgain() async throws {
        let made = try await store.create(title: "Kept", inCoven: nil, as: account)
        let before = try await stored(made.id)

        // The first change waits just before its write; two more are asked and wait their turn behind it.
        let gate = Gate()
        let late = TaskRepository(at: { step in
            switch step {
            case .asked: await gate.note()
            case .beforeWriting: await gate.wait()
            }
        })
        let account = account
        let first = Task { try await late.change(made.id, TaskChange(title: "Rejected title"), as: account) }
        await gate.heard(arrivals: 1)
        let queued = [
            Task { try await late.change(made.id, TaskChange(status: .done), as: account) },
            Task { try await late.change(made.id, TaskChange(stage: .review), as: account) },
        ]
        await gate.heard(noted: 3)
        // Locked, and unlocked again, while they wait: the session they were asked in is over.
        await DataEncryptionService.shared.lock()
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        await gate.letThrough()

        let asked = [(first, "The change under way")] + queued.enumerated().map { ($0.element, "Queued change \($0.offset + 1)") }
        for (change, what) in asked {
            do {
                try await change.value
                XCTFail("\(what) is not made in a later session")
            } catch RepositoryError.accountChanged {}
        }
        let arrivals = await gate.arrivals
        XCTAssertEqual(arrivals, 1, "None of those that waited came to write")
        let after = try await stored(made.id)
        XCTAssertEqual(after, before, "As it stood: no title, status or stage of theirs")
    }

    func testTwoChangesThatOverlapALockLeaveTheTaskAsItStood() async throws {
        let made = try await store.create(title: "Kept", inCoven: nil, as: account)
        let before = try await stored(made.id)

        // Both are asked in one session; the first is held just before its write, the data is locked, and both then go on.
        let gate = Gate()
        let late = TaskRepository(at: { step in
            switch step {
            case .asked: await gate.note()
            case .beforeWriting: await gate.wait()
            }
        })
        let account = account
        let first = Task { try await late.change(made.id, TaskChange(status: .done), as: account) }
        await gate.heard(arrivals: 1)
        let second = Task { try await late.change(made.id, TaskChange(status: .closed), as: account) }
        await gate.heard(noted: 2)
        await DataEncryptionService.shared.lock()
        await gate.letThrough()

        for change in [first, second] {
            do {
                try await change.value
                XCTFail("Neither is made once the data is locked")
            } catch RepositoryError.dataLocked {}
        }
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        let after = try await stored(made.id)
        XCTAssertEqual(after, before, "Open, as it stood, and changed when it was")
    }

    // MARK: - The model by itself

    func testADueDayIsADayThatExists_writtenAsTheCloudAppWritesIt() throws {
        XCTAssertEqual(TaskDueDate(rawValue: "2027-02-28")?.rawValue, "2027-02-28")
        XCTAssertNotNil(TaskDueDate(rawValue: "2028-02-29"), "A leap day")
        for written in ["2027-02-29", "2027-13-01", "2027-00-10", "2027-1-5", "27-01-05", "2027-01-05T00:00", "2027/01/05", "", "２０２７-01-05", "2027-01-0x"] {
            XCTAssertNil(TaskDueDate(rawValue: written), written)
        }
        XCTAssertLessThan(try day("2027-01-31"), try day("2027-02-01"))

        // The day a moment falls on is the person's own: the same moment is another day elsewhere.
        var auckland = Calendar(identifier: .gregorian)
        auckland.timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Auckland"))
        var honolulu = Calendar(identifier: .gregorian)
        honolulu.timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Honolulu"))
        let moment = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00 UTC
        XCTAssertEqual(TaskDueDate(day: moment, in: auckland)?.rawValue, "2027-01-15")
        XCTAssertEqual(TaskDueDate(day: moment, in: honolulu)?.rawValue, "2027-01-14")
        // Whatever calendar the person keeps, the day is written in the Gregorian one.
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = auckland.timeZone
        XCTAssertEqual(TaskDueDate(day: moment, in: buddhist)?.rawValue, "2027-01-15")

        // Overdue from the day after, not on the day itself.
        let due = try day("2027-01-14")
        XCTAssertFalse(due.isOverdue(asOf: moment, calendar: honolulu))
        XCTAssertTrue(due.isOverdue(asOf: moment, calendar: auckland))
    }

    func testADueTimeIsATimeOfDay() throws {
        let date = try day("2027-01-15")
        XCTAssertEqual(TaskDue(date: date, time: "00:00")?.time, "00:00")
        XCTAssertEqual(TaskDue(date: date, time: "23:59")?.time, "23:59")
        XCTAssertNil(try XCTUnwrap(TaskDue(date: date)).time)
        for time in ["24:00", "12:60", "9:30", "09:3", "0930", "09:30:00", "ab:cd", ""] {
            XCTAssertNil(TaskDue(date: date, time: time), time)
        }
    }
}
