internal import Combine
import Foundation
import SwiftUI

/// Sending an asset to an agent, as the cloud app's "Send to Agent": the
/// asset's hand-off brief is made (or the one it has is taken), and the
/// agent chosen is asked, in a thread of the asset's place, to work from
/// it. The agent is given the two assets' ids and reads them with the
/// asset tools: nothing of the asset's files is put into the thread. In
/// the cloud app the server does this; here the device does.
@MainActor
final class AssetHandoffModel: ObservableObject {
    /// An agent an asset can be sent to: one of the place's, or Strix.
    struct Agent: Identifiable, Equatable {
        let id: String
        let name: String
        /// Whether its turns are offered the asset tools, as it is set up
        /// now: a cloud model's turn is; one on this device, Hermes or
        /// OpenClaw is not, and could not open what it is sent. Where no
        /// model could be found to answer for it just now (nothing is
        /// connected, or what is connected could not be read), that
        /// cannot be told.
        enum Tools: Equatable {
            case offered
            case notOffered
            case unknown

            /// As the chat service answers: nil where no model can answer.
            init(_ offered: Bool?) {
                self = offered.map { $0 ? .offered : .notOffered } ?? .unknown
            }
        }

        var tools = Tools.offered

        var readsAssets: Bool {
            tools == .offered
        }

        /// Strix, which answers in its own place and in a coven with no
        /// agents: no stored agent.
        static let strixID = "strix"

        var isStrix: Bool {
            id == Self.strixID
        }
    }

    /// The agents', the threads' and the store's side, which a test replaces.
    struct Hands {
        /// The agents of the place (Strix alone for Strix's, and for a
        /// coven with none); nil where they could not be read.
        var agents: @MainActor (_ covenID: String?, _ account: String) async -> [Agent]?
        /// The place's threads that are not archived, the one last used first.
        var threads: @MainActor (_ covenID: String?, _ account: String) async throws -> [Thread]
        /// Whether a turn for the agent would be offered the asset tools,
        /// as the agent and the connections are set up now; nil where
        /// the account is no longer the one signed in.
        var tools: @MainActor (_ agent: Agent, _ account: String) async -> Agent.Tools?
        /// Whether a turn is under way in the thread: one this app runs,
        /// or a run an agent of the person's own was making when the app
        /// was closed, which goes on without it until the thread is opened.
        var isBusy: @MainActor (_ threadID: String, _ account: String) async throws -> Bool
        /// The asset's hand-off brief (the one it has, or a new one), and
        /// how the asset stood as the store looked.
        var brief: @MainActor (_ assetID: String, _ account: String) async throws -> (brief: Asset, sourceStatus: AssetStatus)
        var createThread: @MainActor (_ title: String, _ covenID: String?, _ agent: Agent, _ account: String) async throws -> Thread
        /// Starts a turn in the thread with these words as the person's
        /// message, answered by the agent given.
        var startTurn: @MainActor (_ thread: Thread, _ text: String, _ agent: Agent) async throws -> Void
        /// Undoes a thread made for a hand-off that did not start: only
        /// as the account it was made for.
        var discardThread: @MainActor (_ thread: Thread, _ account: String) async -> Void
        var signedIn: @MainActor () -> String
        /// Says something to VoiceOver.
        var say: @MainActor (String) -> Void

