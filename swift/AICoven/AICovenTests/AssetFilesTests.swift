@testable import AICoven
import XCTest

/// An asset's files as a view opens them: looked at in Quick Look, or
/// handed to the system's exporter.
@MainActor
final class AssetFilesTests: XCTestCase {
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

        func arrived(_ count: Int) async {
            if arrivals >= count { return }
            await withCheckedContinuation { hearing.append((count, $0)) }
        }

        func letOneThrough() {
            if !held.isEmpty { held.removeFirst().resume() }
        }

        /// Lets the one who came last through, ahead of those before it.
        func letNewestThrough() {
            held.popLast()?.resume()
        }
    }

    /// Who is signed in and what was asked, set and read on the main actor.
    private final class Stand: @unchecked Sendable {
        var account = "ada"
        var asked: [(fileID: String, account: String)] = []
        var fails = false
    }

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("asset-files-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func files(_ stand: Stand, readingWaits gate: Gate? = nil, sharing turn: AssetFiles.Turn? = nil) -> AssetFiles {
        AssetFiles(
            turn: turn,
            load: { fileID, account in
                await MainActor.run { stand.asked.append((fileID, account)) }
                await gate?.wait()
                if await MainActor.run(body: { stand.fails }) { throw AssetError.unreadable }
                return Data("bytes of \(fileID)".utf8)
            },
            signedIn: { stand.account },
            previewRoot: root
        )
    }

    private func file(_ id: String, _ name: String = "chart.csv") -> AssetFile {
        AssetFile(id: id, name: name, mimeType: "text/csv", sizeBytes: 10)
    }

    private func staged() -> [URL] {
        let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])?.compactMap { $0 as? URL } ?? []
        return all.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    func testAFileIsReadAsWhoeverAsked_andOfferedToTheExporterUnderItsName() async {
        let stand = Stand()
        let files = files(stand)
        await files.download(file("f1", "Q3 revenue.csv"))

        XCTAssertEqual(stand.asked.map(\.fileID), ["f1"])
        XCTAssertEqual(stand.asked.map(\.account), ["ada"])
        XCTAssertTrue(files.isExporting)
        XCTAssertEqual(files.exportName, "Q3 revenue.csv")
        XCTAssertEqual(files.document?.data, Data("bytes of f1".utf8))
        XCTAssertNil(files.preparing)
        XCTAssertNil(files.said)
        XCTAssertEqual(staged(), [], "Nothing is written out for a download: the system writes it where the person chooses")
    }

    func testTheBytesGoWhenTheExporterDoes_andASaveThatFailedIsSaid() async {
        let stand = Stand()
        let files = files(stand)
        await files.download(file("f1"))
        files.exported(.success(URL(fileURLWithPath: "/tmp/elsewhere.csv")), of: files.export)
        files.isExporting = false
        XCTAssertNil(files.document, "The bytes go when the exporter does")
        XCTAssertNil(files.said)

        await files.download(file("f1"))
        files.isExporting = false
        XCTAssertNil(files.document, "Closed without saving: nothing is kept in memory")

        await files.download(file("f1"))
        files.exported(.failure(CocoaError(.userCancelled)), of: files.export)
        XCTAssertNil(files.said, "Closing the exporter is no failure")
        files.exported(.failure(CocoaError(.fileWriteNoPermission)), of: files.export)
        XCTAssertEqual(files.said, AssetFiles.cannotSave)
    }

    func testOnlyTheLatestDownloadAskedForIsOffered() async {
        let stand = Stand()
        let gate = Gate()
        let files = files(stand, readingWaits: gate)

        let first = Task { await files.download(self.file("f1", "one.csv")) }
        await gate.arrived(1)
        let second = Task { await files.download(self.file("f2", "two.csv")) }
        await gate.arrived(2)
        XCTAssertEqual(files.preparing, "f2")
        // The later one is read first; the earlier, read after it, is not offered over it.
        await gate.letNewestThrough()
        await second.value
        XCTAssertEqual(files.exportName, "two.csv")
        await gate.letOneThrough()
        await first.value
        XCTAssertEqual(files.exportName, "two.csv")
        XCTAssertEqual(files.document?.data, Data("bytes of f2".utf8))
        XCTAssertNil(files.preparing)
    }

    func testTheLatestDownloadOfAPlaceIsTheOnlyOneOffered_whicheverPresenterWasAsked() async {
        let stand = Stand()
        let gate = Gate()
        // The library's presenter and a page's, taking turns.
        let library = files(stand, readingWaits: gate)
        let page = files(stand, readingWaits: gate, sharing: library.turn)

        let fromARow = Task { await library.download(self.file("f1", "one.csv")) }
        await gate.arrived(1)
        let fromThePage = Task { await page.download(self.file("f2", "two.csv")) }
        await gate.arrived(2)
        // The earlier one is read last: it is not offered after the later one was asked.
        await gate.letNewestThrough()
        await fromThePage.value
        XCTAssertTrue(page.isExporting)
        await gate.letOneThrough()
        await fromARow.value
        XCTAssertFalse(library.isExporting, "Asked before the page's: not offered")
        XCTAssertNil(library.document)
        XCTAssertNil(library.preparing, "And no longer shown as being read")
        XCTAssertEqual(page.exportName, "two.csv")

        // A presenter with a turn of its own is another place's: it is not put off by these.
        let elsewhere = files(stand)
        await elsewhere.download(file("f3", "three.csv"))
        XCTAssertTrue(elsewhere.isExporting)
        XCTAssertTrue(page.isExporting)
    }

    func testAnExportersResultThatComesLateSaysNothing_andClearsNothingNewer() async {
        let stand = Stand()
        let files = files(stand)
        await files.download(file("f1", "one.csv"))
        let first = files.export
        XCTAssertNotNil(first)
        // A second export is up by the time the first one's result comes.
        files.isExporting = false
        await files.download(file("f2", "two.csv"))
        XCTAssertNotEqual(files.export, first, "Each export is its own")

        files.exported(.success(URL(fileURLWithPath: "/tmp/one.csv")), of: first)
        XCTAssertEqual(files.document?.data, Data("bytes of f2".utf8), "The newer export keeps its bytes")
        files.exported(.failure(CocoaError(.fileWriteNoPermission)), of: first)
        XCTAssertNil(files.said, "The earlier export's failure is not said over the later one")
        files.exported(.failure(CocoaError(.fileWriteNoPermission)), of: nil)
        XCTAssertNil(files.said, "Nor a result that is no export's")

        // The later one's own failure is said.
        files.exported(.failure(CocoaError(.fileWriteNoPermission)), of: files.export)
        XCTAssertEqual(files.said, AssetFiles.cannotSave)

        // After another account signed in, or the view has gone, a failed save is not said.
        await files.download(file("f3", "three.csv"))
        XCTAssertNil(files.said)
        stand.account = "grace"
        files.exported(.failure(CocoaError(.fileWriteNoPermission)), of: files.export)
        XCTAssertNil(files.said, "Not to another account")
        stand.account = "ada"
        let last = files.export
        files.teardown()
        files.exported(.failure(CocoaError(.fileWriteNoPermission)), of: last)
        XCTAssertNil(files.said, "Not once its view has gone")
    }

    func testNothingReadForOneAccountIsOfferedToAnother_norItsFailure() async {
        let stand = Stand()
        let gate = Gate()
        let files = files(stand, readingWaits: gate)

        var reading = Task { await files.download(self.file("f1")) }
        await gate.arrived(1)
        stand.account = "grace"
        await gate.letOneThrough()
        await reading.value
        XCTAssertFalse(files.isExporting)
        XCTAssertNil(files.document)

        stand.account = "ada"
        stand.fails = true
        reading = Task { await files.download(self.file("f1")) }
        await gate.arrived(2)
        stand.account = "grace"
        await gate.letOneThrough()
        await reading.value
        XCTAssertNil(files.said)
    }

    func testAFileThatCannotBeReadSaysSo() async {
        let stand = Stand()
        stand.fails = true
        let files = files(stand)
        await files.download(file("f1"))
        XCTAssertEqual(files.said, AssetFiles.cannotOpen)
        XCTAssertFalse(files.isExporting)
        XCTAssertNil(files.preparing)

        // A new ask clears what was said of the last.
        stand.fails = false
        await files.download(file("f1"))
        XCTAssertNil(files.said)
    }

    func testAFileLookedAtIsStagedOnlyWhileItIsLookedAt() async throws {
        let stand = Stand()
        let files = files(stand)
        await files.look(at: file("f1", "../../Q3: revenue.csv"))

        let shown = try XCTUnwrap(files.preview.previewURL)
        // The one file, by its real path: the temporary folder is reached through a link.
        XCTAssertEqual(staged().map { $0.resolvingSymlinksInPath().path }, [shown.resolvingSymlinksInPath().path])
        XCTAssertTrue(
            shown.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
            "Inside the presenter's own folder, whatever the file is called"
        )
        XCTAssertEqual(try Data(contentsOf: shown), Data("bytes of f1".utf8))
        XCTAssertEqual(stand.asked.map(\.account), ["ada"])

        files.teardown()
        XCTAssertNil(files.preview.previewURL)
        XCTAssertEqual(staged(), [], "Nothing is left on disk")
        XCTAssertFalse(files.isExporting)
    }

    func testAFileThatCannotBeLookedAtSaysSo() async {
        let stand = Stand()
        stand.fails = true
        let files = files(stand)
        await files.look(at: file("f1"))
        XCTAssertNil(files.preview.previewURL)
        XCTAssertEqual(files.said, AttachmentPreviewPresenter.cannotOpen)
        XCTAssertEqual(staged(), [])
    }
}
