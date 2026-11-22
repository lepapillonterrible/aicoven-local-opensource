internal import Combine
import Foundation

/// The memory proposals that wait for the person's answer, across Strix
/// and every coven, as Activity lists them under Waiting for you: what an
/// agent asked to remember and nobody has answered yet (the app was closed
/// on the question, say). Answered here, a proposal is kept where it was
/// proposed, or rejected, as from the question beside its thread.
///
/// Each scope is read on its own: one that cannot be read keeps what was
/// read of it before and does not keep the others from being read. Only
/// the latest reading is shown, and nothing read or said for an account
/// that is no longer signed in.
@MainActor
final class ActivityProposals: ObservableObject {
    struct Source {
        /// The latest `limit` of a scope's pending proposals, the latest
        /// first: a coven's, or, for none, those made in no coven.
        var pending: (_ covenID: String?, _ limit: Int) async throws -> [MemoryProposal]
        var review: (_ proposalID: String, _ approve: Bool) async throws -> Void

        static let live = Source(
            pending: { try await MemoryService.shared.listProposals(covenId: $0, limit: $1) },
            review: { proposalID, approve in
                _ = try await MemoryService.shared.reviewProposal(proposalId: proposalID, action: approve ? "approve" : "reject")
            }
        )
    }

    /// Something to tell VoiceOver: each time is its own, also one in the
    /// same words as the time before.
    struct Announcement: Equatable {
        let number: Int
        let words: String
    }

    static let couldNotLoad = "Couldn't load memory proposals."
    static let answerNotKept = "Couldn't save your answer. Try again."
    static let moreWait = "More proposals are waiting. They come in as these are answered."
    static let newlyWaiting = "A memory proposal is waiting for you."
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

    /// What waits in each scope, as last read.
    @Published private var byScope: [ShellScope: [MemoryProposal]] = [:]
    /// The scopes read at least once.
    @Published private var readScopes: Set<ShellScope> = []
    /// The scopes to look in: Strix and the person's covens; nil until
    /// the covens are known.
    @Published private var scopes: [ShellScope]?
    /// Whether a scope could not be read at the latest reading.
    @Published private(set) var loadFailed = false
    /// The proposals whose answer is on its way: one answer at a time.
    @Published private(set) var answering: Set<String> = []
    /// The proposals whose last answer could not be kept.
    @Published private(set) var notKept: Set<String> = []
    /// What VoiceOver is told while the page is on screen: a reading that
    /// failed, an answer kept or not kept, a proposal that newly waits.
    @Published private(set) var announcement: Announcement?

    private let source: Source
    private let signedIn: () -> String
    /// Whose proposals are held.
    private var account: String?
    /// The proposals a question is asking about, as last told: so many
    /// more are read, since they are left out of what is listed.
    private var asked: Set<String> = []
    /// The proposals that were listed when the last reading landed: what
    /// is listed after the next and was not then, newly waits.
    private var listed: Set<String> = []
    /// Counts the readings, so that only the latest is shown.
    private var readings = 0

    init(source: Source = .live, signedIn: @escaping () -> String = { UserScope.currentUserID }) {
        self.source = source
        self.signedIn = signedIn
    }

    /// The proposals to list, the latest first across scopes, `most` at
    /// most: the signed-in account's, without those being asked just now
    /// (`asked`), which the approvals' spot shows.
    func shown(without asked: Set<String>) -> [MemoryProposal] {
        Array(waiting(without: asked).prefix(Self.most))
    }

    /// Whether more wait than are listed.
    func hasMore(without asked: Set<String>) -> Bool {
        waiting(without: asked).count > Self.most
    }

    /// Whether everything that could hold a proposal of the signed-in
    /// account's has been read: only then can it be said that none
    /// waits. Not while the covens are not known.
    var hasRead: Bool {
        guard account == signedIn(), let scopes else { return false }
        return readScopes.isSuperset(of: scopes)
    }

    private func waiting(without asked: Set<String>) -> [MemoryProposal] {
        guard account == signedIn() else { return [] }
        return byScope.values.joined()
            .filter { !asked.contains($0.id) }
            .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
    }

    /// Where to look (`covens`: the person's, or nil while they are not
    /// known, when only Strix is read) and what is being asked just now;
    /// then reads.
    func show(covens: [String]?, asked: Set<String>) async {
        scopes = covens.map { [ShellScope.strix] + $0.map(ShellScope.coven) }
        self.asked = asked
        await load()
    }

    /// Reads what waits in each scope, as things stand now. A scope that
    /// cannot be read keeps what was read of it before, the others are
    /// read all the same, and the reading says it failed.
    func load() async {
        readings += 1
        let reading = readings
        let who = signedIn()
        if account != who {
            byScope = [:]
            readScopes = []
            notKept = []
            listed = []
            account = who
        }
        loadFailed = false
        let looking = scopes ?? [.strix]
        // One more than is listed tells that more wait; and as many more
        // as are left out for being asked about.
        let limit = Self.most + 1 + asked.count
        var read: [ShellScope: [MemoryProposal]] = [:]
        var failed = false
        for scope in looking {
            do {
                let pending = try await source.pending(scope.covenID, limit)
                guard reading == readings, signedIn() == who else { return }
                read[scope] = pending
            } catch {
                guard reading == readings, signedIn() == who else { return }
                // The kind of failure only.
                AppErrorReporter.log(message: "Could not read a scope's memory proposals for Activity (\(type(of: error)))", context: "ActivityProposals.load")
                failed = true
            }
        }
        let hadRead = hasRead
        // A scope no longer looked in goes; one that failed keeps what
        // was read of it before.
        var next: [ShellScope: [MemoryProposal]] = [:]
        for scope in looking {
            next[scope] = read[scope] ?? byScope[scope]
        }
        byScope = next
        readScopes = readScopes.intersection(looking).union(read.keys)
        loadFailed = failed
        // What is listed now and was not when the last reading landed
        // newly waits: one read for the first time, or one whose question
        // was given up.
        let listedNow = Set(waiting(without: asked).map(\.id))
        if failed {
            announce(Self.couldNotLoad)
        } else if hadRead, !listedNow.isSubset(of: listed) {
            announce(Self.newlyWaiting)
        }
        listed = listedNow
    }

    /// Keeps the person's answer to a proposal, as `account`, who gave
    /// it: one answer of a proposal at a time. One that cannot be read is
    /// not approved as it is. What came of it is said aloud; an answer
    /// that could not be kept is also said under the proposal. Only to
    /// that account. The proposals are then read again, as things stand
    /// by then.
    func answer(_ proposal: MemoryProposal, approve: Bool, as account: String) async {
        guard !approve || !proposal.isUnreadable, answering.insert(proposal.id).inserted else { return }
        defer { answering.remove(proposal.id) }
        notKept.remove(proposal.id)
        do {
            try await source.review(proposal.id, approve)
            if signedIn() == account {
                announce((approve ? ToolApprovals.Outcome.approved : .denied).words)
            }
        } catch ProposalReviewError.alreadyReviewed {
            // It has had its answer elsewhere: read again, it is gone.
        } catch {
            AppErrorReporter.log(message: "An answer about a memory could not be kept (\(type(of: error)))", context: "ActivityProposals.answer")
            if signedIn() == account {
                notKept.insert(proposal.id)
                announce(Self.answerNotKept)
            }
        }
        await load()
    }

    private func announce(_ words: String) {
        announcement = Announcement(number: (announcement?.number ?? 0) + 1, words: words)
    }
}
