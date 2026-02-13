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

    enum Columns: String, ColumnExpression {
        case id
        case userId = "user_id"
        case title
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case summaryCiphertext = "summary_ciphertext"
        case metadata
    }

    /// Memberwise initializer used by repositories when inserting new rows.
    init(
        id: String,
        userId: String?,
        title: String?,
        createdAt: Date,
        updatedAt: Date?,
        summaryCiphertext: Data?,
        metadata: String?
    ) {
        self.id = id
        self.userId = userId
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.summaryCiphertext = summaryCiphertext
        self.metadata = metadata
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

    enum Columns: String, ColumnExpression {
        case id
        case userId = "user_id"
        case threadID = "thread_id"
        case role
        case createdAt = "created_at"
        case contentCiphertext = "content_ciphertext"
        case metadata
    }

    /// Memberwise initializer used by repositories when inserting new rows.
    init(
        id: String,
        userId: String?,
        threadID: String,
        role: String,
        createdAt: Date,
        contentCiphertext: Data,
        metadata: String?
    ) {
        self.id = id
        self.userId = userId
        self.threadID = threadID
        self.role = role
        self.createdAt = createdAt
        self.contentCiphertext = contentCiphertext
        self.metadata = metadata
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
    }

    func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.userId] = userId
        container[Columns.threadID] = threadID
        container[Columns.role] = role
        container[Columns.createdAt] = createdAt
        container[Columns.contentCiphertext] = contentCiphertext
        container[Columns.metadata] = metadata
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
    private func getDbQueue() async -> DatabaseQueue? {
        await MainActor.run { DatabaseManager.shared.dbQueue }
    }

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

        let ciphertext: Data?
        if let summary {
            let plaintext = Data(summary.utf8)
            ciphertext = try await DataEncryptionService.shared.encrypt(plaintext, purpose: "thread_summary")
        } else {
            ciphertext = nil
        }

        try await dbQueue.write { db in
            guard var record = try ThreadRecord.fetchOne(db, key: threadID) else { return }
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
            let content = String(decoding: decrypted, as: UTF8.self)
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

// MARK: - Protocol conformances

extension ThreadRepository: ThreadStore {}

enum RepositoryError: Error {
    case databaseUnavailable
}
