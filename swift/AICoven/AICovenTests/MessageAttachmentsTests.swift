@testable import AICoven
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// A message keeps what shows its attachments in the thread; a picture
/// shows as a thumbnail, and either opens in Quick Look from a file that is
/// there only while it is looked at.
final class MessageAttachmentsTests: XCTestCase {
    private let picture = FileAttachmentDetail(id: "11111111-1111-1111-1111-111111111111", name: "beach.jpg", mimeType: "image/jpeg", sizeBytes: 2048, width: 40, height: 30, url: nil)
    private let notes = FileAttachmentDetail(id: "22222222-2222-2222-2222-222222222222", name: "notes.md", mimeType: nil, sizeBytes: nil, width: nil, height: nil, url: nil)

    // MARK: - Kept with the message

    func testAMessage_keepsWhatShowsItsAttachmentsAndReadsThemBackAfterStorage() throws {
        let metadata = try XCTUnwrap(FileAttachmentDetail.messageMetadata(for: [picture, notes]))
        XCTAssertEqual(metadata["file_attachment_ids"], .array([.string(picture.id), .string(notes.id)]))

        // As it comes back from storage: through JSON.
        let stored = try JSONDecoder().decode([String: AnyJSONValue].self, from: JSONEncoder().encode(metadata))
        XCTAssertEqual(FileAttachmentDetail.attachments(in: stored), [picture, notes])

        XCTAssertNil(FileAttachmentDetail.messageMetadata(for: []), "A message with no files keeps nothing of them")
        XCTAssertNil(FileAttachmentDetail.attachments(in: [:]))
        XCTAssertNil(FileAttachmentDetail.attachments(in: ["role_name": .string("Strix")]))
    }

    func testWhatAMessageKeptOfItsAttachments_isReadAsFarAsItMakesSense() {
        // One that is not an attachment is left out; the rest stand.
        let mixed: [String: AnyJSONValue] = ["file_attachments": .array([
            picture.messageMetadata,
            .string("not an attachment"),
            .dictionary(["id": .string(""), "name": .string("no id")]),
            .dictionary(["id": .string("x")]),
            .dictionary(["id": .string("33333333-3333-3333-3333-333333333333"), "name": .string("odd.bin"), "size_bytes": .string("large")]),
        ])]
        let read = FileAttachmentDetail.attachments(in: mixed)
        XCTAssertEqual(read?.map(\.name), ["beach.jpg", "odd.bin"])
        XCTAssertNil(read?.last?.sizeBytes, "A size that is not a number is no size")

        // A message that kept only ids names its attachments by them.
        let idsOnly: [String: AnyJSONValue] = ["file_attachment_ids": .array([.string("file-1"), .int(2), .string("")])]
        XCTAssertEqual(FileAttachmentDetail.attachments(in: idsOnly)?.map(\.name), ["file-1"])
    }

    func testThePersonsMessage_isStoredWithItsFilesAndShownWithThem() {
        let message = TurnProgress.userMessage(in: "thread-1", text: "Look at this", attachments: [picture])
        XCTAssertEqual(message.role, "user")
        XCTAssertEqual(message.content, "Look at this")
        XCTAssertEqual(FileAttachmentDetail.attachments(in: message.metadata ?? [:]), [picture])
        XCTAssertNil(TurnProgress.userMessage(in: "thread-1", text: "Just words", attachments: []).metadata)

        let shown = MessageAdapter.toEnhanced(from: message, response: nil)
        XCTAssertEqual(shown.attachments, [picture])
        XCTAssertNil(MessageAdapter.toEnhanced(from: TurnProgress.userMessage(in: "thread-1", text: "Just words", attachments: []), response: nil).attachments)
    }

    // MARK: - Thumbnails

