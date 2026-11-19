import CryptoKit
import Foundation
import GRDB

/// Low-level GRDB representation of a chat thread.
struct ThreadRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "threads"

    var id: String
    var userId: String? // Owner of this thread for data isolation
    var title: String?
    var createdAt: Date
    var updatedAt: Date?
    var summaryCiphertext: Data?
    var metadata: String?
    /// The encrypted `Thread` this row holds, for a thread of the app's own
    /// chat history. Such a row has no plain `title`.
    var payloadCiphertext: Data?

    enum Columns: String, ColumnExpression {
        case id
        case userId = "user_id"
        case title
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case summaryCiphertext = "summary_ciphertext"
        case metadata
        case payloadCiphertext = "payload_ciphertext"
    }

    /// Memberwise initializer used by repositories when inserting new rows.
    init(
        id: String,
        userId: String?,
        title: String?,
        createdAt: Date,
        updatedAt: Date?,
        summaryCiphertext: Data?,
        metadata: String?,
        payloadCiphertext: Data? = nil
    ) {
        self.id = id
        self.userId = userId
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.summaryCiphertext = summaryCiphertext
        self.metadata = metadata
        self.payloadCiphertext = payloadCiphertext
    }

    /// Custom Row initializer so GRDB can decode from the snake_case schema.
    init(row: Row) {
        id = row[Columns.id]
        userId = row[Columns.userId]
        title = row[Columns.title]
        createdAt = row[Columns.createdAt]
        updatedAt = row[Columns.updatedAt]
        summaryCiphertext = row[Columns.summaryCiphertext]
        metadata = row[Columns.metadata]
        payloadCiphertext = row[Columns.payloadCiphertext]
    }

    /// Ensure GRDB uses snake_case column names on INSERT/UPDATE.
    func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.userId] = userId
        container[Columns.title] = title
        container[Columns.createdAt] = createdAt
        container[Columns.updatedAt] = updatedAt
        container[Columns.summaryCiphertext] = summaryCiphertext
        container[Columns.metadata] = metadata
        container[Columns.payloadCiphertext] = payloadCiphertext
    }
}

/// Low-level GRDB representation of a message.
struct MessageRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "messages"

    var id: String
    var userId: String? // Owner of this message for data isolation
    var threadID: String
    var role: String
    var createdAt: Date
    var contentCiphertext: Data
    var metadata: String?
    /// What `contentCiphertext` holds: `plainContent`, or `chatMessage`, the
    /// whole `ChatMessage` of the app's own chat history.
    var payloadFormat: Int

    static let plainContent = 0
    static let chatMessage = 1

    enum Columns: String, ColumnExpression {
        case id
        case userId = "user_id"
        case threadID = "thread_id"
        case role
        case createdAt = "created_at"
        case contentCiphertext = "content_ciphertext"
        case metadata
        case payloadFormat = "payload_format"
    }

    /// Memberwise initializer used by repositories when inserting new rows.
    init(
        id: String,
        userId: String?,
        threadID: String,
        role: String,
        createdAt: Date,
        contentCiphertext: Data,
        metadata: String?,
        payloadFormat: Int = MessageRecord.plainContent
    ) {
        self.id = id
        self.userId = userId
        self.threadID = threadID
        self.role = role
        self.createdAt = createdAt
        self.contentCiphertext = contentCiphertext
        self.metadata = metadata
        self.payloadFormat = payloadFormat
    }

    /// Custom Row initializer so GRDB can decode from the snake_case schema.
    init(row: Row) {
        id = row[Columns.id]
        userId = row[Columns.userId]
        threadID = row[Columns.threadID]
        role = row[Columns.role]
        createdAt = row[Columns.createdAt]
        contentCiphertext = row[Columns.contentCiphertext]
        metadata = row[Columns.metadata]
        payloadFormat = row[Columns.payloadFormat]
    }

    func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.userId] = userId
        container[Columns.threadID] = threadID
        container[Columns.role] = role
        container[Columns.createdAt] = createdAt
        container[Columns.contentCiphertext] = contentCiphertext
        container[Columns.metadata] = metadata
        container[Columns.payloadFormat] = payloadFormat
    }
}

