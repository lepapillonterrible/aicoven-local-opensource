import Foundation
import GRDB

/// Low-level GRDB representation of a long-term memory chunk.
struct MemoryChunkRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "memory_chunks"

    var id: String
    var userId: String? // Owner of this memory for data isolation
    var scope: String
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
}

actor MemoryRepository {
    static let shared = MemoryRepository()

    /// Access the database queue from the MainActor-isolated DatabaseManager.
    /// This must be called from async context.
    private func getDbQueue() async -> DatabaseQueue? {
        await MainActor.run { DatabaseManager.shared.dbQueue }
    }

    private init() {}

    // MARK: - Public API

    func storeMemory(
        scope: String,
        text: String,
        tags: [String],
        pii: Bool,
        createdBy: String?,
        source: String?,
        embedding: [Float]?
    ) async throws -> LocalMemoryChunk {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        // Get current user ID for data isolation
        let currentUserId = await MainActor.run { UserScope.currentUserID }

        let id = UUID().uuidString
        let now = Date()
        let plaintext = Data(text.utf8)
        let ciphertext = try await DataEncryptionService.shared.encrypt(plaintext, purpose: "memory_chunk")

        let tagsString = tags.isEmpty ? nil : try String(data: JSONEncoder().encode(tags), encoding: .utf8)
        let embeddingData: Data? = if let embedding {
            embedding.withUnsafeBufferPointer { ptr in
                Data(buffer: UnsafeBufferPointer(start: ptr.baseAddress, count: ptr.count))
            }
        } else {
            nil
        }

        var record = MemoryChunkRecord(
            id: id,
            userId: currentUserId,
            scope: scope,
            piiFlag: pii,
            tags: tagsString,
            createdAt: now,
            createdBy: createdBy,
            source: source,
            textCiphertext: ciphertext,
            embedding: embeddingData
        )

        try await dbQueue.write { db in
            try record.insert(db)
        }

        return LocalMemoryChunk(
            id: id,
            scope: scope,
            text: text,
            tags: tags,
            pii: pii,
            createdAt: now,
            createdBy: createdBy,
            source: source,
            embedding: embedding
        )
    }

    /// Load memories belonging to the current user, optionally filtered by scope.
    func loadMemories(scope: String? = nil, limit: Int = 50) async throws -> [LocalMemoryChunk] {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        // Get current user ID for data isolation
        let currentUserId = await MainActor.run { UserScope.currentUserID }

        let records: [MemoryChunkRecord] = try await dbQueue.read { db in
            // Only fetch memories belonging to the current user
            var request = MemoryChunkRecord
                .filter(MemoryChunkRecord.Columns.userId == currentUserId)
                .order(MemoryChunkRecord.Columns.createdAt.desc)
                .limit(limit)
            if let scope {
                request = request.filter(MemoryChunkRecord.Columns.scope == scope)
            }

            return try request.fetchAll(db)
        }

        var result: [LocalMemoryChunk] = []
        result.reserveCapacity(records.count)

        for rec in records {
            if let chunk = try await mapRecordToChunk(rec) {
                result.append(chunk)
            }
        }

        return result
    }

    /// Load a single memory chunk by ID. Only returns if it belongs to the current user.
    func loadMemory(id: String) async throws -> LocalMemoryChunk? {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        // Get current user ID for data isolation
        let currentUserId = await MainActor.run { UserScope.currentUserID }

        let record: MemoryChunkRecord? = try await dbQueue.read { db in
            // Filter by both ID and user_id to ensure user can only see their own memories
            try MemoryChunkRecord
                .filter(MemoryChunkRecord.Columns.id == id)
                .filter(MemoryChunkRecord.Columns.userId == currentUserId)
                .fetchOne(db)
        }

        guard let rec = record else { return nil }
        return try await mapRecordToChunk(rec)
    }

    /// Delete a memory chunk by ID. Only deletes if it belongs to the current user.
    func deleteMemory(id: String) async throws {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        // Get current user ID for data isolation
        let currentUserId = await MainActor.run { UserScope.currentUserID }

        try await dbQueue.write { db in
            // Only delete if it belongs to the current user
            _ = try MemoryChunkRecord
                .filter(MemoryChunkRecord.Columns.id == id)
                .filter(MemoryChunkRecord.Columns.userId == currentUserId)
                .deleteAll(db)
        }
    }

    /// Update an existing memory chunk's text, tags, and embedding.
    /// Only updates if it belongs to the current user.
    func updateMemory(
        id: String,
        newText: String,
        newTags: [String],
        newEmbedding: [Float]?
    ) async throws -> LocalMemoryChunk? {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        // Get current user ID for data isolation
        let currentUserId = await MainActor.run { UserScope.currentUserID }

        let plaintext = Data(newText.utf8)
        let ciphertext = try await DataEncryptionService.shared.encrypt(plaintext, purpose: "memory_chunk")

        let tagsString = newTags.isEmpty ? nil : try String(data: JSONEncoder().encode(newTags), encoding: .utf8)
        let embeddingData: Data? = if let newEmbedding {
            newEmbedding.withUnsafeBufferPointer { ptr in
                Data(buffer: UnsafeBufferPointer(start: ptr.baseAddress, count: ptr.count))
            }
        } else {
            nil
        }

        try await dbQueue.write { db in
            // Only update if it belongs to the current user
            if var record = try MemoryChunkRecord
                .filter(MemoryChunkRecord.Columns.id == id)
                .filter(MemoryChunkRecord.Columns.userId == currentUserId)
                .fetchOne(db) {
                record.textCiphertext = ciphertext
                record.tags = tagsString
                record.embedding = embeddingData
                try record.update(db)
            }
        }

        return try await loadMemory(id: id)
    }

    // MARK: - Mapping helper

    private func mapRecordToChunk(_ rec: MemoryChunkRecord) async throws -> LocalMemoryChunk? {
        let decrypted = try await DataEncryptionService.shared.decrypt(rec.textCiphertext, purpose: "memory_chunk")
        let text = String(decoding: decrypted, as: UTF8.self)

        let tags: [String]
        if let tagsString = rec.tags,
           let data = tagsString.data(using: .utf8) {
            do {
                tags = try JSONDecoder().decode([String].self, from: data)
            } catch {
                AppErrorReporter.log(error: error, context: "MemoryRepository.mapRecordToChunk.tagsDecode")
                tags = []
            }
        } else {
            tags = []
        }

        let embeddingArray: [Float]?
        if let embData = rec.embedding {
            let count = embData.count / MemoryLayout<Float>.size
            embeddingArray = embData.withUnsafeBytes { rawPtr in
                let floatPtr = rawPtr.bindMemory(to: Float.self)
                return Array(UnsafeBufferPointer(start: floatPtr.baseAddress, count: count))
            }
        } else {
            embeddingArray = nil
        }

        return LocalMemoryChunk(
            id: rec.id,
            scope: rec.scope,
            text: text,
            tags: tags,
            pii: rec.piiFlag,
            createdAt: rec.createdAt,
            createdBy: rec.createdBy,
            source: rec.source,
            embedding: embeddingArray
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
        reviewFeedback: String?
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
    }

    func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.userId] = userId
        container[Columns.eventId] = eventId
        container[Columns.covenId] = covenId
        container[Columns.proposedContent] = proposedContent
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

    /// List proposals belonging to the current user, optionally filtering by coven and status.
    /// Results are ordered from newest to oldest.
    func listProposals(covenId: String?, status: String?) async throws -> [MemoryProposalRecord] {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        // Get current user ID for data isolation
        let currentUserId = await MainActor.run { UserScope.currentUserID }

        return try await dbQueue.read { db in
            // Only fetch proposals belonging to the current user
            var request = MemoryProposalRecord
                .filter(MemoryProposalRecord.Columns.userId == currentUserId)
                .order(MemoryProposalRecord.Columns.createdAt.desc)

            if let covenId {
                request = request.filter(MemoryProposalRecord.Columns.covenId == covenId)
            }
            if let status {
                request = request.filter(MemoryProposalRecord.Columns.status == status)
            }

            return try request.fetchAll(db)
        }
    }

    /// Load a single proposal by ID. Only returns if it belongs to the current user.
    func loadProposal(id: String) async throws -> MemoryProposalRecord? {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        // Get current user ID for data isolation
        let currentUserId = await MainActor.run { UserScope.currentUserID }

        return try await dbQueue.read { db in
            // Filter by both ID and user_id to ensure user can only see their own proposals
            try MemoryProposalRecord
                .filter(MemoryProposalRecord.Columns.id == id)
                .filter(MemoryProposalRecord.Columns.userId == currentUserId)
                .fetchOne(db)
        }
    }

    /// Insert a new proposal. This will be used by agent/chat flows when they
    /// generate memory write suggestions.
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
        title: String?
    ) async throws -> MemoryProposalRecord {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        // Get current user ID for data isolation
        let currentUserId = await MainActor.run { UserScope.currentUserID }

        let now = Date()
        let tagsString: String?
        if let proposedTags, !proposedTags.isEmpty {
            let data = try JSONEncoder().encode(proposedTags)
            tagsString = String(data: data, encoding: .utf8)
        } else {
            tagsString = nil
        }

        var record = MemoryProposalRecord(
            id: id,
            userId: currentUserId,
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
            reviewFeedback: nil
        )

        try await dbQueue.write { db in
            try record.insert(db)
        }

        return record
    }

    /// Update the status and review metadata for a proposal, returning the
    /// updated record. Only updates if it belongs to the current user.
    func updateStatus(
        id: String,
        status: String,
        reviewedBy: String?,
        reviewFeedback: String?
    ) async throws -> MemoryProposalRecord {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        // Get current user ID for data isolation
        let currentUserId = await MainActor.run { UserScope.currentUserID }

        let now = Date()

        return try await dbQueue.write { db in
            // Only update if it belongs to the current user
            guard var record = try MemoryProposalRecord
                .filter(MemoryProposalRecord.Columns.id == id)
                .filter(MemoryProposalRecord.Columns.userId == currentUserId)
                .fetchOne(db) else {
                throw RepositoryError.databaseUnavailable
            }

            record.status = status
            record.reviewedBy = reviewedBy
            record.reviewedAt = now
            record.reviewFeedback = reviewFeedback

            try record.update(db)
            return record
        }
    }
}
