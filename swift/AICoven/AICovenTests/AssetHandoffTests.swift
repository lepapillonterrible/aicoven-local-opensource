@testable import AICoven
import XCTest

/// Sending an asset to an agent: the brief is made, the agent chosen is
/// asked in a thread of the asset's place, and nothing is done or said for
/// another account.
@MainActor
final class AssetHandoffTests: XCTestCase {
    /// What the agents', the threads' and the store's side give and were asked, set by the test.
    private final class Stand {
        var account = "ada"
        var agents: [AssetHandoffModel.Agent]? = [.init(id: "scout", name: "Scout"), .init(id: "quill", name: "Quill")]
        var threads: [AICoven.Thread] = []
        var threadsFail = false
        var busy: Set<String> = []
        var busyAsked: [String] = []
        /// What happens as the thread is looked at, by how many times it has been.
        var whenBusyAsked: [Int: () -> Void] = [:]
        /// The agents whose turns are no longer offered the asset tools, as things are set up by the time Send asks.
        var noLongerReads: Set<String> = []
        /// The agents no model can be found for by the time Send asks.
        var noModelFor: Set<String> = []
        /// How the asset stands as the store looks when the brief is asked for.
        var sourceStatus = AssetStatus.approved
        /// Where reading the agents waits, if anywhere.
        var agentsWait: Gate?
        /// A gate for each reading of the agents, in the order they are asked for.
        var agentsWaits: [Gate] = []
        var agentsAsked = 0
        /// Where making the brief waits, if anywhere.
        var briefWaits: Gate?
        var briefFails: Error?
        var briefsAsked: [(assetID: String, account: String)] = []
        var threadFails: Error?
        var madeThreads: [(title: String, covenID: String?, agent: String, account: String)] = []
        var startFails: Error?
        var started: [(threadID: String, text: String, agent: String)] = []
        var discarded: [String] = []
        var said: [String] = []
        /// What happens as each step is asked for, in order: a test changes the account or the thread's turn there.
        var whenAsked: [String: () -> Void] = [:]
        var steps: [String] = []
    }

    private func thread(_ id: String, agent: String? = nil, coven: String? = "work") -> AICoven.Thread {
        AICoven.Thread(
            id: id, userId: "ada", covenId: coven, title: id.capitalized, agentId: agent, agentName: agent?.capitalized,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: nil, lastMessageAt: nil
        )
    }