/// Simple domain model for a local thread, decoupled from any backend schema.
struct LocalThread: Identifiable, Equatable {
    let id: String
    var title: String?
    var createdAt: Date
    var updatedAt: Date?
    var summary: String?
}

/// Simple domain model for a local message.
struct LocalMessage: Identifiable, Equatable {
    let id: String
    let threadID: String
    let role: String
    let content: String
    let createdAt: Date
}

actor ThreadRepository {
    static let shared = ThreadRepository()

    /// Access the database queue from the MainActor-isolated DatabaseManager.
    /// This must be called from async context.
    func getDbQueue() async -> DatabaseQueue? {
        await MainActor.run { DatabaseManager.shared.dbQueue }
    }

    /// The last message being added, which the next one waits for: messages
    /// are read back in the order they were stored.
    private var lastAppend: Task<Void, Never>?

    private init() {}

    // MARK: - Threads

    func createThread(title: String?) async throws -> LocalThread {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        // Get current user ID for data isolation
        let currentUserId = await MainActor.run { UserScope.currentUserID }

        let now = Date()
        let id = UUID().uuidString
        var record = ThreadRecord(
            id: id,
            userId: currentUserId,
            title: title,
            createdAt: now,
            updatedAt: now,
            summaryCiphertext: nil,
            metadata: nil
        )

        try await dbQueue.write { db in
            try record.insert(db)
        }

        return LocalThread(id: id, title: title, createdAt: now, updatedAt: now, summary: nil)
    }

    /// Load a single thread, including its decrypted summary if present.
    /// Only returns the thread if it belongs to the current user.
    func loadThread(id: String) async throws -> LocalThread? {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        // Get current user ID for data isolation
        let currentUserId = await MainActor.run { UserScope.currentUserID }

        let record: ThreadRecord? = try await dbQueue.read { db in
            // Filter by both ID and user_id to ensure user can only see their own threads
            try ThreadRecord
                .filter(ThreadRecord.Columns.id == id)
                .filter(ThreadRecord.Columns.userId == currentUserId)
                .fetchOne(db)
        }
        guard let rec = record else { return nil }

        let summary: String?
        if let cipher = rec.summaryCiphertext {
            let decrypted = try await DataEncryptionService.shared.decrypt(cipher, purpose: "thread_summary")
            summary = String(decoding: decrypted, as: UTF8.self)
        } else {
            summary = nil
        }

        return LocalThread(
            id: rec.id,
            title: rec.title,
            createdAt: rec.createdAt,
            updatedAt: rec.updatedAt,
            summary: summary
        )
    }

    /// Fetch all threads belonging to the current user.
    func fetchAllThreads() async throws -> [LocalThread] {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        // Get current user ID for data isolation
        let currentUserId = await MainActor.run { UserScope.currentUserID }

        let records: [ThreadRecord] = try await dbQueue.read { db in
            // Only fetch threads belonging to the current user
            try ThreadRecord
                .filter(ThreadRecord.Columns.userId == currentUserId)
                .order(ThreadRecord.Columns.updatedAt.desc)
                .fetchAll(db)
        }

        var result: [LocalThread] = []
        result.reserveCapacity(records.count)

        for rec in records {
            let summary: String?
            if let cipher = rec.summaryCiphertext {
                let decrypted = try await DataEncryptionService.shared.decrypt(cipher, purpose: "thread_summary")
                summary = String(decoding: decrypted, as: UTF8.self)
            } else {
                summary = nil
            }

            result.append(
                LocalThread(
                    id: rec.id,
                    title: rec.title,
                    createdAt: rec.createdAt,
                    updatedAt: rec.updatedAt,
                    summary: summary
                )
            )
        }

        return result
    }

    /// Update the encrypted summary for a given thread. Passing `nil` clears
    /// the summary.
    func updateSummary(forThreadID threadID: String, summary: String?) async throws {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        let session = try await beginWrite()

        let ciphertext: Data?
        if let summary {
            let plaintext = Data(summary.utf8)
            ciphertext = try await DataEncryptionService.shared.encrypt(plaintext, purpose: "thread_summary")
        } else {
            ciphertext = nil
        }
        try await confirm(session)

        try await dbQueue.write { db in
            // Only the thread of the account the summary was encrypted for.
            let owned = ThreadRecord
                .filter(ThreadRecord.Columns.id == threadID)
                .filter(ThreadRecord.Columns.userId == session.userID)
            guard var record = try owned.fetchOne(db) else { return }
            record.summaryCiphertext = ciphertext
            record.updatedAt = Date()
            try record.update(db)
        }
    }

    // MARK: - Messages

    func appendMessage(toThreadID threadID: String, role: String, content: String) async throws -> LocalMessage {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        // Get current user ID for data isolation
        let currentUserId = await MainActor.run { UserScope.currentUserID }

        let now = Date()
        let id = UUID().uuidString
        let plaintextData = Data(content.utf8)
        let ciphertext = try await DataEncryptionService.shared.encrypt(plaintextData, purpose: "chat_message")

        var record = MessageRecord(
            id: id,
            userId: currentUserId,
            threadID: threadID,
            role: role,
            createdAt: now,
            contentCiphertext: ciphertext,
            metadata: nil
        )

        try await dbQueue.write { db in
            try record.insert(db)
        }

        return LocalMessage(id: id, threadID: threadID, role: role, content: content, createdAt: now)
    }

    /// Load messages for a thread. Only returns messages belonging to the current user.
    func loadMessages(forThreadID threadID: String, limit: Int? = nil) async throws -> [LocalMessage] {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        // Get current user ID for data isolation
        let currentUserId = await MainActor.run { UserScope.currentUserID }

        let records: [MessageRecord] = try await dbQueue.read { db in
            // Filter by thread AND user_id to ensure user can only see their own messages
            var request = MessageRecord
                .filter(MessageRecord.Columns.threadID == threadID)
                .filter(MessageRecord.Columns.userId == currentUserId)
                .order(MessageRecord.Columns.createdAt.asc)

            if let limit {
                request = request.limit(limit)
            }

            return try request.fetchAll(db)
        }

        var result: [LocalMessage] = []
        result.reserveCapacity(records.count)

        for rec in records {
            let decrypted = try await DataEncryptionService.shared.decrypt(rec.contentCiphertext, purpose: "chat_message")
            let content = rec.payloadFormat == MessageRecord.chatMessage
                ? try JSONDecoder().decode(ChatMessage.self, from: decrypted).content
                : String(decoding: decrypted, as: UTF8.self)
            result.append(
                LocalMessage(
                    id: rec.id,
                    threadID: rec.threadID,
                    role: rec.role,
                    content: content,
                    createdAt: rec.createdAt
                )
            )
        }

        return result
    }
}

