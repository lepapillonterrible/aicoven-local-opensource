import Accessibility
internal import Combine
import Foundation

/// Runs each reply from the person's message to its stored outcome, in a
/// task of its own. The screen that asked for the reply only watches: it can
/// go away, and the reply still finishes and is stored.
///
/// A turn is recorded when it starts, with the person's message, and when it
/// ends, with the reply or what went wrong. A turn still recorded as running
/// that this engine neither runs nor holds an ending for has no reply
/// stored: the app closed on it, or before its ending could be stored.
/// Opening its thread says so there, unless an agent of the person's own
/// was running it: that run went on, and is picked up and followed to its
/// end.
@MainActor
final class TurnEngine: ObservableObject {
    static let shared = TurnEngine(chat: .shared)

    /// What a running turn is doing, for the thread's status line.
    struct Activity: Equatable {
        let turnID: String
        var message: String
        /// The work so far, for Details.
        var trace: WorkTrace
        /// True from the moment the person asks to stop until the turn has
        /// in fact ended.
        var isStopping = false
    }

    enum TurnError: LocalizedError {
        case alreadyRunning
        /// The turn is not this account's running turn, so its ending has
        /// nowhere to be stored.
        case endingNotStored

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: "A reply is already on its way in this thread."
            case .endingNotStored: "The last reply in this thread could not be saved."
            }
        }
    }

    /// How a thread's last turn ended, for the thread to show.
    struct Ending: Equatable {
        let turnID: String
        let outcome: TurnOutcome
        /// The work behind the ending's first message.
        let trace: WorkTrace
        /// The reply or what went wrong, followed, if that could not be
        /// stored, by a line saying so.
        let messages: [ChatMessage]
        let stored: Bool
    }

    /// A message the person sent while the thread's turn ran. It waits,
    /// shown in the thread, and goes when the turn completes; after a stop
    /// or a failure nothing waiting is sent.
    struct WaitingMessage: Identifiable, Equatable {
        let id = UUID().uuidString
        /// What the person typed, as the composer held it: what is given
        /// back if it is not sent.
        let text: String
        /// What is stored and shown as their message, and what the model is
        /// sent, which can carry more.
        let userText: String
        let context: String
        let roleID: String?
        let agentName: String?
        let attachments: [FileAttachmentDetail]
    }

    /// A message the engine added to a thread: numbered in the order
    /// added, across threads, with the work behind it if it is a reply.
    struct Addition: Equatable {
        let sequence: Int
        let message: ChatMessage
        var trace: WorkTrace?
    }

    /// How many additions a thread keeps: more than can be added between
    /// two updates of a thread on screen.
    static let additionsKept = 30

    /// The turn running in each thread, by thread id.
    @Published private(set) var running: [String: Activity] = [:]
    /// The messages waiting for each thread's running turn, in the order
    /// they were sent, by thread id. Kept while the app runs.
    @Published private(set) var waiting: [String: [WaitingMessage]] = [:]
    /// What was handed back to each thread's composer and not yet taken:
    /// waiting messages that were not sent, or one taken back to be edited.
    @Published private(set) var returned: [String: ComposerDraft] = [:]
    /// The waiting message being sent in each thread, by thread id: its
    /// turn is being started, and it can no longer be edited or removed.
    @Published private(set) var starting: [String: WaitingMessage.ID] = [:]
    /// What the engine itself added to each thread, in order, by thread
    /// id: each turn's ending and each waiting message it sent. A thread on
    /// screen shows what it has not shown yet from here, so nothing is
    /// missed however its updates fall. The last few are kept.
    @Published private(set) var additions: [String: [Addition]] = [:]
    /// Why a thread's waiting messages were not sent, for its composer to
    /// say, until the next message is sent there.
    @Published private(set) var notSent: [String: String] = [:]
    /// The ending of the last turn this engine ran in each thread, by
    /// thread id. A thread shows it from here, so the reply appears where
    /// its turn ended whether or not it could be stored.
    @Published private(set) var endings: [String: Ending] = [:]

    /// An ending that could not be stored, by thread id. It is stored
    /// before the thread's next turn starts, so no later turn is stored
    /// ahead of it, and no later ending takes its place.
    private var unstored: [String: (turnID: String, outcome: TurnOutcome, message: ChatMessage, trace: WorkTrace)] = [:]

    /// The task running each thread's reply, which Stop cancels.
    private var replies: [String: Task<Error?, Never>] = [:]
    /// Turns, by id, whose reply has ended and whose ending is being
    /// stored: too late to stop.
    private var settling: Set<String> = []
    /// The text of a send that failed after its thread had left the screen,
    /// and why, by thread id: given back when the thread is next opened.
    private var unsent: [String: (text: String, reason: String)] = [:]

    /// The turns picked up since the app started, by id: each is picked up
    /// once, and ends through that.
    private var pickedUp: Set<String> = []
    /// The last status announced for each running turn, by turn id.
    private var announced: [String: String] = [:]
    /// Turns, by id, on which Stop was pressed too late to stop the reply,
    /// while its ending was being stored.
    private var stoppedTooLate: Set<String> = []
    private var additionsMade = 0

    private let chat: ChatService
    private let store = ThreadRepository.shared
    /// Where the turns' tools ask the person, and the answers are held
    /// while a turn runs.
    private let approvals: ToolApprovals

    init(chat: ChatService, approvals: ToolApprovals = .shared) {
        self.chat = chat
        self.approvals = approvals
    }

    /// Starts a turn with the person's message, which is stored as it is:
    /// what they wrote and the thread shows. `context` is what the model is
    /// sent, which can carry more. Throws, with nothing started, if a turn
    /// is already running in the thread, or the message, or an earlier
    /// ending still waiting to be stored, cannot be stored.
    func start(
        with userMessage: ChatMessage,
        context: String,
        roleID: String?,
        agentName: String?,
        attachments: [FileAttachmentDetail]?
    ) async throws {
        let threadID = userMessage.threadId
        guard running[threadID] == nil else { throw TurnError.alreadyRunning }
        notSent[threadID] = nil
        let turnID = UUID().uuidString
        // Marked before anything waits, so a second send cannot start too.
        running[threadID] = Activity(turnID: turnID, message: TurnProgress.startingMessage, trace: WorkTrace(startedAt: Date()))
        // Answers left from a turn that never ended here are not this one's.
        approvals.forgetAnswers(threadID: threadID)
        do {
            try await storeWaitingEnding(threadID: threadID)
            try await store.beginTurn(id: turnID, userMessage: userMessage)
        } catch {
            running[threadID] = nil
            // What was set to wait for this turn, while it was being
            // started, has no turn to wait for.
            giveBackWaiting(threadID: threadID, because: error)
            throw error
        }
        let chat = chat
        let store = store
        Task {
            await run(turnID: turnID, threadID: threadID, agentName: agentName) { report in
                try await chat.streamMessage(
                    threadId: threadID,
                    message: context,
                    roleId: roleID,
                    attachments: attachments,
                    onAgentRun: { run in
                        // Kept with the turn, so the run can be picked up
                        // again if this app closes on it. If it cannot be
                        // kept, the turn goes on; it would then end as
                        // interrupted after a relaunch, as it did before.
                        var kept = run
                        kept.agentName = agentName
                        do {
                            try await store.keepRun(kept, forTurn: turnID)
                        } catch {
                            AppErrorReporter.log(error: error, context: "TurnEngine.keepRun")
                        }
                    },
                    onStateChange: report
                )
            }
        }
    }

    /// Asks the turn running in a thread to stop. The turn is shown as
    /// stopping until it has ended: a model call in flight is cancelled, a
    /// step that cannot be cancelled runs to its end, and no further step is
    /// taken. If the reply arrives first, the turn ends with it. Pressed
    /// once the reply has ended and is being stored, it is too late for the
    /// reply, and still holds back what waits behind it.
    func stop(threadID: String) {
        guard let turn = running[threadID], !turn.isStopping else { return }
        guard !settling.contains(turn.turnID) else {
            stoppedTooLate.insert(turn.turnID)
            return
        }
        running[threadID]?.isStopping = true
        running[threadID]?.message = TurnProgress.stoppingMessage
        replies[threadID]?.cancel()
        // Said here, once for the turn, whatever screen is showing: with
        // the keyboard shortcut, VoiceOver's focus can be anywhere.
        AccessibilityNotification.Announcement("Stopping").post()
    }

    /// Announces a running turn's new status to VoiceOver, once: each window
    /// showing the turn asks when its line changes, and only the first is
    /// said, whatever other turns say in between. False when it had been
    /// said already, or the turn is no longer running.
    @discardableResult
    func announceStatus(_ message: String, of turnID: String) -> Bool {
        guard running.values.contains(where: { $0.turnID == turnID }), announced[turnID] != message else { return false }
        announced[turnID] = message
        AccessibilityNotification.Announcement(message).post()
        return true
    }

    // MARK: - While a turn runs

    /// Takes a message to wait for the thread's running turn. False, with
    /// nothing taken, if no turn is running there: it can be sent now.
    func enqueue(_ message: WaitingMessage, threadID: String) -> Bool {
        guard running[threadID] != nil else { return false }
        notSent[threadID] = nil
        waiting[threadID, default: []].append(message)
        return true
    }

    /// Remove: the waiting message is dropped. Not one whose turn is
    /// being started: it is on its way.
    func removeWaiting(_ id: WaitingMessage.ID, threadID: String) {
        guard starting[threadID] != id else { return }
        drop(id, from: threadID)
    }

    /// Edit: the waiting message leaves the queue and goes back to the
    /// composer. Not one whose turn is being started.
    func editWaiting(_ id: WaitingMessage.ID, threadID: String) {
        guard starting[threadID] != id, let message = waiting[threadID]?.first(where: { $0.id == id }) else { return }
        drop(id, from: threadID)
        giveBack([message], threadID: threadID)
    }

    private func drop(_ id: WaitingMessage.ID, from threadID: String) {
        waiting[threadID]?.removeAll { $0.id == id }
        if waiting[threadID]?.isEmpty == true { waiting[threadID] = nil }
    }

    /// What was handed back to the thread's composer, once.
    func takeReturned(threadID: String) -> ComposerDraft? {
        returned.removeValue(forKey: threadID)
    }

    /// Hands waiting messages back to the composer, in order, after
    /// whatever was handed back before and not yet taken.
    private func giveBack(_ messages: [WaitingMessage], threadID: String) {
        var draft = returned[threadID] ?? ComposerDraft()
        for message in messages {
            draft = draft.followed(by: ComposerDraft(text: message.text, attachments: message.attachments))
        }
        if !draft.isEmpty { returned[threadID] = draft }
    }

    /// Hands everything waiting in a thread back to its composer, which
    /// says why it was not sent. Said to VoiceOver here, once, whatever
    /// screens show the thread.
    private func giveBackWaiting(threadID: String, because error: Error) {
        guard let queue = waiting.removeValue(forKey: threadID), !queue.isEmpty else { return }
        giveBack(queue, threadID: threadID)
        let notice = "Your waiting message could not be sent: \(error.localizedDescription)"
        notSent[threadID] = notice
        AccessibilityNotification.Announcement(notice).post()
    }

    /// Settles what waited for a turn that has ended. A turn that completed
    /// and that the person did not try to stop sends the first waiting
    /// message, as an ordinary one; the rest wait for that turn. After any
    /// other ending nothing is sent, and what waited goes back to the
    /// composer.
    private func settleWaiting(threadID: String, sendsNext: Bool) async {
        guard let queue = waiting[threadID], let next = queue.first else { return }
        guard sendsNext else {
            waiting[threadID] = nil
            return giveBack(queue, threadID: threadID)
        }
        // Made now, not when it was typed: it is stored after the reply it
        // waited for.
        let userMessage = TurnProgress.message(in: threadID, role: "user", content: next.userText)
        // It stays among the waiting until its turn has started, so the
        // thread never shows it as neither waiting nor sent; from here it
        // is on its way, and is no longer edited or removed.
        starting[threadID] = next.id
        defer { starting[threadID] = nil }
        do {
            try await start(
                with: userMessage,
                context: next.context,
                roleID: next.roleID,
                agentName: next.agentName,
                attachments: next.attachments.isEmpty ? nil : next.attachments
            )
            drop(next.id, from: threadID)
            add(userMessage, to: threadID)
        } catch TurnError.alreadyRunning {
            // A turn started meanwhile: this one waits for it, where it is.
        } catch {
            // Not sent, and nothing behind it is either: `start` has handed
            // it all back, and said why.
            let error = error as NSError
            AppErrorReporter.log(message: "A waiting message could not be sent (\(error.domain) \(error.code)).", context: "TurnEngine.settleWaiting")
        }
    }

    /// Notes a message the engine added to a thread, for a thread on
    /// screen to show.
    private func add(_ message: ChatMessage, trace: WorkTrace? = nil, to threadID: String) {
        additionsMade += 1
        var kept = additions[threadID] ?? []
        kept.append(Addition(sequence: additionsMade, message: message, trace: trace))
        additions[threadID] = Array(kept.suffix(Self.additionsKept))
    }

    /// Keeps the text of a send that could not be started, for a thread that
    /// is no longer on screen to give it back to.
    func keepUnsent(_ text: String, for threadID: String, because reason: String) {
        unsent[threadID] = (text, reason)
    }

    /// The text of a send to this thread that failed while the thread was
    /// off screen, and why, once.
    func takeUnsent(for threadID: String) -> (text: String, reason: String)? {
        unsent.removeValue(forKey: threadID)
    }

    /// Settles any turn in the thread that is recorded as running but is
    /// not, and whose ending this engine does not hold. One an agent of the
    /// person's own was running is picked up and followed to its end; any
    /// other is ended, and the thread gets a line saying no reply was saved.
    /// An ending the engine holds unstored is tried again first.
    func settleInterruptedTurns(threadID: String) async {
        do {
            do {
                try await storeWaitingEnding(threadID: threadID)
            } catch {
                AppErrorReporter.log(error: error, context: "TurnEngine.storeWaitingEnding")
            }
            for turn in try await store.runningTurns(threadID: threadID) where !isBeingSettled(turn.id, in: threadID) {
                // A turn an agent of the person's own was running went on
                // there: it is picked up, not ended. One at a time in a
                // thread, as for any turn.
                let canResume = if let run = turn.run { await chat.canResume(run) } else { false }
                // The thread can be opened in two places at once: the other
                // opener can have picked this turn up while this one waited,
                // and it can have ended since. Either way it is not this
                // opener's to pick up or to end.
                guard !isBeingSettled(turn.id, in: threadID) else { continue }
                if canResume, let run = turn.run, running[threadID] == nil {
                    resume(turn, run, in: threadID)
                    continue
                }
                try await store.endTurn(
                    id: turn.id,
                    outcome: .interrupted,
                    message: TurnProgress.message(in: threadID, role: "assistant", content: TurnProgress.interruptedNotice)
                )
            }
        } catch {
            AppErrorReporter.log(error: error, context: "TurnEngine.settleInterruptedTurns")
        }
    }

    /// Whether this engine is running the turn, holds its ending, or has
    /// picked it up: such a turn is settled by the engine's own run of it,
    /// whatever an earlier reading of the stored turns says.
    private func isBeingSettled(_ turnID: String, in threadID: String) -> Bool {
        running[threadID]?.turnID == turnID || unstored[threadID]?.turnID == turnID || pickedUp.contains(turnID)
    }

    /// Takes up again a turn whose run went on in the agent while this app
    /// was closed: the thread shows it as running, with Stop, and it ends
    /// as any turn does.
    private func resume(_ turn: RunningTurn, _ run: AgentRun, in threadID: String) {
        pickedUp.insert(turn.id)
        running[threadID] = Activity(turnID: turn.id, message: TurnProgress.pickingUpMessage, trace: WorkTrace(startedAt: turn.startedAt))
        let chat = chat
        Task {
            await self.run(turnID: turn.id, threadID: threadID, agentName: run.agentName) { report in
                try await chat.resumeAgentRun(run, threadId: threadID, onStateChange: report)
            }
        }
    }

    /// Stores the thread's ending that could not be stored before, if there
    /// is one. Throws if it still cannot be.
    private func storeWaitingEnding(threadID: String) async throws {
        guard let waiting = unstored[threadID] else { return }
        let stored = try await store.endTurn(id: waiting.turnID, outcome: waiting.outcome, message: waiting.message, trace: waiting.trace)
        // Another call can have stored it while this one waited; then there
        // is nothing left to do, whatever this call's own answer.
        guard unstored[threadID]?.turnID == waiting.turnID else { return }
        guard stored else { throw TurnError.endingNotStored }
        unstored[threadID] = nil
        endings[threadID] = Ending(turnID: waiting.turnID, outcome: waiting.outcome, trace: waiting.trace, messages: [waiting.message], stored: true)
    }

    /// Runs a turn's work to its end and stores how it ended. `work` makes
    /// the reply, reporting each step as it goes: the app's own reply loop,
    /// or the following of an agent's run.
    private func run(
        turnID: String,
        threadID: String,
        agentName: String?,
        work: @escaping @Sendable (_ report: @escaping @Sendable (TurnState) -> Void) async throws -> Void
    ) async {
        // The chat service reports each step from its own actor; the stream
        // keeps the steps in the order they were reported.
        let (states, continuation) = AsyncStream<TurnState>.makeStream()
        let chat = chat
        let reply = Task { () -> Error? in
            defer { continuation.finish() }
            do {
                try await work { continuation.yield($0) }
                return nil
            } catch {
                return error
            }
        }

        replies[threadID] = reply
        // Stop can have been asked while the turn was being stored.
        if running[threadID]?.isStopping == true {
            reply.cancel()
        }

        var progress = TurnProgress(agentName: agentName, startedAt: running[threadID]?.trace.startedAt ?? Date())
        for await state in states {
            progress.note(state)
            // Most reports leave the line and the trace as they are; the
            // thread redraws only when one changes. A stopping turn keeps
            // saying so.
            if running[threadID]?.isStopping == false, running[threadID]?.message != progress.activity {
                running[threadID]?.message = progress.activity
            }
            if running[threadID]?.trace != progress.trace {
                running[threadID]?.trace = progress.trace
            }
        }
        let thrown = await reply.value
        replies[threadID] = nil
        settling.insert(turnID)
        let wasStopped = running[threadID]?.isStopping == true
        var ending = progress.ending(in: threadID, thrown: thrown, stopped: wasStopped)
        // Copied, and forgotten there only once the ending is published:
        // until then the thread shows a running turn's answers from there.
        ending.trace.approvals = approvals.answered[threadID] ?? []

        do {
            guard try await store.endTurn(id: turnID, outcome: ending.outcome, message: ending.message, trace: ending.trace) else {
                throw TurnError.endingNotStored
            }
            endings[threadID] = Ending(turnID: turnID, outcome: ending.outcome, trace: ending.trace, messages: [ending.message], stored: true)
            add(ending.message, trace: ending.trace, to: threadID)
        } catch {
            // The reply exists and the thread shows it, with why it may not
            // be there later. It is tried again before the thread's next
            // turn; if the app closes first, the turn is still recorded as
            // running, and the next launch says no reply was saved.
            AppErrorReporter.log(error: error, context: "TurnEngine.endTurn")
            unstored[threadID] = (turnID, ending.outcome, ending.message, ending.trace)
            let notice = TurnProgress.message(
                in: threadID,
                role: "assistant",
                content: "AICoven couldn't save this reply yet. It will try again when you send your next message here; if the app closes first, the reply is lost. \(error.localizedDescription)"
            )
            endings[threadID] = Ending(turnID: turnID, outcome: ending.outcome, trace: ending.trace, messages: [ending.message, notice], stored: false)
            add(ending.message, trace: ending.trace, to: threadID)
            add(notice, to: threadID)
        }
        // Stop pressed while the ending was being stored was too late for
        // the reply, and still means stop.
        let stopWasPressed = stoppedTooLate.remove(turnID) != nil || wasStopped
        running[threadID] = nil
        settling.remove(turnID)
        announced[turnID] = nil
        approvals.forgetAnswers(threadID: threadID)
        if ending.outcome == .cancelled {
            // Once, when the turn has in fact stopped and Stop is gone.
            AccessibilityNotification.Announcement("Stopped").post()
        }
        // A completion the person tried to stop is not a go-ahead.
        await settleWaiting(threadID: threadID, sendsNext: ending.outcome == .completed && !stopWasPressed)
        if ending.outcome == .completed {
            await chat.updateThreadSummary(threadId: threadID)
        }
    }
}

