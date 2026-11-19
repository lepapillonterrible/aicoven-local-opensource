internal import Combine
import Foundation

/// Runs each reply from the person's message to its stored outcome, in a
/// task of its own. The screen that asked for the reply only watches: it can
/// go away, and the reply still finishes and is stored.
///
/// A turn is recorded when it starts, with the person's message, and when it
/// ends, with the reply or what went wrong. A turn still recorded as running
/// that this engine is not running was cut off by the app closing; opening
/// its thread says so in the thread.
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

    /// The turn running in each thread, by thread id.
    @Published private(set) var running: [String: Activity] = [:]

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

    /// Ends any turn in the thread that is recorded as running but is not:
    /// the app closed while it ran. The thread gets a line saying so.
    func settleInterruptedTurns(threadID: String) async {
        do {
            for turnID in try await store.runningTurnIDs(threadID: threadID) where running[threadID]?.turnID != turnID {
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
        } catch {
            // Left recorded as running, so its thread says it was cut off.
            AppErrorReporter.log(error: error, context: "TurnEngine.endTurn")
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
    static let interruptedNotice = "This reply was cut off because AICoven closed before it finished. Send your message again to get an answer."

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
        guard let last, last.phase == .finalizing else {
            return (.failed, Self.message(in: threadID, role: "assistant", content: "The reply ended without an answer. Send your message again."))
        }
        guard last.status != .failed else {
            return (.failed, Self.message(in: threadID, role: "assistant", content: last.answer))
        }

        var metadata: [String: AnyJSONValue] = [:]
        let joined = thoughts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty {
            metadata["thoughts"] = AnyJSONValue([joined])
        }
        if let agentName {
            metadata["role_name"] = AnyJSONValue(agentName)
        }
        let content = MessageAdapter.sanitizeContentForDisplay(last.answer)
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