        static let live = Hands(
            agents: { covenID, account in
                var agents: [Agent] = []
                if let covenID {
                    guard let roles = try? await RoleService.shared.loadRoles(covenId: covenID) else { return nil }
                    agents = roles.map { Agent(id: $0.id, name: $0.name) }
                }
                if agents.isEmpty { agents = [Agent(id: Agent.strixID, name: "Strix")] }
                // One refresh of what is connected for all of them, as the
                // account that asked. In a task of its own: a sheet closed
                // meanwhile calls this reading off, and the refresh, called
                // off halfway, would leave the app with no models to route to.
                let asked = agents.map { $0.isStrix ? nil : $0.id }
                guard let offered = await Task(operation: { await ChatService.shared.offersPlaceTools(toAgents: asked, as: account) }).value else {
                    return nil
                }
                for (index, reads) in zip(agents.indices, offered) {
                    agents[index].tools = Agent.Tools(reads)
                }
                guard UserScope.currentUserID == account else { return nil }
                return agents
            },
            threads: { covenID, account in
                guard UserScope.currentUserID == account else { throw RepositoryError.accountChanged }
                let threads = try await ThreadService.shared.loadThreads(covenId: covenID)
                return ThreadListRules.ordered(threads)
            },
            tools: { agent, account in
                let asked = [agent.isStrix ? nil : agent.id]
                return await Task { await ChatService.shared.offersPlaceTools(toAgents: asked, as: account) }.value?.first.map(Agent.Tools.init)
            },
            isBusy: { threadID, account in
                if TurnEngine.shared.running[threadID] != nil { return true }
                // A turn stored as running that has an agent's own run is
                // still under way though this app runs nothing in it.
                let marks = try await ThreadRepository.shared.threadMarks(for: account)[threadID]
                // Asked again after the wait: a turn can have started meanwhile.
                if TurnEngine.shared.running[threadID] != nil { return true }
                return marks?.latestTurn == .running && marks?.latestTurnHasRun == true
            },
            brief: {
                let handed = try await AssetRepository.shared.handoffBrief(of: $0, as: $1)
                return (handed.brief, handed.sourceStatus)
            },
            createThread: { title, covenID, agent, account in
                try await ThreadService.shared.createThread(
                    title: title, covenId: covenID, agentId: agent.isStrix ? nil : agent.id, agentName: agent.isStrix ? nil : agent.name, as: account
                )
            },
            startTurn: { thread, text, agent in
                _ = try await TurnEngine.shared.start(
                    with: TurnProgress.userMessage(in: thread.id, text: text, attachments: []), context: text,
                    roleID: agent.isStrix ? nil : agent.id, agentName: agent.name, attachments: nil
                )
            },
            discardThread: { thread, account in
                guard UserScope.currentUserID == account else { return }
                do {
                    try await ThreadService.shared.deleteThread(threadId: thread.id)
                } catch {
                    // The kind of failure only.
                    AppErrorReporter.log(message: "Could not discard a thread a hand-off did not start in (\(type(of: error)))", context: "AssetHandoffModel")
                }
            },
            signedIn: { UserScope.currentUserID },
            say: { AccessibilityNotification.Announcement($0).post() }
        )
    }

    // The cloud app's words.
    static let loading = "Loading agents and threads…"
    static let couldNotLoad = "Couldn't load the agents and threads. Try again."
    static let chooseBoth = "Choose an agent and a thread."
    static let cannotBeSent = "This asset can't be sent to an agent anymore."
    static let threadIsBusy = "This thread's agent is still working. Start a new thread to send it now, or send it again once the agent finishes."
    static let notConfirmed = "AICoven could not confirm the handoff. Try again."
    static let noThreads = "No thread can take this asset. Start a new one to continue."
    static let footer = "The agent receives an in-app asset reference. Asset files and encryption keys are not copied into chat."
    /// What a thread made for a hand-off is called where the person names none.
    static let threadTitle = "Asset handoff"

    /// Why an agent is not sent an asset: its turns are not offered the
    /// asset tools (it runs on this device or this network, on Hermes or
    /// on OpenClaw, or on nothing yet), so it could not open what it is
    /// sent. (This app's own: in the cloud app every agent's turns are.)
    static func cannotRead(_ agent: Agent) -> String {
        "\(agent.name) can't open assets: only an agent that runs on a cloud model is given the asset tools. Choose another agent."
    }

    /// Why an agent cannot be sent an asset just now: no model could be
    /// found to answer for it, which says nothing of where it runs.
    static func cannotTell(_ agent: Agent) -> String {
        "AICoven couldn't find a model to answer for \(agent.name) just now. Check your AI connections, or try again."
    }