    private func jpeg(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.3, green: 0.4, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        try CGImageDestinationAddImage(destination, XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    func testAnAttachment_showsAsAPictureOnlyWhenItsBytesAreOne() throws {
        let large = try AttachmentThumbnail.decode(jpeg(width: 2000, height: 1000), name: "beach")
        let image = try XCTUnwrap(large.image)
        XCTAssertEqual(max(image.width, image.height), Int(AttachmentThumbnail.side * 3), "No larger than the thread shows it, at any screen's scale")
        XCTAssertEqual(large.filename, "beach.jpeg", "Quick Look is told what it is opening")
        XCTAssertEqual(try AttachmentThumbnail.decode(jpeg(width: 20, height: 10), name: "small.jpg").filename, "small.jpg")

        // Named as a picture, but text: its file row stands.
        let text = AttachmentThumbnail.decode(Data("not a picture".utf8), name: "fake.png")
        XCTAssertNil(text.image)
        XCTAssertEqual(text.filename, "fake.png")
    }

    func testAThumbnail_fitsItsSquareAndIsNeverShownLargerThanItIs() {
        XCTAssertEqual(AttachmentThumbnail.displaySize(width: 660, height: 330), CGSize(width: 220, height: 110))
        XCTAssertEqual(AttachmentThumbnail.displaySize(width: 100, height: 440), CGSize(width: 50, height: 220))
        XCTAssertEqual(AttachmentThumbnail.displaySize(width: 40, height: 30), CGSize(width: 40, height: 30))
        XCTAssertEqual(AttachmentThumbnail.displaySize(width: 0, height: 30), .zero)
    }

    // MARK: - Opening one

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("previews-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// Every regular file under `root`.
    private func files(under root: URL) -> [URL] {
        let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
        return all.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    @MainActor
    func testOpeningAnAttachment_writesItToAFileOfItsOwnThatGoesWhenThePreviewCloses() async throws {
        let root = makeRoot()
        let presenter = AttachmentPreviewPresenter(rootDirectory: root, load: { id in Data("bytes of \(id)".utf8) })

        await presenter.open(attachmentID: "a", filename: "../../etc/pass\nwd.txt")

        let shown = try XCTUnwrap(presenter.previewURL)
        XCTAssertEqual(shown.lastPathComponent, "passwd.txt", "A plain file name, whatever the attachment was called")
        XCTAssertTrue(shown.path.hasPrefix(root.path), "Under the presenter's own folder")
        XCTAssertEqual(try String(contentsOf: shown, encoding: .utf8), "bytes of a")
        let permissions = try FileManager.default.attributesOfItem(atPath: shown.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600, "Readable by this user only")
        let folder = try FileManager.default.attributesOfItem(atPath: shown.deletingLastPathComponent().path)[.posixPermissions] as? Int
        XCTAssertEqual(folder, 0o700)
        XCTAssertFalse(presenter.isOpening)
        XCTAssertNil(presenter.errorMessage)

        // Another opened: the first one's file goes.
        await presenter.open(attachmentID: "b", filename: "second.txt")
        XCTAssertEqual(files(under: root).map(\.lastPathComponent), ["second.txt"])

        // The preview closed: nothing is left.
        presenter.previewURL = nil
        XCTAssertEqual(files(under: root), [])
    }

    @MainActor
    func testWhenTheViewGoes_orTheAttachmentCannotBeRead_nothingIsLeftOnDisk() async {
        let root = makeRoot()
        let presenter = AttachmentPreviewPresenter(rootDirectory: root, load: { _ in Data("bytes".utf8) })
        await presenter.open(attachmentID: "a", filename: "notes.txt")
        XCTAssertEqual(files(under: root).count, 1)
        presenter.teardown()
        XCTAssertEqual(files(under: root), [])
        XCTAssertNil(presenter.previewURL)

        let failing = AttachmentPreviewPresenter(rootDirectory: root, load: { _ in throw AttachmentStore.Failure.missing })
        await failing.open(attachmentID: "gone", filename: "gone.txt")
        XCTAssertNil(failing.previewURL)
        XCTAssertEqual(failing.errorMessage, AttachmentPreviewPresenter.cannotOpen)
        XCTAssertFalse(failing.isOpening)
        XCTAssertEqual(files(under: root), [])
    }

    func testAFileName_isMadePlainBeforeItIsUsedOnDisk() {
        XCTAssertEqual(AttachmentPreviewPresenter.safeFilename("report.pdf"), "report.pdf")
        XCTAssertEqual(AttachmentPreviewPresenter.safeFilename("a/b\\c.txt"), "c.txt")
        XCTAssertEqual(AttachmentPreviewPresenter.safeFilename(".."), "Attachment")
        XCTAssertEqual(AttachmentPreviewPresenter.safeFilename("  \n "), "Attachment")
        XCTAssertEqual(AttachmentPreviewPresenter.safeFilename("folder/"), "Attachment")
    }
}
