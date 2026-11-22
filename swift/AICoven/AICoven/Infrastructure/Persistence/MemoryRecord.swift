import CryptoKit
import Foundation
import GRDB

/// Low-level GRDB representation of a long-term memory chunk.
struct MemoryChunkRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "memory_chunks"

    var id: String
    var userId: String? // Owner of this memory for data isolation
    var scope: String
    /// The coven whose memory it is; nil for one kept in no coven.
    var covenId: String?
    var piiFlag: Bool
    var tags: String?
    var createdAt: Date
    var createdBy: String?
    var source: String?
    var textCiphertext: Data
    var embedding: Data?

    enum Columns: String, ColumnExpression {
        case id
        case userId = "user_id"
        case scope
        case covenId = "coven_id"
        case piiFlag = "pii_flag"
        case tags
        case createdAt = "created_at"
        case createdBy = "created_by"
        case source
        case textCiphertext = "text_ciphertext"
        case embedding
    }

    /// Memberwise initializer used by repositories when inserting new rows.
    init(
        id: String,
        userId: String?,
        scope: String,
        covenId: String?,
        piiFlag: Bool,
        tags: String?,
        createdAt: Date,
        createdBy: String?,
        source: String?,
        textCiphertext: Data,
        embedding: Data?
    ) {
        self.id = id
        self.userId = userId
        self.scope = scope
        self.covenId = covenId
        self.piiFlag = piiFlag
        self.tags = tags
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.source = source
        self.textCiphertext = textCiphertext
        self.embedding = embedding
    }

    /// Custom Row initializer so GRDB can decode from the snake_case schema.
    init(row: Row) {
        id = row[Columns.id]
        userId = row[Columns.userId]
        scope = row[Columns.scope]
        covenId = row[Columns.covenId]
        piiFlag = row[Columns.piiFlag]
        tags = row[Columns.tags]
        createdAt = row[Columns.createdAt]
        createdBy = row[Columns.createdBy]
        source = row[Columns.source]
        textCiphertext = row[Columns.textCiphertext]
        embedding = row[Columns.embedding]
    }

    func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.userId] = userId
        container[Columns.scope] = scope
        container[Columns.covenId] = covenId
        container[Columns.piiFlag] = piiFlag
        container[Columns.tags] = tags
        container[Columns.createdAt] = createdAt
        container[Columns.createdBy] = createdBy
        container[Columns.source] = source
        container[Columns.textCiphertext] = textCiphertext
        container[Columns.embedding] = embedding
    }
}

/// Domain model for local memory chunks.
struct LocalMemoryChunk: Identifiable, Equatable {
    let id: String
    let scope: String
    let text: String
    let tags: [String]
    let pii: Bool
    let createdAt: Date
    let createdBy: String?
    let source: String?
    let embedding: [Float]?
    /// The coven whose memory it is; nil for one kept in no coven.
    var covenID: String?
    /// Its text could not be opened with the account's key: it reads as
    /// empty, and no turn reads it.
    var isUnreadable = false
}

/// Why a memory was not changed.
enum MemoryStoreError: Error {
    /// There is no such memory of the account's.
    case noSuchMemory
}

