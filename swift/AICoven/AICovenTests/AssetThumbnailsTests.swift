@testable import AICoven
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// An asset's picture: drawn on the device from its own file, kept in
/// memory only, for the account it was read as and while its data stays
/// unlocked as it was.
@MainActor
final class AssetThumbnailsTests: XCTestCase {
    /// Holds whoever waits at it until the test opens it, and tells when someone has come.
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

    /// What the store and the key give and were asked. Sendable by hand: read and written on the main actor only.
    private final class Stand: @unchecked Sendable {
        var account = "ada"
        var epoch = 1
        /// The files that can be read, and what was read.
        var bytes: [String: Data] = [:]
        var read: [String] = []
        var readingWaits: Gate?
        /// What happens once a file was read, before it is drawn.
        var afterReading: (() -> Void)?
    }

    private func picture(side: Int) -> CGImage? {
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
        return context?.makeImage()
    }

    /// Thumbnails over `stand`: a file's bytes say how large its picture is drawn (one byte, the side in pixels); none for no bytes.
    private func thumbnails(_ stand: Stand, room: Int = AssetThumbnails.room) -> AssetThumbnails {
        AssetThumbnails(hands: AssetThumbnails.Hands(
            data: { fileID, _ in
                let data = await MainActor.run { () -> Data? in
                    stand.read.append(fileID)
                    return stand.bytes[fileID]
                }
                await MainActor.run { stand.readingWaits }?.wait()
                await MainActor.run { stand.afterReading?() }
                guard let data else { throw AssetError.noSuchAsset }
                return data
            },
            signedIn: { stand.account },
            keyEpoch: { await MainActor.run { stand.epoch } },
            draw: { data, _ in
                guard let side = data.first else { return nil }
                return await MainActor.run { self.picture(side: Int(side)) }
            }
        ), room: room)
    }