    private func asset(_ status: AssetStatus = .approved, thread: String? = nil, coven: String? = "work", unreadable: Bool = false) -> Asset {
        Asset(
            id: "logo", covenID: coven, type: .designMockup, status: status, title: "Logo", details: "", madeByAgentID: nil, threadID: thread,
            sourceMessageID: nil, files: [], isUnreadable: unreadable, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// Holds whoever waits at it until the test opens it, and tells when someone has come.
    private actor Gate {
        private var isOpen = false
        private var held: [CheckedContinuation<Void, Never>] = []
        private var arrivals = 0
        private var hearing: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func wait() async {
            arrivals += 1
            let due = hearing.filter { $0.count <= arrivals }
            hearing.removeAll { $0.count <= arrivals }
            due.forEach { $0.continuation.resume() }
            if !isOpen { await withCheckedContinuation { held.append($0) } }
        }

        func arrived(_ count: Int = 1) async {
            if arrivals < count { await withCheckedContinuation { hearing.append((count, $0)) } }
        }

        func open() {
            isOpen = true
            held.forEach { $0.resume() }
            held = []
        }
    }

    private func model(_ asset: Asset, _ stand: Stand) -> AssetHandoffModel {
        AssetHandoffModel(asset: asset, hands: AssetHandoffModel.Hands(
            agents: { _, _ in
                // As they are when asked for, however long the answer takes.
                let agents = stand.agents
                let asked = stand.agentsAsked
                stand.agentsAsked += 1
                await stand.agentsWait?.wait()
                if asked < stand.agentsWaits.count { await stand.agentsWaits[asked].wait() }
                return agents
            },
            threads: { _, _ in
                if stand.threadsFail { throw RepositoryError.databaseUnavailable }
                return stand.threads
            },
            tools: { agent, _ in
                stand.steps.append("reads")
                stand.whenAsked["reads"]?()
                if stand.noModelFor.contains(agent.id) { return .unknown }
                return stand.noLongerReads.contains(agent.id) ? .notOffered : .offered
            },
            isBusy: { threadID, _ in
                stand.busyAsked.append(threadID)
                stand.whenBusyAsked[stand.busyAsked.count]?()
                return stand.busy.contains(threadID)
            },
            brief: { assetID, account in
                stand.steps.append("brief")
                stand.briefsAsked.append((assetID, account))
                if let error = stand.briefFails { throw error }
                stand.whenAsked["brief"]?()
                await stand.briefWaits?.wait()
                let brief = Asset(
                    id: "brief", covenID: nil, type: .implementationBrief, status: .draft, title: "Handoff: Logo", details: "", madeByAgentID: nil,
                    threadID: nil, sourceMessageID: nil, parentID: assetID, files: [], createdAt: Date(), updatedAt: Date()
                )
                return (brief, stand.sourceStatus)
            },
            createThread: { title, covenID, agent, account in
                stand.steps.append("thread")
                if let error = stand.threadFails { throw error }
                stand.madeThreads.append((title, covenID, agent.id, account))
                stand.whenAsked["thread"]?()
                return self.thread("made-\(stand.madeThreads.count)", agent: agent.isStrix ? nil : agent.id, coven: covenID)
            },
            startTurn: { thread, text, agent in
                stand.steps.append("turn")
                if let error = stand.startFails { throw error }
                stand.started.append((thread.id, text, agent.id))
                stand.whenAsked["turn"]?()
            },
            discardThread: { thread, _ in stand.discarded.append(thread.id) },
            signedIn: { stand.account },
            say: { stand.said.append($0) }
        ))
    }

    // MARK: - What is chosen

    func testTheAssetsOwnThreadAndItsAgentAreChosen_asTheCloudAppChooses() async {
        let stand = Stand()
        stand.threads = [thread("recent", agent: "scout"), thread("its-own", agent: "quill"), thread("older")]
        var sending = model(asset(thread: "its-own"), stand)
        XCTAssertTrue(sending.isLoading)
        XCTAssertFalse(sending.canSend)
        await sending.load(as: "ada")
        XCTAssertFalse(sending.isLoading)
        XCTAssertEqual(sending.threadID, "its-own", "The thread the asset was made in")
        XCTAssertEqual(sending.agentID, "quill", "And that thread's agent")
        XCTAssertFalse(sending.startsNewThread)
        XCTAssertTrue(sending.canSend)

        // Made in no thread that is still there: the first thread, and its agent; or the first agent.
        sending = model(asset(thread: "gone"), stand)
        await sending.load(as: "ada")
        XCTAssertEqual(sending.threadID, "recent")
        XCTAssertEqual(sending.agentID, "scout")
        stand.threads = [thread("older")]
        sending = model(asset(), stand)
        await sending.load(as: "ada")
        XCTAssertEqual(sending.threadID, "older")
        XCTAssertEqual(sending.agentID, "scout", "A thread of no agent's: the first agent")

        // No thread can take it: a new one is started.
        stand.threads = []
        sending = model(asset(), stand)
        await sending.load(as: "ada")
        XCTAssertTrue(sending.startsNewThread)
        XCTAssertNil(sending.threadID)
        XCTAssertTrue(sending.canSend)
        XCTAssertEqual(AssetHandoffModel.noThreads, "No thread can take this asset. Start a new one to continue.")
    }

    func testWhatCannotBeReadIsSaid_andOnlyTheLatestReadingIsTaken() async {
        let stand = Stand()
        stand.agents = nil
        let sending = model(asset(), stand)
        await sending.load(as: "ada")
        XCTAssertEqual(sending.failure, "Couldn't load the agents and threads. Try again.")
        XCTAssertEqual(stand.said, [AssetHandoffModel.couldNotLoad], "Told to VoiceOver too")
        XCTAssertFalse(sending.canSend)
        XCTAssertFalse(sending.hasRead, "Nothing is said of what threads there are: they were not read")
        XCTAssertFalse(sending.startsNewThread)
        stand.agents = [.init(id: "scout", name: "Scout")]
        stand.threadsFail = true
        await sending.load(as: "ada")
        XCTAssertEqual(sending.failure, AssetHandoffModel.couldNotLoad)
        XCTAssertFalse(sending.hasRead)
        // Read again, as the sheet offers: what there is is then shown and chosen.
        stand.threadsFail = false
        await sending.load(as: "ada")
        XCTAssertNil(sending.failure)
        XCTAssertTrue(sending.hasRead)
        XCTAssertEqual(sending.agents.map(\.id), ["scout"])
        XCTAssertTrue(sending.startsNewThread, "No thread, read as none")
        XCTAssertTrue(sending.canSend)

        // Nothing read for an account that is no longer signed in is taken.
        let other = model(asset(), stand)
        stand.account = "grace"
        await other.load(as: "ada")
        XCTAssertEqual(other.agents, [])
        XCTAssertTrue(other.isLoading)
    }

    func testAnAgentThatIsNotGivenTheAssetToolsIsNotSentAnAsset() async {
        let stand = Stand()
        stand.agents = [.init(id: "local", name: "Pip", tools: .notOffered), .init(id: "scout", name: "Scout"), .init(id: "lost", name: "Wren", tools: .unknown)]
        let sending = model(asset(), stand)
        await sending.load(as: "ada")
        XCTAssertEqual(sending.agentID, "local")
        XCTAssertFalse(sending.canSend)
        let note = "Pip can't open assets: only an agent that runs on a cloud model is given the asset tools. Choose another agent."
        XCTAssertEqual(sending.agentNote, note)
        XCTAssertEqual(stand.said, [note], "Told to VoiceOver as the agent is chosen: it is why Send is off")
        XCTAssertFalse(sending.offersTryAgain)
        let sent = await sending.send(as: "ada")
        XCTAssertNil(sent)
        XCTAssertEqual(stand.steps, [], "Nothing is made for it")
        XCTAssertNil(sending.failure, "Said under the agent, once")
        sending.agentID = "scout"
        XCTAssertNil(sending.agentNote)
        XCTAssertTrue(sending.canSend)

        // An agent no model could be found for (nothing connected, or the connections could not be read):
        // that says nothing of where it runs, and reading again can find one.
        sending.agentID = "lost"
        XCTAssertEqual(sending.agentNote, "AICoven couldn't find a model to answer for Wren just now. Check your AI connections, or try again.")
        XCTAssertTrue(sending.offersTryAgain)
        XCTAssertFalse(sending.canSend)
        stand.agents = [.init(id: "local", name: "Pip", tools: .notOffered), .init(id: "scout", name: "Scout"), .init(id: "lost", name: "Wren")]
        await sending.load(as: "ada")
        XCTAssertEqual(sending.agentID, "lost", "The choice is kept")
        XCTAssertNil(sending.agentNote)
        XCTAssertTrue(sending.canSend)
        XCTAssertEqual(AssetHandoffModel.Agent.Tools(nil), .unknown)
        XCTAssertEqual(AssetHandoffModel.Agent.Tools(false), .notOffered)
        XCTAssertEqual(AssetHandoffModel.Agent.Tools(true), .offered)

        // Which turns are given the place's tools, as the chat service decides for an agent as it is set up.
        final class Silent: LLMClient, @unchecked Sendable {
            func completeChat(messages _: [LLMMessage], model: String, options _: ChatOptions) async throws -> LLMChatResponse {
                LLMChatResponse(message: LLMMessage(role: .assistant, content: ""), providerID: "test", modelID: model, usage: nil)
            }

            func embed(texts: [String], model _: String) async throws -> [[Float]] {
                Array(repeating: [0], count: texts.count)
            }
        }
        func chat(answeredBy provider: String?) -> ChatService {
            ChatService(
                contextBuilder: ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4)),
                modelRouter: HeuristicModelRouter(availableModels: provider.map { [ModelDescriptor(
                    providerID: $0, modelID: "model", maxContextTokens: 128_000, supportsTools: false, supportsEmbeddings: false, costClass: .cheap
                )] } ?? []),
                llmClients: provider.map { [$0: Silent()] } ?? [:],
                threadStore: ThreadRepository.shared,
                toolService: ToolService.shared,
                shouldAutoRefreshEnvironment: false,
                hermesAgent: { nil },
                openClawTurn: { _ in nil }
            )
        }
        let account = UserScope.currentUserID
        let offeredByACloudModel = await chat(answeredBy: "anthropic").offersPlaceTools(toAgents: [nil, "no-such-agent"], as: account)
        XCTAssertEqual(offeredByACloudModel, [true, true], "Strix and an agent that falls back to the one model there is")
        let offeredOnThisDevice = await chat(answeredBy: "mlx").offersPlaceTools(toAgents: [nil], as: account)
        XCTAssertEqual(offeredOnThisDevice, [false])
        let offeredByNothing = await chat(answeredBy: nil).offersPlaceTools(toAgents: [nil], as: account)
        XCTAssertEqual(offeredByNothing, [nil], "No model can be found to answer: that says nothing of where the agent runs")
        let asAnother = await chat(answeredBy: "anthropic").offersPlaceTools(toAgents: [nil], as: "someone-else")
        XCTAssertNil(asAnother, "Nothing is answered for an account that is not the one signed in")

        XCTAssertTrue(ChatService.givesPlaceTools(provider: "anthropic", isLocal: false))
        XCTAssertTrue(ChatService.givesPlaceTools(provider: "openai_compatible", isLocal: false))
        XCTAssertFalse(ChatService.givesPlaceTools(provider: "openai_compatible", isLocal: true), "A server on this network")
        XCTAssertFalse(ChatService.givesPlaceTools(provider: "mlx", isLocal: true))
        XCTAssertFalse(ChatService.givesPlaceTools(provider: "hermes", isLocal: false))
        XCTAssertFalse(ChatService.givesPlaceTools(provider: "OpenClaw", isLocal: false))
    }

