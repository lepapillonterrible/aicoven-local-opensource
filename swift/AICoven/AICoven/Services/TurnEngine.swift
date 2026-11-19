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
/// Opening its thread says so there.
@MainActor
final class TurnEngine: ObservableObject {
    static let shared = TurnEngine(chat: .shared)

    /// What a running turn is doing, for the thread's loader.
    struct Activity: Equatable {
        let turnID: String
        var message: String
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
        /// The reply or what went wrong, followed, if that could not be
        /// stored, by a line saying so.
        let messages: [ChatMessage]
        let stored: Bool
    }

    /// The turn running in each thread, by thread id.
    @Published private(set) var running: [String: Activity] = [:]
    /// The ending of the last turn this engine ran in each thread, by
    /// thread id. A thread shows it from here, so the reply appears where
    /// its turn ended whether or not it could be stored.
    @Published private(set) var endings: [String: Ending] = [:]

    /// An ending that could not be stored, by thread id. It is stored
    /// before the thread's next turn starts, so no later turn is stored
    /// ahead of it, and no later ending takes its place.
    private var unstored: [String: (turnID: String, outcome: TurnOutcome, message: ChatMessage)] = [:]

    /// The task running each thread's reply, which Stop cancels.
    private var replies: [String: Task<Error?, Never>] = [:]
    /// The text of a send that failed after its thread had left the screen,
    /// and why, by thread id: given back when the thread is next opened.
    private var unsent: [String: (text: String, reason: String)] = [:]

    private let chat: ChatService
    private let store = ThreadRepository.shared

    init(chat: ChatService) {
        self.chat = chat
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
        let turnID = UUID().uuidString
        // Marked before anything waits, so a second send cannot start too.
        running[threadID] = Activity(turnID: turnID, message: TurnProgress.startingMessage)
        do {
            try await storeWaitingEnding(threadID: threadID)
            try await store.beginTurn(id: turnID, userMessage: userMessage)
        } catch {
            running[threadID] = nil
            throw error
        }
        Task {
            await run(turnID: turnID, threadID: threadID, context: context, roleID: roleID, agentName: agentName, attachments: attachments)
        }
    }