    private func asset(_ id: String, files: [(String, String)], unreadable: Bool = false) -> Asset {
        Asset(
            id: id, covenID: nil, type: .image, status: .draft, title: id, details: "", madeByAgentID: nil, threadID: nil, sourceMessageID: nil,
            files: files.map { AssetFile(id: $0.0, name: $0.0, mimeType: $0.1, sizeBytes: 1) }, isUnreadable: unreadable,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - Which file

    func testAnAssetsPictureIsOfItsLatestFileThatCanBeDrawn() {
        let mixed = asset("a", files: [("old.png", "image/png"), ("new.jpg", "image/jpeg"), ("notes.md", "text/markdown")])
        XCTAssertEqual(AssetThumbnails.file(of: mixed)?.id, "new.jpg")
        XCTAssertEqual(AssetThumbnails.file(of: asset("b", files: [("deck.pdf", "application/pdf")]))?.id, "deck.pdf")
        XCTAssertNil(AssetThumbnails.file(of: asset("c", files: [("brief.md", "text/markdown"), ("logo.svg", "image/svg+xml")])), "Kept as its type's symbol")
        XCTAssertNil(AssetThumbnails.file(of: asset("d", files: [])))
        XCTAssertNil(AssetThumbnails.file(of: asset("e", files: [("a.png", "image/png")], unreadable: true)), "Nothing is drawn of an asset the key cannot open")
        XCTAssertTrue(AssetThumbnails.canDraw("image/heic"))
        XCTAssertFalse(AssetThumbnails.canDraw("application/zip"))
    }

    // MARK: - Drawn once, kept in memory

    func testAPictureIsDrawnOnce_andWhoeverAsksMeanwhileWaitsForIt() async {
        let stand = Stand()
        stand.bytes["a.png"] = Data([8])
        let thumbnails = thumbnails(stand)
        let logo = asset("logo", files: [("a.png", "image/png")])
        let gate = Gate()
        stand.readingWaits = gate
        let first = Task { await thumbnails.picture(of: logo, as: "ada") }
        await gate.arrived()
        let second = Task { await thumbnails.picture(of: logo, as: "ada") }
        await Task.yield()
        await gate.open()
        let (one, two) = await (first.value, second.value)
        XCTAssertEqual(one?.width, 8)
        XCTAssertEqual(two?.width, 8)
        XCTAssertEqual(stand.read, ["a.png"], "Read once for both")
        let again = await thumbnails.picture(of: logo, as: "ada")
        XCTAssertNotNil(again)
        XCTAssertEqual(stand.read, ["a.png"], "And kept from then on")

        // A file that was read and cannot be drawn is not tried again.
        stand.bytes["broken.png"] = Data()
        let broken = asset("broken", files: [("broken.png", "image/png")])
        for _ in 1 ... 3 {
            let none = await thumbnails.picture(of: broken, as: "ada")
            XCTAssertNil(none)
        }
        XCTAssertEqual(stand.read, ["a.png", "broken.png"])
        // One that could not be read is: the store may answer the next time.
        let late = asset("late", files: [("late.png", "image/png")])
        var shown = await thumbnails.picture(of: late, as: "ada")
        XCTAssertNil(shown)
        stand.bytes["late.png"] = Data([8])
        shown = await thumbnails.picture(of: late, as: "ada")
        XCTAssertNotNil(shown)
        XCTAssertEqual(stand.read, ["a.png", "broken.png", "late.png", "late.png"])
        // An asset with nothing to draw asks for nothing.
        let none = await thumbnails.picture(of: asset("text", files: [("brief.md", "text/markdown")]), as: "ada")
        XCTAssertNil(none)
        XCTAssertEqual(stand.read.count, 4)
    }

    func testOnlySoMuchIsKept_theOnesAskedForLongestAgoMakingRoom() async {
        let stand = Stand()
        for name in ["a", "b", "c"] {
            stand.bytes[name] = Data([16])
        }
        // Room for two pictures of 16 by 16 (4 bytes a pixel).
        let thumbnails = thumbnails(stand, room: 2 * 16 * 16 * 4)
        func ask(_ name: String) async {
            _ = await thumbnails.picture(of: asset(name, files: [(name, "image/png")]), as: "ada")
        }
        await ask("a")
        await ask("b")
        await ask("a")
        await ask("c")
        XCTAssertEqual(stand.read, ["a", "b", "c"])
        await ask("a")
        XCTAssertEqual(stand.read, ["a", "b", "c"], "Asked for lately: still kept")
        await ask("b")
        XCTAssertEqual(stand.read, ["a", "b", "c", "b"], "Asked for longest ago: it made room, and is drawn again")
    }

    // MARK: - One account's, while its data stays unlocked

    func testNothingReadForOneAccountIsShownOrKeptForAnother() async {
        let stand = Stand()
        stand.bytes["a.png"] = Data([8])
        let thumbnails = thumbnails(stand)
        let logo = asset("logo", files: [("a.png", "image/png")])
        // Another account signs in while the file is read: nothing is answered, and nothing kept.
        stand.afterReading = { stand.account = "grace" }
        var shown = await thumbnails.picture(of: logo, as: "ada")
        XCTAssertNil(shown)
        stand.afterReading = nil
        shown = await thumbnails.picture(of: logo, as: "ada")
        XCTAssertNil(shown, "Asked as an account that is not signed in")
        XCTAssertEqual(stand.read, ["a.png"])

        // Ada again: read anew. Then Grace: what was Ada's is forgotten, and is read anew for Ada afterwards.
        stand.account = "ada"
        shown = await thumbnails.picture(of: logo, as: "ada")
        XCTAssertNotNil(shown)
        XCTAssertEqual(stand.read, ["a.png", "a.png"])
        stand.account = "grace"
        stand.bytes["g.png"] = Data([4])
        shown = await thumbnails.picture(of: asset("graces", files: [("g.png", "image/png")]), as: "grace")
        XCTAssertEqual(shown?.width, 4)
        stand.account = "ada"
        shown = await thumbnails.picture(of: logo, as: "ada")
        XCTAssertEqual(stand.read, ["a.png", "a.png", "g.png", "a.png"], "Not held across accounts")
    }

    func testWhatIsHeldIsForgottenWhenTheDataIsLockedOrTheAccountLeaves() async {
        let stand = Stand()
        stand.bytes["a.png"] = Data([8])
        let thumbnails = thumbnails(stand)
        let logo = asset("logo", files: [("a.png", "image/png")])
        _ = await thumbnails.picture(of: logo, as: "ada")
        // Locked and unlocked again: the key in memory is another unlocking's.
        stand.epoch += 2
        _ = await thumbnails.picture(of: logo, as: "ada")
        XCTAssertEqual(stand.read, ["a.png", "a.png"])
        // Locked while a file is read: nothing is answered or kept.
        stand.bytes["b.png"] = Data([8])
        let mark = asset("mark", files: [("b.png", "image/png")])
        stand.afterReading = { stand.epoch += 1 }
        var shown = await thumbnails.picture(of: mark, as: "ada")
        XCTAssertNil(shown)
        stand.afterReading = nil
        shown = await thumbnails.picture(of: mark, as: "ada")
        XCTAssertNotNil(shown)
        XCTAssertEqual(stand.read, ["a.png", "a.png", "b.png", "b.png"], "Read anew under the unlocking that followed")
        // Told to forget (signing out, another account): nothing is held.
        _ = await thumbnails.picture(of: logo, as: "ada")
        let reads = stand.read.count
        thumbnails.forgetAll()
        _ = await thumbnails.picture(of: logo, as: "ada")
        XCTAssertEqual(stand.read.count, reads + 1)
    }

    // MARK: - Drawing

    private func png(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func pdf(width: CGFloat, height: CGFloat) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    func testAPictureAndAPDFAreDrawnNoLargerThanAThumbnailIs_andNothingElse() throws {
        let large = try XCTUnwrap(AssetThumbnails.draw(png(width: 2400, height: 1200), mimeType: "image/png"))
        XCTAssertEqual(max(large.width, large.height), AssetThumbnails.longestEdge)
        XCTAssertEqual(large.width, 2 * large.height, "In its own shape")
        let small = try XCTUnwrap(AssetThumbnails.draw(png(width: 40, height: 30), mimeType: "image/png"))
        XCTAssertLessThanOrEqual(max(small.width, small.height), AssetThumbnails.longestEdge)
        let page = try XCTUnwrap(AssetThumbnails.draw(pdf(width: 612, height: 792), mimeType: "application/pdf"))
        XCTAssertEqual(page.height, AssetThumbnails.longestEdge, "The first page, its longest edge a thumbnail's")
        XCTAssertLessThan(page.width, page.height)
        // A PDF named as something else is still a PDF; what is neither is not drawn.
        XCTAssertNotNil(try AssetThumbnails.draw(pdf(width: 200, height: 100), mimeType: "application/octet-stream"))
        XCTAssertNil(AssetThumbnails.draw(Data("# A brief".utf8), mimeType: "text/markdown"))
        XCTAssertNil(AssetThumbnails.draw(Data(), mimeType: "image/png"))
    }

    // MARK: - The grid and the reference

    func testWhatACardAndAReferenceSay() {
        var made = asset("6F1C", files: [])
        XCTAssertEqual(AssetLibraryRules.gridLine(made), "Draft · Image · You", "The row's line without its time, as the cloud app's card")
        XCTAssertEqual(AssetLibraryRules.reference(to: made), "aicoven://assets/6F1C 6F1C")
        made = Asset(
            id: "6F1C", covenID: nil, type: .chart, status: .approved, title: "Q3\nrevenue", details: "", madeByAgentID: TurnAssets.strix, threadID: nil,
            sourceMessageID: nil, files: [], createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(AssetLibraryRules.reference(to: made), "aicoven://assets/6F1C Q3 revenue", "On one line")
        XCTAssertEqual(AssetLibraryRules.gridLine(made), "Approved · Chart · Strix, agent")
        XCTAssertEqual(AssetAction.copyReference.title, "Copy Reference")
        XCTAssertNil(AssetAction.copyReference.status)
        XCTAssertFalse(AssetLibraryRules.otherActions(asset("locked", files: [], unreadable: true)).contains(.copyReference))
        XCTAssertEqual(AssetLibraryLayout.allCases.map(\.title), ["List", "Grid"], "The cloud Mac's two layouts")
        XCTAssertEqual(AssetLibraryLayout(rawValue: "grid"), .grid)
    }
}