    // MARK: - Sending

    func testAnAssetIsSentInAThreadOfItsPlace_withTheBriefMadeFirst() async {
        let stand = Stand()
        stand.threads = [thread("its-own", agent: "quill")]
        let sending = model(asset(.approved, thread: "its-own"), stand)
        await sending.load(as: "ada")
        sending.agentID = "scout"
        sending.direction = "  Build it for the web first.\n"
        let sent = await sending.send(as: "ada")
        XCTAssertEqual(sent?.id, "its-own", "The thread to open")
        XCTAssertEqual(stand.steps, ["reads", "brief", "turn"])
        XCTAssertEqual(stand.busyAsked, ["its-own", "its-own"], "Asked before anything is made, and again before the turn is started")
        XCTAssertEqual(stand.briefsAsked.first?.assetID, "logo")
        XCTAssertEqual(stand.briefsAsked.first?.account, "ada")
        XCTAssertEqual(stand.started.first?.threadID, "its-own")
        XCTAssertEqual(stand.started.first?.agent, "scout", "Answered by the agent chosen, whoever the thread's own is")
        XCTAssertEqual(stand.started.first?.text, """
        You are receiving an AICoven asset handoff.

        Implementation brief asset: brief
        Source asset: logo
        Source review state: APPROVED.

        Use asset.get to inspect the brief, source asset, files, relations,
        acceptance criteria, and constraints before making changes.
        Do not assume access to external systems that AICoven has not provided.

        User direction:
        Build it for the web first.
        """, "As the cloud server writes it")
        XCTAssertNil(sending.failure)
        XCTAssertFalse(sending.isSending)
    }

