import Accessibility
internal import Combine
import Foundation

/// One thing a turn asks the person before it does it: which thread asked,
/// the question, and exactly what will happen.
nonisolated struct ToolApproval: Identifiable, Equatable {
    let id: String
    let threadID: String
    /// The thread that asked and where it lives ("Personal", or its coven).
    var threadTitle = "A thread"
    var covenName = "Personal"
    /// "Run this command?"
    let question: String
    /// What will happen, in full: the command and where it runs, the file
    /// and what goes in it.
    let details: String
    let toolName: String

    /// What the thread's line says was approved or denied: the first line
    /// of what will happen (the command, the file, the branch).
    var subject: String {
        details.split(separator: "\n").first.map(String.init) ?? question
    }

    init(threadID: String, question: String, details: String, toolName: String) {
        id = UUID().uuidString
        self.threadID = threadID
        self.question = question
        self.details = details
        self.toolName = toolName
    }
}

/// How asking the person came out.
nonisolated enum ApprovalAnswer: Equatable {
    case approved
    case denied
    /// The turn that asked was stopped before an answer.
    case withdrawn
    /// There was no thread to ask in, so no one was asked.
    case notAsked
}

/// The approvals turns are waiting on, and the one spot that shows them: one
/// at a time, the rest behind it in the order they were asked. A turn asks
/// and waits; the person's answer, or the turn stopping, ends the wait.
///
/// Nothing here is stored: an approval lives as long as the turn that asked.
@MainActor
final class ToolApprovals: ObservableObject {
    static let shared = ToolApprovals()

    enum Outcome: Equatable {
        case approved
        case denied
        /// The turn that asked stopped before an answer.
        case noLongerWaiting

        /// What the block says in place of its buttons.
        var words: String {
            switch self {
            case .approved: "Approved"
            case .denied: "Denied"
            case .noLongerWaiting: "No longer waiting"
            }
        }
    }

    enum Phase: Equatable {
        case asking
        /// Says what happened, then leaves.
        case answered(Outcome)
        /// Leaving, still saying what happened.
        case leaving(Outcome)
    }

    struct Showing: Equatable {
        let approval: ToolApproval
        var phase: Phase
    }

    /// Runs `action` after `delay` seconds.
    typealias Schedule = (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Void

    @Published private(set) var showing: Showing?
    /// Behind the one showing, in the order they were asked.
    @Published private(set) var waiting: [ToolApproval] = []
    /// The threads with a turn waiting on an answer.
    @Published private(set) var askingThreadIDs: Set<String> = []
    /// What each thread's running turn has been asked and has had answered,
    /// in the order answered, by thread id: the thread shows a line for
    /// each, and the turn keeps them when it ends.
    @Published private(set) var answered: [String: [WorkTrace.Approval]] = [:]

    /// How long the block says what was chosen before it leaves, and how
    /// long it takes to leave.
    static let answeredDuration: TimeInterval = 1.3
    static let leavingDuration: TimeInterval = 0.9

    /// The turns waiting, by approval id.
    private var asked: [String: CheckedContinuation<ApprovalAnswer, Never>] = [:]
    /// The approvals a screen has shown and VoiceOver has been told of.
    private var announced: Set<String> = []
    /// Changes whenever a different approval starts showing, so a timer set
    /// for one never acts on another.
    private var showingGeneration = 0
    private let schedule: Schedule

    init(
        schedule: @escaping Schedule = { delay, action in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
                action()
            }
        }
    ) {
        self.schedule = schedule
    }

    // MARK: - Asking

