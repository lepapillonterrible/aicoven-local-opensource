import os
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
    /// False for something that can only be denied: what asks will not
    /// take an approval, or does not say what it would be an approval of.
    var canApprove = true

    /// What the thread's line says was approved or denied: the first line
    /// of what will happen (the command, the file, the branch), or its
    /// start when that line is very long. The line names what was asked;
    /// the approval itself showed all of it.
    var subject: String {
        guard let first = details.split(whereSeparator: \.isNewline).first else { return question }
        return first.count > Self.subjectLimit ? "\(first.prefix(Self.subjectLimit))…" : String(first)
    }

    static let subjectLimit = 200

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
    /// Asked while the person was composing, and not on screen yet: an
    /// approval does not come up under what is being typed. They come in
    /// when the person sends, pauses, or leaves the composer.
    @Published private(set) var held: [ToolApproval] = []
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
    /// The approvals whose turn has stopped, by id, from the moment it
    /// stops: the queue is told a moment later, and nothing of a stopped
    /// turn is shown in between.
    /// Added to from whatever thread stops the turn, read on the main
    /// actor: under its lock.
    private nonisolated let stopped = OSAllocatedUnfairLock(initialState: Set<String>())

    /// How long after the last change to the composer's text the person
    /// still counts as composing.
    let holdInterval: TimeInterval
    private let now: () -> Date
    private var composerFocused = false
    private var keyboardUp = false
    private var lastComposerChange: Date?
    private var releaseCheckScheduled = false

    init(
        holdInterval: TimeInterval = 3,
        now: @escaping () -> Date = Date.init,
        schedule: @escaping Schedule = { delay, action in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
                action()
            }
        }
    ) {
        self.holdInterval = holdInterval
        self.now = now
        self.schedule = schedule
    }

    /// Composing: the composer has focus and its text changed within
    /// `holdInterval`, or the on-screen keyboard is up.
    var isComposing: Bool {
        if keyboardUp { return true }
        guard composerFocused, let lastComposerChange else { return false }
        return now().timeIntervalSince(lastComposerChange) < holdInterval
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
                if isComposing {
                    held.append(approval)
                    releaseWhenComposingEnds()
                } else {
                    enqueue(approval)
                }
            }
        } onCancel: {
            stopped.withLock { _ = $0.insert(approval.id) }
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
        guard let approval = showing?.approval, approval.id == approvalID, showing?.phase == .asking else { return }
        // What can only be denied takes no approval.
        guard approval.canApprove || !approve else { return }
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
        // What can only be denied is not waiting for an OK.
        let needs = showing.approval.canApprove ? "Needs your OK" : "Can only be denied"
        AccessibilityNotification.Announcement("\(needs), from \(showing.approval.threadTitle): \(showing.approval.question)").post()
        return true
    }

    /// "N more waiting": the one showing goes to the back, the next shows.
    func showNext() {
        // Not one whose turn has stopped: it leaves unseen.
        waiting.removeAll { hasStopped($0.id) }
        guard let current = showing, current.phase == .asking, !waiting.isEmpty else { return }
        waiting.append(current.approval)
        show(waiting.removeFirst())
    }

    /// Forgets the answers given to a thread's turn: a turn that has ended
    /// keeps them itself, and a turn that starts begins with none.
    func forgetAnswers(threadID: String) {
        answered[threadID] = nil
    }

    // MARK: - Composing

    /// The composer's text changed.
    func noteComposerChanged() {
        lastComposerChange = now()
    }

    /// The composer took, or lost, keyboard focus.
    func composerFocusChanged(_ focused: Bool) {
        composerFocused = focused
        releaseWhenComposingEnds()
    }

    /// The on-screen keyboard came up or went down (iPhone and iPad).
    func keyboardVisibilityChanged(_ visible: Bool) {
        keyboardUp = visible
        releaseWhenComposingEnds()
    }

    /// A message was sent: what was held comes in, even with the keyboard
    /// still up.
    func noteSent() {
        lastComposerChange = nil
        let released = held
        held = []
        released.forEach(enqueue)
    }

    // MARK: - Private

    /// Lets held approvals in once the person stops composing; while they
    /// type, checks again when the hold would end. The keyboard going down
    /// and focus changes call this themselves.
    private func releaseWhenComposingEnds() {
        guard !held.isEmpty else { return }
        guard isComposing else {
            let released = held
            held = []
            released.forEach(enqueue)
            return
        }
        guard !releaseCheckScheduled, !keyboardUp, let lastComposerChange else { return }
        releaseCheckScheduled = true
        schedule(holdInterval - now().timeIntervalSince(lastComposerChange)) { [weak self] in
            guard let self else { return }
            releaseCheckScheduled = false
            releaseWhenComposingEnds()
        }
    }

    /// Whether the approval's turn has stopped, known from the moment it
    /// does.
    private func hasStopped(_ approvalID: String) -> Bool {
        stopped.withLock { $0.contains(approvalID) }
    }

    /// Shows the approval, or puts it behind the one showing. Not one
    /// whose turn has stopped: it leaves unseen when the queue is told.
    private func enqueue(_ approval: ToolApproval) {
        guard !hasStopped(approval.id) else { return }
        if showing == nil {
            show(approval)
        } else {
            waiting.append(approval)
        }
    }

    /// The turn that asked has stopped: its approval leaves unanswered.
    private func withdraw(_ approvalID: String) {
        stopped.withLock { _ = $0.remove(approvalID) }
        guard asked[approvalID] != nil else { return }
        settle(approvalID, with: .withdrawn)
        if showing?.approval.id == approvalID, showing?.phase == .asking {
            finishShowing(outcome: .noLongerWaiting)
        } else {
            // Not on screen: it leaves unseen.
            waiting.removeAll { $0.id == approvalID }
            held.removeAll { $0.id == approvalID }
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
        let stillAsking = Set(([showing?.approval].compactMap(\.self) + waiting + held).filter { asked[$0.id] != nil }.map(\.threadID))
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
                // Nor is one whose turn has stopped shown next.
                waiting.removeAll { self.hasStopped($0.id) }
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
        owner: String, repo: String, path: String, branch: String?, message: String, content: String, replaces: Bool, threadID: String
    ) -> ToolApproval {
        ToolApproval(
            threadID: threadID,
            question: "Commit this file to GitHub?",
            details: "\(path) in \(owner)/\(repo), on \(branch ?? "the default branch")\nCommit message: \(message)\n\(replaces ? "Replaces the file that is there" : "A new file") · \(size(of: content))\n\n\(shown(content))",
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

    static func driveUpload(name: String, mimeType: String, content: String, folders: [String] = [], threadID: String) -> ToolApproval {
        let place = folders.isEmpty ? "" : "\nIn \(folders.count == 1 ? "folder" : "folders") \(folders.joined(separator: ", "))"
        return ToolApproval(
            threadID: threadID,
            question: "Upload this file to Google Drive?",
            details: "\(name)\(place)\n\(mimeType) · \(size(of: content))\n\n\(shown(content))",
            toolName: "google_drive.uploadFile"
        )
    }

    /// Writing cells of a spreadsheet. `asTyped` says how Google takes
    /// them: as if typed (a cell that starts with "=" becomes a formula),
    /// or exactly as written.
    static func sheetsWrite(spreadsheetID: String, range: String, values: [[String]], asTyped: Bool = true, threadID: String) -> ToolApproval {
        let rows = values.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        return ToolApproval(
            threadID: threadID,
            question: "Write to this Google Sheet?",
            details: "\(range) in spreadsheet \(spreadsheetID)\n\(values.count) \(values.count == 1 ? "row" : "rows"), \(asTyped ? "entered as if typed (formulas are worked out)" : "entered exactly as written")\n\n\(shown(rows))",
            toolName: "google_sheets.updateValues"
        )
    }

    /// Adding text to a Google Doc: where, and all of it up to the limit.
    static func docsAddText(documentID: String, text: String, index: Int?, threadID: String) -> ToolApproval {
        ToolApproval(
            threadID: threadID,
            question: "Add this text to the Google Doc?",
            details: "Document \(documentID)\n\(index.map { "At position \($0)" } ?? "At the end") · \(size(of: text))\n\n\(shown(text))",
            toolName: "google_docs.update"
        )
    }

    /// A comment posted to a Figma file as the person: which file, whether
    /// it answers another comment, and all of it up to the limit.
    static func figmaComment(file: String, replyTo: String?, message: String, threadID: String) -> ToolApproval {
        ToolApproval(
            threadID: threadID,
            question: "Post this comment in Figma?",
            details: "File \(file)\(replyTo.map { ", in reply to comment \($0)" } ?? "")\nPosted as you · \(size(of: message))\n\n\(shown(message))",
            toolName: "figma.addComment"
        )
    }

    /// The kinds of Google file a model can ask to be changed in Google's
    /// own form of requests.
    enum GoogleFile {
        case document, spreadsheet, presentation

        var question: String {
            switch self {
            case .document: "Change this Google Doc?"
            case .spreadsheet: "Change this Google Sheet?"
            case .presentation: "Change this Google Slides presentation?"
            }
        }

        var named: String {
            switch self {
            case .document: "Document"
            case .spreadsheet: "Spreadsheet"
            case .presentation: "Presentation"
            }
        }

        var toolName: String {
            switch self {
            case .document: "google_docs.update"
            case .spreadsheet: "google_sheets.batchUpdate"
            case .presentation: "google_slides.update"
            }
        }
    }

    /// Changes to a Google file in Google's own form: which file, how
    /// many changes, and the requests as they will be sent, in full up to
    /// the limit.
    static func googleRequests(_ file: GoogleFile, id: String, requests: [[String: AnyJSONValue]], threadID: String) -> ToolApproval {
        var asked = "The requests cannot be shown."
        if let data = try? JSONSerialization.data(withJSONObject: requests.map { $0.mapValues(MCPClient.plain) }, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            asked = shown(String(decoding: data, as: UTF8.self))
        }
        return ToolApproval(
            threadID: threadID,
            question: file.question,
            details: "\(file.named) \(id)\n\(requests.count) \(requests.count == 1 ? "change" : "changes"), as Google is asked to make \(requests.count == 1 ? "it" : "them"):\n\n\(asked)",
            toolName: file.toolName
        )
    }

    /// A tool of an MCP server that is not marked as only reading: which
    /// tool, on which server and where that is, and what it is given, in
    /// full up to the limit. Nothing of what the server says of the tool
    /// is shown: only what will be sent.
    static func mcp(server: String, address: String, tool: String, arguments: [String: AnyJSONValue], threadID: String) -> ToolApproval {
        var given = "Nothing is given to it."
        if !arguments.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: arguments.mapValues(MCPClient.plain), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            given = shown(String(decoding: data, as: UTF8.self))
        }
        return ToolApproval(
            threadID: threadID,
            question: "Use this tool on \(server)?",
            details: "\(tool) on \(server)\nAt \(address)\n\n\(given)",
            toolName: "mcp.\(tool)"
        )
    }

    /// What a Hermes run is waiting to be allowed, in Hermes's own words:
    /// the command whole where it gives one, then what it says about it.
    static func hermes(_ request: HermesApprovalRequest, threadID: String) -> ToolApproval {
        let lines = [request.command, request.description].compactMap(\.self)
        return ToolApproval(
            threadID: threadID,
            question: request.command == nil ? "Let Hermes do this?" : "Let Hermes run this command?",
            details: lines.isEmpty ? "Hermes did not say what it is for." : lines.joined(separator: "\n"),
            toolName: request.tool ?? "hermes"
        )
    }

    /// What OpenClaw is waiting to be allowed, as its Gateway presents it:
    /// a command, whole, or a plugin's or an agent's own title and
    /// description. It can be approved only if the Gateway takes an
    /// approval for this once and says what it would be an approval of,
    /// and all of that is shown; otherwise its last line says why not.
    /// Each text is measured as the Gateway sent it, and shown without the
    /// white space around it.
    static func openClaw(_ presentation: [String: Any], threadID: String) -> ToolApproval {
        var isCut = false
        func text(_ key: String, limit: Int) -> String? {
            guard let sent = presentation[key] as? String else { return nil }
            isCut = isCut || sent.count > limit
            let value = sent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            return value.count > limit ? "\(value.prefix(limit))\n… and \(value.count - limit) more characters" : value
        }
        let sentCommand = presentation["commandText"] as? String ?? ""
        let command = sentCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let said = [text("title", limit: 160), text("description", limit: 2000), text("warningText", limit: 500)].compactMap(\.self)
        let host = text("host", limit: 160).map { "On \($0)" }
        let allowsOnce = (presentation["allowedDecisions"] as? [String])?.contains("allow-once") == true

        var lines: [String] = []
        let whyNot: String?
        if sentCommand.count > HermesAgentClient.longestCommandShown {
            whyNot = "OpenClaw's command is too long to show here, so it can only be denied."
        } else if command.isEmpty {
            lines = said
            whyNot = if said.isEmpty {
                "OpenClaw did not say what it is for, so it can only be denied."
            } else if isCut {
                "What OpenClaw sent is longer than can be shown here, so it can only be denied."
            } else if !allowsOnce {
                "OpenClaw does not take an approval for this, so it can only be denied."
            } else {
                nil
            }
        } else {
            lines = [command] + said + [host].compactMap(\.self)
            whyNot = if isCut {
                "What OpenClaw sent is longer than can be shown here, so it can only be denied."
            } else if !allowsOnce {
                "OpenClaw does not take an approval for this, so it can only be denied."
            } else {
                nil
            }
        }
        var approval = ToolApproval(
            threadID: threadID,
            question: command.isEmpty ? "Let OpenClaw do this?" : "Let OpenClaw run this command?",
            details: (lines + [whyNot].compactMap(\.self)).joined(separator: "\n"),
            toolName: (presentation["kind"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(40)) } ?? "openclaw"
        )
        approval.canApprove = whyNot == nil
        return approval
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