    func testWhatTheAgentIsTold() {
        let proposed = AssetHandoffModel.message(briefID: "b", sourceID: "s", isApproved: false, direction: "  ")
        XCTAssertTrue(proposed.contains("Source review state: PROPOSED — this source has not been approved."))
        XCTAssertFalse(proposed.contains("User direction"), "Nothing added says nothing")
        XCTAssertTrue(proposed.hasSuffix("Do not assume access to external systems that AICoven has not provided."))
        // It names the tool it is read with, so the turn is given its tools whatever the person adds.
        for direction in ["", "Draft the plan and explain it.", "Summarize what changed, thanks"] {
            let message = AssetHandoffModel.message(briefID: "b", sourceID: "s", isApproved: true, direction: direction)
            guard case .useTools = ToolIntentDecision.heuristic(for: message) else {
                XCTFail("The turn would get no tools: \(direction)")
                continue
            }
        }
        guard case .noTools = ToolIntentDecision.heuristic(for: "Draft the plan and explain it.") else {
            XCTFail("Words alone are still read as before")
            return
        }
    }

    func testANewThreadIsMadeForTheAgentChosen_namedAsThePersonSaysOrAsTheCloudAppNamesIt() async {
        let stand = Stand()
        stand.threads = [thread("its-own", agent: "quill")]
        stand.sourceStatus = .proposed
        var sending = model(asset(.proposed, coven: "work"), stand)
        await sending.load(as: "ada")
        sending.startsNewThread = true
        sending.agentID = "quill"
        var sent = await sending.send(as: "ada")
        XCTAssertEqual(sent?.id, "made-1")
        XCTAssertEqual(stand.steps, ["reads", "brief", "thread", "turn"], "The brief first: a thread is made only for an asset that is handed over")
        XCTAssertEqual(stand.madeThreads.first?.title, "Asset handoff")
        XCTAssertEqual(stand.madeThreads.first?.covenID, "work", "In the asset's place")
        XCTAssertEqual(stand.madeThreads.first?.agent, "quill")
        XCTAssertEqual(stand.started.first?.threadID, "made-1")
        XCTAssertTrue(stand.started.first?.text.contains("PROPOSED — this source has not been approved.") == true)

        sending = model(asset(), stand)
        await sending.load(as: "ada")
        sending.startsNewThread = true
        sending.newThreadTitle = "  Logo   build "
        sent = await sending.send(as: "ada")
        XCTAssertEqual(stand.madeThreads.last?.title, "Logo build")

        // In Strix's place, and in a coven with no agents, Strix is sent it.
        stand.agents = [.init(id: AssetHandoffModel.Agent.strixID, name: "Strix")]
        stand.threads = []
        sending = model(asset(coven: nil), stand)
        await sending.load(as: "ada")
        sent = await sending.send(as: "ada")
        XCTAssertNil(stand.madeThreads.last?.covenID)
        XCTAssertEqual(stand.started.last?.agent, AssetHandoffModel.Agent.strixID)
        XCTAssertTrue(sending.agent?.isStrix == true)
    }