// MARK: - Chat history

/// How far a turn has got: running, or how it ended.
enum TurnOutcome: String {
    case running
    case completed
    case failed
    /// The person stopped it.
    case cancelled
    /// The app closed while it was running.
    case interrupted
}

/// The run an agent of the person's own is making for a turn: enough to
/// find it again there.
nonisolated struct AgentRun: Codable, Equatable {
    static let hermes = "hermes"
    static let openClaw = "openclaw"

    /// Whose run it is: `AgentRun.hermes` or `AgentRun.openClaw`.
    let provider: String
    let runID: String
    /// The name the reply is shown under, as the turn was started with.
    var agentName: String?
    /// Where the run is, for an agent that can be reached at more than one
    /// place: the address of the OpenClaw Gateway it was started through.
    var origin: String?
}

/// A turn still recorded as running.
nonisolated struct RunningTurn: Equatable {
    let id: String
    let startedAt: Date
    /// The agent's run making it, if one is.
    let run: AgentRun?
}

/// What storing a message does to a turn, in the same write.
private enum TurnChange {
    case begin(id: String)
    case end(id: String, outcome: TurnOutcome, trace: WorkTrace?)
}

/// The account a write is for and the data key it starts under, which is
/// that account's. A write encrypts and then stores, and waits in between;
/// the account, or the key in memory, can change while it does.
struct WriteSession {
    let userID: String
    let keyEpoch: Int
}

