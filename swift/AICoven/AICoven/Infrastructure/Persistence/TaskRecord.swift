import Foundation
import GRDB

/// Why a task was not kept, changed or read.
enum TaskError: Error, Equatable {
    /// There is no such task of the account's.
    case noSuchTask
    /// A task has a title.
    case noTitle
    /// The coven (or Strix) has as many open tasks as it may.
    case tooMany
    /// The coven it is to be kept in is not a coven of the account's.
    case noSuchCoven
    /// A task that is done or closed is not pinned.
    case finished
    /// A pin ends at a time still to come.
    case pinEnded
    /// The task has a thread already: it keeps the one it has.
    case hasThread
    /// The thread is not a thread of the account's in the task's place.
    case noSuchThread
    /// The agent is not an agent of the task's coven.
    case noSuchAgent
    /// The turn is not a turn of the task's thread.
    case noSuchTurn
}

/// A coven's tasks (or Strix's) as a listing gives them.
nonisolated struct TaskListing: Equatable {
    /// Those still open, all of them, and after them the finished ones
    /// last changed, as many as a listing gives; within each, the one
    /// last changed first.
    let tasks: [TaskItem]
    /// How many are finished in all, listed or not.
    let finished: Int
    /// The agent the place's latest hand-off went to, of every task of
    /// the place, listed or not: an agent that is still there.
    var lastHandedTo: String?
}