    func testAThreadWhoseAgentIsStillWorkingIsNotSentInto() async {
        let stand = Stand()
        stand.threads = [thread("its-own", agent: "scout")]
        stand.busy = ["its-own"]
        let sending = model(asset(thread: "its-own"), stand)
        await sending.load(as: "ada")
        var sent = await sending.send(as: "ada")
        XCTAssertNil(sent)
        XCTAssertEqual(
            sending.failure, "This thread's agent is still working. Start a new thread to send it now, or send it again once the agent finishes."
        )
        XCTAssertEqual(stand.steps, [], "Nothing is made for it")
        XCTAssertEqual(stand.said.last, AssetHandoffModel.threadIsBusy)

        // One that starts while the brief is made is not sent into either.
        stand.busy = []
        stand.whenAsked["brief"] = { stand.busy = ["its-own"] }
        sent = await sending.send(as: "ada")
        XCTAssertNil(sent)
        XCTAssertEqual(stand.steps, ["reads", "brief"])
        XCTAssertEqual(sending.failure, AssetHandoffModel.threadIsBusy)
        // One that starts between the last look and the start is refused by the engine: said in the same words.
        stand.busy = []
        stand.whenAsked["brief"] = nil
        stand.startFails = TurnEngine.TurnError.alreadyRunning
        sent = await sending.send(as: "ada")
        XCTAssertNil(sent)
        XCTAssertEqual(sending.failure, AssetHandoffModel.threadIsBusy)
        stand.startFails = nil
        // A new thread is the way round it.
        sending.startsNewThread = true
        sent = await sending.send(as: "ada")
        XCTAssertEqual(sent?.id, "made-1")
        XCTAssertNil(sending.failure)
    }

