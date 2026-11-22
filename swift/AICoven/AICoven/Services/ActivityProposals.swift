internal import Combine
import Foundation

/// The memory proposals that wait for the person's answer, across Strix
/// and every coven, as Activity lists them under Waiting for you: what an
/// agent asked to remember and nobody has answered yet (the app was closed
/// on the question, say). Answered here, a proposal is kept where it was
/// proposed, or rejected, as from the question beside its thread.
///
/// Only its latest reading is shown, and nothing read or said for an
/// account that is no longer signed in.
@MainActor
final class ActivityProposals: ObservableObject {
    struct Source {
        /// A scope's pending proposals, the latest first: a coven's, or,
        /// for none, those made in no coven. One more than are listed
        /// at once is enough: it tells that more wait.
        var pending: (_ covenID: String?) async throws -> [MemoryProposal]
        var review: (_ proposalID: String, _ approve: Bool) async throws -> Void

        static let live = Source(
            pending: { try await MemoryService.shared.listProposals(covenId: $0, limit: ActivityProposals.most + 1) },
            review: { proposalID, approve in
                _ = try await MemoryService.shared.reviewProposal(proposalId: proposalID, action: approve ? "approve" : "reject")
            }
        )
    }

    static let couldNotLoad = "Couldn't load memory proposals."
    static let answerNotKept = "Couldn't save your answer. Try again."
    static let moreWait = "More proposals are waiting. They come in as these are answered."
    /// The most proposals listed at once: the rest come in as these are
    /// answered.
    static let most = 20

    static let unreadableQuestion = "This proposal can't be read"
    static let unreadableDetails = "Its text can't be opened with your encryption key, so it can't be approved. Deny it to clear it."

    /// A proposal as the approval's block asks it: whether to remember
    /// what it says, about the person or for its coven (`place` names
    /// where: Strix, or the coven). One whose text cannot be opened says
    /// so in place of the text, and can only be denied.
    static func question(about proposal: MemoryProposal, in place: String) -> ToolApproval {
        var approval = proposal.isUnreadable
            ? ToolApproval(threadID: "", question: unreadableQuestion, details: unreadableDetails, toolName: "memory")
            : ToolApproval.memory(proposal.proposedContent, forACoven: proposal.covenId != nil, threadID: "")
        approval.isOfATurn = false
        approval.canApprove = !proposal.isUnreadable
        approval.threadTitle = "Memory"
        approval.covenName = place
        return approval
    }

    @Published private var proposals: [MemoryProposal] = []
    /// Whether the account's proposals have been read at least once:
    /// until then nothing is known of whether any wait.
    @Published private var wasRead = false
    /// Whether the latest reading failed.
    @Published private(set) var loadFailed = false
    /// The proposals whose answer is on its way: one answer at a time.
    @Published private(set) var answering: Set<String> = []
    /// The proposals whose last answer could not be kept.
    @Published private(set) var notKept: Set<String> = []

    private let source: Source
    private let signedIn: () -> String
    /// Whose proposals are held.
    private var account: String?
    /// Counts the readings, so that only the latest is shown.
    private var readings = 0

    init(source: Source = .live, signedIn: @escaping () -> String = { UserScope.currentUserID }) {
        self.source = source
        self.signedIn = signedIn
    }

    /// The proposals to list, the latest first: the signed-in account's,
    /// without those being asked just now (`asked`), which the approvals'
    /// spot shows.
    func shown(without asked: Set<String>) -> [MemoryProposal] {
        Array(waiting(without: asked).prefix(Self.most))
    }

    /// Whether more wait than are listed.
    func hasMore(without asked: Set<String>) -> Bool {
        waiting(without: asked).count > Self.most
    }

    /// Whether the signed-in account's proposals have been read: only
    /// then can it be said that none waits.
    var hasRead: Bool {
        account == signedIn() && wasRead
    }

    private func waiting(without asked: Set<String>) -> [MemoryProposal] {
        guard account == signedIn() else { return [] }
        return proposals.filter { !asked.contains($0.id) }
    }

    /// Reads what waits in Strix and in each of `covens`. A reading that
    /// fails leaves what was read before for the same account, and says
    /// it failed.
    func load(covens: [String]) async {
        readings += 1
        let reading = readings
        let asked = signedIn()
        if account != asked {
            proposals = []
            notKept = []
            wasRead = false
            account = asked
        }
        loadFailed = false
        do {
            var read = try await source.pending(nil)
            for coven in covens {
                read += try await source.pending(coven)
            }
            guard reading == readings, signedIn() == asked else { return }
            proposals = read.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
            wasRead = true
        } catch {
            guard reading == readings, signedIn() == asked else { return }
            // The kind of failure only.
            AppErrorReporter.log(message: "Could not read the memory proposals for Activity (\(type(of: error)))", context: "ActivityProposals.load")
            loadFailed = true
        }
    }

    /// Keeps the person's answer to a proposal, as `account`, who gave
    /// it: one answer of a proposal at a time. One that cannot be read is
    /// not approved as it is. An answer that could not be kept is said
    /// under the proposal, to that account only.
    func answer(_ proposal: MemoryProposal, approve: Bool, covens: [String], as account: String) async {
        guard !approve || !proposal.isUnreadable, answering.insert(proposal.id).inserted else { return }
        defer { answering.remove(proposal.id) }
        notKept.remove(proposal.id)
        do {
            try await source.review(proposal.id, approve)
        } catch ProposalReviewError.alreadyReviewed {
            // It has had its answer elsewhere: read again, it is gone.
        } catch {
            AppErrorReporter.log(message: "An answer about a memory could not be kept (\(type(of: error)))", context: "ActivityProposals.answer")
            if signedIn() == account { notKept.insert(proposal.id) }
        }
        await load(covens: covens)
    }
}
