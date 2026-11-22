@testable import AICoven
internal import Combine
import XCTest

/// The Assets place: which assets it shows and what a row says, and the
/// model that reads a scope's assets and makes a new one.
@MainActor
final class AssetLibraryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private func asset(
        _ id: String, _ title: String = "", type: AssetType = .image, status: AssetStatus = .draft, details: String = "", files: [String] = [],
        agent: String? = nil, changed: TimeInterval = 0, unreadable: Bool = false
    ) -> Asset {
        Asset(
            id: id, covenID: nil, type: type, status: status, title: title.isEmpty ? id : title, details: details, madeByAgentID: agent,
            threadID: nil, sourceMessageID: nil,
            files: files.enumerated().map { AssetFile(id: "\(id)-\($0.offset)", name: $0.element, mimeType: "text/plain", sizeBytes: 1) },
            isUnreadable: unreadable, createdAt: now, updatedAt: now.addingTimeInterval(changed)
        )
    }

    // MARK: - The rules

    func testWhatIsProposedComesFirst_andWhatIsArchivedIsLeftOutUnlessAskedFor() {
        let all = [
            asset("a", status: .draft), asset("b", status: .proposed), asset("c", status: .archived),
            asset("d", status: .approved), asset("e", status: .proposed),
        ]
        var shown = AssetLibraryRules.shown(all, search: "", type: nil, status: nil)
        XCTAssertEqual(shown.needsReview.map(\.id), ["b", "e"], "In the order given")
        XCTAssertEqual(shown.others.map(\.id), ["a", "d"], "Without what is archived")

        shown = AssetLibraryRules.shown(all, search: "", type: nil, status: .archived)
        XCTAssertEqual(shown.needsReview.map(\.id), [])
        XCTAssertEqual(shown.others.map(\.id), ["c"])
        shown = AssetLibraryRules.shown(all, search: "  ", type: nil, status: .proposed)
        XCTAssertEqual(shown.needsReview.map(\.id), ["b", "e"])
        XCTAssertEqual(shown.others.map(\.id), [])
    }

    func testTheTypeAndTheSearchNarrowWhatIsShown() {
        let all = [
            asset("a", "Q3 revenue", type: .chart),
            asset("b", "Launch plan", type: .report, details: "Covers the café opening"),
            asset("c", "Homepage", type: .designMockup, files: ["Hero-Final.PNG"]),
            asset("d", "Archive of Q3", type: .chart, status: .archived),
        ]
        func ids(_ search: String, type: AssetType? = nil, status: AssetStatus? = nil) -> [String] {
            let shown = AssetLibraryRules.shown(all, search: search, type: type, status: status)
            return (shown.needsReview + shown.others).map(\.id)
        }
        XCTAssertEqual(ids("", type: .chart), ["a"])
        XCTAssertEqual(ids(" q3 "), ["a"], "The title, whatever its case, without the space around what was typed")
        XCTAssertEqual(ids("cafe"), ["b"], "What says what it is, whatever its accents")
        XCTAssertEqual(ids("hero-final.png"), ["c"], "A file's name")
        XCTAssertEqual(ids("q3", status: .archived), ["d"])
        XCTAssertEqual(ids("nothing like it"), [])
        XCTAssertEqual(ids("plan", type: .chart), [], "Both must hold")
    }

    func testWhatARowSays() {
        let mine = asset("a", "Q3 revenue", type: .designMockup, status: .approved, changed: -5 * 3600)
        XCTAssertEqual(AssetLibraryRules.quietLine(mine, now: now, calendar: utc), "Approved · Design Mockup · You · 5h ago")
        let agents = asset("b", type: .chart, status: .proposed, agent: "agent-1", changed: -90)
        XCTAssertEqual(AssetLibraryRules.quietLine(agents, now: now, calendar: utc), "Proposed · Chart · Agent · 1m ago")
        let locked = asset("c", status: .approved, unreadable: true)
        XCTAssertEqual(AssetLibraryRules.statusLabel(locked), "Locked", "Whatever status it has")
        XCTAssertEqual(AssetLibraryRules.filterSummary(type: .chart, status: .draft), "Showing Chart, Draft")
        XCTAssertEqual(AssetLibraryRules.filterSummary(type: nil, status: .archived), "Showing Archived")
        XCTAssertNil(AssetLibraryRules.filterSummary(type: nil, status: nil))
    }

    func testWhenSomethingWasLastChanged_shortly() {
        /// 1_800_000_000 is 15 January 2027, 08:00 UTC.
        func said(_ secondsAgo: TimeInterval) -> String {
            AssetLibraryRules.shortTime(now.addingTimeInterval(-secondsAgo), now: now, calendar: utc)
        }
        XCTAssertEqual(said(0), "Just now")
        XCTAssertEqual(said(59), "Just now")
        XCTAssertEqual(said(60), "1m ago")
        XCTAssertEqual(said(59 * 60), "59m ago")
        XCTAssertEqual(said(3600), "1h ago")
        XCTAssertEqual(said(7 * 3600 + 59 * 60), "7h ago", "Still today")
        XCTAssertEqual(said(8 * 3600 + 60), "Yesterday", "Before midnight")
        XCTAssertEqual(said(32 * 3600), "Yesterday")
        XCTAssertEqual(said(3 * 86400), "3 days")
        XCTAssertEqual(said(6 * 86400), "6 days")
        let older = AssetLibraryRules.shortTime(now.addingTimeInterval(-9 * 86400), now: now, calendar: utc)
        XCTAssertFalse(older.contains("days"), "Then its day")
        XCTAssertFalse(older.contains("ago"))
        let ahead = AssetLibraryRules.shortTime(now.addingTimeInterval(3600), now: now, calendar: utc)
        XCTAssertFalse(ahead.contains("ago"), "A time ahead of now is said as its day")
        XCTAssertNotEqual(ahead, "Just now")
    }

    func testATypeInWords_andItsSymbolAndTag() {
        XCTAssertEqual(AssetType.designMockup.displayName, "Design Mockup")
        XCTAssertEqual(AssetType(rawValue: "wireframe_v2").displayName, "Wireframe V2")
        XCTAssertEqual(AssetType.implementationBrief.iconSystemName, "doc.text")
        XCTAssertEqual(AssetType(rawValue: "moodboard").iconSystemName, "shippingbox", "A type the app has no symbol for still has one")
        XCTAssertEqual(AssetType.implementationBrief.thumbnailTag, "MD")
        XCTAssertEqual(AssetType.dataset.thumbnailTag, "CSV")
        XCTAssertEqual(AssetType.image.thumbnailTag, "IMA")
        XCTAssertEqual(AssetType.offered.map(\.displayName), ["Image", "Design Mockup", "Chart", "Dataset", "Implementation Brief", "Social Creative", "Deck"])
        XCTAssertTrue(AssetType.offered.allSatisfy(\.isName))
        XCTAssertEqual(AssetStatus.allCases.map(\.displayName), ["Draft", "Proposed", "Approved", "Archived"])
    }

    // MARK: - The model

    /// Holds whoever waits at it until the test lets them through, in the order they came.
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
    }

    /// What a source gives and was asked, set by the test. Sendable by hand: used one step at a time.
    private final class Stand: @unchecked Sendable {
        var listed: [[Asset]] = []
        var listFails = false
        var created: [(new: AssetLibraryModel.NewAsset, covenID: String?, account: String)] = []
        var createFails: Error?
        var account = "ada"
        var readings = 0
    }

    private func source(_ stand: Stand, readingWaits gate: Gate? = nil, creatingWaits: Gate? = nil) -> AssetLibraryModel.Source {
        AssetLibraryModel.Source(
            assets: { _, _ in
                let reading = await MainActor.run { () -> Int in
                    stand.readings += 1
                    return stand.readings
                }
                await gate?.wait()
                return try await MainActor.run {
                    if stand.listFails { throw RepositoryError.databaseUnavailable }
                    return stand.listed[min(reading, stand.listed.count) - 1]
                }
            },
            create: { new, covenID, account in
                await creatingWaits?.wait()
                return try await MainActor.run {
                    if let error = stand.createFails { throw error }
                    stand.created.append((new, covenID, account))
                    let made = Asset(
                        id: "made-\(stand.created.count)", covenID: covenID, type: new.type, status: .draft, title: new.title, details: new.details,
                        madeByAgentID: nil, threadID: nil, sourceMessageID: nil, files: [], createdAt: Date(), updatedAt: Date()
                    )
                    stand.listed = [(stand.listed.last ?? []) + [made]]
                    stand.readings = 0
                    return made
                }
            }
        )
    }

    private func new(_ title: String = "Chart", type: AssetType = .chart) -> AssetLibraryModel.NewAsset {
        AssetLibraryModel.NewAsset(type: type, title: title, details: "", file: AssetRepository.NewFile(name: "c.csv", data: Data([1])))
    }

    func testTheScopesAssetsAreRead_andAFailedRefreshKeepsWhatWasShown() async {
        let stand = Stand()
        stand.listed = [[asset("a"), asset("b", status: .proposed)]]
        let model = AssetLibraryModel(covenID: "work", source: source(stand), signedIn: { stand.account })
        XCTAssertFalse(model.hasRead)

        await model.load()
        XCTAssertTrue(model.hasRead)
        XCTAssertFalse(model.loadFailed)
        XCTAssertEqual(model.shown.needsReview.map(\.id), ["b"])
        XCTAssertEqual(model.shown.others.map(\.id), ["a"])

        stand.listFails = true
        await model.load()
        XCTAssertTrue(model.loadFailed)
        XCTAssertEqual(model.assets.map(\.id), ["a", "b"], "The list stays as it was read before")

        stand.listFails = false
        await model.load()
        XCTAssertFalse(model.loadFailed)
    }

    func testAFirstReadingThatFailsSaysSo_withNothingShown() async {
        let stand = Stand()
        stand.listFails = true
        let model = AssetLibraryModel(covenID: nil, source: source(stand), signedIn: { stand.account })
        await model.load()
        XCTAssertFalse(model.hasRead)
        XCTAssertTrue(model.loadFailed)
        XCTAssertEqual(model.assets.count, 0)
    }

    func testOnlyTheLatestReadingIsShown() async {
        let stand = Stand()
        stand.listed = [[asset("old")], [asset("new")]]
        let gate = Gate()
        let model = AssetLibraryModel(covenID: nil, source: source(stand, readingWaits: gate), signedIn: { stand.account })

        let first = Task { await model.load() }
        await gate.arrived(1)
        let second = Task { await model.load() }
        await gate.arrived(2)
        // The later reading lands first; the earlier one, landing after it, is not shown over it.
        await gate.letOneThrough()
        await gate.letOneThrough()
        await first.value
        await second.value
        XCTAssertEqual(model.assets.map(\.id), ["new"])
    }

    func testNothingReadForAnAccountThatIsNoLongerSignedInIsShown() async {
        let stand = Stand()
        stand.listed = [[asset("adas")]]
        let gate = Gate()
        let model = AssetLibraryModel(covenID: nil, source: source(stand, readingWaits: gate), signedIn: { stand.account })

        let reading = Task { await model.load() }
        await gate.arrived(1)
        stand.account = "grace"
        await gate.letOneThrough()
        await reading.value
        XCTAssertEqual(model.assets.count, 0)
        XCTAssertFalse(model.hasRead)
        XCTAssertFalse(model.loadFailed)
    }

    func testAReadingThatWasCalledOffIsNoFailedReading() async {
        let model = AssetLibraryModel(
            covenID: nil,
            source: AssetLibraryModel.Source(assets: { _, _ in throw CancellationError() }, create: { _, _, _ in throw CancellationError() }),
            signedIn: { "ada" }
        )
        await model.load()
        XCTAssertFalse(model.loadFailed)
        XCTAssertFalse(model.hasRead)
    }

    func testANewAssetIsMadeInTheScope_forWhoeverPressedCreate_andIsSeen() async {
        let stand = Stand()
        stand.listed = [[asset("a", "Old report", type: .report)]]
        let model = AssetLibraryModel(covenID: "work", source: source(stand), signedIn: { stand.account })
        await model.load()
        // A search and a filter that the new asset does not match.
        model.search = "old"
        model.typeFilter = .report

        let made = await model.create(new("Q3 chart"), as: "ada")
        guard case let .made(asset) = made else { return XCTFail("It is made") }
        XCTAssertEqual(stand.created.map(\.covenID), ["work"])
        XCTAssertEqual(stand.created.map(\.account), ["ada"])
        XCTAssertEqual(stand.created.map(\.new.title), ["Q3 chart"])
        XCTAssertEqual(model.assets.map(\.id), ["a", asset.id], "Read again")
        XCTAssertEqual(model.search, "", "What would hide the new asset is cleared")
        XCTAssertNil(model.typeFilter)
        XCTAssertFalse(model.isCreating)
    }

    func testASearchTheNewAssetMatchesIsKept() async {
        let stand = Stand()
        stand.listed = [[]]
        let model = AssetLibraryModel(covenID: nil, source: source(stand), signedIn: { stand.account })
        await model.load()
        model.search = "q3"
        model.typeFilter = .chart
        _ = await model.create(new("Q3 chart"), as: "ada")
        XCTAssertEqual(model.search, "q3")
        XCTAssertEqual(model.typeFilter, .chart)
    }

    func testOneAssetIsMadeAtATime() async {
        let stand = Stand()
        stand.listed = [[]]
        let gate = Gate()
        let model = AssetLibraryModel(covenID: nil, source: source(stand, creatingWaits: gate), signedIn: { stand.account })

        let first = Task { await model.create(self.new("One"), as: "ada") }
        await gate.arrived(1)
        XCTAssertTrue(model.isCreating)
        let second = await model.create(new("Two"), as: "ada")
        XCTAssertNil(second, "A second Create while one is under way makes nothing")
        await gate.letOneThrough()
        let made = await first.value
        XCTAssertNotNil(made)
        XCTAssertEqual(stand.created.map(\.new.title), ["One"])
    }

    func testWhatCameOfMakingIsNotSaidToAnotherAccount() async {
        let stand = Stand()
        stand.listed = [[]]
        let gate = Gate()
        let model = AssetLibraryModel(covenID: nil, source: source(stand, creatingWaits: gate), signedIn: { stand.account })

        var making = Task { await model.create(self.new(), as: "ada") }
        await gate.arrived(1)
        stand.account = "grace"
        await gate.letOneThrough()
        var said = await making.value
        XCTAssertNil(said, "Made for Ada; nothing of it is said to Grace")
        XCTAssertEqual(model.assets.count, 0, "Nor shown")

        stand.account = "ada"
        stand.createFails = AssetError.tooMany
        making = Task { await model.create(self.new(), as: "ada") }
        await gate.arrived(2)
        stand.account = "grace"
        await gate.letOneThrough()
        said = await making.value
        XCTAssertNil(said, "Nor why it was not made")
    }

    func testWhyAnAssetWasNotMadeIsSaidInWords() async {
        let stand = Stand()
        stand.listed = [[]]
        let model = AssetLibraryModel(covenID: nil, source: source(stand), signedIn: { stand.account })
        for (error, words) in [
            (AssetError.fileTooLarge(name: "big.bin") as Error, AssetLibraryModel.fileTooLarge),
            (AssetFileChoice.Unread.tooLarge, AssetLibraryModel.fileTooLarge),
            (AssetFileChoice.Unread.notOpened, AssetLibraryModel.couldNotOpenFile),
            (AssetError.tooMany, AssetLibraryModel.tooMany),
            (AssetError.tooLong, AssetLibraryModel.detailsTooLong),
            (RepositoryError.dataLocked, AssetLibraryModel.needsUnlock),
            (RepositoryError.databaseUnavailable, AssetLibraryModel.couldNotCreate),
            (AssetError.noSuchCoven, AssetLibraryModel.couldNotCreate),
        ] {
            stand.createFails = error
            let said = await model.create(new(), as: "ada")
            XCTAssertEqual(said, .failed(words), "\(error)")
        }
        XCTAssertFalse(model.isCreating)
    }

    func testAChosenFileIsReadUnlessItIsTooLarge() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("asset-choice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        let small = folder.appendingPathComponent("notes.md")
        try Data("hello".utf8).write(to: small)
        let read = try AssetFileChoice.read(small)
        XCTAssertEqual(read.name, "notes.md")
        XCTAssertEqual(read.data, Data("hello".utf8))

        let large = folder.appendingPathComponent("large.bin")
        try Data(count: AssetRepository.largestFile + 1).write(to: large)
        XCTAssertThrowsError(try AssetFileChoice.read(large)) { XCTAssertEqual($0 as? AssetFileChoice.Unread, .tooLarge) }
        XCTAssertThrowsError(try AssetFileChoice.read(folder.appendingPathComponent("gone.md"))) {
            XCTAssertEqual($0 as? AssetFileChoice.Unread, .notOpened)
        }
    }
}