    func testWhatGoesWrongIsSaidInTheCloudAppsWords_andAThreadMadeForNothingIsDeleted() async {
        let stand = Stand()
        let sending = model(asset(), stand)
        await sending.load(as: "ada")
        XCTAssertTrue(sending.startsNewThread)

        // No longer proposed or approved, gone, or locked: it cannot be sent.
        for refusal in [AssetError.needsReview, .noSuchAsset, .unreadable] {
            stand.briefFails = refusal
            let sent = await sending.send(as: "ada")
            XCTAssertNil(sent)
            XCTAssertEqual(sending.failure, "This asset can't be sent to an agent anymore.", "\(refusal)")
        }
        XCTAssertEqual(stand.madeThreads.count, 0, "No thread is made for an asset that is not handed over")

        // The thread cannot be made, or the turn cannot be started.
        stand.briefFails = nil
        stand.threadFails = RepositoryError.databaseUnavailable
        var sent = await sending.send(as: "ada")
        XCTAssertNil(sent)
        XCTAssertEqual(sending.failure, "AICoven could not confirm the handoff. Try again.")
        stand.threadFails = nil
        stand.startFails = RepositoryError.databaseUnavailable
        sent = await sending.send(as: "ada")
        XCTAssertNil(sent)
        XCTAssertEqual(sending.failure, AssetHandoffModel.notConfirmed)
        XCTAssertEqual(stand.discarded, ["made-1"], "The thread made for it is deleted again")
        XCTAssertEqual(stand.said.last, AssetHandoffModel.notConfirmed)

        // Sent once it can be.
        stand.startFails = nil
        sent = await sending.send(as: "ada")
        XCTAssertEqual(sent?.id, "made-2")
        XCTAssertNil(sending.failure)
        XCTAssertEqual(stand.discarded, ["made-1"])
    }

    func testNothingMoreIsDoneOrSaidOnceAnotherAccountHasSignedIn() async {
        for step in ["reads", "brief", "thread", "turn"] {
            let stand = Stand()
            let sending = model(asset(), stand)
            await sending.load(as: "ada")
            stand.whenAsked[step] = { stand.account = "grace" }
            let sent = await sending.send(as: "ada")
            XCTAssertNil(sent, "No thread is opened for another account (\(step))")
            XCTAssertNil(sending.failure, step)
            XCTAssertEqual(stand.said, [], step)
            switch step {
            case "reads": XCTAssertEqual(stand.steps, ["reads"], "No brief is made")
            case "brief": XCTAssertEqual(stand.steps, ["reads", "brief"], "No thread is made")
            case "thread": XCTAssertEqual(stand.steps, ["reads", "brief", "thread"], "No turn is started")
            default: XCTAssertEqual(stand.steps, ["reads", "brief", "thread", "turn"])
            }
        }
        // Signed in while the thread was looked at, the first time or the second: nothing more is done, though it is not busy.
        for look in [1, 2] {
            let stand = Stand()
            stand.threads = [thread("its-own")]
            let sending = model(asset(thread: "its-own"), stand)
            await sending.load(as: "ada")
            stand.whenBusyAsked[look] = { stand.account = "grace" }
            let sent = await sending.send(as: "ada")
            XCTAssertNil(sent, "\(look)")
            XCTAssertEqual(stand.started.count, 0, "No turn is started for another account (\(look))")
            XCTAssertEqual(stand.steps, look == 1 ? [] : ["reads", "brief"])
            XCTAssertNil(sending.failure)
            XCTAssertEqual(stand.said, [])
        }
        // Signed in before Send's task began: nothing is looked at or said, though the thread chosen is busy.
        let late = Stand()
        late.threads = [thread("its-own")]
        late.busy = ["its-own"]
        let pressed = model(asset(thread: "its-own"), late)
        await pressed.load(as: "ada")
        late.account = "grace"
        let sentLate = await pressed.send(as: "ada")
        XCTAssertNil(sentLate)
        XCTAssertEqual(late.busyAsked, [])
        XCTAssertEqual(late.said, [])
        XCTAssertNil(pressed.failure)
        // A failure after the account changed is not said to the next account either.
        let stand = Stand()
        let sending = model(asset(), stand)
        await sending.load(as: "ada")
        stand.whenAsked["thread"] = { stand.account = "grace" }
        stand.startFails = RepositoryError.accountChanged
        _ = await sending.send(as: "ada")
        XCTAssertNil(sending.failure)
    }

