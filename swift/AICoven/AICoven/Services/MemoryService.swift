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
    /// Its text could not be opened with the account's key: it can be
    /// rejected, and not approved.
    var isUnreadable = false

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

/// Why a proposal was not reviewed.
nonisolated enum ProposalReviewError: LocalizedError, Equatable {
    /// A review of it is under way (a second press, or another window).
    case underWay
    /// It was reviewed already, and is no longer pending.
    case alreadyReviewed
    /// Its text cannot be opened, so there is nothing to approve.
    case unreadable

    var errorDescription: String? {
        switch self {
        case .underWay: "This proposal is already being reviewed."
        case .alreadyReviewed: "This proposal was already reviewed."
        case .unreadable: "This proposal's text can't be opened, so it can't be approved as it is."
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

    /// The account something is done as: the one the caller read already,
    /// or the one signed in now.
    private func account(_ asked: String?) async -> String {
        if let asked { asked } else { await currentAccount() }
    }

    /// A page of the memories kept in one place, newest first: `limit` of
    /// them after the first `offset`. They are `asked`'s, and are not read
    /// if another account is signed in.
    func memories(in place: MemoryPlace, limit: Int, offset: Int = 0, as asked: String? = nil) async throws -> [Memory] {
        try await memoryStore.loadMemories(in: place, limit: limit, offset: offset, as: account(asked)).map(Self.memory)
    }

    // MARK: - Memory Creation and Updates (Local-only)

    /// Stores a new memory, encrypted, in `place`, as `account` where the
    /// caller has read whose it is already (the account signed in now
    /// otherwise).
    func createMemory(in place: MemoryPlace, content: String, tags: [String]?, as asked: String? = nil) async throws -> Memory {
        // Whose memory it is, read before the embedding is waited for: it
        // is stored as theirs, or not at all if another account is signed
        // in by then.
        let account = await account(asked)
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
    /// keeps its tags). It is changed as the account that asked (`asked`
    /// where the caller has read whose it is already), read before the
    /// embedding is waited for, and not at all if another is signed in by
    /// then. Throws `MemoryStoreError.noSuchMemory` if that account has no
    /// such memory. It stays where it is kept.
    func updateMemory(memoryId: String, content: String, tags: [String]?, as asked: String? = nil) async throws -> Memory {
        let account = await account(asked)
        let embedding = try await embed(content)
        let chunk = try await memoryStore.updateMemory(id: memoryId, newText: content, newTags: tags, newEmbedding: embedding, as: account)
        return Self.memory(from: chunk)
    }

    /// Removes a memory of the signed-in account's, or of `asked`'s where
    /// the caller has read whose it is already.
    func deleteMemory(memoryId: String, as asked: String? = nil) async throws {
        try await memoryStore.deleteMemory(id: memoryId, as: account(asked))
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
            title: rec.title,
            isUnreadable: rec.isUnreadable
        )
    }

    /// List memory proposals from the local SQLite store. The default
    /// `status = "pending"` matches the UI's initial filter; passing "all"
    /// disables status filtering. With a `limit`, the latest that many.
    func listProposals(
        covenId: String?,
        status: String = "pending",
        limit: Int? = nil
    ) async throws -> [MemoryProposal] {
        let effectiveStatus: String? = (status == "all") ? nil : status
        let records = try await MemoryProposalRepository.shared.listProposals(
            covenId: covenId,
            status: effectiveStatus,
            limit: limit
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
        return try await settle(proposalId: proposalId, as: newStatus, feedback: feedback, keeping: newStatus == "approved")
    }

    /// Settles a pending proposal as `status`; with `keeping`, its content
    /// is stored as a memory where it was proposed.
    private func settle(proposalId: String, as status: String, feedback: String?, keeping: Bool) async throws -> MemoryProposal {
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

        guard keeping else {
            return try await mark(existing, as: status, feedback: feedback, for: account)
        }
        guard !existing.isUnreadable else { throw ProposalReviewError.unreadable }
        let text = existing.proposedContent
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
        let settled = try await mark(existing, as: status, feedback: feedback, for: account)
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
    /// `.alreadyReviewed` if it is no longer pending. The answer carries
    /// the proposal's text as it was read before it was settled.
    private func mark(_ proposal: MemoryProposalRecord, as status: String, feedback: String?, for account: String) async throws -> MemoryProposal {
        guard var settled = try await MemoryProposalRepository.shared.settlePending(
            id: proposal.id, as: status, reviewedBy: "local-user", reviewFeedback: feedback, for: account
        ) else {
            throw ProposalReviewError.alreadyReviewed
        }
        settled.proposedContent = proposal.proposedContent
        settled.isUnreadable = proposal.isUnreadable
        return mapRecordToProposal(settled)
    }
}