    /// Asks the person, and waits for the answer. Approved only when they
    /// approved and the task that asked has not been cancelled: a turn that
    /// is stopped does not go on to do what it was asking about, even if
    /// Approve was pressed as it stopped.
    func ask(_ approval: ToolApproval) async -> ApprovalAnswer {
        let answer = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalAnswer, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .withdrawn)
                    return
                }
                asked[approval.id] = continuation
                askingThreadIDs.insert(approval.threadID)
                if showing == nil {
                    show(approval)
                } else {
                    waiting.append(approval)
                }
            }
        } onCancel: {
            Task { @MainActor in self.withdraw(approval.id) }
        }
        // An answer counts, and is kept, only if the turn was still there to
        // take it.
        guard !Task.isCancelled else {
            sayNoLongerWaiting(approval.id)
            return .withdrawn
        }
        if answer == .approved || answer == .denied {
            answered[approval.threadID, default: []].append(
                WorkTrace.Approval(id: approval.id, subject: approval.subject, approved: answer == .approved)
            )
        }
        return answer
    }

    /// The person pressed Approve or Deny on the approval showing.
    func answer(_ approvalID: String, approve: Bool) {
        guard showing?.approval.id == approvalID, showing?.phase == .asking else { return }
        settle(approvalID, with: approve ? .approved : .denied)
        finishShowing(outcome: approve ? .approved : .denied)
    }

    /// A screen is showing this approval: VoiceOver is told once, however
    /// many windows show it and however often it comes back to the front.
    /// The block never takes focus, and the thread that asked may not be the
    /// one on screen. False when it had been said already.
    @discardableResult
    func announceShowing(_ approvalID: String) -> Bool {
        guard let showing, showing.approval.id == approvalID, showing.phase == .asking, !announced.contains(approvalID) else { return false }
        announced.insert(approvalID)
        AccessibilityNotification.Announcement("Needs your OK, from \(showing.approval.threadTitle): \(showing.approval.question)").post()
        return true
    }

    /// "N more waiting": the one showing goes to the back, the next shows.
    func showNext() {
        guard let current = showing, current.phase == .asking, !waiting.isEmpty else { return }
        waiting.append(current.approval)
        show(waiting.removeFirst())
    }

    /// The answers given to a thread's turn, which are then no longer held
    /// here: the turn that ends takes them with it, and a turn that starts
    /// begins with none.
    func takeAnswers(threadID: String) -> [WorkTrace.Approval] {
        answered.removeValue(forKey: threadID) ?? []
    }

    // MARK: - Private

    /// The turn that asked has stopped: its approval leaves unanswered.
    private func withdraw(_ approvalID: String) {
        guard asked[approvalID] != nil else { return }
        settle(approvalID, with: .withdrawn)
        if showing?.approval.id == approvalID, showing?.phase == .asking {
            finishShowing(outcome: .noLongerWaiting)
        } else {
            waiting.removeAll { $0.id == approvalID }
            announced.remove(approvalID)
        }
    }

    /// Approve or Deny was pressed as the turn stopped, and the block said
    /// so: the turn did not take the answer, and the block says that
    /// instead.
    private func sayNoLongerWaiting(_ approvalID: String) {
        // A block already on its way out is left to go.
        guard showing?.approval.id == approvalID,
              showing?.phase == .answered(.approved) || showing?.phase == .answered(.denied) else { return }
        showing?.phase = .answered(.noLongerWaiting)
        if announced.contains(approvalID) {
            AccessibilityNotification.Announcement(Outcome.noLongerWaiting.words).post()
        }
    }

    /// Gives the waiting turn its answer, once.
    private func settle(_ approvalID: String, with answer: ApprovalAnswer) {
        guard let continuation = asked.removeValue(forKey: approvalID) else { return }
        let stillAsking = Set(([showing?.approval].compactMap(\.self) + waiting).filter { asked[$0.id] != nil }.map(\.threadID))
        askingThreadIDs = stillAsking
        continuation.resume(returning: answer)
    }

    private func show(_ approval: ToolApproval) {
        showingGeneration += 1
        showing = Showing(approval: approval, phase: .asking)
    }

    /// Says what happened, leaves, then shows the next.
    private func finishShowing(outcome: Outcome) {
        showing?.phase = .answered(outcome)
        // An approval VoiceOver was told of is told how it ended: the block
        // says so for a moment and is gone.
        if let id = showing?.approval.id, announced.contains(id) {
            AccessibilityNotification.Announcement(outcome.words).post()
        }
        let generation = showingGeneration
        schedule(Self.answeredDuration) { [weak self] in
            guard let self, showingGeneration == generation else { return }
            // What it says by now, which a turn that stopped can have changed.
            if case let .answered(said) = showing?.phase {
                showing?.phase = .leaving(said)
            }
            schedule(Self.leavingDuration) { [weak self] in
                guard let self, showingGeneration == generation else { return }
                if let id = showing?.approval.id {
                    announced.remove(id)
                }
                if waiting.isEmpty {
                    showingGeneration += 1
                    showing = nil
                } else {
                    show(waiting.removeFirst())
                }
            }
        }
    }
}

