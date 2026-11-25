@testable import AICoven
import XCTest

/// An asset's card in the thread it was made in: which assets a reply
/// shows, what a card says, approving from it, and the way to the asset.
@MainActor
final class AssetCardsTests: XCTestCase {
    private func asset(
        _ id: String, _ title: String = "Launch brief", status: AssetStatus = .proposed, files: Int = 1, coven: String? = nil, agent: String? = "scout",
        unreadable: Bool = false, version: String = "v1"
    ) -> Asset {
        Asset(
            id: id, covenID: coven, type: .implementationBrief, status: status, title: title, details: "", madeByAgentID: agent, threadID: "t",
            sourceMessageID: nil,
            files: (0 ..< files).map { AssetFile(id: "\(id)-\($0)", name: "f\($0).md", mimeType: "text/markdown", sizeBytes: 1) },
            isUnreadable: unreadable, version: version, createdAt: Date(), updatedAt: Date()
        )
    }

    // MARK: - What a reply keeps of the assets its turn made

    func testTheAssetsATurnMadeAreKeptWithItsReply_andReadBackInOrder() {
        var state = TurnState(answer: "Kept as an asset.", status: .completed, phase: .finalizing)
        state.madeAssets = ["a2", "a1"]
        var progress = TurnProgress(agentName: "Scout")
        progress.note(state)
        let reply = progress.ending(in: "t", thrown: nil).message
        XCTAssertEqual(Asset.ids(in: reply.metadata ?? [:]), ["a2", "a1"], "In the order they were made")

        // A reply whose turn made none says nothing of assets.
        var other = TurnProgress(agentName: nil)
        other.note(TurnState(answer: "Nothing made.", status: .completed, phase: .finalizing))
        XCTAssertNil(other.ending(in: "t", thrown: nil).message.metadata?[Asset.messageMetadataKey])

        // What is read from a stored message is ids only, each once.
        XCTAssertEqual(Asset.ids(in: [:]), [])
        XCTAssertEqual(Asset.ids(in: [Asset.messageMetadataKey: .string("a1")]), [], "Not a list")
        XCTAssertEqual(
            Asset.ids(in: [Asset.messageMetadataKey: .array([.string("a1"), .int(3), .string(""), .string("a1"), .string("a2")])]), ["a1", "a2"]
        )
    }

    func testAStoredReplyShowsItsAssets() {
        let message = ChatMessage(
            id: "m1", threadId: "t", role: "assistant", content: "Kept.",
            metadata: [Asset.messageMetadataKey: .array([.string("a1"), .string("a2")])], tokenUsage: nil, createdAt: Date(), isEncrypted: false,
            keyFingerprint: nil
        )
        XCTAssertEqual(MessageAdapter.toEnhanced(from: message, response: nil).assetIDs, ["a1", "a2"])
        // And the thread shows them: its bubbles' messages keep the ids (#228 had them dropped there).
        let shown = PersonalChatView.shown([message, message], agentName: "Scout")
        XCTAssertEqual(shown.map(\.assetIDs), [["a1", "a2"], ["a1", "a2"]])
        XCTAssertEqual(shown.map(\.id), [message.id, "\(message.id)-dup1"])
        XCTAssertEqual(shown.first?.agentRole, "Scout", "The thread's agent, where the message names none")
        let plain = ChatMessage(
            id: "m2", threadId: "t", role: "assistant", content: "Nothing.", metadata: nil, tokenUsage: nil, createdAt: Date(), isEncrypted: false,
            keyFingerprint: nil
        )
        XCTAssertEqual(MessageAdapter.toEnhanced(from: plain, response: nil).assetIDs, [])
    }

    // MARK: - What a card says