/// What a turn has reported so far, turned into what the thread shows while
/// it runs and the message it ends with.
struct TurnProgress {
    static let startingMessage = "Thinking through your request…"
    static let stoppingMessage = "Stopping…"
    static let pickingUpMessage = "Picking up where your agent is…"
    static let interruptedNotice = "No reply to this message was saved. Send it again to get an answer."

    let agentName: String?
    /// The status line's text.
    private(set) var activity = TurnProgress.startingMessage
    /// The work so far.
    private(set) var trace: WorkTrace
    private var thoughts: [String] = []
    private var usedTools = false
    private var last: TurnState?
    /// What had been answered so far, while the answer was arriving.
    private var partialAnswer = ""

    init(agentName: String?, startedAt: Date = Date()) {
        self.agentName = agentName
        trace = WorkTrace(startedAt: startedAt)
    }

    mutating func note(_ state: TurnState, at now: Date = Date()) {
        last = state
        trace.note(state, at: now)
        switch state.phase {
        case .starting, .planning, .modelAttempt:
            let thought = state.scratchpad.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !thought.isEmpty else { return }
            activity = usedTools ? "Using tools and memory: \(thought)" : "Planning: \(thought)"
            if thoughts.last != thought {
                thoughts.append(thought)
            }
        case .tooling:
            usedTools = true
            if let tool = state.toolsInProgress.values.first ?? state.toolsCompleted.last {
                activity = Self.toolActivity(for: tool.name)
            }
        case .answering:
            partialAnswer = state.answer
        case .finalizing:
            break
        }
    }

