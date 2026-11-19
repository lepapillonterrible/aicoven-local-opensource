internal import Combine
import Foundation

/// Runs each reply from the person's message to its stored outcome, in a
/// task of its own. The screen that asked for the reply only watches: it can
/// go away, and the reply still finishes and is stored.
///
/// A turn is recorded when it starts, with the person's message, and when it
/// ends, with the reply or what went wrong. A turn still recorded as running
/// that this engine is not running has no stored ending: the app closed on
/// it, or its ending could not be stored. Opening its thread says so there.
@MainActor
final class TurnEngine: ObservableObject {
    static let shared = TurnEngine(chat: .shared)

    /// What a running turn is doing, for the thread's loader.
    struct Activity: Equatable {
        let turnID: String
        var message: String
    }

    enum TurnError: LocalizedError {
        case alreadyRunning

        var errorDescription: String? {
            "A reply is already on its way in this thread."
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

    private let chat: ChatService
    private let store = ThreadRepository.shared

    init(chat: ChatService) {
        self.chat = chat
    }

    /// Starts a turn in a thread and returns the person's message as stored.
    /// `text` is what the person wrote and what the thread shows; `context`
    /// is what the model is sent, which can carry more. Throws, with nothing
    /// started, if a turn is already running in the thread or the message
    /// cannot be stored.
    func start(
        threadID: String,
        text: String,
        context: String,
        roleID: String?,
        agentName: String?,
        attachments: [FileAttachmentDetail]?
    ) async throws -> ChatMessage {
        guard running[threadID] == nil else { throw TurnError.alreadyRunning }
        let turnID = UUID().uuidString
        // Marked before anything waits, so a second send cannot start too.
        running[threadID] = Activity(turnID: turnID, message: TurnProgress.startingMessage)
        let userMessage = TurnProgress.message(in: threadID, role: "user", content: text)
        do {
            try await store.beginTurn(id: turnID, userMessage: userMessage)
        } catch {
            running[threadID] = nil
            throw error
        }
        Task {
            await run(turnID: turnID, threadID: threadID, context: context, roleID: roleID, agentName: agentName, attachments: attachments)
        }
        return userMessage
    }

    /// Ends any turn in the thread that is recorded as running but is not,
    /// and whose ending this engine does not hold: the thread gets a line
    /// saying its reply was not saved.
    func settleInterruptedTurns(threadID: String) async {
        do {
            for turnID in try await store.runningTurnIDs(threadID: threadID)
                where running[threadID]?.turnID != turnID && endings[threadID]?.turnID != turnID {
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

        var progress = TurnProgress(agentName: agentName)
        for await state in states {
            progress.note(state)
            running[threadID]?.message = progress.activity
        }
        let thrown = await reply.value
        let ending = progress.ending(in: threadID, thrown: thrown)

        do {
            try await store.endTurn(id: turnID, outcome: ending.outcome, message: ending.message)
            endings[threadID] = Ending(turnID: turnID, messages: [ending.message], stored: true)
        } catch {
            // The reply exists and the thread shows it, with why it will not
            // be there later. The turn stays recorded as running, and a
            // later launch says its reply was not saved.
            AppErrorReporter.log(error: error, context: "TurnEngine.endTurn")
            let notice = TurnProgress.message(
                in: threadID,
                role: "assistant",
                content: "AICoven couldn't save this reply, so it will be gone when the app closes: \(error.localizedDescription)"
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
    static let interruptedNotice = "This reply was not saved: AICoven closed, or could not store it, before it was finished. Send your message again to get an answer."

    let agentName: String?
    /// The loader's line.
    private(set) var activity = TurnProgress.startingMessage
    private var thoughts: [String] = []
    private var usedTools = false
    private var last: TurnState?

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
        case .answering, .finalizing:
            break
        }
    }

    /// How the turn ended and the message that says so: the reply, the
    /// failure the chat service reported, or the error it threw.
    func ending(in threadID: String, thrown: Error?) -> (outcome: TurnOutcome, message: ChatMessage) {
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
