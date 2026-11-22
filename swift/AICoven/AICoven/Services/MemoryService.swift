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

/// Why a proposal was not reviewed.
nonisolated enum ProposalReviewError: LocalizedError, Equatable {
    /// A review of it is under way (a second press, or another window).
    case underWay
    /// It was reviewed already, and is no longer pending.
    case alreadyReviewed

    var errorDescription: String? {
        switch self {
        case .underWay: "This proposal is already being reviewed."
        case .alreadyReviewed: "This proposal was already reviewed."
        }
    }
}

/// Service for managing memory operations
actor MemoryService {
    static let shared = MemoryService()

    /// Abstraction over long-term memory persistence so higher-level features
    /// do not depend directly on the GRDB-backed repository.
    private let memoryStore: MemoryStore
    /// The embedding of a text, where a provider can make one.
    private let embed: @Sendable (String) async throws -> [Float]?
    /// The account signed in, by its id.
    private let currentAccount: @Sendable () async -> String
    /// The proposals being reviewed now: each is reviewed once at a time.
    private var reviewing: Set<String> = []

    /// Internal initializer so tests can inject a mock MemoryStore, the
    /// embedding step, and who is signed in.
    init(
        memoryStore: MemoryStore = MemoryRepository.shared,
        embed: @escaping @Sendable (String) async throws -> [Float]? = { try await EmbeddingService.shared.embedText($0) },
        currentAccount: @escaping @Sendable () async -> String = { await MainActor.run { UserScope.currentUserID } }
    ) {
        self.memoryStore = memoryStore
        self.embed = embed
        self.currentAccount = currentAccount
    }

    // MARK: - Memory Search and Retrieval (Local-only)

    /// A memory as the views have it.
    private static func memory(from chunk: LocalMemoryChunk) -> Memory {
        Memory(
            id: chunk.id,
            covenId: chunk.covenID,
            userId: nil,
            roleId: nil,
            scope: MemoryScope(rawValue: chunk.scope) ?? .user,
            title: nil,
            content: chunk.text,
            tags: chunk.tags.isEmpty ? nil : chunk.tags,
            isPinned: false,
            isApproved: true,
            createdAt: chunk.createdAt,
            updatedAt: nil,
            unreadable: chunk.isUnreadable ? true : nil
        )
    }

    /// A page of the memories kept in one place, newest first: `limit` of
    /// them after the first `offset`.
    func memories(in place: MemoryPlace, limit: Int, offset: Int = 0) async throws -> [Memory] {
        try await memoryStore.loadMemories(in: place, limit: limit, offset: offset, as: currentAccount()).map(Self.memory)
    }

    /// The memories of one place (`MemoryPlace.init(covenID:scope:)`): the
    /// newest, or with a query those among the newest that match it best.
    func searchMemory(
        covenId: String?,
        query: String? = nil,
        scope: String? = nil,
        tags _: [String]? = nil,
        limit: Int = 20
    ) async throws -> [Memory] {
        let place = MemoryPlace(covenID: covenId, scope: scope)
        let chunks: [LocalMemoryChunk] = if let queryText = query, !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Use embedding+lexical hybrid search for text queries.
            try await EmbeddingService.shared.searchRelevantMemories(
                query: queryText,
                in: [place],
                topK: limit,
                candidateLimit: limit * 4,
                includePII: false
            )
        } else {
            try await memoryStore.loadMemories(in: place, limit: limit, offset: 0, as: currentAccount())
        }
        return chunks.map(Self.memory)
    }

    /// Get a specific memory chunk by ID from the local store.
    func getMemory(memoryId: String) async throws -> Memory {
        guard let chunk = try await memoryStore.loadMemory(id: memoryId) else {
            throw MemoryStoreError.noSuchMemory
        }
        return Self.memory(from: chunk)
    }

    // MARK: - Memory Creation and Updates (Local-only)

    /// Stores a new memory, encrypted, where its coven and scope say
    /// (`MemoryPlace.init(covenID:scope:)`).
    func createMemory(
        covenId: String?,
        scope: String,
        title _: String?,
        content: String,
        tags: [String]?,
        isPinned _: Bool = false
    ) async throws -> Memory {
        try await createMemory(in: MemoryPlace(covenID: covenId, scope: scope), content: content, tags: tags)
    }

    /// Stores a new memory, encrypted, in `place`, as `account` where the
    /// caller has read whose it is already (the account signed in now
    /// otherwise).
    func createMemory(in place: MemoryPlace, content: String, tags: [String]?, as asked: String? = nil) async throws -> Memory {
        // Whose memory it is, read before the embedding is waited for: it
        // is stored as theirs, or not at all if another account is signed
        // in by then.
        let account = if let asked { asked } else { await currentAccount() }
        let embedding = try await embed(content)
        let chunk = try await memoryStore.storeMemory(
            in: place,
            text: content,
            tags: tags ?? [],
            pii: false,
            createdBy: nil,
            source: nil,
            embedding: embedding,
            as: account
        )
        return Self.memory(from: chunk)
    }

    /// Gives a memory new text, and new tags where some are given (nil
    /// keeps its tags). It is changed as the account that asked, read
    /// before the embedding is waited for, and not at all if another is
    /// signed in by then. Throws `MemoryStoreError.noSuchMemory` if that
    /// account has no such memory. A memory has no title, pin or scope of
    /// its own to change: it stays where it is kept.
    func updateMemory(
        memoryId: String,
        title _: String? = nil,
        content: String,
        tags: [String]?,
        scope _: String? = nil,
        isPinned _: Bool? = nil
    ) async throws -> Memory {
        let account = await currentAccount()
        let embedding = try await embed(content)
        let chunk = try await memoryStore.updateMemory(id: memoryId, newText: content, newTags: tags, newEmbedding: embedding, as: account)
        return Self.memory(from: chunk)
    }

    /// Removes a memory of the signed-in account's.
    func deleteMemory(memoryId: String) async throws {
        try await memoryStore.deleteMemory(id: memoryId, as: currentAccount())
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

    /// Reviews a proposal that is still pending: approved, its content is
    /// stored as a memory; rejected, it is only marked. One review of a
    /// proposal runs at a time (`ProposalReviewError.underWay` for a second
    /// press), and one that was settled already is not settled again
    /// (`.alreadyReviewed`): approving twice makes one memory, and a
    /// rejection is not overwritten by an older approval. It is reviewed
    /// as the account that asked: if another is signed in by the time the
    /// embedding has been made, nothing is stored or marked.
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
        return try await settle(proposalId: proposalId, as: newStatus, feedback: feedback, storing: newStatus == "approved" ? .itsContent : nil)
    }

    /// Saves a proposal's content, as the person edited it, as a memory,
    /// and marks the proposal reviewed so it is no longer pending. The
    /// memory is stored once. Under the same rules as `reviewProposal`.
    func saveProposalAsMemory(proposalId: String, content: String) async throws -> MemoryProposal {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await settle(
            proposalId: proposalId, as: "rejected", feedback: "Saved as manual memory from Swift client", storing: .text(text)
        )
    }

    /// What settling a proposal stores as a memory.
    private enum Stored {
        case itsContent
        case text(String)
    }

    private func settle(proposalId: String, as status: String, feedback: String?, storing: Stored?) async throws -> MemoryProposal {
        // Whose review it is, read before anything is waited for.
        let account = await currentAccount()
        // Reserved before the first wait on anything else: a second press
        // finds it taken.
        guard reviewing.insert(proposalId).inserted else { throw ProposalReviewError.underWay }
        defer { reviewing.remove(proposalId) }

        guard let existing = try await MemoryProposalRepository.shared.loadProposal(id: proposalId, for: account) else {
            throw APIError.backendUnavailable
        }
        guard existing.status == "pending" else { throw ProposalReviewError.alreadyReviewed }

        guard let storing else {
            return try await mark(proposalId, as: status, feedback: feedback, for: account)
        }
        let text: String = switch storing {
        case .itsContent: existing.proposedContent
        case let .text(edited): edited
        }
        // Kept where it was proposed: in its coven's pages, or for one
        // proposed in no coven as the person's own.
        let place = existing.covenId.map(MemoryPlace.coven) ?? .aboutMe
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
        // The long wait. Nothing is written before it, so an account that
        // changes meanwhile finds nothing of this review.
        let embedding = try await embed(text)
        guard await currentAccount() == account else { throw RepositoryError.accountChanged }
        // Marked first, in one write that only a pending proposal passes:
        // the memory is then stored for a proposal no other review can
        // settle. If it cannot be stored, the proposal is pending again.
        let settled = try await mark(proposalId, as: status, feedback: feedback, for: account)
        do {
            try await memoryStore.storeMemory(
                in: place,
                text: text,
                tags: tags,
                pii: false,
                createdBy: existing.proposedBy,
                source: existing.sourceMessageId,
                embedding: embedding,
                as: account
            )
        } catch {
            do {
                try await MemoryProposalRepository.shared.reopen(id: proposalId, for: account)
            } catch let reopening {
                // The kind of failure only.
                AppErrorReporter.log(
                    message: "A proposal whose memory could not be stored could not be made pending again (\(type(of: reopening)))",
                    context: "MemoryService.settle"
                )
            }
            throw error
        }
        return settled
    }

    /// Marks a pending proposal of `account`'s as reviewed; throws
    /// `.alreadyReviewed` if it is no longer pending.
    private func mark(_ proposalId: String, as status: String, feedback: String?, for account: String) async throws -> MemoryProposal {
        guard let updated = try await MemoryProposalRepository.shared.settlePending(
            id: proposalId, as: status, reviewedBy: "local-user", reviewFeedback: feedback, for: account
        ) else {
            throw ProposalReviewError.alreadyReviewed
        }
        return mapRecordToProposal(updated)
    }
}
