@testable import AICoven
import GRDB
import XCTest

/// A memory an agent proposes is asked of the person, and its text is
/// kept encrypted until it is answered.
@MainActor
final class MemoryProposalQuestionsTests: XCTestCase {
    private let proposals = MemoryProposalRepository.shared

    override func setUp() async throws {
        try await super.setUp()
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        await ThreadService.shared.reloadForCurrentUser()
    }

    override func tearDown() async throws {
        await DataEncryptionService.shared.lock()
        try await super.tearDown()
    }

    private var account: String {
        UserScope.currentUserID
    }

    /// A coven of the signed-in account's, deleted (with what was proposed in it) when the test ends.
    private func newCoven() async throws -> String {
        let coven = try await CovenService.shared.createCoven(name: "Asked \(UUID().uuidString)")
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await CovenService.shared.deleteCoven(id: coven.id)
        }
        return coven.id
    }

    private func propose(_ text: String, in coven: String) async throws -> MemoryProposalRecord {
        try await proposals.insertProposal(
            eventId: nil, covenId: coven, proposedContent: text, proposedTags: ["fact"], scope: "coven", reason: nil,
            sourceMessageId: nil, proposedBy: "agent", title: nil, as: account
        )
    }

    private func status(of id: String) async throws -> String? {
        try await proposals.loadProposal(id: id, for: account)?.status
    }

    private func kept(in coven: String) async throws -> [String] {
        try await MemoryRepository.shared.loadMemories(in: .coven(coven), limit: 20).map(\.text)
    }

    // MARK: - Kept encrypted

    func testAProposalsTextIsKeptEncrypted_andReadOnlyWithItsAccountsKey() async throws {
        let coven = try await newCoven()
        let stored = try await propose("Ships on Fridays", in: coven)
        XCTAssertEqual(stored.proposedContent, "Ships on Fridays")

        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let row = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT proposed_content, content_ciphertext FROM memory_proposals WHERE id = ?", arguments: [stored.id])
        }
        XCTAssertEqual(row?["proposed_content"] as String?, "", "Its words are not in the row as text")
        let sealed = try XCTUnwrap(row?["content_ciphertext"] as Data?)
        XCTAssertFalse(String(decoding: sealed, as: UTF8.self).contains("Ships on Fridays"))

        let listed = try await proposals.listProposals(covenId: coven, status: "pending")
        XCTAssertEqual(listed.map(\.proposedContent), ["Ships on Fridays"])

        // Settling it does not write its words back as text.
        _ = try await proposals.settlePending(id: stored.id, as: "rejected", reviewedBy: "local-user", reviewFeedback: nil, for: account)
        let after = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT proposed_content FROM memory_proposals WHERE id = ?", arguments: [stored.id])
        }
        XCTAssertEqual(after, "")

        // Not proposed to an account that is not signed in, nor with another account's key in memory.
        do {
            _ = try await proposals.insertProposal(
                eventId: nil, covenId: coven, proposedContent: "Theirs", proposedTags: nil, scope: "coven", reason: nil,
                sourceMessageId: nil, proposedBy: "agent", title: nil, as: "someone-who-signed-out"
            )
            XCTFail("Stored a proposal for an account that is not signed in")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .accountChanged)
        }
        await DataEncryptionService.shared.unlockForTestingEphemeral(ownedBy: "someone-who-signed-out")
        do {
            _ = try await proposals.listProposals(covenId: coven, status: nil)
            XCTFail("Read proposals with another account's key")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .dataLocked)
        }
    }

    func testAProposalStoredAsText_isSealedWhenItsAccountsProposalsAreNextRead() async throws {
        let coven = try await newCoven()
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let id = "old-proposal-\(UUID().uuidString)"
        let account = account
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO memory_proposals (id, user_id, coven_id, proposed_content, scope, status, created_at)
                VALUES (?, ?, ?, 'Stored as text', 'coven', 'pending', ?)
                """,
                arguments: [id, account, coven, Date()]
            )
        }

        let listed = try await proposals.listProposals(covenId: coven, status: "pending")
        XCTAssertEqual(listed.map(\.proposedContent), ["Stored as text"], "It reads as it did")
        let row = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT proposed_content, content_ciphertext FROM memory_proposals WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(row?["proposed_content"] as String?, "")
        XCTAssertNotNil(row?["content_ciphertext"] as Data?)

        // And it can still be approved into its coven.
        _ = try await MemoryService(memoryStore: MemoryRepository.shared).reviewProposal(proposalId: id, action: "approve")
        let memories = try await kept(in: coven)
        XCTAssertEqual(memories, ["Stored as text"])
    }

    func testAProposalTheKeyCannotOpen_saysSo_andIsNotApprovedAsItIs() async throws {
        let coven = try await newCoven()
        let stored = try await propose("Written under another key", in: coven)
        // The account's key is another now.
        await DataEncryptionService.shared.unlockForTestingEphemeral()

        let listed = try await proposals.listProposals(covenId: coven, status: "pending")
        XCTAssertEqual(listed.map(\.isUnreadable), [true])
        XCTAssertEqual(listed.map(\.proposedContent), [""])

        let service = MemoryService(memoryStore: MemoryRepository.shared)
        do {
            _ = try await service.reviewProposal(proposalId: stored.id, action: "approve")
            XCTFail("Approved a proposal whose text cannot be opened")
        } catch {
            XCTAssertEqual(error as? ProposalReviewError, .unreadable)
        }
        let none = try await kept(in: coven)
        XCTAssertEqual(none, [], "No empty memory is made of it")
        let still = try await status(of: stored.id)
        XCTAssertEqual(still, "pending")
        // It can be rejected.
        _ = try await service.reviewProposal(proposalId: stored.id, action: "reject")
        let rejected = try await status(of: stored.id)
        XCTAssertEqual(rejected, "rejected")
    }

    // MARK: - Asked beside the thread

    /// Asks through `answering`, and reviews with the real service.
    private func questions(answering: @escaping MemoryProposalQuestions.Asking) -> MemoryProposalQuestions {
        MemoryProposalQuestions(asking: answering, reviewing: { id, approve in
            _ = try await MemoryService(memoryStore: MemoryRepository.shared, embed: { _ in nil })
                .reviewProposal(proposalId: id, action: approve ? "approve" : "reject")
        })
    }

    func testApproveKeepsItWhereItWasProposed_denyDoesNot_andUnansweredItWaits() async throws {
        let coven = try await newCoven()
        var asked: [ToolApproval] = []

        let approved = try await propose("Ships on Fridays", in: coven)
        let approving = questions { question in
            asked.append(question)
            return .approved
        }
        approving.ask(approved, inThread: "thread-1", as: account)
        await approving.settled(approved.id)
        XCTAssertEqual(asked.map(\.question), ["Remember this for the coven?"])
        XCTAssertEqual(asked.map(\.details), ["Ships on Fridays"], "The question shows what would be remembered, whole")
        XCTAssertEqual(asked.map(\.threadID), ["thread-1"])
        XCTAssertEqual(asked.map(\.isOfATurn), [false])
        var memories = try await kept(in: coven)
        XCTAssertEqual(memories, ["Ships on Fridays"])
        let approvedStatus = try await status(of: approved.id)
        XCTAssertEqual(approvedStatus, "approved")

        let denied = try await propose("Never ships", in: coven)
        let denying = questions { _ in .denied }
        denying.ask(denied, inThread: "thread-1", as: account)
        await denying.settled(denied.id)
        memories = try await kept(in: coven)
        XCTAssertEqual(memories, ["Ships on Fridays"], "What was denied is not kept")
        let deniedStatus = try await status(of: denied.id)
        XCTAssertEqual(deniedStatus, "rejected")

        // With nowhere to ask (its thread is gone, say), it waits among the proposals.
        let unasked = try await propose("Ships on Mondays", in: coven)
        let notAsking = questions { _ in .notAsked }
        notAsking.ask(unasked, inThread: "thread-1", as: account)
        await notAsking.settled(unasked.id)
        let waiting = try await status(of: unasked.id)
        XCTAssertEqual(waiting, "pending")
        memories = try await kept(in: coven)
        XCTAssertEqual(memories.count, 1)
    }

    func testAnAnswerThatCouldNotBeKept_isAskedForOnceMore_sayingSo() async throws {
        let coven = try await newCoven()
        let proposal = try await propose("Ships on Fridays", in: coven)
        var asked: [String] = []
        var reviews = 0
        let failingOnce = MemoryProposalQuestions(
            asking: { question in
                asked.append(question.question)
                return .approved
            },
            reviewing: { id, approve in
                reviews += 1
                if reviews == 1 { throw RepositoryError.databaseUnavailable }
                _ = try await MemoryService(memoryStore: MemoryRepository.shared, embed: { _ in nil })
                    .reviewProposal(proposalId: id, action: approve ? "approve" : "reject")
            }
        )
        failingOnce.ask(proposal, inThread: "thread-1", as: account)
        await failingOnce.settled(proposal.id)
        XCTAssertEqual(asked, ["Remember this for the coven?", "Couldn't confirm your answer. Remember this for the coven?"])
        let memories = try await kept(in: coven)
        XCTAssertEqual(memories, ["Ships on Fridays"])

        // Failing again, it is left among the proposals: it is not asked a third time.
        let again = try await propose("Ships on Mondays", in: coven)
        asked = []
        let alwaysFailing = MemoryProposalQuestions(
            asking: { question in
                asked.append(question.question)
                return .approved
            },
            reviewing: { _, _ in throw RepositoryError.databaseUnavailable }
        )
        alwaysFailing.ask(again, inThread: "thread-1", as: account)
        await alwaysFailing.settled(again.id)
        XCTAssertEqual(asked.count, 2)
        let still = try await status(of: again.id)
        XCTAssertEqual(still, "pending")
    }

    func testWhenAnotherAccountSignsIn_theQuestionLeavesUnanswered_andAnAnswerForTheFirstIsNotTaken() async throws {
        let coven = try await newCoven()
        let me = account

        // The question is on screen when the account changes: it is withdrawn.
        let waiting = try await propose("Ships on Fridays", in: coven)
        let (reached, reach) = AsyncStream<Void>.makeStream()
        var reviewed = 0
        let asking = MemoryProposalQuestions(
            asking: { _ in
                reach.yield()
                // As the approvals do: the answer of a question whose task is cancelled is that it was withdrawn.
                while !Task.isCancelled {
                    await Task.yield()
                }
                return .withdrawn
            },
            reviewing: { _, _ in reviewed += 1 }
        )
        asking.ask(waiting, inThread: "thread-1", as: me)
        for await _ in reached {
            break
        }
        asking.accountChanged()
        await asking.settled(waiting.id)
        XCTAssertEqual(reviewed, 0)
        let stillWaiting = try await status(of: waiting.id)
        XCTAssertEqual(stillWaiting, "pending", "It waits among its account's proposals")

        // An answer that arrives once another account is signed in is not taken.
        var signedIn = me
        let answeredLate = MemoryProposalQuestions(
            asking: { _ in
                signedIn = "someone-else"
                return .approved
            },
            reviewing: { _, _ in reviewed += 1 },
            signedIn: { signedIn }
        )
        answeredLate.ask(waiting, inThread: "thread-1", as: me)
        await answeredLate.settled(waiting.id)
        XCTAssertEqual(reviewed, 0)
    }
}
