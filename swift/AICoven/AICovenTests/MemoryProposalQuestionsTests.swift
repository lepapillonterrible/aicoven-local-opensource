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
        let row: Row? = try await queue.read { db in
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
        let row: Row? = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT proposed_content, content_ciphertext FROM memory_proposals WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(row?["proposed_content"] as String?, "")
        XCTAssertNotNil(row?["content_ciphertext"] as Data?)

        // And it can still be approved into its coven.
        _ = try await MemoryService(memoryStore: MemoryRepository.shared).reviewProposal(proposalId: id, action: "approve")
        let memories = try await kept(in: coven)
        XCTAssertEqual(memories, ["Stored as text"])

        // One read on its own, not through the list, is sealed the same, and reviewing it leaves no text behind.
        let alone = "old-proposal-\(UUID().uuidString)"
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO memory_proposals (id, user_id, coven_id, proposed_content, scope, status, created_at)
                VALUES (?, ?, ?, 'Also stored as text', 'coven', 'pending', ?)
                """,
                arguments: [alone, account, coven, Date()]
            )
        }
        let reviewedAlone = try await MemoryService(memoryStore: MemoryRepository.shared).reviewProposal(proposalId: alone, action: "reject")
        XCTAssertEqual(reviewedAlone.proposedContent, "Also stored as text", "The answer still carries its words")
        let left = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT proposed_content FROM memory_proposals WHERE id = ?", arguments: [alone])
        }
        XCTAssertEqual(left, "")
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
        MemoryProposalQuestions(asking: answering, reviewing: Self.review, turnEnding: { _ in })
    }

    /// Reviews as the app does, with no embedding to wait for.
    private static let review: MemoryProposalQuestions.Reviewing = { id, approve in
        _ = try await MemoryService(memoryStore: MemoryRepository.shared, embed: { _ in nil })
            .reviewProposal(proposalId: id, action: approve ? "approve" : "reject")
    }

    func testWithALimitOnlyTheLatestOfAScopesProposalsAreRead() async throws {
        let coven = try await newCoven()
        var stored: [String] = []
        for text in ["First", "Second", "Third"] {
            try await stored.append(propose(text, in: coven).id)
        }
        // Each a moment after the one before, whatever the clock's grain.
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let ids = stored
        try await queue.write { db in
            for (index, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE memory_proposals SET created_at = ? WHERE id = ?", arguments: [Date(timeIntervalSince1970: TimeInterval(1000 + index)), id])
            }
        }

        let latest = try await MemoryService.shared.listProposals(covenId: coven, limit: 2)
        XCTAssertEqual(latest.map(\.proposedContent), ["Third", "Second"])
        let all = try await MemoryService.shared.listProposals(covenId: coven)
        XCTAssertEqual(all.count, 3)
    }

    func testApproveKeepsItWhereItWasProposed_denyDoesNot_andUnansweredItWaits() async throws {
        let coven = try await newCoven()
        var asked: [ToolApproval] = []

        let approved = try await propose("Ships on Fridays", in: coven)
        let approving = questions { question, _ in
            asked.append(question)
            return .approved
        }
        approving.ask(approved, inThread: "thread-1", as: account)
        XCTAssertEqual(approving.asked, [approved.id], "While it is asked, what lists the proposals that wait leaves it to the question")
        await approving.settled(approved.id)
        XCTAssertEqual(approving.asked, [], "And no longer once it has its answer")
        XCTAssertEqual(asked.map(\.question), ["Remember this for the coven?"])
        XCTAssertEqual(asked.map(\.details), ["Ships on Fridays"], "The question shows what would be remembered, whole")
        XCTAssertEqual(asked.map(\.threadID), ["thread-1"])
        XCTAssertEqual(asked.map(\.isOfATurn), [false])
        var memories = try await kept(in: coven)
        XCTAssertEqual(memories, ["Ships on Fridays"])
        let approvedStatus = try await status(of: approved.id)
        XCTAssertEqual(approvedStatus, "approved")

        let denied = try await propose("Never ships", in: coven)
        let denying = questions { _, _ in .denied }
        denying.ask(denied, inThread: "thread-1", as: account)
        await denying.settled(denied.id)
        memories = try await kept(in: coven)
        XCTAssertEqual(memories, ["Ships on Fridays"], "What was denied is not kept")
        let deniedStatus = try await status(of: denied.id)
        XCTAssertEqual(deniedStatus, "rejected")

        // With nowhere to ask (its thread is gone, say), it stays pending, and waits on Activity.
        let unasked = try await propose("Ships on Mondays", in: coven)
        let notAsking = questions { _, _ in .notAsked }
        notAsking.ask(unasked, inThread: "thread-1", as: account)
        await notAsking.settled(unasked.id)
        XCTAssertEqual(notAsking.asked, [], "Nor once the question was given up: the proposal is then listed where it waits")
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
            asking: { question, _ in
                asked.append(question.question)
                return .approved
            },
            reviewing: { id, approve in
                reviews += 1
                if reviews == 1 { throw RepositoryError.databaseUnavailable }
                try await Self.review(id, approve)
            },
            turnEnding: { _ in }
        )
        failingOnce.ask(proposal, inThread: "thread-1", as: account)
        await failingOnce.settled(proposal.id)
        XCTAssertEqual(asked, ["Remember this for the coven?", "Couldn't confirm your answer. Remember this for the coven?"])
        let memories = try await kept(in: coven)
        XCTAssertEqual(memories, ["Ships on Fridays"])

        // Failing again, it is left pending: it is not asked a third time.
        let again = try await propose("Ships on Mondays", in: coven)
        asked = []
        let alwaysFailing = MemoryProposalQuestions(
            asking: { question, _ in
                asked.append(question.question)
                return .approved
            },
            reviewing: { _, _ in throw RepositoryError.databaseUnavailable },
            turnEnding: { _ in }
        )
        alwaysFailing.ask(again, inThread: "thread-1", as: account)
        await alwaysFailing.settled(again.id)
        XCTAssertEqual(asked.count, 2)
        let still = try await status(of: again.id)
        XCTAssertEqual(still, "pending")
    }

    func testAnAnswerGivenWhileItIsReviewedElsewhere_isAskedForAgainOnlyIfTheProposalStillWaits() async throws {
        let coven = try await newCoven()

        // Reviewed in Memory's list just then, and that review went through: there is nothing to ask again.
        let reviewed = try await propose("Ships on Fridays", in: coven)
        var asked = 0
        let reviewedElsewhere = MemoryProposalQuestions(
            asking: { _, _ in
                asked += 1
                return .approved
            },
            reviewing: { id, _ in
                try await Self.review(id, false)
                throw ProposalReviewError.underWay
            },
            turnEnding: { _ in }
        )
        reviewedElsewhere.ask(reviewed, inThread: "thread-1", as: account)
        await reviewedElsewhere.settled(reviewed.id)
        XCTAssertEqual(asked, 1, "It has had its answer")
        let memories = try await kept(in: coven)
        XCTAssertEqual(memories, [])

        // Under review elsewhere, and that review came to nothing: it still waits, so it is asked once more.
        let stillWaiting = try await propose("Ships on Mondays", in: coven)
        asked = 0
        var reviews = 0
        let underWayThenFree = MemoryProposalQuestions(
            asking: { _, _ in
                asked += 1
                return .approved
            },
            reviewing: { id, approve in
                reviews += 1
                if reviews == 1 { throw ProposalReviewError.underWay }
                try await Self.review(id, approve)
            },
            turnEnding: { _ in }
        )
        underWayThenFree.ask(stillWaiting, inThread: "thread-1", as: account)
        await underWayThenFree.settled(stillWaiting.id)
        XCTAssertEqual(asked, 2)
        let kept = try await kept(in: coven)
        XCTAssertEqual(kept, ["Ships on Mondays"])
    }

    func testTheQuestionIsAskedOnlyOnceNoTurnRunsInItsThread() async throws {
        let coven = try await newCoven()
        let proposal = try await propose("Ships on Fridays", in: coven)
        let (ended, end) = AsyncStream<Void>.makeStream()
        let (waited, wait) = AsyncStream<Void>.makeStream()
        var asked = 0
        let afterTheTurn = MemoryProposalQuestions(
            asking: { _, _ in
                asked += 1
                return .denied
            },
            reviewing: Self.review,
            turnEnding: { _ in
                wait.yield()
                for await _ in ended {
                    break
                }
            }
        )
        afterTheTurn.ask(proposal, inThread: "thread-1", as: account)
        for await _ in waited {
            break
        }
        XCTAssertEqual(asked, 0, "Not under the reply that proposed it")
        end.yield()
        await afterTheTurn.settled(proposal.id)
        XCTAssertEqual(asked, 1)
    }

    func testAProposalIsStoredOnlyForACovenOfTheSameAccount() async throws {
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let theirs = "their-coven-\(UUID().uuidString)"
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO covens (id, name, created_at, updated_at, user_id) VALUES (?, ?, ?, ?, ?)",
                arguments: [theirs, "Theirs", Date(), Date(), "someone-else"]
            )
        }
        addTeardownBlock {
            try? await queue.write { db in try db.execute(sql: "DELETE FROM covens WHERE id = ?", arguments: [theirs]) }
        }
        for coven in [theirs, "no-such-coven-\(UUID().uuidString)"] {
            do {
                _ = try await propose("For a coven that is not the account's", in: coven)
                XCTFail("Stored a proposal for \(coven)")
            } catch {}
        }
        // Nor is one of the account's own moved there.
        let mine = try await newCoven()
        let own = try await propose("Mine", in: mine)
        for coven in [theirs, "no-such-coven-\(UUID().uuidString)"] {
            do {
                try await queue.write { db in
                    try db.execute(sql: "UPDATE memory_proposals SET coven_id = ? WHERE id = ?", arguments: [coven, own.id])
                }
                XCTFail("Moved a proposal to \(coven)")
            } catch {}
        }
        // One proposed in no coven is stored.
        let personal = try await proposals.insertProposal(
            eventId: nil, covenId: nil, proposedContent: "About the person", proposedTags: nil, scope: "user", reason: nil,
            sourceMessageId: nil, proposedBy: "agent", title: nil, as: account
        )
        _ = try await proposals.settlePending(id: personal.id, as: "rejected", reviewedBy: nil, reviewFeedback: nil, for: account)
    }

    func testWhenAnotherAccountSignsIn_theQuestionLeavesUnanswered_andAnAnswerForTheFirstIsNotTaken() async throws {
        let coven = try await newCoven()
        let me = account

        // The question is on screen when the account changes: it is withdrawn.
        let waiting = try await propose("Ships on Fridays", in: coven)
        let (reached, reach) = AsyncStream<Void>.makeStream()
        var reviewed = 0
        let asking = MemoryProposalQuestions(
            asking: { _, _ in
                reach.yield()
                // As the approvals do: the answer of a question whose task is cancelled is that it was withdrawn.
                while !Task.isCancelled {
                    await Task.yield()
                }
                return .withdrawn
            },
            reviewing: { _, _ in reviewed += 1 },
            turnEnding: { _ in }
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
            asking: { _, _ in
                signedIn = "someone-else"
                return .approved
            },
            reviewing: { _, _ in reviewed += 1 },
            turnEnding: { _ in },
            signedIn: { signedIn }
        )
        answeredLate.ask(waiting, inThread: "thread-1", as: me)
        await answeredLate.settled(waiting.id)
        XCTAssertEqual(reviewed, 0)
    }
}