    /// How the turn ended and the message that says so: the reply, the
    /// failure the chat service reported, or the error it threw. A turn the
    /// person stopped ends as stopped, with what had been answered so far,
    /// unless the reply had already arrived in full: then it ends with it.
    func ending(
        in threadID: String,
        thrown: Error?,
        stopped: Bool = false,
        at now: Date = Date()
    ) -> (outcome: TurnOutcome, message: ChatMessage, trace: WorkTrace) {
        var trace = trace
        trace.finishedAt = now
        // However the turn ended, its message is shown under the name it
        // was started with.
        let named = agentName.map { ["role_name": AnyJSONValue($0)] }
        // Stopped by the person, or by the agent that was running it.
        if (stopped && (thrown != nil || last?.status != .completed)) || (thrown == nil && last?.status == .cancelled) {
            let partial = MessageAdapter.sanitizeContentForDisplay(partialAnswer).trimmingCharacters(in: .whitespacesAndNewlines)
            let content = partial.isEmpty ? "Stopped before any reply." : "\(partial)\n\n_Stopped here._"
            return (.cancelled, Self.message(in: threadID, role: "assistant", content: content, metadata: named), trace)
        }
        if let thrown {
            let text = "I ran into an error while contacting your provider: \(thrown.localizedDescription)"
            return (.failed, Self.message(in: threadID, role: "assistant", content: text, metadata: named), trace)
        }
        // The chat service's last report is its outcome: the answer, or what
        // went wrong.
        let answer = last?.answer ?? ""
        guard last?.status != .failed else {
            return (.failed, Self.message(in: threadID, role: "assistant", content: answer, metadata: named), trace)
        }

        var metadata: [String: AnyJSONValue] = [:]
        let joined = thoughts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty {
            metadata["thoughts"] = AnyJSONValue([joined])
        }
        if let agentName {
            metadata["role_name"] = AnyJSONValue(agentName)
        }
        let content = MessageAdapter.sanitizeContentForDisplay(answer)
        return (.completed, Self.message(in: threadID, role: "assistant", content: content, metadata: metadata), trace)
    }