/// The app's own threads and messages. Each thread and each message is
/// stored whole and encrypted, so a conversation's titles and content are
/// not readable in the database file; a row's dates, role and owner are.
/// Reading or adding to the history first moves in whatever earlier builds
/// left in files.
extension ThreadRepository {
    /// Begins a write for the current account. Throws while the data key in
    /// memory is not that account's.
    func beginWrite() async throws -> WriteSession {
        let userID = await MainActor.run { UserScope.currentUserID }
        let keyEpoch = await DataEncryptionService.shared.keyEpoch
        guard await DataEncryptionService.shared.isUnlocked(for: userID) else { throw RepositoryError.dataLocked }
        // The key that was just seen to be this account's is the one counted.
        guard await DataEncryptionService.shared.keyEpoch == keyEpoch else { throw RepositoryError.accountChanged }
        return WriteSession(userID: userID, keyEpoch: keyEpoch)
    }

    /// Throws unless the account and the data key are still the ones the
    /// write began under. Checked after the last encryption, so what is then
    /// stored was encrypted for the account it is stored under.
    func confirm(_ session: WriteSession) async throws {
        let userID = await MainActor.run { UserScope.currentUserID }
        guard userID == session.userID, await DataEncryptionService.shared.keyEpoch == session.keyEpoch else {
            throw RepositoryError.accountChanged
        }
    }

    /// Saves a thread, new or changed. Throws if the thread is not the
    /// current account's.
    func saveThread(_ thread: Thread) async throws {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        let session = try await beginWrite()
        guard thread.userId == session.userID else { throw RepositoryError.accountChanged }
        let payload = try await DataEncryptionService.shared.encrypt(JSONEncoder().encode(thread), purpose: "chat_thread")
        try await confirm(session)

        try await dbQueue.write { db in
            try Self.upsert(thread, payload: payload, userId: session.userID, in: db)
        }
    }

    /// The current user's threads, in no particular order.
    func loadChatThreads() async throws -> [Thread] {
        try await LegacyChatHistoryImport.shared.importIfNeeded()
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        let currentUserId = await MainActor.run { UserScope.currentUserID }

        let payloads: [Data] = try await dbQueue.read { db in
            try ThreadRecord
                .filter(ThreadRecord.Columns.userId == currentUserId)
                .filter(ThreadRecord.Columns.payloadCiphertext != nil)
                .fetchAll(db)
                .compactMap(\.payloadCiphertext)
        }

        try await requireKey(of: currentUserId)
        guard !payloads.isEmpty else { return [] }
        let decoder = JSONDecoder()
        var threads: [Thread] = []
        threads.reserveCapacity(payloads.count)
        for payload in payloads {
            if let thread = try await open(Thread.self, payload, purpose: "chat_thread", with: decoder) {
                threads.append(thread)
            }
        }
        // If the key changed hands while these were read, the ones read
        // after it did were passed over as unreadable: none of it is kept.
        try await requireKey(of: currentUserId)
        return threads
    }