    func testAnAssetIsSentAsItStandsNow_notAsTheSheetReadIt() async {
        // Archived or sent back since the sheet was opened: it has a brief, and is not sent on.
        for status in [AssetStatus.archived, .draft] {
            let stand = Stand()
            stand.sourceStatus = status
            let sending = model(asset(.approved), stand)
            await sending.load(as: "ada")
            let sent = await sending.send(as: "ada")
            XCTAssertNil(sent, "\(status)")
            XCTAssertEqual(sending.failure, AssetHandoffModel.cannotBeSent)
            XCTAssertEqual(stand.steps, ["reads", "brief"], "No thread is made and no turn started")
        }
        // Approved since it was listed as proposed, and the other way round: the agent is told how it stands now.
        for (listed, now, words) in [
            (AssetStatus.proposed, AssetStatus.approved, "Source review state: APPROVED."),
            (.approved, .proposed, "Source review state: PROPOSED — this source has not been approved."),
        ] {
            let stand = Stand()
            stand.sourceStatus = now
            let sending = model(asset(listed), stand)
            await sending.load(as: "ada")
            _ = await sending.send(as: "ada")
            XCTAssertTrue(stand.started.first?.text.contains(words) == true, "\(listed) listed, \(now) now")
        }
        // An agent set up otherwise since the sheet read it is not sent the asset, and the sheet says so from then on.
        let stand = Stand()
        stand.noLongerReads = ["scout"]
        let sending = model(asset(), stand)
        await sending.load(as: "ada")
        XCTAssertTrue(sending.canSend)
        let sent = await sending.send(as: "ada")
        XCTAssertNil(sent)
        XCTAssertEqual(stand.steps, ["reads"], "Nothing is made for it")
        XCTAssertEqual(sending.agentNote, AssetHandoffModel.cannotRead(.init(id: "scout", name: "Scout")))
        XCTAssertEqual(stand.said.last, sending.agentNote)
        XCTAssertNil(sending.failure, "Said under the agent, once")
        XCTAssertFalse(sending.canSend)
        // Or no model can be found for it by then (the device went offline): said as that, with the way to read again.
        let offline = Stand()
        offline.noModelFor = ["scout"]
        let later = model(asset(), offline)
        await later.load(as: "ada")
        let notSent = await later.send(as: "ada")
        XCTAssertNil(notSent)
        XCTAssertEqual(later.agentNote, AssetHandoffModel.cannotTell(.init(id: "scout", name: "Scout")))
        XCTAssertTrue(later.offersTryAgain)
        XCTAssertEqual(offline.steps, ["reads"])
    }

    func testAChoiceChangedTakesAwayWhatWasSaidOfTheChoiceBefore() async {
        let stand = Stand()
        stand.threads = [thread("its-own", agent: "scout"), thread("other")]
        stand.busy = ["its-own"]
        let sending = model(asset(thread: "its-own"), stand)
        await sending.load(as: "ada")
        _ = await sending.send(as: "ada")
        XCTAssertEqual(sending.failure, AssetHandoffModel.threadIsBusy)
        sending.threadID = "other"
        XCTAssertNil(sending.failure, "Said of the thread chosen before")
        sending.threadID = "its-own"
        _ = await sending.send(as: "ada")
        XCTAssertNotNil(sending.failure)
        sending.startsNewThread = true
        XCTAssertNil(sending.failure)
        sending.startsNewThread = false
        _ = await sending.send(as: "ada")
        XCTAssertNotNil(sending.failure)
        sending.agentID = "quill"
        XCTAssertNil(sending.failure)
    }