    static func message(in threadID: String, role: String, content: String, metadata: [String: AnyJSONValue]? = nil) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString,
            threadId: threadID,
            role: role,
            content: content,
            metadata: metadata,
            tokenUsage: nil,
            createdAt: Date(),
            isEncrypted: false,
            keyFingerprint: nil
        )
    }

    /// The status line's text while a tool runs.
    static func toolActivity(for toolName: String) -> String {
        let known: [(prefix: String, activity: String)] = [
            ("web.search", "Using web.search to look up information on the web…"),
            ("web.browse", "Using web.browse to read a web page…"),
            ("github.readFile", "Using github.readFile to inspect a file in your repo…"),
            ("github.listFiles", "Using github.listFiles to explore the repository structure…"),
            ("github.searchCode", "Using github.searchCode to search through your codebase…"),
            ("github.writeFile", "Using github.writeFile to apply code changes…"),
            ("github.createBranch", "Using github.createBranch to create a new branch…"),
            ("github.createPR", "Using github.createPR to open a pull request…"),
            ("image.generate", "Using image.generate to create an image…"),
            ("video.generate", "Using video.generate to create a video…"),
            ("file.generate", "Using file.generate to create a file…"),
            ("shell.execute", "Using shell.execute to run a command on your machine…"),
            ("google_drive.", "Using Google Workspace tools to work with your docs and files…"),
            ("google_docs.", "Using Google Workspace tools to work with your docs and files…"),
            ("google_sheets.", "Using Google Workspace tools to work with your docs and files…"),
            ("google_slides.", "Using Google Workspace tools to work with your docs and files…"),
        ]
        return known.first { toolName.hasPrefix($0.prefix) }?.activity ?? "Using tool \(toolName)…"
    }
}
