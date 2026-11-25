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

    /// A coven of the signed-in account's, so that what a test stores in
    /// its memory can be counted. It is deleted when the test ends.
    private func newCoven() async throws -> String {
        let coven = try await CovenService.shared.createCoven(name: "Memory \(UUID().uuidString)")
        addTeardownBlock { try? await CovenService.shared.deleteCoven(id: coven.id) }
        return coven.id
    }

    func testCreateMemoryPersistsChunk() async throws {
        let service = MemoryService(memoryStore: MemoryRepository.shared)
        let coven = try await newCoven()
        let content = "Memory content for integration test"
        let tags = ["one", "two"]

        let memory = try await service.createMemory(in: .coven(coven), content: content, tags: tags)

        XCTAssertEqual(memory.scope, .coven)
        XCTAssertEqual(memory.covenId, coven)
        XCTAssertEqual(memory.content, content)
        XCTAssertEqual(memory.tags ?? [], tags)

        // Verify it can be loaded back through the MemoryRepository.
        let chunks = try await MemoryRepository.shared.loadMemories(in: .coven(coven), limit: 10)
        XCTAssertEqual(chunks.map(\.id), [memory.id])
        XCTAssertEqual(chunks.first?.text, content)
    }

    func testUpdatingAMemory_keepsItsTagsWhereNoneAreGiven_andItStaysWhereItIsKept() async throws {
        let service = MemoryService(memoryStore: MemoryRepository.shared)
        let coven = try await newCoven()
        let created = try await service.createMemory(in: .coven(coven), content: "Original text", tags: ["alpha"])

        // New text alone: the tags stay.
        let rewritten = try await service.updateMemory(memoryId: created.id, content: "New text", tags: nil)
        XCTAssertEqual(rewritten.id, created.id)
        XCTAssertEqual(rewritten.content, "New text")
        XCTAssertEqual(rewritten.tags ?? [], ["alpha"])
        XCTAssertEqual(rewritten.covenId, coven)

        // New tags with it: both are as given.
        let retagged = try await service.updateMemory(memoryId: created.id, content: "Newer text", tags: ["beta"])
        XCTAssertEqual(retagged.content, "Newer text")
        XCTAssertEqual(retagged.tags ?? [], ["beta"])

        let stored = try await MemoryRepository.shared.loadMemories(in: .coven(coven), limit: 10)
        XCTAssertEqual(stored.map(\.text), ["Newer text"])
        XCTAssertEqual(stored.map(\.id), [created.id], "It is the same entry, where it was")
    }

    func testAMemoryThatIsNotThere_isNotChanged_andNoneIsMadeUp() async throws {
        let service = MemoryService(memoryStore: MemoryRepository.shared)
        do {
            _ = try await service.updateMemory(memoryId: "no-such-memory-\(UUID().uuidString)", content: "New text", tags: nil)
            XCTFail("Reported a change to a memory that is not there")
        } catch {
            guard case MemoryStoreError.noSuchMemory = error else { return XCTFail("\(type(of: error))") }
        }
    }

    func testAMemoryIsChangedAndRemovedOnlyAsTheAccountThatAsked() async throws {
        let coven = try await newCoven()
        let created = try await MemoryService(memoryStore: MemoryRepository.shared).createMemory(in: .coven(coven), content: "Mine", tags: nil)
        // The one who asked is no longer signed in by the time the embedding is made.
        let service = MemoryService(memoryStore: MemoryRepository.shared, embed: { _ in nil }, currentAccount: { "someone-who-signed-out" })
        do {
            _ = try await service.updateMemory(memoryId: created.id, content: "Theirs", tags: nil)
            XCTFail("Changed as an account that is not signed in")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .accountChanged)
        }
        do {
            try await MemoryRepository.shared.deleteMemory(id: created.id, as: "someone-who-signed-out")
            XCTFail("Removed as an account that is not signed in")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .accountChanged)
        }
        let kept = try await MemoryRepository.shared.loadMemories(in: .coven(coven), limit: 10)
        XCTAssertEqual(kept.map(\.text), ["Mine"])
    }

    func testReviewProposalApprove_createsMemoryAndUpdatesStatus() async throws {
        // Arrange: insert a proposal directly via the repository so we exercise
        // the full reviewProposal flow, including MemoryProposalRepository and
        // the memory store.
        let coven = try await newCoven()
        let proposedContent = "Proposed memory content for approve flow"
        let proposedTags = ["tag1", "tag2"]

        let record = try await MemoryProposalRepository.shared.insertProposal(
            eventId: "event-1",
            covenId: coven,
            proposedContent: proposedContent,
            proposedTags: proposedTags,
            scope: "coven",
            sourceMessageId: "source-1",
            proposedBy: "tester"
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
        // Kept in the clear as the page the entry goes on, not the words given.
        XCTAssertEqual(updated.proposedTags ?? [], ["page:facts"])
        XCTAssertEqual(updated.reviewedBy, "local-user")
        XCTAssertNotNil(updated.reviewedAt)

        // Assert: a corresponding memory chunk was created with the same
        // content/tags in the proposal's coven.
        let chunks = try await MemoryRepository.shared.loadMemories(in: .coven(coven), limit: 10)
        XCTAssertEqual(chunks.map(\.text), [proposedContent], "Expected a memory matching the approved proposal")
        XCTAssertEqual(chunks.first?.tags, ["page:facts"], "On the page its tags put it on")
    }

    func testAProposalIsKeptWhereItWasMade_whateverItsScopeSays() async throws {
        let service = MemoryService(memoryStore: MemoryRepository.shared)
        let coven = try await newCoven()
        // Made in a coven, about the person: it is the coven's.
        let inCoven = try await MemoryProposalRepository.shared.insertProposal(
            eventId: nil, covenId: coven, proposedContent: "Proposed in the coven", proposedTags: nil, scope: "user",
            sourceMessageId: nil, proposedBy: "tester"
        )
        _ = try await service.reviewProposal(proposalId: inCoven.id, action: "approve")
        let covens = try await memories(in: coven)
        XCTAssertEqual(covens.map(\.text), ["Proposed in the coven"])

        // Made in no coven, with a coven's scope: it is the person's own.
        let content = "Proposed in no coven \(UUID().uuidString)"
        let inNone = try await MemoryProposalRepository.shared.insertProposal(
            eventId: nil, covenId: nil, proposedContent: content, proposedTags: nil, scope: "coven",
            sourceMessageId: nil, proposedBy: "tester"
        )
        _ = try await service.reviewProposal(proposalId: inNone.id, action: "approve")
        let own = try await MemoryRepository.shared.loadMemories(in: .aboutMe, limit: 5)
        let made = try XCTUnwrap(own.first { $0.text == content })
        addTeardownBlock { try? await MemoryRepository.shared.deleteMemory(id: made.id, as: UserScope.currentUserID) }
        XCTAssertEqual(made.scope, "user")
    }

    func testAProposalMadeInNoCoven_isKeptAsThePersonsOwn() async throws {
        let content = "About the person \(UUID().uuidString)"
        let record = try await MemoryProposalRepository.shared.insertProposal(
            eventId: nil, covenId: nil, proposedContent: content, proposedTags: nil, scope: "user",
            sourceMessageId: nil, proposedBy: "tester"
        )
        _ = try await MemoryService(memoryStore: MemoryRepository.shared).reviewProposal(proposalId: record.id, action: "approve")

        let own = try await MemoryRepository.shared.loadMemories(in: .aboutMe, limit: 5)
        let made = try XCTUnwrap(own.first { $0.text == content })
        addTeardownBlock { try? await MemoryRepository.shared.deleteMemory(id: made.id, as: UserScope.currentUserID) }
        XCTAssertNil(made.covenID)
        XCTAssertEqual(made.scope, "user")
    }

    func testReviewProposalReject_updatesStatusWithoutCreatingMemory() async throws {
        // Arrange: a proposal in a coven of its own, so we can verify that
        // rejecting it does not create any stored memories.
        let coven = try await newCoven()
        let record = try await proposal(in: coven, content: "Proposed memory content for reject flow")
        let service = MemoryService(memoryStore: MemoryRepository.shared)

        // Act: reject the proposal.
        let updated = try await service.reviewProposal(
            proposalId: record.id,
            action: "reject"
        )

        // Assert: status is updated but no new memories are created.
        XCTAssertEqual(updated.id, record.id)
        XCTAssertEqual(updated.status, "rejected")

        let chunks = try await memories(in: coven)
        XCTAssertTrue(chunks.isEmpty, "Expected no memory chunks to be created when rejecting a proposal")
    }

    // MARK: - A proposal is reviewed once, as the account that reviewed it, in its own scope

    /// A pending proposal in a coven, whose memories can then be counted.
    private func proposal(in coven: String?, content: String = "What was proposed") async throws -> MemoryProposalRecord {
        try await MemoryProposalRepository.shared.insertProposal(
            eventId: nil, covenId: coven, proposedContent: content, proposedTags: ["one"], scope: coven == nil ? "user" : "coven",
            sourceMessageId: nil, proposedBy: "tester"
        )
    }

    private func memories(in coven: String) async throws -> [LocalMemoryChunk] {
        try await MemoryRepository.shared.loadMemories(in: .coven(coven), limit: 20)
    }

    private func status(of id: String) async throws -> String? {
        try await MemoryProposalRepository.shared.loadProposal(id: id, for: UserScope.currentUserID)?.status
    }

    func testAProposalIsSettledOnce_approvedTwiceMakesOneMemoryAndARejectionIsNotOverwritten() async throws {
        let scope = try await newCoven()
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
        let rejectedScope = try await newCoven()
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
        let scope = try await newCoven()
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
        let scope = try await newCoven()
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

    func testAProposalWhoseMemoryCouldNotBeStored_isPendingAgain_andCanBeApprovedThen() async throws {
        let scope = try await newCoven()
        let record = try await proposal(in: scope)
        // The store refuses the memory, as it does while it cannot be written.
        let failing = MemoryService(memoryStore: RefusingStore(), embed: { _ in nil })
        do {
            _ = try await failing.reviewProposal(proposalId: record.id, action: "approve")
            XCTFail("Approved with nothing stored")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .databaseUnavailable)
        }
        let reopened = try await status(of: record.id)
        XCTAssertEqual(reopened, "pending", "Not left approved with no memory behind it")
        let none = try await memories(in: scope)
        XCTAssertTrue(none.isEmpty)

        // Tried again once the store takes it: approved, with its one memory.
        let service = MemoryService(memoryStore: MemoryRepository.shared, embed: { _ in nil })
        let approved = try await service.reviewProposal(proposalId: record.id, action: "approve")
        XCTAssertEqual(approved.status, "approved")
        let made = try await memories(in: scope)
        XCTAssertEqual(made.count, 1)
    }

    func testAScopesProposalsAreItsOwn_strixsAreThoseMadeInNoCoven() async throws {
        let coven = try await newCoven()
        let personal = try await proposal(in: nil)
        let inCoven = try await proposal(in: coven)
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

/// A store that keeps nothing: every write is refused.
private struct RefusingStore: MemoryStore {
    func storeMemory(
        in _: MemoryPlace, text _: String, tags _: [String], pii _: Bool, createdBy _: String?, source _: String?, embedding _: [Float]?,
        as _: String
    ) async throws -> LocalMemoryChunk {
        throw RepositoryError.databaseUnavailable
    }

    func loadMemories(in _: MemoryPlace, limit _: Int, offset _: Int, as _: String) async throws -> [LocalMemoryChunk] {
        []
    }

    func loadMemory(id _: String) async throws -> LocalMemoryChunk? {
        nil
    }

    func deleteMemory(id _: String, as _: String) async throws {}

    func updateMemory(
        id _: String, newText _: String, newTags _: [String]?, newEmbedding _: [Float]?, as _: String
    ) async throws -> LocalMemoryChunk {
        throw RepositoryError.databaseUnavailable
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