    func testWhatACardSays_andWhoMadeAnAsset() {
        XCTAssertEqual(AssetLibraryRules.cardLine(asset("a")), "Proposed · Implementation Brief · 1 file")
        XCTAssertEqual(AssetLibraryRules.cardLine(asset("a", status: .approved, files: 3)), "Approved · Implementation Brief · 3 files")
        XCTAssertEqual(AssetLibraryRules.cardLine(asset("a", status: .draft, files: 0)), "Draft · Implementation Brief")
        XCTAssertEqual(AssetLibraryRules.cardLine(asset("a", unreadable: true)), "Locked · Implementation Brief")

        XCTAssertEqual(AssetLibraryRules.madeBy(asset("a", agent: nil)), "You")
        XCTAssertEqual(AssetLibraryRules.madeBy(asset("a", agent: "scout"), agents: ["scout": "Scout"]), "Scout, agent")
        XCTAssertEqual(AssetLibraryRules.madeBy(asset("a", agent: TurnAssets.strix)), "Strix, agent", "Strix is no stored agent")
        XCTAssertEqual(AssetLibraryRules.madeBy(asset("a", agent: "gone"), agents: ["scout": "Scout"]), "Agent", "An agent that is gone has no name left")
    }

    func testTheAgentsNamesStayAsLastReadWhenTheyCannotBeReadAgain() async {
        final class Names: @unchecked Sendable {
            var given: [String: String]? = ["scout": "Scout"]
        }
        let names = Names()
        let library = AssetLibraryModel(
            covenID: "work",
            source: AssetLibraryModel.Source(
                assets: { _, _ in [] }, create: { _, _, _ in throw AssetError.tooMany }, move: { _, _, _ in },
                agents: { _ in await MainActor.run { names.given } }
            ),
            signedIn: { "ada" }
        )
        await library.load()
        XCTAssertEqual(library.agents, ["scout": "Scout"])
        names.given = nil
        await library.load()
        XCTAssertEqual(library.agents, ["scout": "Scout"], "Not read this time: as they were")
        names.given = [:]
        await library.load()
        XCTAssertEqual(library.agents, [:], "Read, and there are none")

        XCTAssertEqual(AssetCardsView.name(of: asset("a", "Launch brief")), "Launch brief")
        XCTAssertEqual(AssetCardsView.name(of: asset("a", unreadable: true)), "the locked asset")
    }

    // MARK: - The cards' model

    /// What a source gives and was asked. Sendable by hand: used one step at a time.
    private final class Stand: @unchecked Sendable {
        var account = "ada"
        var readingWaits: Gate?
        var approvingWaits: Gate?
        var kept: [Asset] = []
        var asked: [(ids: [String], account: String)] = []
        var approved: [(id: String, version: String, account: String)] = []
        var approveFails: Error?
        var readFails = false
    }

    private func model(_ stand: Stand, ids: [String]) -> AssetCardsModel {
        AssetCardsModel(
            ids: ids,
            source: AssetCardsModel.Source(
                assets: { ids, account in
                    // What is kept is read as the reading is asked, and given once it is let through.
                    let read = try await MainActor.run {
                        stand.asked.append((ids, account))
                        if stand.readFails { throw RepositoryError.databaseUnavailable }
                        return ids.compactMap { id in stand.kept.first { $0.id == id } }
                    }
                    await MainActor.run { stand.readingWaits }?.wait()
                    return read
                },
                approve: { asset, account in
                    await MainActor.run { stand.approvingWaits }?.wait()
                    try await MainActor.run {
                        if let error = stand.approveFails { throw error }
                        stand.approved.append((asset.id, asset.version, account))
                        stand.kept = stand.kept.map { $0.id == asset.id ? self.asset($0.id, $0.title, status: .approved, version: $0.version) : $0 }
                    }
                }
            ),
            signedIn: { stand.account }
        )
    }