// MARK: - What each tool asks

nonisolated extension ToolApproval {
    /// The most of a file's or a message's text an approval shows.
    static let shownTextLimit = 2000

    static func shell(command: String, directory: String, threadID: String) -> ToolApproval {
        ToolApproval(
            threadID: threadID,
            question: "Run this command?",
            details: "\(command)\nIn \(directory)",
            toolName: "shell.execute"
        )
    }

    static func fileWrite(path: String, content: String, replaces: Bool, threadID: String) -> ToolApproval {
        ToolApproval(
            threadID: threadID,
            question: replaces ? "Replace this file?" : "Write this file?",
            details: "\(path)\n\(replaces ? "Replaces the file that is there" : "A new file") · \(size(of: content))\n\n\(shown(content))",
            toolName: "file.write"
        )
    }

    static func gitHubWriteFile(
        owner: String, repo: String, path: String, branch: String?, message: String, content: String, threadID: String
    ) -> ToolApproval {
        ToolApproval(
            threadID: threadID,
            question: "Commit this file to GitHub?",
            details: "\(path) in \(owner)/\(repo), on \(branch ?? "the default branch")\nCommit message: \(message)\n\(size(of: content))\n\n\(shown(content))",
            toolName: "github.writeFile"
        )
    }

    static func gitHubCreateBranch(owner: String, repo: String, newBranch: String, baseBranch: String, threadID: String) -> ToolApproval {
        ToolApproval(
            threadID: threadID,
            question: "Create this branch on GitHub?",
            details: "\(newBranch) in \(owner)/\(repo)\nFrom \(baseBranch)",
            toolName: "github.createBranch"
        )
    }

    static func gitHubCreatePR(
        owner: String, repo: String, title: String, head: String, base: String, body: String?, threadID: String
    ) -> ToolApproval {
        ToolApproval(
            threadID: threadID,
            question: "Open this pull request on GitHub?",
            details: "\(title)\n\(head) into \(base) in \(owner)/\(repo)" + (body.map { "\n\n\(shown($0))" } ?? ""),
            toolName: "github.createPR"
        )
    }

    static func driveUpload(name: String, mimeType: String, content: String, threadID: String) -> ToolApproval {
        ToolApproval(
            threadID: threadID,
            question: "Upload this file to Google Drive?",
            details: "\(name)\n\(mimeType) · \(size(of: content))\n\n\(shown(content))",
            toolName: "google_drive.uploadFile"
        )
    }

    static func sheetsWrite(spreadsheetID: String, range: String, values: [[String]], threadID: String) -> ToolApproval {
        let rows = values.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        return ToolApproval(
            threadID: threadID,
            question: "Write to this Google Sheet?",
            details: "\(range) in spreadsheet \(spreadsheetID)\n\(values.count) \(values.count == 1 ? "row" : "rows")\n\n\(shown(rows))",
            toolName: "google_sheets.writeValues"
        )
    }

    /// The text as it will be written, or its start and how much more
    /// there is: the whole of a long file does not fit in an approval.
    private static func shown(_ text: String) -> String {
        guard text.count > shownTextLimit else { return text }
        return "\(text.prefix(shownTextLimit))\n… and \(text.count - shownTextLimit) more characters"
    }

    private static func size(of text: String) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file)
    }
}