actor MemoryRepository {
    static let shared = MemoryRepository()

    /// Access the database queue from the MainActor-isolated DatabaseManager.
    /// This must be called from async context.
    private func getDbQueue() async -> DatabaseQueue? {
        await MainActor.run { DatabaseManager.shared.dbQueue }
    }

    private init() {}

    private func signedInAccount() async -> String {
        await MainActor.run { UserScope.currentUserID }
    }

    /// The account's memories kept in one place.
    private static func rows(of account: String, in place: MemoryPlace) -> QueryInterfaceRequest<MemoryChunkRecord> {
        let own = MemoryChunkRecord.filter(MemoryChunkRecord.Columns.userId == account)
        switch place {
        case .aboutMe:
            return own.filter(MemoryChunkRecord.Columns.covenId == nil).filter(MemoryChunkRecord.Columns.scope == "user")
        case .strix:
            // Not what a model once asked to keep for one conversation
            // (scope "thread"): no turn read those, and none reads them now.
            return own.filter(MemoryChunkRecord.Columns.covenId == nil)
                .filter(!["user", "thread"].contains(MemoryChunkRecord.Columns.scope))
        case let .coven(id):
            return own.filter(MemoryChunkRecord.Columns.covenId == id)
        }
    }

    private static func stored(_ tags: [String]) throws -> String? {
        tags.isEmpty ? nil : try String(data: JSONEncoder().encode(tags), encoding: .utf8)
    }

    private static func stored(_ embedding: [Float]?) -> Data? {
        embedding.map { vector in
            vector.withUnsafeBufferPointer { Data(buffer: $0) }
        }
    }

    // MARK: - Public API

    /// Stores a memory in `place` for the account that wrote it, read by
    /// the caller before anything it waited for: it is stored as that
    /// account's, and not at all if another is signed in, or the data key
    /// has changed hands, by the time it is stored. A coven's memory is
    /// stored only in a coven of that account's.
    func storeMemory(
        in place: MemoryPlace,
        text: String,
        tags: [String],
        pii: Bool,
        createdBy: String?,
        source: String?,
        embedding: [Float]?,
        as account: String
    ) async throws -> LocalMemoryChunk {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        let record = try await MemoryChunkRecord(
            id: UUID().uuidString,
            userId: account,
            scope: place.scope,
            covenId: place.covenID,
            piiFlag: pii,
            tags: Self.stored(tags),
            createdAt: Date(),
            createdBy: createdBy,
            source: source,
            textCiphertext: AccountSeal.seal(text, purpose: "memory_chunk", for: account),
            embedding: Self.stored(embedding)
        )

        try await dbQueue.write { db in
            try record.insert(db)
        }

        return LocalMemoryChunk(
            id: record.id,
            scope: record.scope,
            text: text,
            tags: tags,
            pii: pii,
            createdAt: record.createdAt,
            createdBy: createdBy,
            source: source,
            embedding: embedding,
            covenID: record.covenId
        )
    }

    /// A page of the signed-in account's memories in one place.
    func loadMemories(in place: MemoryPlace, limit: Int, offset: Int = 0) async throws -> [LocalMemoryChunk] {
        try await loadMemories(in: place, limit: limit, offset: offset, as: signedInAccount())
    }

    /// A page of `account`'s memories in one place, newest first: `limit`
    /// of them after the first `offset`. Throws unless `account` is the
    /// one signed in, with its own data key in memory, from before the
    /// page is read until after.
    func loadMemories(in place: MemoryPlace, limit: Int, offset: Int, as account: String) async throws -> [LocalMemoryChunk] {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        return try await AccountSeal.reading(as: account) {
            let records: [MemoryChunkRecord] = try await dbQueue.read { db in
                try Self.rows(of: account, in: place)
                    .order(MemoryChunkRecord.Columns.createdAt.desc, MemoryChunkRecord.Columns.id.desc)
                    .limit(limit, offset: offset)
                    .fetchAll(db)
            }
            var result: [LocalMemoryChunk] = []
            result.reserveCapacity(records.count)
            for record in records {
                try await result.append(self.chunk(from: record))
            }
            return result
        }
    }

    /// One memory of the signed-in account's, by its id, read as a page
    /// is; nil if that account has none with that id.
    func loadMemory(id: String) async throws -> LocalMemoryChunk? {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        let account = await signedInAccount()
        return try await AccountSeal.reading(as: account) {
            let record: MemoryChunkRecord? = try await dbQueue.read { db in
                try MemoryChunkRecord
                    .filter(MemoryChunkRecord.Columns.id == id)
                    .filter(MemoryChunkRecord.Columns.userId == account)
                    .fetchOne(db)
            }
            guard let record else { return nil }
            return try await self.chunk(from: record)
        }
    }

    /// Removes a memory of `account`'s, the account signed in. One that is
    /// not there, or is another account's, is left as it is. It needs no
    /// key: an entry the key cannot open is removed like any other.
    func deleteMemory(id: String, as account: String) async throws {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        guard await signedInAccount() == account else { throw RepositoryError.accountChanged }

        try await dbQueue.write { db in
            _ = try MemoryChunkRecord
                .filter(MemoryChunkRecord.Columns.id == id)
                .filter(MemoryChunkRecord.Columns.userId == account)
                .deleteAll(db)
        }
    }

    /// Gives a memory of `account`'s new text, with its embedding, and new
    /// tags where some are given (nil keeps its tags, read in the same
    /// write). It stays where it is kept. Throws
    /// `MemoryStoreError.noSuchMemory` if the account has no such memory,
    /// and, as `storeMemory` does, unless the account is signed in with its
    /// own key while the text is encrypted.
    func updateMemory(
        id: String,
        newText: String,
        newTags: [String]?,
        newEmbedding: [Float]?,
        as account: String
    ) async throws -> LocalMemoryChunk {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        let ciphertext = try await AccountSeal.seal(newText, purpose: "memory_chunk", for: account)
        let tags = try newTags.map { try Self.stored($0) }
        let embedding = Self.stored(newEmbedding)

        let updated: MemoryChunkRecord? = try await dbQueue.write { db in
            guard var record = try MemoryChunkRecord
                .filter(MemoryChunkRecord.Columns.id == id)
                .filter(MemoryChunkRecord.Columns.userId == account)
                .fetchOne(db)
            else { return nil }
            record.textCiphertext = ciphertext
            if let tags { record.tags = tags }
            record.embedding = embedding
            try record.update(db)
            return record
        }
        guard let updated else { throw MemoryStoreError.noSuchMemory }

        return LocalMemoryChunk(
            id: updated.id,
            scope: updated.scope,
            text: newText,
            tags: Self.tags(of: updated),
            pii: updated.piiFlag,
            createdAt: updated.createdAt,
            createdBy: updated.createdBy,
            source: updated.source,
            embedding: newEmbedding,
            covenID: updated.covenId
        )
    }

    // MARK: - Mapping helper

    private static func tags(of record: MemoryChunkRecord) -> [String] {
        guard let stored = record.tags, let data = stored.data(using: .utf8) else { return [] }
        do {
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            AppErrorReporter.log(error: error, context: "MemoryRepository.tags")
            return []
        }
    }

    /// A stored memory, opened. A memory whose text the key in memory
    /// cannot open is given as unreadable, so that the rest of its page is
    /// still read and it can be removed. A key locked meanwhile is thrown
    /// (`AccountSeal.reading(as:)` tells it as locked data).
    private func chunk(from record: MemoryChunkRecord) async throws -> LocalMemoryChunk {
        var text = ""
        var isUnreadable = false
        do {
            let opened = try await DataEncryptionService.shared.decrypt(record.textCiphertext, purpose: "memory_chunk")
            text = String(decoding: opened, as: UTF8.self)
        } catch let error as CryptoKitError {
            // The kind of failure only.
            AppErrorReporter.log(message: "A memory could not be opened (\(error))", context: "MemoryRepository.chunk")
            isUnreadable = true
        }

        let embedding: [Float]? = record.embedding.map { data in
            let count = data.count / MemoryLayout<Float>.size
            return data.withUnsafeBytes { raw in
                Array(UnsafeBufferPointer(start: raw.bindMemory(to: Float.self).baseAddress, count: count))
            }
        }

        return LocalMemoryChunk(
            id: record.id,
            scope: record.scope,
            text: text,
            tags: Self.tags(of: record),
            pii: record.piiFlag,
            createdAt: record.createdAt,
            createdBy: record.createdBy,
            source: record.source,
            embedding: isUnreadable ? nil : embedding,
            covenID: record.covenId,
            isUnreadable: isUnreadable
        )
    }
}