    /// Deletes a thread of the account `userID`'s, and with it its messages.
    @discardableResult
    func deleteThread(id: String, for userID: String) async throws -> [String] {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        // The thread's attachments are listed as it is deleted, in the one
        // write: none can be added in between, and the files of those
        // listed are the caller's to delete now that their rows are gone.
        return try await dbQueue.write { db in
            let attached = try String.fetchAll(
                db,
                sql: "SELECT id FROM attachments WHERE thread_id = ? AND user_id = ?",
                arguments: [id, userID]
            )
            _ = try ThreadRecord
                .filter(ThreadRecord.Columns.id == id)
                .filter(ThreadRecord.Columns.userId == userID)
                .deleteAll(db)
            return attached
        }
    }

    /// Adds a message to the end of its thread. Messages are stored in the
    /// order they are added, one at a time: storing one waits on encryption,
    /// and a later one must not get ahead of it.
    func appendChatMessage(_ message: ChatMessage) async throws {
        _ = try await storeInOrder(message, turn: nil)
    }

    /// Stores the person's message and a running turn for it, together.
    func beginTurn(id: String, userMessage: ChatMessage) async throws {
        _ = try await storeInOrder(userMessage, turn: .begin(id: id))
    }

    /// Stores the message a turn ends with, the reply or what went wrong,
    /// and the turn's outcome, together. A turn ends once: if it is not the
    /// current account's running turn, nothing is stored, its state stands,
    /// and the answer is false.
    @discardableResult
    func endTurn(id: String, outcome: TurnOutcome, message: ChatMessage, trace: WorkTrace? = nil) async throws -> Bool {
        try await storeInOrder(message, turn: .end(id: id, outcome: outcome, trace: trace))
    }