/// The account's tasks, kept on the device: each in a coven of the
/// account's, or with Strix (an empty coven id). A task's title is
/// encrypted with the account's key; whether it is open, how far along it
/// is, the day it is due, its pin and its times are kept as they are, to
/// list and order it by. A task is read, made and changed only as the
/// account signed in, with its own key in memory. There is no deleting a
/// task, as in the cloud app: it is closed.
actor TaskRepository {
    static let shared = TaskRepository()

    /// The longest title, in characters.
    static let longestTitle = 200
    /// The most open tasks kept in one coven, or with Strix.
    static let mostOpen = 1000
    /// The most finished tasks a listing gives.
    static let mostFinishedListed = 200

    private static let titlePurpose = "task_title"

    /// Where a test may step in: nothing in the app does.
    enum Step {
        /// A change to a stored task was asked for, before it waits its turn.
        case asked
        /// Just before a write, after everything it writes was looked at
        /// and sealed.
        case beforeWriting
    }

    private let at: (@Sendable (Step) async -> Void)?
    private let now: @Sendable () -> Date

    init(at: (@Sendable (Step) async -> Void)? = nil, now: (@Sendable () -> Date)? = nil) {
        self.at = at
        self.now = now ?? { Date() }
    }

    private func getDbQueue() async -> DatabaseQueue? {
        await MainActor.run { DatabaseManager.shared.dbQueue }
    }

    /// Takes back what a rejected write wrote, whatever became of whoever
    /// asked: one that was called off still has its write taken back. If
    /// it cannot be, that is logged, by its kind only.
    private func takeBack(in dbQueue: DatabaseQueue, _ undo: @escaping @Sendable (Database) throws -> Void) async {
        await Task {
            do {
                try await dbQueue.write(undo)
            } catch {
                AppErrorReporter.log(message: "A rejected task write could not be taken back (\(type(of: error)))", context: "TaskRepository")
            }
        }.value
    }

    /// A title as it is kept: one line, single spaces, no longer than the
    /// longest.
    static func keptTitle(_ given: String) -> String {
        let oneLine = given.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(oneLine.prefix(longestTitle)).trimmingCharacters(in: .whitespaces)
    }

    private nonisolated static func openTasks(of account: String, inCoven coven: String, in db: Database) throws -> Int {
        try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM tasks WHERE user_id = ? AND coven_id = ? AND status = ?", arguments: [account, coven, TaskStatus.open.rawValue]
        ) ?? 0
    }

    // MARK: - Making

    /// Keeps a new task in `account`'s coven (Strix for nil): open, at the
    /// start of the board, as the cloud app adds one by hand, and only in
    /// a coven of the account's. Throws unless `account` is the one signed
    /// in with its own key in memory.
    func create(title: String, due: TaskDue? = nil, inCoven covenID: String?, as account: String) async throws -> TaskItem {
        // Whoever asks is the account signed in, before anything is said
        // of what was given; and with the same key in memory from here
        // until the task has been written.
        let epoch = await DataEncryptionService.shared.keyEpoch
        try await AccountSeal.requireKey(of: account, since: epoch)
        let title = Self.keptTitle(title)
        guard !title.isEmpty else { throw TaskError.noTitle }
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        let sealedTitle = try await AccountSeal.seal(title, purpose: Self.titlePurpose, for: account)

        let id = UUID().uuidString
        let made = now()
        let coven = covenID ?? ""
        await at?(.beforeWriting)
        try await dbQueue.write { db in
            // Counted in the write that adds it.
            guard try Self.openTasks(of: account, inCoven: coven, in: db) < Self.mostOpen else { throw TaskError.tooMany }
            if !coven.isEmpty {
                let isTheirs = try Bool.fetchOne(db, sql: "SELECT 1 FROM covens WHERE id = ? AND user_id = ?", arguments: [coven, account]) ?? false
                guard isTheirs else { throw TaskError.noSuchCoven }
            }
            try db.execute(
                sql: """
                INSERT INTO tasks (id, user_id, coven_id, title_ciphertext, status, stage, due_date, due_time, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    id, account, coven, sealedTitle, TaskStatus.open.rawValue, TaskStage.backlog.rawValue, due?.date.rawValue, due?.time, made, made,
                ]
            )
        }
        do {
            try await AccountSeal.requireKey(of: account, since: epoch)
        } catch {
            // The account's data was locked, or changed hands, while the
            // write waited its turn: what it wrote is taken back.
            await takeBack(in: dbQueue) { db in
                try db.execute(sql: "DELETE FROM tasks WHERE id = ? AND user_id = ?", arguments: [id, account])
            }
            throw error
        }
        return TaskItem(id: id, covenID: covenID, title: title, status: .open, stage: .backlog, due: due, pin: nil, createdAt: made, updatedAt: made)
    }

    // MARK: - Changing

    /// One change to a stored task at a time: each waits for the one
    /// before it to be written and, if it must be, put back. Two that
    /// overlapped while the data was being locked could otherwise put
    /// back each other's rejected write in place of how the task stood.
    ///
    /// A change is `account`'s as its data stood when the change was asked
    /// for: the key's epoch is read then, before the change waits, and the
    /// change is made only if the same key is still in memory when its
    /// turn comes (and until it has been written). One asked for before
    /// the data was locked is not made after it was unlocked again.
    private func inTurn<Done: Sendable>(
        as account: String, _ change: @escaping @Sendable (_ epoch: Int) async throws -> Done
    ) async throws -> Done {
        let epoch = await DataEncryptionService.shared.keyEpoch
        try await AccountSeal.requireKey(of: account, since: epoch)
        let before = lastChange
        let changing = Task { () throws -> Done in
            await self.at?(.asked)
            await before?.value
            try await AccountSeal.requireKey(of: account, since: epoch)
            return try await change(epoch)
        }
        lastChange = Task { _ = try? await changing.value }
        return try await changing.value
    }

    /// The change last asked for, done or not.
    private var lastChange: Task<Void, Never>?

    /// What a change writes of a task, in the order it is put back by.
    private static let changed = [
        "title_ciphertext", "status", "stage", "due_date", "due_time", "pin_period", "pin_expires_at", "updated_at",
        "thread_id", "lead_agent_id", "handoff_turn_id", "handoff_agent_id",
    ]

    /// Changes one of `account`'s tasks: what `change` names, and nothing
    /// else. What it comes to is decided in the write itself, against the
    /// task as it is then:
    /// - a task that is finished (by this change or before it) has no
    ///   pin, and is not given one (`TaskError.finished`);
    /// - a pin ends at a time still to come (`TaskError.pinEnded`);
    /// - a task is opened again only while its place has room for one
    ///   more open task (`TaskError.tooMany`);
    /// - a pin set or taken away leaves when the task was last changed as
    ///   it is: a list ordered by that does not move for a pin;
    /// - a task is given a thread once (`TaskError.hasThread`), and only a
    ///   thread of the account's in the task's own place: its coven's, or
    ///   for Strix's a thread in no coven (`TaskError.noSuchThread`);
    /// - its lead agent is an agent of its coven (`TaskError.noSuchAgent`;
    ///   Strix's tasks have none to name);
    /// - the turn it is handed over in is a turn of its thread
    ///   (`TaskError.noSuchTurn`), and the agent it is handed to in it an
    ///   agent of its coven (`TaskError.noSuchAgent`), or Strix (none).
    /// A new title is sealed with the account's key, also for a task whose
    /// title could not be opened. It takes its turn among the changes to
    /// stored tasks (`inTurn`).
    func change(_ id: String, _ change: TaskChange, as account: String) async throws {
        try await inTurn(as: account) { epoch in try await self.changeInTurn(id, change, as: account, since: epoch) }
    }

    private func changeInTurn(_ id: String, _ change: TaskChange, as account: String, since epoch: Int) async throws {
        let title = change.title.map(Self.keptTitle)
        if let title, title.isEmpty { throw TaskError.noTitle }
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        var sealed: Data?
        if let title { sealed = try await AccountSeal.seal(title, purpose: Self.titlePurpose, for: account) }
        // A change that names nothing writes nothing.
        guard change != TaskChange() else { return }
        if let threadID = change.threadID {
            // A thread's coven is read from the thread as it is stored,
            // and the task's from the task: neither changes afterwards.
            let place = try await dbQueue.read { db in
                try String.fetchOne(db, sql: "SELECT coven_id FROM tasks WHERE id = ? AND user_id = ?", arguments: [id, account])
            }
            guard let place else { throw TaskError.noSuchTask }
            let threadsCoven: String?
            do {
                threadsCoven = try await ThreadRepository.shared.covenID(ofThread: threadID, for: account)
            } catch is ThreadLookupError {
                throw TaskError.noSuchThread
            }
            guard (threadsCoven ?? "") == place else { throw TaskError.noSuchThread }
        }
        let newTitle = sealed
        let now = now
        let holding = AttachmentStore.holdingThreadID(for: account)
        await at?(.beforeWriting)
        // How it stood before, as it is stored, to put it back by, and
        // which writing of it this one is.
        let written: (before: [DatabaseValue], revision: Int) = try await dbQueue.write { db in
            guard let stored = try Row.fetchOne(db, sql: "SELECT * FROM tasks WHERE id = ? AND user_id = ?", arguments: [id, account]) else {
                throw TaskError.noSuchTask
            }
            // The time of the write itself: a pin that ran out while the
            // change waited its turn is not kept.
            let moment = now()
            let wasOpen = (stored["status"] as String) == TaskStatus.open.rawValue
            let isOpen = change.status.map { $0 == .open } ?? wasOpen
            if isOpen, !wasOpen {
                guard try Self.openTasks(of: account, inCoven: stored["coven_id"], in: db) < Self.mostOpen else { throw TaskError.tooMany }
            }
            var due: (date: String?, time: String?) = (stored["due_date"], stored["due_time"])
            switch change.due {
            case let .to(new): due = (new.date.rawValue, new.time)
            case .cleared: due = (nil, nil)
            case nil: break
            }
            var pin: (period: String?, ends: DatabaseValue) = (stored["pin_period"], stored["pin_expires_at"])
            switch change.pin {
            case let .to(new):
                guard isOpen else { throw TaskError.finished }
                guard new.expiresAt > moment else { throw TaskError.pinEnded }
                pin = (new.period.rawValue, new.expiresAt.databaseValue)
            case .cleared: pin = (nil, .null)
            case nil: break
            }
            // Finishing a task takes its pin, as in the cloud app.
            if !isOpen { pin = (nil, .null) }
            var thread: String? = stored["thread_id"]
            if let given = change.threadID, given != thread {
                guard thread == nil else { throw TaskError.hasThread }
                // A thread of the account's: not the row its unsent files wait under.
                let isTheirs = try Bool.fetchOne(
                    db, sql: "SELECT 1 FROM threads WHERE id = ? AND user_id = ? AND id <> ?", arguments: [given, account, holding]
                ) ?? false
                guard isTheirs else { throw TaskError.noSuchThread }
                thread = given
            }
            let coven: String = stored["coven_id"]
            func isOfTheCoven(_ agent: String) throws -> Bool {
                try !coven.isEmpty && Bool.fetchOne(
                    db, sql: "SELECT 1 FROM roles WHERE id = ? AND user_id = ? AND coven_id = ?", arguments: [agent, account, coven]
                ) ?? false
            }
            var lead: String? = stored["lead_agent_id"]
            switch change.leadAgentID {
            case let .to(agent):
                guard try isOfTheCoven(agent) else { throw TaskError.noSuchAgent }
                lead = agent
            case .cleared: lead = nil
            case nil: break
            }
            var handoff: (turn: String?, agent: String?) = (stored["handoff_turn_id"], stored["handoff_agent_id"])
            if let turn = change.handoffTurnID {
                let isOfTheThread = try thread != nil && Bool.fetchOne(
                    db, sql: "SELECT 1 FROM turns WHERE id = ? AND user_id = ? AND thread_id = ?", arguments: [turn, account, thread]
                ) ?? false
                guard isOfTheThread else { throw TaskError.noSuchTurn }
                if let agent = change.handoffAgentID {
                    guard try isOfTheCoven(agent) else { throw TaskError.noSuchAgent }
                }
                // The turn and who it was handed to are written together.
                handoff = (turn, change.handoffAgentID)
            }
            // A pin alone is no change to the task.
            let touches = change != TaskChange(pin: change.pin)
            let revision: Int = stored["revision"]
            try db.execute(
                sql: """
                UPDATE tasks SET title_ciphertext = ?, status = ?, stage = ?, due_date = ?, due_time = ?, pin_period = ?, pin_expires_at = ?,
                                 updated_at = ?, thread_id = ?, lead_agent_id = ?, handoff_turn_id = ?, handoff_agent_id = ?,
                                 revision = ?
                WHERE id = ? AND user_id = ?
                """,
                arguments: [
                    newTitle ?? (stored["title_ciphertext"] as Data), change.status?.rawValue ?? (stored["status"] as String),
                    change.stage?.rawValue ?? (stored["stage"] as String), due.date, due.time, pin.period, pin.ends,
                    touches ? moment.databaseValue : (stored["updated_at"] as DatabaseValue), thread, lead, handoff.turn, handoff.agent,
                    revision + 1, id, account,
                ]
            )
            return (Self.changed.map { stored[$0] as DatabaseValue }, revision + 1)
        }
        do {
            try await AccountSeal.requireKey(of: account, since: epoch)
        } catch {
            // Locked, or another account's, while the write waited its
            // turn: the task is put back as it stood, unless something
            // has written it since.
            await takeBack(in: dbQueue) { db in
                try db.execute(
                    sql: """
                    UPDATE tasks SET \(Self.changed.map { "\($0) = ?" }.joined(separator: ", ")), revision = revision + 1
                    WHERE id = ? AND user_id = ? AND revision = ?
                    """,
                    arguments: StatementArguments(written.before + [id.databaseValue, account.databaseValue, written.revision.databaseValue])
                )
            }
            throw error
        }
    }

    // MARK: - Pins that have run out

    /// Answers "Still on today?" for these of `account`'s tasks, in one
    /// write: each that is open and pinned for a day that is over (at the
    /// time of the write) is kept for today, its pin ending at `keepUntil`,
    /// or loses its pin (nil). A task that is not, because it was pinned
    /// again, finished or answered meanwhile, is left as it is. Answers
    /// with the tasks it changed. Like any pin, this leaves when a task
    /// was last changed as it is. It takes its turn among the changes.
    @discardableResult
    func answerLapsedPins(of ids: [String], keepUntil: Date?, as account: String) async throws -> Set<String> {
        try await inTurn(as: account) { epoch in try await self.answerLapsedPinsInTurn(of: ids, keepUntil: keepUntil, as: account, since: epoch) }
    }

    private func answerLapsedPinsInTurn(of ids: [String], keepUntil: Date?, as account: String, since epoch: Int) async throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        let now = now
        await at?(.beforeWriting)
        // Each task it changed, with its pin's end as it was stored and
        // which writing of the task this one is, to put it back by.
        let written: [(id: String, ends: DatabaseValue, revision: Int)] = try await dbQueue.write { db in
            let moment = now()
            if let keepUntil, keepUntil <= moment { throw TaskError.pinEnded }
            var changed: [(id: String, ends: DatabaseValue, revision: Int)] = []
            for id in Set(ids) {
                let stored = try Row.fetchOne(
                    db, sql: "SELECT status, pin_period, pin_expires_at, revision FROM tasks WHERE id = ? AND user_id = ?", arguments: [id, account]
                )
                guard let stored, (stored["status"] as String) == TaskStatus.open.rawValue,
                      (stored["pin_period"] as String?) == TaskPinPeriod.today.rawValue,
                      let ends = Date.fromDatabaseValue(stored["pin_expires_at"]), ends <= moment else { continue }
                let revision: Int = stored["revision"]
                try db.execute(
                    sql: "UPDATE tasks SET pin_period = ?, pin_expires_at = ?, revision = ? WHERE id = ? AND user_id = ?",
                    arguments: [keepUntil == nil ? nil : TaskPinPeriod.today.rawValue, keepUntil, revision + 1, id, account]
                )
                changed.append((id, stored["pin_expires_at"], revision + 1))
            }
            return changed
        }
        do {
            try await AccountSeal.requireKey(of: account, since: epoch)
        } catch {
            // Locked, or another account's, while the write waited its
            // turn: each pin is put back as it stood, unless something has
            // written its task since.
            await takeBack(in: dbQueue) { db in
                for task in written {
                    try db.execute(
                        sql: """
                        UPDATE tasks SET pin_period = ?, pin_expires_at = ?, revision = revision + 1
                        WHERE id = ? AND user_id = ? AND revision = ?
                        """,
                        arguments: [TaskPinPeriod.today.rawValue, task.ends, task.id, account, task.revision]
                    )
                }
            }
            throw error
        }
        return Set(written.map(\.id))
    }

    // MARK: - Reading

    /// A task's row as it is stored: what is kept as it is, and its
    /// sealed title.
    private struct Stored {
        let id: String
        let covenID: String
        let title: Data
        let status: String
        let stage: String
        let dueDate: String?
        let dueTime: String?
        let pinPeriod: String?
        let pinEnds: Date?
        let threadID: String?
        let leadAgentID: String?
        let handoffTurnID: String?
        let handoffAgentID: String?
        let handoffStatus: String?
        let handoffHasRun: Bool
        let createdAt: Date
        let updatedAt: Date

        init(_ row: Row) {
            id = row["id"]
            covenID = row["coven_id"]
            title = row["title_ciphertext"]
            status = row["status"]
            stage = row["stage"]
            dueDate = row["due_date"]
            dueTime = row["due_time"]
            pinPeriod = row["pin_period"]
            // A time that does not read as one (written by a later
            // version, say) is no pin's end, and the earliest of times: the
            // rest of the listing is still read.
            threadID = row["thread_id"]
            leadAgentID = row["lead_agent_id"]
            handoffTurnID = row["handoff_turn_id"]
            handoffAgentID = row["handoff_agent_id"]
            handoffStatus = row["handoff_status"]
            handoffHasRun = row["handoff_has_run"] ?? false
            pinEnds = Self.time(row["pin_expires_at"])
            createdAt = Self.time(row["created_at"]) ?? .distantPast
            updatedAt = Self.time(row["updated_at"]) ?? .distantPast
        }

        private static func time(_ stored: DatabaseValue) -> Date? {
            Date.fromDatabaseValue(stored)
        }
    }

    /// The tasks kept in `account`'s coven (Strix for nil): every open
    /// one, then the finished ones last changed, as many as a listing
    /// gives, with how many are finished in all. Within each, the one
    /// last changed comes first (of two changed at once, the one made
    /// later). A task whose title cannot be opened with the account's key
    /// is listed as unreadable, with no title. `alsoListing` names a task
    /// of that place to list even where it is finished and not among the
    /// ones last changed (the one whose details are on screen): it then
    /// comes after them.
    func tasks(inCoven covenID: String?, alsoListing shown: String? = nil, as account: String) async throws -> TaskListing {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        let coven = covenID ?? ""
        return try await AccountSeal.reading(as: account) {
            // All in one read, so that what is listed and what is counted are of one moment.
            let (stored, finished, lastHandedTo): ([Stored], Int, String?) = try await dbQueue.read { db in
                // Each task with the turn it was handed over in, as that turn stands.
                let columns = """
                tasks.id, tasks.coven_id, tasks.title_ciphertext, tasks.status, tasks.stage, tasks.due_date, tasks.due_time, tasks.pin_period,
                tasks.pin_expires_at, tasks.thread_id, tasks.lead_agent_id, tasks.handoff_turn_id, tasks.handoff_agent_id, tasks.created_at,
                tasks.updated_at, turns.status AS handoff_status, (turns.run_ciphertext IS NOT NULL) AS handoff_has_run
                """
                let from = "tasks LEFT JOIN turns ON turns.id = tasks.handoff_turn_id AND turns.user_id = tasks.user_id"
                let open = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT \(columns) FROM \(from) WHERE tasks.user_id = ? AND tasks.coven_id = ? AND tasks.status = ?
                    ORDER BY tasks.updated_at DESC, tasks.created_at DESC, tasks.rowid DESC
                    """,
                    arguments: [account, coven, TaskStatus.open.rawValue]
                )
                let done = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT \(columns) FROM \(from) WHERE tasks.user_id = ? AND tasks.coven_id = ? AND tasks.status <> ?
                    ORDER BY tasks.updated_at DESC, tasks.created_at DESC, tasks.rowid DESC LIMIT ?
                    """,
                    arguments: [account, coven, TaskStatus.open.rawValue, Self.mostFinishedListed]
                )
                var also: [Row] = []
                if let shown, !(open + done).contains(where: { ($0["id"] as String) == shown }) {
                    also = try Row.fetchAll(
                        db, sql: "SELECT \(columns) FROM \(from) WHERE tasks.id = ? AND tasks.user_id = ? AND tasks.coven_id = ?",
                        arguments: [shown, account, coven]
                    )
                }
                let count = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM tasks WHERE user_id = ? AND coven_id = ? AND status <> ?",
                    arguments: [account, coven, TaskStatus.open.rawValue]
                ) ?? 0
                // Of every task of the place, listed or not: the agent,
                // still there, that the one last changed was handed to.
                let lastHandedTo = try String.fetchOne(
                    db,
                    sql: """
                    SELECT tasks.handoff_agent_id FROM tasks
                    WHERE tasks.user_id = ? AND tasks.coven_id = ? AND tasks.handoff_turn_id IS NOT NULL AND EXISTS (
                        SELECT 1 FROM roles
                        WHERE roles.id = tasks.handoff_agent_id AND roles.user_id = tasks.user_id AND roles.coven_id = tasks.coven_id
                    )
                    ORDER BY tasks.updated_at DESC, tasks.created_at DESC, tasks.rowid DESC LIMIT 1
                    """,
                    arguments: [account, coven]
                )
                return ((open + done + also).map(Stored.init), count, lastHandedTo)
            }
            var tasks: [TaskItem] = []
            for stored in stored {
                let title = try? await DataEncryptionService.shared.decrypt(stored.title, purpose: Self.titlePurpose)
                // A status this version does not know is read as closed:
                // nothing takes it for a task still to do. A stage it does
                // not know is read as the board's first.
                let status = TaskStatus(rawValue: stored.status) ?? .closed
                var pin: TaskPin?
                if status == .open, let period = stored.pinPeriod.flatMap(TaskPinPeriod.init), let ends = stored.pinEnds {
                    pin = TaskPin(period: period, expiresAt: ends)
                }
                tasks.append(TaskItem(
                    id: stored.id, covenID: stored.covenID.isEmpty ? nil : stored.covenID,
                    title: title.map { String(decoding: $0, as: UTF8.self) } ?? "",
                    status: status, stage: TaskStage(rawValue: stored.stage) ?? .backlog,
                    due: stored.dueDate.flatMap(TaskDueDate.init).flatMap { TaskDue(date: $0, time: stored.dueTime) ?? TaskDue(date: $0) },
                    pin: pin, isUnreadable: title == nil, threadID: stored.threadID, leadAgentID: stored.leadAgentID,
                    handoff: stored.handoffTurnID.map {
                        TaskHandoff(
                            turnID: $0, outcome: stored.handoffStatus.flatMap(TurnOutcome.init), hasRun: stored.handoffHasRun,
                            agentID: stored.handoffAgentID
                        )
                    },
                    createdAt: stored.createdAt, updatedAt: stored.updatedAt
                ))
            }
            return TaskListing(tasks: tasks, finished: finished, lastHandedTo: lastHandedTo)
        }
    }
}