    func testTheCardsShowTheAssetsThatAreStillThere_asTheyAreNow() async {
        let stand = Stand()
        stand.kept = [asset("a1"), asset("a2", "Chart", status: .draft)]
        let cards = model(stand, ids: ["a1", "gone", "a2"])
        await cards.load()
        XCTAssertEqual(cards.assets.map(\.id), ["a1", "a2"], "One that is gone has no card")
        XCTAssertEqual(stand.asked.first?.ids, ["a1", "gone", "a2"])
        XCTAssertEqual(stand.asked.first?.account, "ada")

        // Read again, a card says how its asset stands now; a reading that fails leaves the cards as they were.
        stand.kept = [asset("a1", status: .approved)]
        await cards.load()
        XCTAssertEqual(cards.assets.map(\.status), [.approved])
        stand.readFails = true
        await cards.load()
        XCTAssertEqual(cards.assets.map(\.id), ["a1"])
    }

    func testAnAssetIsApprovedFromItsCard_asTheCardShowsIt_forWhoeverPressed() async {
        let stand = Stand()
        stand.kept = [asset("a1", version: "as-listed")]
        let cards = model(stand, ids: ["a1"])
        await cards.load()

        var told = 0
        let hearing = NotificationCenter.default.addObserver(forName: Asset.didChange, object: nil, queue: nil) { _ in told += 1 }
        defer { NotificationCenter.default.removeObserver(hearing) }
        await cards.approve(cards.assets[0], as: "ada")
        XCTAssertEqual(stand.approved.map(\.id), ["a1"])
        XCTAssertEqual(stand.approved.map(\.version), ["as-listed"], "As the card showed it")
        XCTAssertEqual(stand.approved.map(\.account), ["ada"])
        XCTAssertEqual(cards.assets.map(\.status), [.approved], "Read again")
        XCTAssertNil(cards.failure)
        XCTAssertEqual(cards.approving, [])
        XCTAssertEqual(told, 1, "Whatever else shows the asset is told")
        XCTAssertEqual(cards.said, AssetCardsModel.Said(number: 1, words: AssetCardsModel.approved), "And VoiceOver that it was approved")
    }

    func testOnlyTheLatestReadingOfTheCardsIsShown() async {
        let stand = Stand()
        let gate = Gate()
        stand.readingWaits = gate
        let cards = model(stand, ids: ["a1"])

        stand.kept = [asset("a1", status: .proposed)]
        let earlier = Task { await cards.load() }
        await gate.arrived(1)
        stand.kept = [asset("a1", status: .approved)]
        let later = Task { await cards.load() }
        await gate.arrived(2)

        await gate.letNewestThrough()
        await later.value
        XCTAssertEqual(cards.assets.map(\.status), [.approved])
        await gate.letOneThrough()
        await earlier.value
        XCTAssertEqual(cards.assets.map(\.status), [.approved], "A reading that lands after a later one is not shown over it")
    }

    func testAnAssetIsApprovedOnceAtATime_andNothingIsSaidToAnotherAccount() async {
        let stand = Stand()
        stand.kept = [asset("a1")]
        let cards = model(stand, ids: ["a1"])
        await cards.load()
        let listed = cards.assets[0]
        let gate = Gate()
        stand.approvingWaits = gate

        let first = Task { await cards.approve(listed, as: "ada") }
        await gate.arrived(1)
        XCTAssertEqual(cards.approving, ["a1"])
        await cards.approve(listed, as: "ada")
        XCTAssertEqual(stand.approved.count, 0, "A second press while the first is on its way does nothing")

        // Another account signs in before the approval lands: nothing is said or read for it.
        stand.account = "grace"
        let readings = stand.asked.count
        await gate.letOneThrough()
        await first.value
        XCTAssertEqual(stand.approved.map(\.account), ["ada"])
        XCTAssertNil(cards.said)
        XCTAssertNil(cards.failure)
        XCTAssertEqual(stand.asked.count, readings)
        XCTAssertEqual(cards.approving, [])
    }

