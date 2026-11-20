import XCTest
@testable import AICoven

/// Integration-style tests for MemoryService using the real MemoryRepository
/// and EmbeddingService (which will no-op if no providers are configured).
@MainActor
final class MemoryServiceIntegrationTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
    }

    override func tearDown() async throws {
        await DataEncryptionService.shared.lock()
        try await super.tearDown()
    }

    func testCreateMemoryPersistsChunk() async throws {
        let service = MemoryService(memoryStore: MemoryRepository.shared)

        let scope = "integration_scope_" + UUID().uuidString
        let content = "Memory content for integration test"
        let tags = ["one", "two"]

        let memory = try await service.createMemory(
            covenId: nil,
            scope: scope,
            title: "Test Title",
            content: content,
            tags: tags,
            isPinned: false
        )

        XCTAssertEqual(memory.scope, .user)
        XCTAssertEqual(memory.content, content)
        XCTAssertEqual(memory.tags ?? [], tags)

        // Verify it can be loaded back through the MemoryRepository.
        let chunks = try await MemoryRepository.shared.loadMemories(scope: scope, limit: 10)
        XCTAssertTrue(chunks.contains(where: { $0.id == memory.id && $0.text == content }))
    }

    func testUpdateMemoryFallsBackToExistingTextWhenContentNil() async throws {
        let service = MemoryService(memoryStore: MemoryRepository.shared)

        let scope = "integration_update_scope_" + UUID().uuidString
        let originalContent = "Original text"
        let tags = ["alpha"]

        let created = try await service.createMemory(
            covenId: nil,
            scope: scope,
            title: nil,
            content: originalContent,
            tags: tags,
            isPinned: false
        )

        // Update without providing new content; MemoryService should preserve the
        // original text and only update tags/metadata.
        let updated = try await service.updateMemory(
            memoryId: created.id,
            title: nil,
            content: nil,
            tags: ["beta"],
            scope: scope,
            isPinned: true
        )

        XCTAssertEqual(updated.id, created.id)
        XCTAssertEqual(updated.content, originalContent)
        XCTAssertEqual(updated.tags ?? [], ["beta"])
        XCTAssertTrue(updated.isPinned)
    }

    func testReviewProposalApprove_createsMemoryAndUpdatesStatus() async throws {
        // Arrange: insert a proposal directly via the repository so we exercise
        // the full reviewProposal flow, including MemoryProposalRepository and
        // EmbeddingService.indexMemory.
        let uniqueScope = "proposal_scope_" + UUID().uuidString
        let proposedContent = "Proposed memory content for approve flow"
        let proposedTags = ["tag1", "tag2"]

        let record = try await MemoryProposalRepository.shared.insertProposal(
            eventId: "event-1",
            covenId: nil,
            proposedContent: proposedContent,
            proposedTags: proposedTags,
            scope: uniqueScope,
            reason: "test",
            sourceMessageId: "source-1",
            proposedBy: "tester",
            title: "Test Proposal"
        )

        // Act: approve the proposal via MemoryService.
        let service = MemoryService(memoryStore: MemoryRepository.shared)
        let updated = try await service.reviewProposal(
            proposalId: record.id,
            action: "approve"
        )

        // Assert: proposal status and review metadata are updated.
        XCTAssertEqual(updated.id, record.id)
        XCTAssertEqual(updated.status, "approved")
        XCTAssertEqual(updated.proposedContent, proposedContent)
        XCTAssertEqual(updated.proposedTags ?? [], proposedTags)
        XCTAssertEqual(updated.reviewedBy, "local-user")
        XCTAssertNotNil(updated.reviewedAt)

        // Assert: a corresponding memory chunk was created with the same
        // content/tags under the derived scope.
        let chunks = try await MemoryRepository.shared.loadMemories(scope: uniqueScope, limit: 10)
        XCTAssertTrue(
            chunks.contains(where: { chunk in
                chunk.text == proposedContent && chunk.tags == proposedTags && chunk.scope == uniqueScope
            }),
            "Expected an indexed memory chunk matching the approved proposal"
        )
    }

    func testReviewProposalReject_updatesStatusWithoutCreatingMemory() async throws {
        // Arrange: insert a proposal under a unique scope so we can verify that
        // rejecting it does not create any stored memories.
        let uniqueScope = "proposal_reject_scope_" + UUID().uuidString
        let proposedContent = "Proposed memory content for reject flow"

        let record = try await MemoryProposalRepository.shared.insertProposal(
            eventId: "event-2",
            covenId: nil,
            proposedContent: proposedContent,
            proposedTags: nil,
            scope: uniqueScope,
            reason: nil,
            sourceMessageId: nil,
            proposedBy: "tester",
            title: nil
        )

        let service = MemoryService(memoryStore: MemoryRepository.shared)

        // Act: reject the proposal.
        let updated = try await service.reviewProposal(
            proposalId: record.id,
            action: "reject"
        )

        // Assert: status is updated but no new memories are created for the
        // unique scope.
        XCTAssertEqual(updated.id, record.id)
        XCTAssertEqual(updated.status, "rejected")

        let chunks = try await MemoryRepository.shared.loadMemories(scope: uniqueScope, limit: 10)
        XCTAssertTrue(chunks.isEmpty, "Expected no memory chunks to be created when rejecting a proposal")
    }

    // MARK: - A proposal is reviewed once, as the account that reviewed it, in its own scope

    /// A pending proposal in a scope of its own, so its memories can be counted.
    private func proposal(in scope: String, covenID: String? = nil, content: String = "What was proposed") async throws -> MemoryProposalRecord {
        try await MemoryProposalRepository.shared.insertProposal(
            eventId: nil, covenId: covenID, proposedContent: content, proposedTags: ["one"], scope: scope, reason: nil,
            sourceMessageId: nil, proposedBy: "tester", title: nil
        )
    }

    private func memories(in scope: String) async throws -> [LocalMemoryChunk] {
        try await MemoryRepository.shared.loadMemories(scope: scope, limit: 20)
    }

    private func status(of id: String) async throws -> String? {
        try await MemoryProposalRepository.shared.loadProposal(id: id, for: UserScope.currentUserID)?.status
    }

    func testAProposalIsSettledOnce_approvedTwiceMakesOneMemoryAndARejectionIsNotOverwritten() async throws {
        let scope = "proposal_once_" + UUID().uuidString
        let service = MemoryService(memoryStore: MemoryRepository.shared)

        let approved = try await proposal(in: scope)
        _ = try await service.reviewProposal(proposalId: approved.id, action: "approve")
        for action in ["approve", "reject"] {
            do {
                _ = try await service.reviewProposal(proposalId: approved.id, action: action)
                XCTFail("Reviewed again: \(action)")
            } catch {
                XCTAssertEqual(error as? ProposalReviewError, .alreadyReviewed, action)
            }
        }
        let made = try await memories(in: scope)
        XCTAssertEqual(made.count, 1, "One memory, however often it is approved")
        let stays = try await status(of: approved.id)
        XCTAssertEqual(stays, "approved", "A later rejection does not undo it")

        // Rejected first: an approval after it stores nothing.
        let rejectedScope = "proposal_rejected_" + UUID().uuidString
        let rejected = try await proposal(in: rejectedScope)
        _ = try await service.reviewProposal(proposalId: rejected.id, action: "reject")
        do {
            _ = try await service.reviewProposal(proposalId: rejected.id, action: "approve")
            XCTFail("Approved what was rejected")
        } catch {
            XCTAssertEqual(error as? ProposalReviewError, .alreadyReviewed)
        }
        let none = try await memories(in: rejectedScope)
        XCTAssertTrue(none.isEmpty)
    }

    func testASecondReviewWhileOneIsUnderWay_isRefused_andOneMemoryIsMade() async throws {
        let scope = "proposal_two_presses_" + UUID().uuidString
        // The embedding is held, as a slow provider holds it, until the test lets it go.
        let (reached, reach) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        let service = MemoryService(memoryStore: MemoryRepository.shared, embed: { _ in
            reach.yield()
            for await _ in released {
                break
            }
            return nil
        })
        let record = try await proposal(in: scope)
        let first = Task { try await service.reviewProposal(proposalId: record.id, action: "approve") }
        for await _ in reached {
            break
        }
        // Pressed again, and Reject pressed, while the first approval waits.
        for action in ["approve", "reject"] {
            do {
                _ = try await service.reviewProposal(proposalId: record.id, action: action)
                XCTFail("A second review ran: \(action)")
            } catch {
                XCTAssertEqual(error as? ProposalReviewError, .underWay, action)
            }
        }
        release.yield()
        let settled = try await first.value
        XCTAssertEqual(settled.status, "approved")
        let made = try await memories(in: scope)
        XCTAssertEqual(made.count, 1)
    }

    func testAnApprovalWhoseAccountChangedWhileItWaited_storesAndMarksNothing() async throws {
        let scope = "proposal_account_" + UUID().uuidString
        let record = try await proposal(in: scope)
        let me = UserScope.currentUserID
        // Who is signed in: the reviewer when the review begins, another by the time the embedding is made.
        let asked = Counter()
        let service = MemoryService(
            memoryStore: MemoryRepository.shared,
            embed: { _ in nil },
            currentAccount: { await asked.next() == 1 ? me : "someone-else" }
        )
        do {
            _ = try await service.reviewProposal(proposalId: record.id, action: "approve")
            XCTFail("Approved as another account")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .accountChanged)
        }
        let made = try await memories(in: scope)
        XCTAssertTrue(made.isEmpty, "Nothing of one account's is stored once another is signed in")
        let still = try await status(of: record.id)
        XCTAssertEqual(still, "pending", "It is still theirs to review")
    }

    func testSavingAProposalAsAMemory_storesItOnceAsEdited_andItIsNoLongerPending() async throws {
        let scope = "proposal_saved_" + UUID().uuidString
        let record = try await proposal(in: scope, content: "As the agent put it")
        let service = MemoryService(memoryStore: MemoryRepository.shared)

        let saved = try await service.saveProposalAsMemory(proposalId: record.id, content: "  As the person put it\n")
        XCTAssertEqual(saved.status, "rejected", "Reviewed, as the app has always marked one saved by hand")
        let made = try await memories(in: scope)
        XCTAssertEqual(made.map(\.text), ["As the person put it"], "Once, and as edited")
        XCTAssertEqual(made.first?.tags, ["one"])

        do {
            _ = try await service.saveProposalAsMemory(proposalId: record.id, content: "Again")
            XCTFail("Saved twice")
        } catch {
            XCTAssertEqual(error as? ProposalReviewError, .alreadyReviewed)
        }
        let after = try await memories(in: scope)
        XCTAssertEqual(after.count, 1)
    }

    func testAScopesProposalsAreItsOwn_strixsAreThoseMadeInNoCoven() async throws {
        let scope = "proposal_scopes_" + UUID().uuidString
        let coven = "coven_" + UUID().uuidString
        let personal = try await proposal(in: scope)
        let inCoven = try await proposal(in: scope, covenID: coven)
        let service = MemoryService(memoryStore: MemoryRepository.shared)

        let strix = try await service.listProposals(covenId: nil, status: "all")
        XCTAssertTrue(strix.contains { $0.id == personal.id })
        XCTAssertFalse(strix.contains { $0.id == inCoven.id }, "A coven's proposal is not reviewed from Strix")
        let covens = try await service.listProposals(covenId: coven, status: "all")
        XCTAssertEqual(covens.map(\.id), [inCoven.id])
        // Settled, so they do not wait in later runs.
        _ = try await service.reviewProposal(proposalId: personal.id, action: "reject")
        _ = try await service.reviewProposal(proposalId: inCoven.id, action: "reject")
    }
}

/// Counts the times it is asked.
private actor Counter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}
