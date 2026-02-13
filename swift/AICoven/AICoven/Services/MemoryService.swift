import Foundation

/// Memory write proposal model for pending approvals
struct MemoryProposal: Codable, Identifiable {
    let id: String
    let eventId: String
    let covenId: String?
    let proposedContent: String
    let proposedTags: [String]?
    let scope: String?
    let reason: String?
    let sourceMessageId: String?
    let status: String
    let proposedBy: String?
    let reviewedBy: String?
    let createdAt: Date
    let reviewedAt: Date?
    let title: String?

    enum CodingKeys: String, CodingKey {
        case id
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
    }
}

/// Memory search response wrapper
struct MemorySearchResponse: Codable {
    let chunks: [Memory]
    let totalCount: Int

    enum CodingKeys: String, CodingKey {
        case chunks
        case totalCount = "total_count"
    }
}

/// Request body for creating a memory
struct CreateMemoryRequest: Codable {
    let covenId: String?
    let scope: String
    let title: String?
    let content: String
    let tags: [String]?
    let sourceMessageId: String?
    let isPinned: Bool

    enum CodingKeys: String, CodingKey {
        case covenId = "coven_id"
        case scope
        case title
        case content
        case tags
        case sourceMessageId = "source_message_id"
        case isPinned = "is_pinned"
    }
}

/// Request body for updating a memory
struct UpdateMemoryRequest: Codable {
    let title: String?
    let content: String?
    let tags: [String]?
    let scope: String?
    let isPinned: Bool?

    enum CodingKeys: String, CodingKey {
        case title
        case content
        case tags
        case scope
        case isPinned = "is_pinned"
    }
}

/// Request body for reviewing a memory proposal
struct ReviewMemoryRequest: Codable {
    let action: String
    let feedback: String?
}