    func testOnlyTheLatestReadingIsTaken_andOneSendingAtATime() async {
        // Two readings under way: the earlier one, landing last, is not taken over the later one.
        let stand = Stand()
        let (first, second) = (Gate(), Gate())
        stand.agentsWaits = [first, second]
        stand.agents = [.init(id: "old", name: "Old")]
        let sending = model(asset(), stand)
        let early = Task { await sending.load(as: "ada") }
        await first.arrived()
        stand.agents = [.init(id: "new", name: "New")]
        let later = Task { await sending.load(as: "ada") }
        await second.arrived()
        // The later one lands first, and is what the sheet shows.
        await second.open()
        await later.value
        XCTAssertEqual(sending.agents.map(\.id), ["new"])
        XCTAssertEqual(sending.agentID, "new")
        XCTAssertFalse(sending.isLoading, "Read, though the earlier reading is still under way")
        await first.open()
        await early.value
        XCTAssertEqual(sending.agents.map(\.id), ["new"], "The earlier one, landing last, is not taken over it")
        XCTAssertFalse(sending.isLoading)

        // A second Send while one is on its way does nothing.
        let making = Gate()
        stand.briefWaits = making
        let sendingFirst = Task { await sending.send(as: "ada") }
        await making.arrived()
        XCTAssertTrue(sending.isSending)
        XCTAssertFalse(sending.canSend)
        let again = await sending.send(as: "ada")
        XCTAssertNil(again)
        XCTAssertNil(sending.failure, "Nor is anything said of it")
        await making.open()
        let sent = await sendingFirst.value
        XCTAssertEqual(sent?.id, "made-1")
        XCTAssertEqual(stand.started.count, 1)
        XCTAssertEqual(stand.madeThreads.count, 1)
        XCTAssertFalse(sending.isSending)
    }

    func testAToolIsNamedByItsWholeName() {
        XCTAssertTrue(ToolIntentDecision.names("asset.get", in: "use asset.get to read it"))
        XCTAssertTrue(ToolIntentDecision.names("asset.get", in: "read it with asset.get."))
        XCTAssertTrue(ToolIntentDecision.names("asset.get", in: "(asset.get)"))
        XCTAssertFalse(ToolIntentDecision.names("asset.get", in: "an asset.getter"))
        XCTAssertFalse(ToolIntentDecision.names("asset.get", in: "asset.get.all"))
        XCTAssertFalse(ToolIntentDecision.names("file.read", in: "explain how file.reading works"))
        XCTAssertFalse(ToolIntentDecision.names("file.read", in: "my.file.read"))
        XCTAssertFalse(ToolIntentDecision.names("web_search", in: "a web_searching habit"))
        XCTAssertFalse(ToolIntentDecision.names("file.read", in: "how file.read-extra would open it"))
        XCTAssertFalse(ToolIntentDecision.names("file.read", in: "the other-file.read helper"))
        XCTAssertTrue(ToolIntentDecision.names("file.read", in: "file.read - then tell me"), "A hyphen that joins nothing")
        XCTAssertTrue(ToolIntentDecision.names("file.read", in: "file.reading is not file.read"), "A later whole mention counts")
        guard case .noTools = ToolIntentDecision.heuristic(for: "Explain how file.reading would open the file /tmp/example") else {
            XCTFail("A longer name names no tool")
            return
        }
    }

    // MARK: - Offered

    func testOnlyAnAssetThatIsProposedOrApprovedAndCanBeOpenedIsSentToAnAgent() {
        XCTAssertEqual(AssetAction.sendToAgent.title, "Send to Agent…")
        XCTAssertNil(AssetAction.sendToAgent.status, "It moves no status")
        for (status, offered) in [(AssetStatus.draft, false), (.proposed, true), (.approved, true), (.archived, false)] {
            XCTAssertEqual(AssetLibraryRules.otherActions(asset(status)).contains(.sendToAgent), offered, "\(status)")
            XCTAssertFalse(AssetLibraryRules.otherActions(asset(status, unreadable: true)).contains(.sendToAgent))
        }
        XCTAssertEqual(AssetLibraryRules.otherActions(asset(.approved)).first, .sendToAgent, "Before Download… and Archive")
    }
}