// MARK: - Protocol conformances

extension MemoryRepository: MemoryStore {}

/// Low-level GRDB representation of a memory write proposal. This backs the
/// local-only MemoryService proposal APIs and the MemoryProposalsView UI.
struct MemoryProposalRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "memory_proposals"

    var id: String
    var userId: String? // Owner of this proposal for data isolation
    var eventId: String?
    var covenId: String?
    /// What is proposed. It is stored encrypted (`contentCiphertext`), and
    /// held here opened; a row from before proposals were encrypted holds
    /// it as text until the account's proposals are next read.
    var proposedContent: String
    var proposedTags: String?
    var scope: String?
    var reason: String?
    var sourceMessageId: String?
    var status: String
    var proposedBy: String?
    var reviewedBy: String?
    var createdAt: Date
    var reviewedAt: Date?
    var title: String?
    var reviewFeedback: String?
    var contentCiphertext: Data?
    /// Its text could not be opened with the account's key (not stored).
    var isUnreadable = false

    enum Columns: String, ColumnExpression {
        case id
        case userId = "user_id"
        case eventId = "event_id"
        case covenId = "coven_id"
        case proposedContent = "proposed_content"
        case proposedTags = "proposed_tags"
        case scope
        case reason
        case sourceMessageId = "source_message_id"
        case status
        case proposedBy = "proposed_by"
        case reviewedBy = "reviewed_by"
        case createdAt = "created_at"
        case reviewedAt = "reviewed_at"
        case title
        case reviewFeedback = "review_feedback"
        case contentCiphertext = "content_ciphertext"
    }

    /// The stored columns only: `isUnreadable` is told, not kept.
    enum CodingKeys: String, CodingKey {
        case id, userId, eventId, covenId, proposedContent, proposedTags, scope, reason, sourceMessageId, status, proposedBy, reviewedBy
        case createdAt, reviewedAt, title, reviewFeedback, contentCiphertext
    }

    /// Memberwise initializer used by repositories when inserting new rows.
    init(
        id: String,
        userId: String?,
        eventId: String?,
        covenId: String?,
        proposedContent: String,
        proposedTags: String?,
        scope: String?,
        reason: String?,
        sourceMessageId: String?,
        status: String,
        proposedBy: String?,
        reviewedBy: String?,
        createdAt: Date,
        reviewedAt: Date?,
        title: String?,
        reviewFeedback: String?,
        contentCiphertext: Data? = nil
    ) {
        self.id = id
        self.userId = userId
        self.eventId = eventId
        self.covenId = covenId
        self.proposedContent = proposedContent
        self.proposedTags = proposedTags
        self.scope = scope
        self.reason = reason
        self.sourceMessageId = sourceMessageId
        self.status = status
        self.proposedBy = proposedBy
        self.reviewedBy = reviewedBy
        self.createdAt = createdAt
        self.reviewedAt = reviewedAt
        self.title = title
        self.reviewFeedback = reviewFeedback
        self.contentCiphertext = contentCiphertext
    }

    /// Custom Row initializer so GRDB can decode from the snake_case schema.
    init(row: Row) {
        id = row[Columns.id]
        userId = row[Columns.userId]
        eventId = row[Columns.eventId]
        covenId = row[Columns.covenId]
        proposedContent = row[Columns.proposedContent]
        proposedTags = row[Columns.proposedTags]
        scope = row[Columns.scope]
        reason = row[Columns.reason]
        sourceMessageId = row[Columns.sourceMessageId]
        status = row[Columns.status]
        proposedBy = row[Columns.proposedBy]
        reviewedBy = row[Columns.reviewedBy]
        createdAt = row[Columns.createdAt]
        reviewedAt = row[Columns.reviewedAt]
        title = row[Columns.title]
        reviewFeedback = row[Columns.reviewFeedback]
        contentCiphertext = row[Columns.contentCiphertext]
    }

    func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.userId] = userId
        container[Columns.eventId] = eventId
        container[Columns.covenId] = covenId
        // The text is kept only encrypted: what is held here opened is
        // never written back as text.
        container[Columns.proposedContent] = contentCiphertext == nil ? proposedContent : ""
        container[Columns.proposedTags] = proposedTags
        container[Columns.scope] = scope
        container[Columns.reason] = reason
        container[Columns.sourceMessageId] = sourceMessageId
        container[Columns.status] = status
        container[Columns.proposedBy] = proposedBy
        container[Columns.reviewedBy] = reviewedBy
        container[Columns.createdAt] = createdAt
        container[Columns.reviewedAt] = reviewedAt
        container[Columns.title] = title
        container[Columns.reviewFeedback] = reviewFeedback
        container[Columns.contentCiphertext] = contentCiphertext
    }
}