/// Service for managing memory operations
actor MemoryService {
    static let shared = MemoryService()

    /// Abstraction over long-term memory persistence so higher-level features
    /// do not depend directly on the GRDB-backed repository.
    private let memoryStore: MemoryStore

    /// Internal initializer so tests can inject a mock MemoryStore.
    init(memoryStore: MemoryStore = MemoryRepository.shared) {
        self.memoryStore = memoryStore
    }

    // MARK: - Memory Search and Retrieval (Local-only)

    /// Search memory chunks using the local SQLite store and embeddings. This
    /// replaces the original backend search API in the open-source client.
    func searchMemory(
        covenId: String?,
        query: String? = nil,
        scope: String? = nil,
        tags: [String]? = nil,
        limit: Int = 20
    ) async throws -> [Memory] {
        // Determine the effective scope for local storage. For personal
        // memories we default to "user"; for coven contexts we default to
        // "coven". The legacy "all" scope is approximated by using the
        // default scope.
        let effectiveScope: String = {
            if let scope, !scope.isEmpty, scope != "all" {
                return scope
            }
            return covenId == nil ? "user" : "coven"
        }()

        let chunks: [LocalMemoryChunk] = if let queryText = query, !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Use embedding+lexical hybrid search for text queries.
            try await EmbeddingService.shared.searchRelevantMemories(
                query: queryText,
                scope: effectiveScope,
                topK: limit,
                candidateLimit: limit * 4,
                includePII: false
            )
        } else {
            // Fallback: most recent memories for the scope.
            try await memoryStore.loadMemories(scope: effectiveScope, limit: limit)
        }

        // Local store does not yet support tag- or pin-based filtering beyond
        // what is stored in `tags`; we ignore the `tags` parameter for now.
        return chunks.map { chunk in
            Memory(
                id: chunk.id,
                covenId: covenId,
                userId: nil,
                roleId: nil,
                scope: MemoryScope(rawValue: chunk.scope) ?? .user,
                title: nil,
                content: chunk.text,
                tags: chunk.tags.isEmpty ? nil : chunk.tags,
                isPinned: false,
                isApproved: true,
                createdAt: chunk.createdAt,
                updatedAt: nil
            )
        }
    }

    /// Get a specific memory chunk by ID from the local store.
    func getMemory(memoryId: String) async throws -> Memory {
        guard let chunk = try await memoryStore.loadMemory(id: memoryId) else {
            throw APIError.backendUnavailable // reuse error for "not found" in this build
        }
        return Memory(
            id: chunk.id,
            covenId: nil,
            userId: nil,
            roleId: nil,
            scope: MemoryScope(rawValue: chunk.scope) ?? .user,
            title: nil,
            content: chunk.text,
            tags: chunk.tags.isEmpty ? nil : chunk.tags,
            isPinned: false,
            isApproved: true,
            createdAt: chunk.createdAt,
            updatedAt: nil
        )
    }

    // MARK: - Memory Creation and Updates (Local-only)

    /// Create a new memory chunk in the local encrypted store.
    func createMemory(
        covenId: String?,
        scope: String,
        title: String?,
        content: String,
        tags: [String]?,
        isPinned: Bool = false
    ) async throws -> Memory {
        let embedding = try await EmbeddingService.shared.embedText(content)
        let chunk = try await memoryStore.storeMemory(
            scope: scope,
            text: content,
            tags: tags ?? [],
            pii: false,
            createdBy: nil,
            source: nil,
            embedding: embedding
        )

        return Memory(
            id: chunk.id,
            covenId: covenId,
            userId: nil,
            roleId: nil,
            scope: MemoryScope(rawValue: chunk.scope) ?? .user,
            title: title,
            content: chunk.text,
            tags: chunk.tags.isEmpty ? nil : chunk.tags,
            isPinned: isPinned,
            isApproved: true,
            createdAt: chunk.createdAt,
            updatedAt: nil
        )
    }

    /// Update an existing memory chunk in the local store.
    func updateMemory(
        memoryId: String,
        title: String?,
        content: String?,
        tags: [String]?,
        scope: String?,
        isPinned: Bool?
    ) async throws -> Memory {
        // For now we ignore title/scope/isPinned in the underlying store and
        // simply update the plaintext + tags + embedding.
        let newText: String
        let newTags: [String]

        if let content {
            newText = content
        } else if let existing = try await memoryStore.loadMemory(id: memoryId) {
            newText = existing.text
        } else {
            newText = content ?? ""
        }

        if let tags {
            newTags = tags
        } else if let existing = try await memoryStore.loadMemory(id: memoryId) {
            newTags = existing.tags
        } else {
            newTags = []
        }

        let embedding = try await EmbeddingService.shared.embedText(newText)
        let updatedChunk = try await memoryStore.updateMemory(
            id: memoryId,
            newText: newText,
            newTags: newTags,
            newEmbedding: embedding
        ) ?? LocalMemoryChunk(
            id: memoryId,
            scope: scope ?? "user",
            text: newText,
            tags: newTags,
            pii: false,
            createdAt: Date(),
            createdBy: nil,
            source: nil,
            embedding: embedding
        )

        return Memory(
            id: updatedChunk.id,
            covenId: nil,
            userId: nil,
            roleId: nil,
            scope: MemoryScope(rawValue: updatedChunk.scope) ?? .user,
            title: title,
            content: updatedChunk.text,
            tags: updatedChunk.tags.isEmpty ? nil : updatedChunk.tags,
            isPinned: isPinned ?? false,
            isApproved: true,
            createdAt: updatedChunk.createdAt,
            updatedAt: Date()
        )
    }

    /// Delete a memory chunk from the local store.
    func deleteMemory(memoryId: String) async throws {
        try await memoryStore.deleteMemory(id: memoryId)
    }

    /// Pin or unpin a memory chunk. In the local-only client we treat this as
    /// a purely in-memory flag and do not persist it yet.
    func togglePin(memoryId: String, isPinned: Bool) async throws -> Memory {
        let base = try await getMemory(memoryId: memoryId)
        return Memory(
            id: base.id,
            covenId: base.covenId,
            userId: base.userId,
            roleId: base.roleId,
            scope: base.scope,
            title: base.title,
            content: base.content,
            tags: base.tags,
            isPinned: isPinned,
            isApproved: base.isApproved,
            createdAt: base.createdAt,
            updatedAt: base.updatedAt
        )
    }

    // MARK: - Memory Proposals (local-only)

    /// Map a low-level GRDB record into the public MemoryProposal model used by
    /// the views and (legacy) service APIs.
    private func mapRecordToProposal(_ rec: MemoryProposalRecord) -> MemoryProposal {
        let tags: [String]?
        if let tagsString = rec.proposedTags,
           let data = tagsString.data(using: .utf8) {
            do {
                tags = try JSONDecoder().decode([String].self, from: data)
            } catch {
                AppErrorReporter.log(error: error, context: "MemoryService.mapRecordToProposal.proposedTagsDecode")
                tags = nil
            }
        } else {
            tags = nil
        }

        return MemoryProposal(
            id: rec.id,
            eventId: rec.eventId ?? "",
            covenId: rec.covenId,
            proposedContent: rec.proposedContent,
            proposedTags: tags,
            scope: rec.scope,
            reason: rec.reason,
            sourceMessageId: rec.sourceMessageId,
            status: rec.status,
            proposedBy: rec.proposedBy,
            reviewedBy: rec.reviewedBy,
            createdAt: rec.createdAt,
            reviewedAt: rec.reviewedAt,
            title: rec.title
        )
    }

    /// List memory proposals from the local SQLite store. The default
    /// `status = "pending"` matches the UI's initial filter; passing "all"
    /// disables status filtering.
    func listProposals(
        covenId: String?,
        status: String = "pending"
    ) async throws -> [MemoryProposal] {
        let effectiveStatus: String? = (status == "all") ? nil : status
        let records = try await MemoryProposalRepository.shared.listProposals(
            covenId: covenId,
            status: effectiveStatus
        )
        return records.map(mapRecordToProposal)
    }

    /// Review a proposal by updating its status and, when approved, creating a
    /// real memory chunk in the local encrypted store.
    func reviewProposal(
        proposalId: String,
        action: String,
        feedback: String? = nil
    ) async throws -> MemoryProposal {
        // Normalize the new status from the requested action.
        let newStatus: String = switch action.lowercased() {
        case "approve":
            "approved"
        case "reject":
            "rejected"
        default:
            action
        }

        // Load the current proposal so we can both validate it exists and, for
        // approvals, create a corresponding memory chunk.
        guard let existing = try await MemoryProposalRepository.shared.loadProposal(id: proposalId) else {
            throw APIError.backendUnavailable
        }

        // If the proposal is being approved, create a local memory entry using
        // the proposed content, tags, and scope. This ensures that "Approve"
        // behaves as "save this as memory" in the local-only client.
        if newStatus == "approved" {
            let scope = existing.scope ?? (existing.covenId == nil ? "user" : "coven")
            let tags: [String]
            if let tagsString = existing.proposedTags,
               let data = tagsString.data(using: .utf8) {
                do {
                    tags = try JSONDecoder().decode([String].self, from: data)
                } catch {
                    AppErrorReporter.log(error: error, context: "MemoryService.reviewProposal.proposedTagsDecode")
                    tags = []
                }
            } else {
                tags = []
            }
            _ = try await EmbeddingService.shared.indexMemory(
                scope: scope,
                text: existing.proposedContent,
                tags: tags,
                pii: false,
                createdBy: existing.proposedBy,
                source: existing.sourceMessageId
            )
        }

        let updated = try await MemoryProposalRepository.shared.updateStatus(
            id: proposalId,
            status: newStatus,
            reviewedBy: "local-user",
            reviewFeedback: feedback
        )

        return mapRecordToProposal(updated)
    }
}