    /// Asks the turn running in a thread to stop. The turn is shown as
    /// stopping until it has ended: a model call in flight is cancelled, a
    /// step that cannot be cancelled runs to its end, and no further step is
    /// taken. If the reply arrives first, the turn ends with it.
    func stop(threadID: String) {
        guard running[threadID]?.isStopping == false else { return }
        running[threadID]?.isStopping = true
        running[threadID]?.message = TurnProgress.stoppingMessage
        replies[threadID]?.cancel()
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

    /// Ends any turn in the thread that is recorded as running but is not,
    /// and whose ending this engine does not hold: the thread gets a line
    /// saying no reply was saved. An ending the engine holds unstored is
    /// tried again first.
    func settleInterruptedTurns(threadID: String) async {
        do {
            do {
                try await storeWaitingEnding(threadID: threadID)
            } catch {
                AppErrorReporter.log(error: error, context: "TurnEngine.storeWaitingEnding")
            }
            for turnID in try await store.runningTurnIDs(threadID: threadID)
                where running[threadID]?.turnID != turnID && unstored[threadID]?.turnID != turnID {
                try await store.endTurn(
                    id: turnID,
                    outcome: .interrupted,
                    message: TurnProgress.message(in: threadID, role: "assistant", content: TurnProgress.interruptedNotice)
                )
            }
        } catch {
            AppErrorReporter.log(error: error, context: "TurnEngine.settleInterruptedTurns")
        }
    }

    /// Stores the thread's ending that could not be stored before, if there
    /// is one. Throws if it still cannot be.
    private func storeWaitingEnding(threadID: String) async throws {
        guard let waiting = unstored[threadID] else { return }
        let stored = try await store.endTurn(id: waiting.turnID, outcome: waiting.outcome, message: waiting.message)
        // Another call can have stored it while this one waited; then there
        // is nothing left to do, whatever this call's own answer.
        guard unstored[threadID]?.turnID == waiting.turnID else { return }
        guard stored else { throw TurnError.endingNotStored }
        unstored[threadID] = nil
        endings[threadID] = Ending(turnID: waiting.turnID, messages: [waiting.message], stored: true)
    }

    private func run(
        turnID: String,
        threadID: String,
        context: String,
        roleID: String?,
        agentName: String?,
        attachments: [FileAttachmentDetail]?
    ) async {
        // The chat service reports each step from its own actor; the stream
        // keeps the steps in the order they were reported.
        let (states, continuation) = AsyncStream<TurnState>.makeStream()
        let chat = chat
        let reply = Task { () -> Error? in
            defer { continuation.finish() }
            do {
                try await chat.streamMessage(
                    threadId: threadID,
                    message: context,
                    roleId: roleID,
                    attachments: attachments,
                    onStateChange: { continuation.yield($0) }
                )
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

        var progress = TurnProgress(agentName: agentName)
        for await state in states {
            progress.note(state)
            // Most reports leave the line as it is; the thread redraws only
            // when it changes. A stopping turn keeps saying so.
            if running[threadID]?.isStopping == false, running[threadID]?.message != progress.activity {
                running[threadID]?.message = progress.activity
            }
        }
        let thrown = await reply.value
        replies[threadID] = nil
        let ending = progress.ending(in: threadID, thrown: thrown, stopped: running[threadID]?.isStopping == true)

        do {
            guard try await store.endTurn(id: turnID, outcome: ending.outcome, message: ending.message) else {
                throw TurnError.endingNotStored
            }
            endings[threadID] = Ending(turnID: turnID, messages: [ending.message], stored: true)
        } catch {
            // The reply exists and the thread shows it, with why it may not
            // be there later. It is tried again before the thread's next
            // turn; if the app closes first, the turn is still recorded as
            // running, and the next launch says no reply was saved.
            AppErrorReporter.log(error: error, context: "TurnEngine.endTurn")
            unstored[threadID] = (turnID, ending.outcome, ending.message)
            let notice = TurnProgress.message(
                in: threadID,
                role: "assistant",
                content: "AICoven couldn't save this reply yet. It will try again when you send your next message here; if the app closes first, the reply is lost. \(error.localizedDescription)"
            )
            endings[threadID] = Ending(turnID: turnID, messages: [ending.message, notice], stored: false)
        }
        running[threadID] = nil
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
    static let interruptedNotice = "No reply to this message was saved. Send it again to get an answer."

    let agentName: String?
    /// The loader's line.
    private(set) var activity = TurnProgress.startingMessage
    private var thoughts: [String] = []
    private var usedTools = false
    private var last: TurnState?
    /// What had been answered so far, while the answer was arriving.
    private var partialAnswer = ""

    init(agentName: String?) {
        self.agentName = agentName
    }

    mutating func note(_ state: TurnState) {
        last = state
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
    func ending(in threadID: String, thrown: Error?, stopped: Bool = false) -> (outcome: TurnOutcome, message: ChatMessage) {
        if stopped, thrown != nil || last?.status != .completed {
            let partial = MessageAdapter.sanitizeContentForDisplay(partialAnswer).trimmingCharacters(in: .whitespacesAndNewlines)
            let content = partial.isEmpty ? "Stopped before any reply." : "\(partial)\n\n_Stopped here._"
            return (.cancelled, Self.message(in: threadID, role: "assistant", content: content, metadata: ["stopped": AnyJSONValue(true)]))
        }
        if let thrown {
            let text = "I ran into an error while contacting your provider: \(thrown.localizedDescription)"
            return (.failed, Self.message(in: threadID, role: "assistant", content: text))
        }
        // The chat service's last report is its outcome: the answer, or what
        // went wrong.
        let answer = last?.answer ?? ""
        guard last?.status != .failed else {
            return (.failed, Self.message(in: threadID, role: "assistant", content: answer))
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
        return (.completed, Self.message(in: threadID, role: "assistant", content: content, metadata: metadata))
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

    /// The loader's line while a tool runs.
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
