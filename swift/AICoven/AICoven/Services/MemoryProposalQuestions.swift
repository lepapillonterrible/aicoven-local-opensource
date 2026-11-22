internal import Combine
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
final class MemoryProposalQuestions: ObservableObject {
    static let shared = MemoryProposalQuestions()

    /// The proposals a question is being asked about, or is waiting to be:
    /// what lists the proposals that wait leaves these to the question.
    @Published private(set) var asked: Set<String> = []

    typealias Asking = (ToolApproval) async -> ApprovalAnswer
    typealias Reviewing = (_ proposalID: String, _ approve: Bool) async throws -> Void
    /// Whether a proposal of an account's is still waiting for an answer.
    typealias Waiting = (_ proposalID: String, _ account: String) async -> Bool
    /// Returns once no turn runs in a thread.
    typealias TurnEnding = (_ threadID: String) async -> Void

    private let asking: Asking
    private let reviewing: Reviewing
    private let isWaiting: Waiting
    private let turnEnding: TurnEnding
    private let signedIn: () -> String
    /// The questions waiting for an answer, by proposal.
    private var questions: [String: Task<Void, Never>] = [:]

    init(
        asking: @escaping Asking = { await ToolExecutionService.askInItsThread($0) },
        reviewing: @escaping Reviewing = { proposalID, approve in
            _ = try await MemoryService.shared.reviewProposal(proposalId: proposalID, action: approve ? "approve" : "reject")
        },
        isWaiting: @escaping Waiting = { proposalID, account in
            await (try? MemoryProposalRepository.shared.loadProposal(id: proposalID, for: account))?.status == "pending"
        },
        turnEnding: @escaping TurnEnding = { threadID in
            for await running in TurnEngine.shared.$running.values where running[threadID] == nil {
                break
            }
        },
        signedIn: @escaping () -> String = { UserScope.currentUserID }
    ) {
        self.asking = asking
        self.reviewing = reviewing
        self.isWaiting = isWaiting
        self.turnEnding = turnEnding
        self.signedIn = signedIn
    }

    /// Asks about a proposal of `account`'s made in `threadID`, without
    /// waiting for the answer: once the thread has been seen with no turn
    /// running, so the question does not come up under the reply that
    /// proposed it (a later turn of the thread can be running by the time
    /// it shows, as with any approval). An
    /// answer is taken only while that account is still the one signed
    /// in. If the answer cannot be kept (it failed, or the proposal was
    /// being reviewed elsewhere just then) and the proposal still waits,
    /// the question is asked once more, saying so.
    func ask(_ proposal: MemoryProposalRecord, inThread threadID: String, as account: String) {
        guard questions[proposal.id] == nil else { return }
        asked.insert(proposal.id)
        questions[proposal.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                questions[proposal.id] = nil
                asked.remove(proposal.id)
            }
            await turnEnding(threadID)
            for attempt in 1 ... 2 {
                guard !Task.isCancelled, signedIn() == account else { return }
                let question = ToolApproval.memory(
                    proposal.proposedContent, forACoven: proposal.covenId != nil, threadID: threadID, afterAFailedAnswer: attempt > 1
                )
                let answer = await asking(question)
                guard answer == .approved || answer == .denied, signedIn() == account else { return }
                do {
                    try await reviewing(proposal.id, answer == .approved)
                    return
                } catch {
                    // The kind of failure only.
                    AppErrorReporter.log(message: "An answer about a memory could not be kept (\(type(of: error)))", context: "MemoryProposalQuestions.ask")
                    // Asked again only if it still waits: one reviewed
                    // elsewhere meanwhile has had its answer.
                    guard signedIn() == account, await isWaiting(proposal.id, account) else { return }
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
