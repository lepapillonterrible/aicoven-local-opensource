import Foundation

/// Asks the person, beside the thread, whether to remember what an agent
/// proposed in it, as the cloud app does: Approve keeps it where it was
/// proposed, Deny does not.
///
/// The question is asked once the turn that proposed it has ended, and no
/// turn waits on it. The proposal itself is stored: one that is not
/// answered here (the app closes, the thread is gone, another account
/// signs in) waits among the proposals of its scope's Memory.
@MainActor
final class MemoryProposalQuestions {
    static let shared = MemoryProposalQuestions()

    typealias Asking = (ToolApproval) async -> ApprovalAnswer
    typealias Reviewing = (_ proposalID: String, _ approve: Bool) async throws -> Void

    private let asking: Asking
    private let reviewing: Reviewing
    private let signedIn: () -> String
    /// The questions waiting for an answer, by proposal.
    private var questions: [String: Task<Void, Never>] = [:]

    init(
        asking: @escaping Asking = { await ToolExecutionService.askInItsThread($0) },
        reviewing: @escaping Reviewing = { proposalID, approve in
            _ = try await MemoryService.shared.reviewProposal(proposalId: proposalID, action: approve ? "approve" : "reject")
        },
        signedIn: @escaping () -> String = { UserScope.currentUserID }
    ) {
        self.asking = asking
        self.reviewing = reviewing
        self.signedIn = signedIn
    }

    /// Asks about a proposal of `account`'s made in `threadID`, without
    /// waiting for the answer. An answer is taken only while that account
    /// is still the one signed in. If the answer cannot be kept, the
    /// question is asked once more, saying so.
    func ask(_ proposal: MemoryProposalRecord, inThread threadID: String, as account: String) {
        guard questions[proposal.id] == nil, !proposal.isUnreadable else { return }
        questions[proposal.id] = Task { [weak self] in
            guard let self else { return }
            defer { questions[proposal.id] = nil }
            var question = ToolApproval.memory(proposal.proposedContent, forACoven: proposal.covenId != nil, threadID: threadID)
            for attempt in 1 ... 2 {
                let answer = await asking(question)
                guard answer == .approved || answer == .denied, signedIn() == account else { return }
                do {
                    try await reviewing(proposal.id, answer == .approved)
                    return
                } catch is ProposalReviewError {
                    // Reviewed elsewhere meanwhile: there is nothing to ask again.
                    return
                } catch {
                    // The kind of failure only.
                    AppErrorReporter.log(message: "An answer about a memory could not be kept (\(type(of: error)))", context: "MemoryProposalQuestions.ask")
                    guard attempt == 1, signedIn() == account else { return }
                    question = ToolApproval.memory(
                        proposal.proposedContent, forACoven: proposal.covenId != nil, threadID: threadID, afterAFailedAnswer: true
                    )
                }
            }
        }
    }

    /// Returns once the question about a proposal has been answered or
    /// given up; at once where none is being asked.
    func settled(_ proposalID: String) async {
        await questions[proposalID]?.value
    }

    /// Another account is signed in, or none: what was being asked of the
    /// first leaves the screen unanswered, and stays among its proposals.
    func accountChanged() {
        questions.values.forEach { $0.cancel() }
    }
}