    /// What the agent is told, as the cloud server writes it: the brief
    /// and the asset by their ids, where the asset's review stands, and
    /// what the person adds.
    static func message(briefID: String, sourceID: String, isApproved: Bool, direction: String) -> String {
        var text = """
        You are receiving an AICoven asset handoff.

        Implementation brief asset: \(briefID)
        Source asset: \(sourceID)
        Source review state: \(isApproved ? "APPROVED." : "PROPOSED — this source has not been approved.")

        Use asset.get to inspect the brief, source asset, files, relations,
        acceptance criteria, and constraints before making changes.
        Do not assume access to external systems that AICoven has not provided.
        """
        let direction = direction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !direction.isEmpty { text += "\n\nUser direction:\n" + direction }
        return text
    }

    let asset: Asset
    private let hands: Hands

    @Published private(set) var agents: [Agent] = []
    @Published private(set) var threads: [Thread] = []
    @Published private(set) var isLoading = true
    /// Whether the agents and the threads were read: until they are,
    /// nothing is chosen, and nothing is said of what there is.
    @Published private(set) var hasRead = false
    @Published private(set) var isSending = false
    /// What went wrong with the last thing asked, in words.
    @Published private(set) var failure: String?
    /// The choices. A choice changed takes away what went wrong with the
    /// last thing asked, which was said of the choice before; an agent
    /// that cannot be sent the asset is told to VoiceOver with why.
    @Published var agentID: String? {
        didSet {
            guard agentID != oldValue else { return }
            failure = nil
            if let note = agentNote { hands.say(note) }
        }
    }

    @Published var threadID: String? {
        didSet { if threadID != oldValue { failure = nil } }
    }

    @Published var startsNewThread = false {
        didSet { if startsNewThread != oldValue { failure = nil } }
    }

    @Published var newThreadTitle = ""
    @Published var direction = ""
    private var loads = 0

    init(asset: Asset, hands: Hands = .live) {
        self.asset = asset
        self.hands = hands
    }

    var agent: Agent? {
        agents.first { $0.id == agentID }
    }

    var thread: Thread? {
        threads.first { $0.id == threadID }
    }

    /// What is said under the agent chosen where it cannot be sent the asset.
    var agentNote: String? {
        guard let agent else { return nil }
        switch agent.tools {
        case .offered: return nil
        case .notOffered: return Self.cannotRead(agent)
        case .unknown: return Self.cannotTell(agent)
        }
    }

    /// Whether reading again could help the agent chosen: no model was
    /// found for it, which a connection that answers again changes.
    var offersTryAgain: Bool {
        agent?.tools == .unknown
    }

    /// Whether Send sends: an agent that can read the asset, and a thread
    /// (or a new one), once both are read and nothing is on its way.
    var canSend: Bool {
        guard hasRead, !isLoading, !isSending, let agent, agent.readsAssets else { return false }
        return startsNewThread || thread != nil
    }

    /// Reads the place's agents and threads for `account` and chooses as
    /// the cloud app does: the asset's own thread, else the first; that
    /// thread's agent, else the first agent. Only the latest reading is
    /// taken, and none for an account no longer signed in.
    func load(as account: String) async {
        loads += 1
        let load = loads
        isLoading = true
        failure = nil
        let chosenBefore = agentID
        // Read together: neither waits for the other.
        async let readAgents = hands.agents(asset.covenID, account)
        async let readThreads: [Thread]? = try? await hands.threads(asset.covenID, account)
        let (agents, threads) = await (readAgents, readThreads)
        // A reading that was called off (its sheet was closed) lands
        // nothing and says nothing.
        guard !Task.isCancelled, load == loads, hands.signedIn() == account else { return }
        isLoading = false
        guard let agents, let threads else {
            fail(Self.couldNotLoad)
            return
        }
        hasRead = true
        self.agents = agents
        self.threads = threads
        failure = nil
        if thread == nil { threadID = (threads.first { $0.id == asset.threadID } ?? threads.first)?.id }
        if threads.isEmpty { startsNewThread = true }
        if agent == nil { agentID = (agents.first { $0.id == thread?.agentId } ?? agents.first)?.id }
        // Read again for the agent already chosen (Try Again): what stands
        // in its way now is said, also where that is the same as before.
        if agentID == chosenBefore, let note = agentNote { hands.say(note) }
    }