/// Repository for reading and updating local memory proposals.
actor MemoryProposalRepository {
    static let shared = MemoryProposalRepository()

    /// Access the database queue from the MainActor-isolated DatabaseManager.
    /// This must be called from async context.
    private func getDbQueue() async -> DatabaseQueue? {
        await MainActor.run { DatabaseManager.shared.dbQueue }
    }

    private init() {}

    private static let purpose = "memory_proposal"

    /// A stored proposal with its text opened. One whose text the key in
    /// memory cannot open is given as unreadable, with no text.
    private func opened(_ record: MemoryProposalRecord) async throws -> MemoryProposalRecord {
        guard let sealed = record.contentCiphertext else { return record }
        var record = record
        do {
            record.proposedContent = try await String(decoding: DataEncryptionService.shared.decrypt(sealed, purpose: Self.purpose), as: UTF8.self)
        } catch let error as CryptoKitError {
            // The kind of failure only.
            AppErrorReporter.log(message: "A memory proposal could not be opened (\(error))", context: "MemoryProposalRepository.opened")
            record.proposedContent = ""
            record.isUnreadable = true
        }
        return record
    }

    /// Proposals stored before their text was encrypted are sealed, and
    /// the text taken out of the row, the first time the account's
    /// proposals are read with its key in memory.
    private func sealPlainText(of account: String, in dbQueue: DatabaseQueue) async throws {
        let plain: [Row] = try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, proposed_content FROM memory_proposals WHERE user_id = ? AND content_ciphertext IS NULL AND proposed_content <> ''",
                arguments: [account]
            )
        }
        for row in plain {
            let id: String = row["id"]
            let sealed = try await AccountSeal.seal(row["proposed_content"], purpose: Self.purpose, for: account)
            try await dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE memory_proposals SET content_ciphertext = ?, proposed_content = ''
                    WHERE id = ? AND user_id = ? AND content_ciphertext IS NULL
                    """,
                    arguments: [sealed, id, account]
                )
            }
        }
    }

    /// The current user's proposals in one scope: a coven's, or with no
    /// coven the person's own. Optionally of one status. Newest first.
    /// Read with the account's own key in memory, and not at all while its
    /// data is locked.
    func listProposals(covenId: String?, status: String?) async throws -> [MemoryProposalRecord] {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        // Get current user ID for data isolation
        let currentUserId = await MainActor.run { UserScope.currentUserID }
        try await sealPlainText(of: currentUserId, in: dbQueue)

        return try await AccountSeal.reading(as: currentUserId) {
            let records: [MemoryProposalRecord] = try await dbQueue.read { db in
                // Only fetch proposals belonging to the current user
                var request = MemoryProposalRecord
                    .filter(MemoryProposalRecord.Columns.userId == currentUserId)
                    .order(MemoryProposalRecord.Columns.createdAt.desc)

                // One scope's proposals: a coven's, or, for none, the person's
                // own (those made in no coven), never every coven's together.
                request = request.filter(MemoryProposalRecord.Columns.covenId == covenId)
                if let status {
                    request = request.filter(MemoryProposalRecord.Columns.status == status)
                }

                return try request.fetchAll(db)
            }
            var result: [MemoryProposalRecord] = []
            for record in records {
                try await result.append(self.opened(record))
            }
            return result
        }
    }

    /// A proposal of `userID`'s; nil if there is none with that id.
    func loadProposal(id: String, for userID: String) async throws -> MemoryProposalRecord? {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        return try await AccountSeal.reading(as: userID) {
            let record = try await dbQueue.read { db in
                try MemoryProposalRecord
                    .filter(MemoryProposalRecord.Columns.id == id)
                    .filter(MemoryProposalRecord.Columns.userId == userID)
                    .fetchOne(db)
            }
            guard let record else { return nil }
            return try await self.opened(record)
        }
    }

    /// Stores a new proposal, its text encrypted, for the account that it
    /// was proposed to (`account`, read by the caller before anything it
    /// waited for; the account signed in now otherwise): it is stored as
    /// that account's, and not at all unless that account is signed in
    /// with its own key in memory.
    func insertProposal(
        id: String = UUID().uuidString,
        eventId: String?,
        covenId: String?,
        proposedContent: String,
        proposedTags: [String]?,
        scope: String?,
        reason: String?,
        sourceMessageId: String?,
        proposedBy: String?,
        title: String?,
        as account: String? = nil
    ) async throws -> MemoryProposalRecord {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        let owner = if let account { account } else { await MainActor.run { UserScope.currentUserID } }
        let sealed = try await AccountSeal.seal(proposedContent, purpose: Self.purpose, for: owner)

        let now = Date()
        let tagsString: String?
        if let proposedTags, !proposedTags.isEmpty {
            let data = try JSONEncoder().encode(proposedTags)
            tagsString = String(data: data, encoding: .utf8)
        } else {
            tagsString = nil
        }

        let record = MemoryProposalRecord(
            id: id,
            userId: owner,
            eventId: eventId,
            covenId: covenId,
            proposedContent: proposedContent,
            proposedTags: tagsString,
            scope: scope,
            reason: reason,
            sourceMessageId: sourceMessageId,
            status: "pending",
            proposedBy: proposedBy,
            reviewedBy: nil,
            createdAt: now,
            reviewedAt: nil,
            title: title,
            reviewFeedback: nil,
            contentCiphertext: sealed
        )

        try await dbQueue.write { db in
            try record.insert(db)
        }

        return record
    }

    /// Settles a proposal of `userID`'s that is still pending, as
    /// `status`, in one write: nil if it is not theirs, or is no longer
    /// pending (it was settled already, here or in another window), and
    /// then nothing is changed. Throws `accountChanged` unless `userID` is
    /// the account signed in: a review is one account's, and is dropped if
    /// another is signed in by the time it lands.
    func settlePending(
        id: String,
        as status: String,
        reviewedBy: String?,
        reviewFeedback: String?,
        for userID: String
    ) async throws -> MemoryProposalRecord? {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        guard await MainActor.run(body: { UserScope.currentUserID }) == userID else { throw RepositoryError.accountChanged }
        let now = Date()
        let settled: MemoryProposalRecord? = try await dbQueue.write { db in
            guard var record = try MemoryProposalRecord
                .filter(MemoryProposalRecord.Columns.id == id)
                .filter(MemoryProposalRecord.Columns.userId == userID)
                .filter(MemoryProposalRecord.Columns.status == "pending")
                .fetchOne(db) else {
                return nil
            }
            record.status = status
            record.reviewedBy = reviewedBy
            record.reviewedAt = now
            record.reviewFeedback = reviewFeedback
            try record.update(db)
            return record
        }
        guard let settled else { return nil }
        return try await opened(settled)
    }

    /// Makes a proposal of `userID`'s pending again: it was settled a
    /// moment ago for a memory that could then not be stored.
    func reopen(id: String, for userID: String) async throws {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE memory_proposals SET status = 'pending', reviewed_by = NULL, reviewed_at = NULL, review_feedback = NULL
                WHERE id = ? AND user_id = ?
                """,
                arguments: [id, userID]
            )
        }
    }
}
