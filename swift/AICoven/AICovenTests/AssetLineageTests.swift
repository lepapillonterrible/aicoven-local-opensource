@testable import AICoven
import GRDB
import XCTest

/// Where an asset came from: the asset it was made from, and its hand-off
/// brief, kept between assets of one account in one place.
@MainActor
final class AssetLineageTests: XCTestCase {
    private let store = AssetRepository.shared

    private var account: String {
        UserScope.currentUserID
    }

    override func setUp() async throws {
        try await super.setUp()
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        try await removeAll()
    }

    override func tearDown() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        try await removeAll()
        await DataEncryptionService.shared.lock()
        try await super.tearDown()
    }

    private func removeAll() async throws {
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let account = account
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM assets WHERE user_id IN (?, 'someone-else')", arguments: [account])
        }
    }

    /// A coven of the signed-in account's, deleted when the test ends.
    private func newCoven() async throws -> String {
        let coven = try await CovenService.shared.createCoven(name: "Lineage \(UUID().uuidString)")
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await CovenService.shared.deleteCoven(id: coven.id)
        }
        return coven.id
    }

    private func file(_ name: String) -> AssetRepository.NewFile {
        AssetRepository.NewFile(name: name, data: Data("bytes".utf8))
    }

    /// An asset of the account's with a file, moved to `status`.
    private func asset(_ title: String, _ status: AssetStatus = .proposed, inCoven coven: String? = nil) async throws -> Asset {
        let made = try await store.create(type: .designMockup, title: title, files: [file("m.svg")], inCoven: coven, as: account)
        if status == .draft { return made }
        _ = try await store.move(made.id, to: .proposed, as: account)
        if status != .proposed {
            let listed = try await store.assets(withIDs: [made.id], as: account)
            _ = try await store.move(made.id, to: status, listedAs: listed.first?.version, as: account)
        }
        let kept = try await store.assets(withIDs: [made.id], as: account)
        return try XCTUnwrap(kept.first)
    }

    private func expect(_ expected: AssetError, _ what: String, _ work: () async throws -> Void) async {
        do {
            try await work()
            XCTFail(what)
        } catch let error as AssetError {
            XCTAssertEqual(error, expected, what)
        } catch {
            XCTFail("\(what): \(type(of: error))")
        }
    }

    private func counts() async throws -> (assets: Int, relations: Int) {
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let account = account
        return try await queue.read { db in
            try (
                Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets WHERE user_id = ?", arguments: [account]) ?? -1,
                Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_relations WHERE user_id = ?", arguments: [account]) ?? -1
            )
        }
    }

    // MARK: - Made from

    func testAnAssetSaysWhatItWasMadeFrom_onlyAnAssetOfItsOwnPlace() async throws {
        let coven = try await newCoven()
        let logo = try await asset("Logo", .draft)
        let variant = try await store.create(type: .designMockup, title: "Logo, dark", files: [], inCoven: nil, parent: logo.id, as: account)
        XCTAssertEqual(variant.parentID, logo.id)
        let listed = try await store.assets(inCoven: nil, as: account)
        XCTAssertEqual(listed.first { $0.id == variant.id }?.parentID, logo.id)
        XCTAssertNil(listed.first { $0.id == logo.id }?.parentID)
        let related = try await store.relations(ofAsset: variant.id, as: account)
        XCTAssertEqual(related, [], "Made from is no relation, as in the cloud app")

        // Not from an asset of another place, of another account, or from none.
        let covens = try await asset("The coven's", .draft, inCoven: coven)
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        try await queue.write { db in
            try db.execute(sql: """
            INSERT INTO assets (id, user_id, coven_id, type, status, title_ciphertext, details_ciphertext, created_at, updated_at)
            VALUES ('theirs', 'someone-else', '', 'image', 'draft', x'00', x'00', 0, 0)
            """)
        }
        for parent in [covens.id, "theirs", "no-such-asset"] {
            await expect(.noSuchParent, parent) {
                _ = try await self.store.create(type: .image, title: "From elsewhere", files: [], inCoven: nil, parent: parent, as: self.account)
            }
        }
        // The store itself refuses such a row, whoever writes it.
        let account = account
        for (what, sql, arguments) in [
            ("made from another place's asset", "INSERT INTO assets (id, user_id, coven_id, type, status, title_ciphertext, details_ciphertext, parent_asset_id, created_at, updated_at) VALUES ('a-row', ?, '', 'image', 'draft', x'00', x'00', ?, 0, 0)", [account, covens.id]),
            ("made from another account's asset", "INSERT INTO assets (id, user_id, coven_id, type, status, title_ciphertext, details_ciphertext, parent_asset_id, created_at, updated_at) VALUES ('a-row', ?, '', 'image', 'draft', x'00', x'00', 'theirs', 0, 0)", [account]),
            ("given another place's asset as its parent", "UPDATE assets SET parent_asset_id = ? WHERE id = ?", [covens.id, logo.id]),
        ] as [(String, String, StatementArguments)] {
            do {
                try await queue.write { db in try db.execute(sql: sql, arguments: arguments) }
                XCTFail("A row \(what) is refused")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT, what)
            }
        }
        let after = try await counts()
        XCTAssertEqual(after.assets, 3, "The logo, its variant and the coven's")
    }

    // MARK: - The hand-off brief

    func testAnAssetThatIsProposedOrApprovedHasOneHandOffBrief_madeFromIt() async throws {
        let coven = try await newCoven()
        let logo = try await asset("Logo", .proposed, inCoven: coven)
        let made = try await store.handoffBrief(of: logo.id, madeBy: "scout", as: account)
        XCTAssertTrue(made.isNew)
        XCTAssertEqual(made.sourceStatus, .proposed, "How the asset stood in the write that made it")
        let brief = made.brief
        XCTAssertEqual(brief.title, "Handoff: Logo", "As the cloud app names it")
        XCTAssertEqual(brief.type, .implementationBrief)
        XCTAssertEqual(brief.status, .draft)
        XCTAssertEqual(brief.covenID, coven, "Kept where the asset is")
        XCTAssertEqual(brief.parentID, logo.id)
        XCTAssertEqual(brief.madeByAgentID, "scout")
        XCTAssertEqual(brief.files, [])

        // Related from either end, each naming the other.
        var ofTheBrief = try await store.relations(ofAsset: brief.id, as: account)
        XCTAssertEqual(ofTheBrief.map(\.kind), [AssetRelation.handoffFor])
        XCTAssertEqual(ofTheBrief.first?.fromAssetID, brief.id)
        XCTAssertEqual(ofTheBrief.first?.toAssetID, logo.id)
        XCTAssertEqual(ofTheBrief.first?.relatedID, logo.id)
        XCTAssertEqual(ofTheBrief.first?.line, "Handoff for Logo")
        let ofTheLogo = try await store.relations(ofAsset: logo.id, as: account)
        XCTAssertEqual(ofTheLogo.first?.relatedID, brief.id)
        XCTAssertEqual(ofTheLogo.first?.line, "Handoff for Handoff: Logo", "The cloud app's line, whichever end the asset is")

        // Asked for again, and once the asset is approved: the brief it has, whatever has become of it.
        _ = try await store.update(brief.id, title: "Build the logo", as: account)
        var again = try await store.handoffBrief(of: logo.id, as: account)
        XCTAssertFalse(again.isNew)
        XCTAssertEqual(again.brief.id, brief.id)
        XCTAssertEqual(again.brief.title, "Build the logo")
        let listed = try await store.assets(withIDs: [logo.id], as: account)
        _ = try await store.move(logo.id, to: .approved, listedAs: listed.first?.version, as: account)
        again = try await store.handoffBrief(of: logo.id, as: account)
        XCTAssertEqual(again.brief.id, brief.id)
        XCTAssertEqual(again.sourceStatus, .approved, "And how it stands now")
        let kept = try await counts()
        XCTAssertEqual(kept.assets, 2)
        XCTAssertEqual(kept.relations, 1)
        ofTheBrief = try await store.relations(ofAsset: brief.id, as: account)
        XCTAssertEqual(ofTheBrief.count, 1)
    }

    func testOnlyWhatIsProposedOrApprovedIsHandedOver_andOnlyTheAccountsOwn() async throws {
        let draft = try await asset("A draft", .draft)
        await expect(.needsReview, "A draft is not handed over") { _ = try await self.store.handoffBrief(of: draft.id, as: self.account) }
        let archived = try await asset("Archived", .archived)
        await expect(.needsReview, "Nor what is archived") { _ = try await self.store.handoffBrief(of: archived.id, as: self.account) }
        await expect(.noSuchAsset, "Nor what is not there") { _ = try await self.store.handoffBrief(of: "no-such-asset", as: self.account) }
        let approved = try await asset("Approved", .approved)
        let made = try await store.handoffBrief(of: approved.id, as: account)
        XCTAssertTrue(made.isNew)
        XCTAssertNil(made.brief.covenID, "With Strix's, where the asset is")
        XCTAssertNil(made.brief.madeByAgentID)

        // A long title is kept as a title is.
        let long = try await asset(String(repeating: "wide ", count: 60), .proposed)
        let brief = try await store.handoffBrief(of: long.id, as: account).brief
        XCTAssertEqual(brief.title.count, AssetRepository.longestTitle)
        XCTAssertTrue(brief.title.hasPrefix("Handoff: wide wide"))

        // Not as another account, nor while the data is locked.
        do {
            _ = try await store.handoffBrief(of: approved.id, as: "someone-else")
            XCTFail("Made as another account")
        } catch {}
        await DataEncryptionService.shared.lock()
        do {
            _ = try await store.handoffBrief(of: draft.id, as: account)
            XCTFail("Made while the data is locked")
        } catch RepositoryError.dataLocked {}
        do {
            _ = try await store.relations(ofAsset: approved.id, as: account)
            XCTFail("Read while the data is locked")
        } catch RepositoryError.dataLocked {}
    }

    func testTheBriefAnAssetHasIsItsAnswerAlsoWhereItsPlaceHasNoRoomForAnother() async throws {
        let logo = try await asset("Logo", .proposed)
        let brief = try await store.handoffBrief(of: logo.id, as: account).brief
        let unbriefed = try await asset("No brief yet", .proposed)
        // The place is filled to what it keeps.
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let account = account
        try await queue.write { db in
            for _ in 3 ..< AssetRepository.most {
                try db.execute(
                    sql: """
                    INSERT INTO assets (id, user_id, coven_id, type, status, title_ciphertext, details_ciphertext, created_at, updated_at)
                    VALUES (?, ?, '', 'image', 'draft', x'00', x'00', ?, ?)
                    """,
                    arguments: [UUID().uuidString, account, Date(), Date()]
                )
            }
        }
        let again = try await store.handoffBrief(of: logo.id, as: account)
        XCTAssertFalse(again.isNew)
        XCTAssertEqual(again.brief.id, brief.id)
        await expect(.tooMany, "A new brief is a new asset") { _ = try await self.store.handoffBrief(of: unbriefed.id, as: self.account) }
        // And once the asset is no longer proposed or approved: the brief it has is still the answer.
        _ = try await store.move(logo.id, to: .archived, as: account)
        let archived = try await store.handoffBrief(of: logo.id, as: account)
        XCTAssertEqual(archived.brief.id, brief.id)
        XCTAssertEqual(archived.sourceStatus, .archived, "Whoever sends it on is told that it is no longer for review")
    }

    func testAHandOffWrittenAfterTheDataWasLockedIsTakenBack_withItsRelation() async throws {
        let logo = try await asset("Logo", .proposed)
        // Locked once everything was sealed, before the write has its turn.
        let late = AssetRepository(at: { step in if step == .beforeWriting { await DataEncryptionService.shared.lock() } })
        do {
            _ = try await late.handoffBrief(of: logo.id, as: account)
            XCTFail("Nothing is made once the account's data is locked")
        } catch RepositoryError.dataLocked {}
        let kept = try await counts()
        XCTAssertEqual(kept.assets, 1, "The asset alone")
        XCTAssertEqual(kept.relations, 0)
    }

    func testARelationIsBetweenTwoAssetsOfOneAccountInOnePlace_writtenOnce_andGoesWithEither() async throws {
        let coven = try await newCoven()
        let logo = try await asset("Logo", .proposed, inCoven: coven)
        let brief = try await store.handoffBrief(of: logo.id, as: account).brief
        let strixs = try await asset("Strix's", .proposed)
        let other = try await asset("Another of the coven's", .draft, inCoven: coven)
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let account = account
        let insert = "INSERT INTO asset_relations (id, user_id, source_asset_id, target_asset_id, relation_type, created_at) VALUES ('a-row', ?, ?, ?, ?, 0)"
        for (what, sql, arguments) in [
            ("across places", insert, [account, strixs.id, logo.id, "references"]),
            ("of an asset to itself", insert, [account, logo.id, logo.id, "references"]),
            ("as another account's", insert, ["someone-else", other.id, logo.id, "references"]),
            ("as a second hand-off brief of one asset", insert, [account, other.id, logo.id, AssetRelation.handoffFor]),
            ("changed afterwards", "UPDATE asset_relations SET target_asset_id = ? WHERE source_asset_id = ?", [other.id, brief.id]),
            // An asset others were made from, or that is related to another, keeps its place.
            ("left across places by its asset moving", "UPDATE assets SET coven_id = '' WHERE id = ?", [logo.id]),
            ("left across places by its brief moving", "UPDATE assets SET coven_id = '' WHERE id = ?", [brief.id]),
        ] as [(String, String, StatementArguments)] {
            do {
                try await queue.write { db in try db.execute(sql: sql, arguments: arguments) }
                XCTFail("A relation \(what) is refused")
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT, what)
            }
        }
        var kept = try await counts()
        XCTAssertEqual(kept.relations, 1)
        // An asset that nothing was made from and that is related to nothing can still be moved by whoever writes the store.
        try await queue.write { db in try db.execute(sql: "UPDATE assets SET coven_id = '' WHERE id = ?", arguments: [other.id]) }

        // The asset a brief was made from is gone: the brief stays, made from nothing, and related to nothing.
        try await queue.write { db in try db.execute(sql: "DELETE FROM assets WHERE id = ?", arguments: [logo.id]) }
        let left = try await store.assets(withIDs: [brief.id], as: account)
        XCTAssertEqual(left.map(\.id), [brief.id])
        XCTAssertNil(left.first?.parentID)
        kept = try await counts()
        XCTAssertEqual(kept.relations, 0)

        // A coven that is deleted takes its assets and what related them.
        let second = try await asset("Second", .proposed, inCoven: coven)
        _ = try await store.handoffBrief(of: second.id, as: account)
        try await CovenService.shared.deleteCoven(id: coven)
        kept = try await counts()
        XCTAssertEqual(kept.assets, 2, "Strix's stay")
        XCTAssertEqual(kept.relations, 0)
    }

    func testARelatedAssetTheKeyCannotOpenIsNotNamed() async throws {
        let logo = try await asset("Logo", .proposed)
        let brief = try await store.handoffBrief(of: logo.id, as: account).brief
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        try await queue.write { db in try db.execute(sql: "UPDATE assets SET title_ciphertext = x'0102' WHERE id = ?", arguments: [logo.id]) }
        let related = try await store.relations(ofAsset: brief.id, as: account)
        XCTAssertNil(related.first?.relatedTitle)
        XCTAssertEqual(related.first?.line, "Handoff for another asset", "The cloud app's words for one it cannot name")
        XCTAssertEqual(AssetRelation(id: "r", fromAssetID: "a", toAssetID: "b", kind: "references", relatedID: "b", relatedTitle: "Tokens").line, "Related to Tokens")
        // An asset that cannot be opened is not handed over.
        await expect(.unreadable, "Handed over unseen") { _ = try await self.store.handoffBrief(of: logo.id, as: self.account) }

        // Nor is one named of which only something else cannot be opened: a listing gives it as unreadable, title and all.
        let mark = try await asset("Wordmark", .proposed)
        let second = try await store.handoffBrief(of: mark.id, as: account).brief
        try await queue.write { db in try db.execute(sql: "UPDATE assets SET details_ciphertext = x'0102' WHERE id = ?", arguments: [mark.id]) }
        let ofTheSecond = try await store.relations(ofAsset: second.id, as: account)
        XCTAssertEqual(ofTheSecond.map(\.relatedID), [mark.id])
        XCTAssertNil(ofTheSecond.first?.relatedTitle)
    }

    // MARK: - The page's lineage

    /// Holds whoever waits at it until the test opens it.
    private actor Gate {
        private var isOpen = false
        private var held: [CheckedContinuation<Void, Never>] = []
        private var arrivals = 0
        private var hearing: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            arrivals += 1
            hearing.forEach { $0.resume() }
            hearing = []
            if !isOpen { await withCheckedContinuation { held.append($0) } }
        }

        func arrived() async {
            if arrivals == 0 { await withCheckedContinuation { hearing.append($0) } }
        }

        func open() {
            isOpen = true
            held.forEach { $0.resume() }
            held = []
        }
    }

    private func relation(_ title: String) -> AssetRelation {
        AssetRelation(id: title, fromAssetID: "brief", toAssetID: "logo", kind: AssetRelation.handoffFor, relatedID: "logo", relatedTitle: title)
    }

    func testThePageShowsOnlyItsLatestReadingOfTheLineage_andNoneOfAnotherAccounts() async {
        let model = AssetLineageModel()
        await model.read("brief", as: "ada", signedIn: { "ada" }, relations: { _, _ in [self.relation("Logo")] })
        XCTAssertEqual(model.relations.map(\.line), ["Handoff for Logo"])
        XCTAssertFalse(model.failed)

        // An earlier reading that lands after a later one is not shown over it.
        let gate = Gate()
        let early = Task {
            await model.read("brief", as: "ada", signedIn: { "ada" }, relations: { _, _ in
                await gate.wait()
                return [self.relation("Stale")]
            })
        }
        await gate.arrived()
        await model.read("brief", as: "ada", signedIn: { "ada" }, relations: { _, _ in [self.relation("Fresh")] })
        await gate.open()
        await early.value
        XCTAssertEqual(model.relations.map(\.relatedTitle), ["Fresh"])

        // A reading that fails says so in place of what was read before; one called off says nothing.
        await model.read("brief", as: "ada", signedIn: { "ada" }, relations: { _, _ in throw CancellationError() })
        XCTAssertEqual(model.relations.count, 1)
        XCTAssertFalse(model.failed)
        var said: [String] = []
        await model.read("brief", as: "ada", signedIn: { "ada" }, say: { said.append($0) }, relations: { _, _ in throw RepositoryError.databaseUnavailable })
        XCTAssertEqual(model.relations, [])
        XCTAssertTrue(model.failed)
        await model.read("brief", as: "ada", signedIn: { "ada" }, say: { said.append($0) }, relations: { _, _ in throw RepositoryError.databaseUnavailable })
        XCTAssertEqual(said, [AssetDetailView.lineageFailed], "Told to VoiceOver when it newly shows, once")
        XCTAssertEqual(AssetDetailView.lineageFailed, "Couldn't load where this came from.")

        // Nothing read as one account is shown once another is signed in.
        await model.read("brief", as: "ada", signedIn: { "grace" }, relations: { _, _ in [self.relation("Ada's")] })
        XCTAssertEqual(model.relations, [])

        // The asset can no longer be opened: what was read of it is forgotten, and a reading under way is not taken.
        await model.read("brief", as: "ada", signedIn: { "ada" }, relations: { _, _ in [self.relation("Logo")] })
        XCTAssertEqual(model.relations.count, 1)
        let slow = Gate()
        let underWay = Task {
            await model.read("brief", as: "ada", signedIn: { "ada" }, relations: { _, _ in
                await slow.wait()
                return [self.relation("Read before it was locked")]
            })
        }
        await slow.arrived()
        model.forget()
        XCTAssertEqual(model.relations, [])
        XCTAssertFalse(model.failed)
        await slow.open()
        await underWay.value
        XCTAssertEqual(model.relations, [])
    }
}