    private func fail(_ words: String) {
        failure = words
        hands.say(words)
    }

    /// Sends the asset to the agent chosen, for the account that pressed
    /// Send, and answers with the thread it was sent in, to be opened;
    /// nil where it was not sent, with why in `failure`. One sending at a
    /// time, and nothing is looked at, said or done for an account that
    /// is no longer the one signed in. Everything is decided as things
    /// stand now, not as the sheet read them: the agent's turns are still
    /// offered the asset tools, the thread has no turn under way (one
    /// that has is not sent into: the engine would refuse it), and the
    /// asset is still proposed or approved as the store looks, which is
    /// also what the agent is told of its review. The brief is asked for
    /// before a thread is made, so that a thread is made only for an
    /// asset that is handed over; a thread made for a hand-off whose turn
    /// did not start is deleted again.
    func send(as account: String) async -> Thread? {
        guard hands.signedIn() == account, !isSending, !isLoading else { return nil }
        guard let agent, agent.readsAssets, startsNewThread || thread != nil else {
            // What is wrong with the agent is under it already.
            if let note = agentNote { hands.say(note) } else { fail(Self.chooseBoth) }
            return nil
        }
        isSending = true
        failure = nil
        defer { isSending = false }
        var made: Thread?
        do {
            let existing = startsNewThread ? nil : thread
            if let existing {
                let isBusy = try await hands.isBusy(existing.id, account)
                // Asked after every wait, whatever it answered.
                guard hands.signedIn() == account else { return nil }
                if isBusy {
                    fail(Self.threadIsBusy)
                    return nil
                }
            }
            guard let tools = await hands.tools(agent, account), hands.signedIn() == account else { return nil }
            guard tools == .offered else {
                // Set up otherwise since the sheet read it (or no model
                // can be found for it now): the sheet says so under the
                // agent from here on, and VoiceOver is told.
                if let index = agents.firstIndex(where: { $0.id == agent.id }) { agents[index].tools = tools }
                if let note = agentNote { hands.say(note) }
                return nil
            }
            let handed = try await hands.brief(asset.id, account)
            guard hands.signedIn() == account else { return nil }
            // An asset that has a brief can have been archived or sent
            // back since the sheet was opened: it is not sent on.
            guard handed.sourceStatus == .proposed || handed.sourceStatus == .approved else {
                fail(Self.cannotBeSent)
                return nil
            }
            var target = existing
            if target == nil {
                let title = ThreadInputValidator.normalizedTitle(newThreadTitle, defaultTitle: Self.threadTitle)
                made = try await hands.createThread(title, asset.covenID, agent, account)
                target = made
            }
            guard let target, hands.signedIn() == account else { return nil }
            if made == nil {
                let isBusy = try await hands.isBusy(target.id, account)
                guard hands.signedIn() == account else { return nil }
                if isBusy {
                    fail(Self.threadIsBusy)
                    return nil
                }
            }
            let words = Self.message(
                briefID: handed.brief.id, sourceID: asset.id, isApproved: handed.sourceStatus == .approved, direction: direction
            )
            try await hands.startTurn(target, words, agent)
            return hands.signedIn() == account ? target : nil
        } catch {
            if let made { await hands.discardThread(made, account) }
            guard hands.signedIn() == account, !(error is CancellationError) else { return nil }
            switch error {
            case AssetError.needsReview, AssetError.noSuchAsset, AssetError.unreadable:
                fail(Self.cannotBeSent)
            case TurnEngine.TurnError.alreadyRunning:
                // A turn started in the thread between the last look and the start: the engine refused.
                fail(Self.threadIsBusy)
            default:
                // The kind of failure only.
                AppErrorReporter.log(message: "An asset could not be sent to an agent (\(type(of: error)))", context: "AssetHandoffModel")
                fail(Self.notConfirmed)
            }
            return nil
        }
    }
}
