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

    private func model(_ asset: Asset, _ stand: Stand) -> AssetHandoffModel {
        AssetHandoffModel(asset: asset, hands: AssetHandoffModel.Hands(
            agents: { _, _ in stand.agents },
            threads: { _, _ in
                if stand.threadsFail { throw RepositoryError.databaseUnavailable }
                return stand.threads
            },
            isBusy: { stand.busy.contains($0) },
            brief: { assetID, account in
                stand.steps.append("brief")
                stand.briefsAsked.append((assetID, account))
                if let error = stand.briefFails { throw error }
                stand.whenAsked["brief"]?()
                return Asset(
                    id: "brief", covenID: nil, type: .implementationBrief, status: .draft, title: "Handoff: Logo", details: "", madeByAgentID: nil,
                    threadID: nil, sourceMessageID: nil, parentID: assetID, files: [], createdAt: Date(), updatedAt: Date()
                )
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
        stand.agents = [.init(id: "scout", name: "Scout")]
        stand.threadsFail = true
        await sending.load(as: "ada")
        XCTAssertEqual(sending.failure, AssetHandoffModel.couldNotLoad)
        stand.threadsFail = false
        await sending.load(as: "ada")
        XCTAssertNil(sending.failure)
        XCTAssertEqual(sending.agents.map(\.id), ["scout"])

        // Nothing read for an account that is no longer signed in is taken.
        let other = model(asset(), stand)
        stand.account = "grace"
        await other.load(as: "ada")
        XCTAssertEqual(other.agents, [])
        XCTAssertTrue(other.isLoading)
    }

    func testAnAgentThatIsNotGivenTheAssetToolsIsNotSentAnAsset() async {
        let stand = Stand()
        stand.agents = [.init(id: "local", name: "Pip", readsAssets: false), .init(id: "scout", name: "Scout")]
        let sending = model(asset(), stand)
        await sending.load(as: "ada")
        XCTAssertEqual(sending.agentID, "local")
        XCTAssertFalse(sending.canSend)
        XCTAssertEqual(
            sending.agentNote,
            "Pip can't open assets: only an agent that runs on a cloud model is given the asset tools. Choose another agent."
        )
        let sent = await sending.send(as: "ada")
        XCTAssertNil(sent)
        XCTAssertEqual(stand.steps, [], "Nothing is made for it")
        XCTAssertEqual(sending.failure, sending.agentNote)
        sending.agentID = "scout"
        XCTAssertNil(sending.agentNote)
        XCTAssertTrue(sending.canSend)

        // Which turns are given the place's tools.
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
        XCTAssertEqual(stand.steps, ["brief", "turn"])
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
        var sending = model(asset(.proposed, coven: "work"), stand)
        await sending.load(as: "ada")
        sending.startsNewThread = true
        sending.agentID = "quill"
        var sent = await sending.send(as: "ada")
        XCTAssertEqual(sent?.id, "made-1")
        XCTAssertEqual(stand.steps, ["brief", "thread", "turn"], "The brief first: a thread is made only for an asset that is handed over")
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
        XCTAssertEqual(stand.steps, ["brief"])
        XCTAssertEqual(sending.failure, AssetHandoffModel.threadIsBusy)
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
        stand.startFails = TurnEngine.TurnError.alreadyRunning
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
        for step in ["brief", "thread", "turn"] {
            let stand = Stand()
            let sending = model(asset(), stand)
            await sending.load(as: "ada")
            stand.whenAsked[step] = { stand.account = "grace" }
            let sent = await sending.send(as: "ada")
            XCTAssertNil(sent, "No thread is opened for another account (\(step))")
            XCTAssertNil(sending.failure, step)
            XCTAssertEqual(stand.said, [], step)
            switch step {
            case "brief": XCTAssertEqual(stand.steps, ["brief"], "No thread is made")
            case "thread": XCTAssertEqual(stand.steps, ["brief", "thread"], "No turn is started")
            default: XCTAssertEqual(stand.steps, ["brief", "thread", "turn"])
            }
        }
        // A failure after the account changed is not said to the next account either.
        let stand = Stand()
        let sending = model(asset(), stand)
        await sending.load(as: "ada")
        stand.whenAsked["thread"] = { stand.account = "grace" }
        stand.startFails = RepositoryError.accountChanged
        _ = await sending.send(as: "ada")
        XCTAssertNil(sending.failure)
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