    func testAnApprovalThatWasRefusedSaysWhy_toWhoeverPressed() async {
        let stand = Stand()
        stand.kept = [asset("a1")]
        let cards = model(stand, ids: ["a1"])
        await cards.load()
        let listed = cards.assets[0]

        for (error, words) in [
            (AssetError.changed as Error, AssetLibraryModel.changedMeanwhile), (AssetError.notAllowed, AssetLibraryModel.changedMeanwhile),
            (RepositoryError.dataLocked, AssetLibraryModel.needsUnlockToChange), (RepositoryError.databaseUnavailable, AssetCardsModel.couldNotApprove),
        ] {
            stand.approveFails = error
            await cards.approve(listed, as: "ada")
            XCTAssertEqual(cards.failure?.words, words, "\(error)")
            XCTAssertEqual(cards.failure?.assetID, "a1")
            XCTAssertEqual(cards.said?.words, words, "Said to VoiceOver too")
        }
        XCTAssertEqual(cards.said?.number, 4, "Each its own, so the same words twice are said twice")
        // An asset that is gone is not said to have failed; nor is anything said to another account.
        stand.approveFails = AssetError.noSuchAsset
        await cards.approve(listed, as: "ada")
        XCTAssertNil(cards.failure)
        stand.approveFails = RepositoryError.databaseUnavailable
        stand.account = "grace"
        await cards.approve(listed, as: "ada")
        XCTAssertNil(cards.failure)
        XCTAssertEqual(stand.approved.count, 0)
    }

    // MARK: - The way to the asset

    func testACardOpensItsAssetInTheAssetsOfWhereItIsKept_once() async {
        let navigator = ShellNavigator()
        navigator.open(.memoryList(covenId: nil))

        navigator.showAsset("a1", in: .coven("work"))
        XCTAssertEqual(navigator.selected, .coven("work"))
        XCTAssertEqual(navigator.place, .assets(covenId: "work"))
        XCTAssertEqual(navigator.sidebarItem, .assets)
        XCTAssertNil(navigator.takeAssetAsk(in: .strix), "Only the place that shows that scope's assets is asked")
        XCTAssertEqual(navigator.takeAssetAsk(in: .coven("work")), "a1")
        XCTAssertNil(navigator.takeAssetAsk(in: .coven("work")), "Once")

        navigator.showAsset("s1", in: .strix)
        XCTAssertEqual(navigator.place, .assets(covenId: nil))
        XCTAssertEqual(navigator.takeAssetAsk(in: .strix), "s1")
        // Freed inside a task: a main-actor object released outside one
        // aborts on macOS 15 (issue #61).
        await Task.yield()
    }

    func testAnAssetAskedForIsItsScopesOwn_andNoLongerAskedOnceThePersonHasGoneElsewhere() async {
        let navigator = ShellNavigator()
        // Asked of a coven's Assets; the person goes to Strix's Assets before the coven's are read.
        navigator.showAsset("a1", in: .coven("work"))
        navigator.open(.assets(covenId: nil), in: .strix)
        XCTAssertNil(navigator.takeAssetAsk(in: .strix), "Another scope's place does not take it")
        XCTAssertNil(navigator.assetAsked, "And it is no longer asked")
        navigator.open(.assets(covenId: "work"), in: .coven("work"))
        XCTAssertNil(navigator.takeAssetAsk(in: .coven("work")), "Also when the person comes back")

        // Asked for again, it is shown; a later ask takes an earlier one's place.
        navigator.showAsset("a1", in: .coven("work"))
        navigator.showAsset("a2", in: .coven("work"))
        XCTAssertEqual(navigator.takeAssetAsk(in: .coven("work")), "a2")
        // Freed inside a task: a main-actor object released outside one
        // aborts on macOS 15 (issue #61).
        await Task.yield()
    }

    // MARK: - The thread an asset was made in