    /// The work traces of a thread's ended turns, by the id of the message
    /// each turn ended with.
    func loadWorkTraces(threadID: String) async throws -> [String: WorkTrace] {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        let currentUserId = await MainActor.run { UserScope.currentUserID }

        let rows: [Row] = try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT message_id, trace_ciphertext FROM turns WHERE user_id = ? AND thread_id = ? AND message_id IS NOT NULL AND trace_ciphertext IS NOT NULL",
                arguments: [currentUserId, threadID]
            )
        }
        try await requireKey(of: currentUserId)
        guard !rows.isEmpty else { return [:] }
        let decoder = JSONDecoder()
        var traces: [String: WorkTrace] = [:]
        for row in rows {
            let messageID: String = row["message_id"]
            let ciphertext: Data = row["trace_ciphertext"]
            if let trace = try await open(WorkTrace.self, ciphertext, purpose: "turn_trace", with: decoder) {
                traces[messageID] = trace
            }
        }
        try await requireKey(of: currentUserId)
        return traces
    }

    /// The current account's turns in a thread that are still marked as
    /// running, oldest first, each with the agent's run making it, if one
    /// is. A run that cannot be read is given as none.
    func runningTurns(threadID: String) async throws -> [RunningTurn] {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        let currentUserId = await MainActor.run { UserScope.currentUserID }
        let rows: [Row] = try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, started_at, run_ciphertext FROM turns WHERE user_id = ? AND thread_id = ? AND status = ? ORDER BY started_at",
                arguments: [currentUserId, threadID, TurnOutcome.running.rawValue]
            )
        }
        try await requireKey(of: currentUserId)
        let decoder = JSONDecoder()
        var turns: [RunningTurn] = []
        for row in rows {
            var run: AgentRun?
            if let ciphertext: Data = row["run_ciphertext"] {
                run = try await open(AgentRun.self, ciphertext, purpose: "turn_run", with: decoder)
            }
            turns.append(RunningTurn(id: row["id"], startedAt: row["started_at"], run: run))
        }
        try await requireKey(of: currentUserId)
        return turns
    }

    /// Keeps what is typed in a thread's composer and not sent, encrypted
    /// with the thread; empty text keeps nothing. Nothing is kept for a
    /// thread that is not the current account's.
    func saveDraft(_ text: String, forThread id: String) async throws {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        let session = try await beginWrite()
        var ciphertext: Data?
        if !text.isEmpty {
            ciphertext = try await DataEncryptionService.shared.encrypt(Data(text.utf8), purpose: "thread_draft")
        }
        try await confirm(session)
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE threads SET draft_ciphertext = ? WHERE id = ? AND user_id = ?",
                arguments: [ciphertext, id, session.userID]
            )
        }
    }

    /// What was typed in a thread's composer and not sent, or nil if there
    /// is nothing, the thread is not the current account's, or what is kept
    /// cannot be read.
    func draft(forThread id: String) async throws -> String? {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        let currentUserId = await MainActor.run { UserScope.currentUserID }
        let ciphertext: Data? = try await dbQueue.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT draft_ciphertext FROM threads WHERE id = ? AND user_id = ?",
                arguments: [id, currentUserId]
            )
        }
        try await requireKey(of: currentUserId)
        var text: String?
        if let ciphertext {
            do {
                text = try await String(data: DataEncryptionService.shared.decrypt(ciphertext, purpose: "thread_draft"), encoding: .utf8)
            } catch is CryptoKitError {
                // Not readable with the key in memory: nothing to show.
                AppErrorReporter.log(message: "A thread's draft could not be decrypted.", context: "ThreadRepository.draft")
            }
        }
        try await requireKey(of: currentUserId)
        return text
    }

    /// Keeps, with a running turn, the agent's run that is making it.
    /// Nothing is kept for a turn that is not the current account's running
    /// turn.
    func keepRun(_ run: AgentRun, forTurn id: String) async throws {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        let session = try await beginWrite()
        let ciphertext = try await DataEncryptionService.shared.encrypt(JSONEncoder().encode(run), purpose: "turn_run")
        try await confirm(session)
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE turns SET run_ciphertext = ? WHERE id = ? AND user_id = ? AND status = ?",
                arguments: [ciphertext, id, session.userID, TurnOutcome.running.rawValue]
            )
        }
    }

    /// False when the message was not stored because it ends a turn that
    /// this account is not running.
    private func storeInOrder(_ message: ChatMessage, turn: TurnChange?) async throws -> Bool {
        let previous = lastAppend
        let task = Task {
            await previous?.value
            return try await store(message, turn: turn)
        }
        lastAppend = Task { _ = await task.result }
        return try await task.value
    }

    private func store(_ message: ChatMessage, turn: TurnChange?) async throws -> Bool {
        try await LegacyChatHistoryImport.shared.importIfNeeded()
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        let session = try await beginWrite()
        let record = try await Self.record(for: message, userId: session.userID)
        var traceCiphertext: Data?
        if case let .end(_, _, trace?) = turn {
            traceCiphertext = try await DataEncryptionService.shared.encrypt(JSONEncoder().encode(trace), purpose: "turn_trace")
        }
        try await confirm(session)

        let storedTrace = traceCiphertext
        return try await dbQueue.write { db in
            switch turn {
            case nil:
                break
            case let .begin(id):
                try db.execute(
                    sql: "INSERT INTO turns (id, user_id, thread_id, status, started_at) VALUES (?, ?, ?, ?, ?)",
                    arguments: [id, session.userID, message.threadId, TurnOutcome.running.rawValue, Date()]
                )
            case let .end(id, outcome, _):
                try db.execute(
                    // The run that was making it is no longer needed to find
                    // it again, and is not kept.
                    sql: "UPDATE turns SET status = ?, finished_at = ?, message_id = ?, trace_ciphertext = ?, run_ciphertext = NULL WHERE id = ? AND user_id = ? AND status = ?",
                    arguments: [outcome.rawValue, Date(), message.id, storedTrace, id, session.userID, TurnOutcome.running.rawValue]
                )
                guard db.changesCount > 0 else { return false }
            }
            try record.insert(db)
            return true
        }
    }

    /// A page of a thread's messages, oldest first: the `limit` newest, or
    /// the `limit` just before the message `before`. Fewer than `limit`
    /// means there are no older ones: a stored message that cannot be read
    /// is passed over, and the page is filled from further back.
    func loadChatMessages(threadID: String, limit: Int, before: String?) async throws -> [ChatMessage] {
        try await LegacyChatHistoryImport.shared.importIfNeeded()
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        let currentUserId = await MainActor.run { UserScope.currentUserID }

        // Messages are appended in order, so the row order is their order.
        var olderThan: Int64?
        if let before {
            olderThan = try await dbQueue.read { db in
                try Int64.fetchOne(
                    db,
                    sql: "SELECT rowid FROM messages WHERE id = ? AND thread_id = ? AND user_id = ?",
                    arguments: [before, threadID, currentUserId]
                )
            }
            guard olderThan != nil else {
                try await requireKey(of: currentUserId)
                return []
            }
        }

        let decoder = JSONDecoder()
        var newestFirst: [ChatMessage] = []
        while newestFirst.count < limit {
            let wanted = limit - newestFirst.count
            let cursor = olderThan
            let rows: [Row] = try await dbQueue.read { db in
                var sql = "SELECT rowid AS row_order, content_ciphertext FROM messages WHERE thread_id = ? AND user_id = ? AND payload_format = ?"
                var arguments: [any DatabaseValueConvertible] = [threadID, currentUserId, MessageRecord.chatMessage]
                if let cursor {
                    sql += " AND rowid < ?"
                    arguments.append(cursor)
                }
                sql += " ORDER BY rowid DESC LIMIT ?"
                arguments.append(wanted)
                return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            }
            guard !rows.isEmpty else { break }
            try await requireKey(of: currentUserId)
            for row in rows {
                let ciphertext: Data = row["content_ciphertext"]
                if let message = try await open(ChatMessage.self, ciphertext, purpose: "chat_message", with: decoder) {
                    newestFirst.append(message)
                }
            }
            // As for threads: a key that changed hands mid-read makes the
            // page incomplete, not shorter.
            try await requireKey(of: currentUserId)
            guard rows.count == wanted, let oldest = rows.last else { break }
            olderThan = oldest["row_order"]
        }
        // However the page was completed, including by a last look that
        // found nothing more, and when it is empty.
        try await requireKey(of: currentUserId)
        return newestFirst.reversed()
    }

    /// Stores the account `userID`'s threads and messages together, or not at
    /// all: the one write of chat history from the files that used to hold
    /// it. A message is stored if its thread is one of `threads` or is
    /// already this account's in the database; any other has no thread to
    /// belong to. A thread or message already stored is left as it is.
    /// Throws if `userID` is not, or stops being, the current account.
    func importChatHistory(threads: [Thread], messages: [String: [ChatMessage]], userID: String) async throws {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        let session = try await beginWrite()
        guard session.userID == userID else { throw RepositoryError.accountChanged }

        let stored: Set<String> = try await dbQueue.read { db in
            try Set(String.fetchAll(db, sql: "SELECT id FROM threads WHERE user_id = ?", arguments: [userID]))
        }
        var payloads: [(thread: Thread, payload: Data)] = []
        for thread in threads {
            let payload = try await DataEncryptionService.shared.encrypt(JSONEncoder().encode(thread), purpose: "chat_thread")
            payloads.append((thread, payload))
        }
        let known = stored.union(threads.map(\.id))
        var records: [MessageRecord] = []
        for (threadID, threadMessages) in messages where known.contains(threadID) {
            for message in threadMessages {
                try await records.append(Self.record(for: message, userId: userID))
            }
        }
        try await confirm(session)

        let toWrite = (payloads, records)
        try await dbQueue.write { db in
            // Read again: a thread can have been deleted while encrypting.
            var owned = try Set(String.fetchAll(db, sql: "SELECT id FROM threads WHERE user_id = ?", arguments: [userID]))
            for (thread, payload) in toWrite.0 where !owned.contains(thread.id) {
                // A row another user owns keeps this id from being stored;
                // this user's messages cannot go under it.
                guard try ThreadRecord.fetchOne(db, key: thread.id) == nil else { continue }
                try Self.upsert(thread, payload: payload, userId: userID, in: db)
                owned.insert(thread.id)
            }
            for record in toWrite.1 where owned.contains(record.threadID) {
                try record.insert(db, onConflict: .ignore)
            }
        }
    }

    /// Whether the thread is this account's, as the database has it.
    /// Throws where that cannot be read.
    func isThread(_ threadID: String, of userID: String) async throws -> Bool {
        guard let queue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        return try await queue.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM threads WHERE id = ? AND user_id = ?)", arguments: [threadID, userID]) ?? false
        }
    }

    /// Throws unless `userID` is still the current account and the data key
    /// in memory is its own. A read checks before it decrypts and before
    /// every return, with or without anything read: after a switch of
    /// account the earlier one's key can stay in memory for a moment, and
    /// what it opens is not the new account's to see; and nothing is read,
    /// not even that there is nothing, while the data is locked.
    func requireKey(of userID: String) async throws {
        guard await MainActor.run(body: { UserScope.currentUserID }) == userID else { throw RepositoryError.accountChanged }
        guard await DataEncryptionService.shared.isUnlocked(for: userID) else { throw RepositoryError.dataLocked }
        // Again, because the account can have changed while the key was
        // asked about. Whoever shows what was read checks once more.
        guard await MainActor.run(body: { UserScope.currentUserID }) == userID else { throw RepositoryError.accountChanged }
    }

    /// Decrypts and decodes one stored record. `nil`, and logged, when this
    /// record cannot be read with the key in memory or is not what it should
    /// be: one unreadable record must not hide the rest. A locked key is
    /// thrown.
    private func open<Value: Decodable>(
        _ type: Value.Type,
        _ ciphertext: Data,
        purpose: String,
        with decoder: JSONDecoder
    ) async throws -> Value? {
        do {
            let plaintext = try await DataEncryptionService.shared.decrypt(ciphertext, purpose: purpose)
            return try decoder.decode(type, from: plaintext)
        } catch let error as CryptoKitError {
            AppErrorReporter.log(error: error, context: "ThreadRepository.open.\(purpose)")
            return nil
        } catch let error as DecodingError {
            AppErrorReporter.log(error: error, context: "ThreadRepository.open.\(purpose)")
            return nil
        }
    }

    private static func record(for message: ChatMessage, userId: String) async throws -> MessageRecord {
        let ciphertext = try await DataEncryptionService.shared.encrypt(JSONEncoder().encode(message), purpose: "chat_message")
        return MessageRecord(
            id: message.id,
            userId: userId,
            threadID: message.threadId,
            role: message.role,
            createdAt: message.createdAt ?? Date(),
            contentCiphertext: ciphertext,
            metadata: nil,
            payloadFormat: MessageRecord.chatMessage
        )
    }

    /// Writes a thread's row: a new row, or the payload and dates of the
    /// user's existing one, whose summary stays.
    private static func upsert(_ thread: Thread, payload: Data, userId: String, in db: Database) throws {
        let existing = try ThreadRecord
            .filter(ThreadRecord.Columns.id == thread.id)
            .filter(ThreadRecord.Columns.userId == userId)
            .fetchOne(db)
        if var existing {
            existing.payloadCiphertext = payload
            existing.updatedAt = thread.updatedAt
            try existing.update(db)
        } else {
            try ThreadRecord(
                id: thread.id,
                userId: userId,
                title: nil,
                createdAt: thread.createdAt,
                updatedAt: thread.updatedAt,
                summaryCiphertext: nil,
                metadata: nil,
                payloadCiphertext: payload
            ).insert(db)
        }
    }
}

// MARK: - Protocol conformances

extension ThreadRepository: ThreadStore {}

enum RepositoryError: Error {
    case databaseUnavailable
    /// The account's data is locked, so nothing of it can be read.
    case dataLocked
    /// The account, or its data key, changed while a write was encrypting.
    case accountChanged
}
