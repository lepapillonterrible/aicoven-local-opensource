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

    // MARK: - The cards' model

    /// What a source gives and was asked. Sendable by hand: used one step at a time.
    private final class Stand: @unchecked Sendable {
        var account = "ada"
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
                    try await MainActor.run {
                        stand.asked.append((ids, account))
                        if stand.readFails { throw RepositoryError.databaseUnavailable }
                        return ids.compactMap { id in stand.kept.first { $0.id == id } }
                    }
                },
                approve: { asset, account in
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
        }
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

    func testACardOpensItsAssetInTheAssetsOfWhereItIsKept_once() {
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
    }
}