    func testTheThreadAnAssetWasMadeInIsGoneOnlyWhereTheStoreSaysSo() async {
        func made(by account: String) -> AICoven.Thread {
            AICoven.Thread(id: "t", userId: account, covenId: nil, title: "Plans", createdAt: Date(timeIntervalSince1970: 0), updatedAt: nil, lastMessageAt: nil)
        }
        let thread = made(by: "ada")
        struct Failed: Error {}
        typealias Origin = AssetDetailView.Origin
        func origin(
            _ threadID: String? = "t", thread: @escaping (String) async throws -> AICoven.Thread, isThread: @escaping (String, String) async throws -> Bool,
            signedIn: String = "ada"
        ) async -> Origin? {
            await AssetDetailView.origin(ofThread: threadID, as: "ada", thread: thread, isThread: isThread, signedIn: { signedIn })
        }

        let found = await origin(thread: { _ in thread }, isThread: { _, _ in XCTFail("Not asked")
            return true
        })
        XCTAssertEqual(found, .thread(thread))
        let gone = await origin(thread: { _ in throw Failed() }, isThread: { id, account in
            XCTAssertEqual(id, "t")
            XCTAssertEqual(account, "ada")
            return false
        })
        XCTAssertEqual(gone, .gone, "The store says the account has no such thread")
        let notRead = await origin(thread: { _ in throw Failed() }, isThread: { _, _ in true })
        XCTAssertEqual(notRead, .unknown, "There, but it could not be read: nothing is said of a deletion")
        let unreadable = await origin(thread: { _ in throw Failed() }, isThread: { _, _ in throw Failed() })
        XCTAssertEqual(unreadable, .unknown, "Whether it is there could not be read either")
        let anothers = await origin(thread: { _ in made(by: "grace") }, isThread: { _, _ in false })
        XCTAssertEqual(anothers, .gone, "Another account's thread is no thread of this one's")
        let none = await origin(nil, thread: { _ in thread }, isThread: { _, _ in true })
        XCTAssertEqual(none, .unknown, "Made in no thread")
        let late = await origin(thread: { _ in thread }, isThread: { _, _ in true }, signedIn: "grace")
        XCTAssertNil(late, "Nothing is said once another account is signed in")
    }

    func testOnlyTheLatestLookupOfAnAssetsThreadIsShown() async {
        let thread = AICoven.Thread(
            id: "t", userId: "ada", covenId: nil, title: "Plans", createdAt: Date(timeIntervalSince1970: 0), updatedAt: nil, lastMessageAt: nil
        )
        let model = AssetOriginModel()
        let gate = Gate()

        // The page's first lookup reads the thread and is held; the thread is deleted and looked up again.
        let earlier = Task {
            await model.find {
                await gate.wait()
                return .thread(thread)
            }
        }
        await gate.arrived(1)
        await model.find { .gone }
        XCTAssertEqual(model.origin, .gone)
        await gate.letOneThrough()
        await earlier.value
        XCTAssertEqual(model.origin, .gone, "An earlier lookup landing late does not bring back the way to a deleted thread")

        // An answer that is not to be shown (another account by then) changes nothing; a later one is shown.
        await model.find { nil }
        XCTAssertEqual(model.origin, .gone)
        await model.find { .thread(thread) }
        XCTAssertEqual(model.origin, .thread(thread))
    }

    private actor Gate {
        private var held: [CheckedContinuation<Void, Never>] = []
        private var arrivals = 0
        private var hearing: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                held.append(continuation)
                arrivals += 1
                for heard in hearing where heard.count <= arrivals {
                    heard.continuation.resume()
                }
                hearing.removeAll { $0.count <= arrivals }
            }
        }

        /// Returns once `count` have come to wait.
        func arrived(_ count: Int) async {
            if arrivals >= count { return }
            await withCheckedContinuation { hearing.append((count, $0)) }
        }

        /// Lets the one who came first through.
        func letOneThrough() {
            if !held.isEmpty { held.removeFirst().resume() }
        }

        /// Lets the one who came last through, ahead of those before it.
        func letNewestThrough() {
            held.popLast()?.resume()
        }
    }
}
