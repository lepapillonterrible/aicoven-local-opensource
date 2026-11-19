@testable import AICoven
import CoreGraphics
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Attached files are copied into the app's own store, encrypted, when they
/// are attached, and go when they are taken out unsent, with their thread,
/// and with their account.
final class AttachmentStoreTests: XCTestCase {
    private var threadID = ""
    private var folder = URL(fileURLWithPath: NSTemporaryDirectory())
    private var store = AttachmentStore()

    override func setUp() async throws {
        try await super.setUp()
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        await MainActor.run { DatabaseManager.shared.configureIfNeeded() }
        await ThreadService.shared.reloadForCurrentUser()
        threadID = try await ThreadService.shared.createThread(title: "Attachments \(UUID().uuidString)").id
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("attachments-\(UUID().uuidString)", isDirectory: true)
        store = AttachmentStore(directory: folder)
    }

    override func tearDown() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        try? await ThreadService.shared.deleteThread(threadId: threadID)
        await ThreadService.shared.reloadForCurrentUser()
        await DataEncryptionService.shared.lock()
        try? FileManager.default.removeItem(at: folder)
        try await super.tearDown()
    }

    /// Every file under the store's folder.
    private func filesKept() -> [URL] {
        let all = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
        return all.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    private func row(_ id: String) async throws -> Row? {
        try await MainActor.run { DatabaseManager.shared.dbQueue }?.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM attachments WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Kept, encrypted

    func testAnAttachedFile_isCopiedInEncryptedAndReadBackAsItWas() async throws {
        let original = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).md")
        let text = "The launch is on Friday. Do not tell Sam."
        try Data(text.utf8).write(to: original)

        let attached = try await store.add(fileAt: original, toThread: threadID)
        // Whatever becomes of the original, the copy is there to send.
        try FileManager.default.removeItem(at: original)

        XCTAssertNotNil(UUID(uuidString: attached.id))
        XCTAssertEqual(attached.name, original.lastPathComponent)
        XCTAssertEqual(attached.mimeType, "text/markdown")
        XCTAssertEqual(attached.sizeBytes, text.utf8.count)
        XCTAssertNil(attached.url, "It names no file elsewhere")
        let read = try await store.data(of: attached.id)
        XCTAssertEqual(String(decoding: read, as: UTF8.self), text)

        // On disk: one file, named by the attachment's id, in a folder that
        // does not name the account, and nothing of the text or the file's
        // name readable there or in the database.
        let files = filesKept()
        XCTAssertEqual(files.map(\.lastPathComponent), [attached.id])
        let onDisk = try Data(contentsOf: XCTUnwrap(files.first))
        XCTAssertNil(onDisk.range(of: Data("launch".utf8)))
        let stored = try await row(attached.id)
        let meta: Data? = stored?["meta_ciphertext"]
        XCTAssertNil(meta?.range(of: Data("notes".utf8)))
        XCTAssertEqual(stored?["thread_id"], threadID)
        XCTAssertNil(stored?["message_id"] as String?, "Not sent yet")
    }

    func testAFileOverTenMegabytes_isRefusedByNameAndNothingIsKept() async throws {
        let big = Data(count: AttachmentStore.maxBytes + 1)
        do {
            _ = try await store.add(big, named: "video.mov", mimeType: "video/quicktime", toThread: threadID)
            XCTFail("A file over the limit is not attached")
        } catch {
            XCTAssertEqual(error as? AttachmentStore.Failure, .tooLarge(name: "video.mov"))
            XCTAssertEqual(error.localizedDescription, "video.mov is larger than 10 MB and was not attached.")
        }
        // Chosen as a file, it is refused by its size without being read.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString).bin")
        try big.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            _ = try await store.add(fileAt: file, toThread: threadID)
            XCTFail("A file over the limit is not attached")
        } catch {
            XCTAssertEqual(error as? AttachmentStore.Failure, .tooLarge(name: file.lastPathComponent))
        }
        // At the limit it is taken.
        let atLimit = try await store.add(Data(count: AttachmentStore.maxBytes), named: "full.bin", mimeType: nil, toThread: threadID)
        XCTAssertEqual(atLimit.sizeBytes, AttachmentStore.maxBytes)
        XCTAssertEqual(filesKept().count, 1)
    }

    func testAFileThatCannotBeRead_isRefusedByName() async {
        let nowhere = FileManager.default.temporaryDirectory.appendingPathComponent("gone-\(UUID().uuidString).txt")
        do {
            _ = try await store.add(fileAt: nowhere, toThread: threadID)
            XCTFail("A file that is not there is not attached")
        } catch {
            XCTAssertEqual(error as? AttachmentStore.Failure, .unreadable(name: nowhere.lastPathComponent))
        }
        XCTAssertEqual(filesKept(), [])
    }

    func testNothingIsKeptForAThreadThatIsNotTheAccounts_orWhileTheDataIsLocked() async throws {
        do {
            _ = try await store.add(Data("x".utf8), named: "x.txt", mimeType: "text/plain", toThread: "no-such-thread")
            XCTFail("A file is attached to a thread of the account's")
        } catch {}
        XCTAssertEqual(filesKept(), [])

        let kept = try await store.add(Data("mine".utf8), named: "mine.txt", mimeType: "text/plain", toThread: threadID)
        await DataEncryptionService.shared.lock()
        do {
            _ = try await store.add(Data("x".utf8), named: "x.txt", mimeType: "text/plain", toThread: threadID)
            XCTFail("Nothing is attached while the data is locked")
        } catch {}
        do {
            _ = try await store.data(of: kept.id)
            XCTFail("Nothing is read while the data is locked")
        } catch {}
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        XCTAssertEqual(filesKept().count, 1)
    }

    func testAnAttachmentOfAnotherAccounts_orAnIdThatIsNotOne_isNotRead() async throws {
        // Another account's thread and attachment, as the database holds them.
        let othersThread = "others-\(UUID().uuidString)"
        let othersAttachment = UUID().uuidString
        let opened = await MainActor.run { DatabaseManager.shared.dbQueue }
        let queue = try XCTUnwrap(opened)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO threads (id, user_id, created_at) VALUES (?, ?, ?)", arguments: [othersThread, "another-account", Date()])
            try db.execute(
                sql: "INSERT INTO attachments (id, user_id, thread_id, meta_ciphertext, created_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [othersAttachment, "another-account", othersThread, Data("meta".utf8), Date()]
            )
        }
        addTeardownBlock {
            _ = try? await queue.write { db in
                try db.execute(sql: "DELETE FROM threads WHERE id = ?", arguments: [othersThread])
            }
        }

        for id in [othersAttachment, "../../aicoven.sqlite", "", UUID().uuidString] {
            do {
                _ = try await store.data(of: id)
                XCTFail("Only the account's own attachments are read")
            } catch {
                XCTAssertEqual(error as? AttachmentStore.Failure, .missing)
            }
        }
        // Nor is another account's removed or marked.
        await store.removeUnsent([othersAttachment])
        try await store.markSent([othersAttachment], with: "message", inThread: othersThread)
        let untouched = try await row(othersAttachment)
        XCTAssertNotNil(untouched)
        XCTAssertNil(untouched?["message_id"] as String?)
        // And the database refuses an attachment in a thread of another's.
        do {
            try await queue.write { db in
                try db.execute(
                    sql: "INSERT INTO attachments (id, user_id, thread_id, meta_ciphertext, created_at) VALUES (?, ?, ?, ?, ?)",
                    arguments: [UUID().uuidString, UserScope.currentUserID, othersThread, Data(), Date()]
                )
            }
            XCTFail("An attachment belongs to the user its thread does")
        } catch {}
    }

    // MARK: - Sent, taken out, and gone with its thread

    func testAnAttachmentTakenOutUnsent_isNotKept_andOneSentStays() async throws {
        let unsent = try await store.add(Data("draft".utf8), named: "draft.txt", mimeType: "text/plain", toThread: threadID)
        let sent = try await store.add(Data("sent".utf8), named: "sent.txt", mimeType: "text/plain", toThread: threadID)
        try await store.markSent([sent.id], with: "message-1", inThread: threadID)
        let marked = try await row(sent.id)
        XCTAssertEqual(marked?["message_id"], "message-1")

        await store.removeUnsent([unsent.id, sent.id])

        XCTAssertEqual(filesKept().map(\.lastPathComponent), [sent.id])
        let gone = try await row(unsent.id)
        XCTAssertNil(gone)
        let read = try await store.data(of: sent.id)
        XCTAssertEqual(String(decoding: read, as: UTF8.self), "sent")
        do {
            _ = try await store.data(of: unsent.id)
            XCTFail("What was taken out is gone")
        } catch {
            XCTAssertEqual(error as? AttachmentStore.Failure, .missing)
        }
    }

    func testWhatWasLeftAttachedAndUnsentWhenTheAppLastClosed_isClearedOnceInEachRun() async throws {
        let userID = await MainActor.run { UserScope.currentUserID }
        let unsent = try await store.add(Data("draft".utf8), named: "draft.txt", mimeType: "text/plain", toThread: threadID)
        let sent = try await store.add(Data("sent".utf8), named: "sent.txt", mimeType: "text/plain", toThread: threadID)
        try await store.markSent([sent.id], with: "message-1", inThread: threadID)
        // And a file with no row: one whose thread went as it was written.
        let strayFile = try XCTUnwrap(filesKept().first).deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data("nobody's".utf8).write(to: strayFile)

        // The next run of the app: a store that has cleared nothing yet.
        let nextRun = AttachmentStore(directory: folder)
        await nextRun.clearLeftovers(for: userID)
        XCTAssertEqual(filesKept().map(\.lastPathComponent), [sent.id], "Only what was sent is left")
        let cleared = try await row(unsent.id)
        XCTAssertNil(cleared)

        // What is attached after that, in the same run, is left alone,
        // however often the clearing is asked for.
        let fresh = try await nextRun.add(Data("new".utf8), named: "new.txt", mimeType: "text/plain", toThread: threadID)
        await nextRun.clearLeftovers(for: userID)
        async let again: Void = nextRun.clearLeftovers(for: userID)
        async let andAgain: Void = nextRun.clearLeftovers(for: userID)
        _ = await (again, andAgain)
        XCTAssertEqual(Set(filesKept().map(\.lastPathComponent)), [sent.id, fresh.id])
    }

    func testAMessageThatWasNotStoredAfterAll_leavesItsFilesUnsent() async throws {
        let file = try await store.add(Data("draft".utf8), named: "draft.txt", mimeType: "text/plain", toThread: threadID)
        try await store.markSent([file.id], with: "message-1", inThread: threadID)

        // Not the message it was marked with: nothing is taken back.
        await store.markUnsent([file.id], markedWith: "another-message")
        let stillMarked = try await row(file.id)
        XCTAssertEqual(stillMarked?["message_id"], "message-1")

        await store.markUnsent([file.id], markedWith: "message-1")
        let unmarked = try await row(file.id)
        XCTAssertNil(unmarked?["message_id"] as String?)
        // Unsent again, it can be taken out of the composer.
        await store.removeUnsent([file.id])
        XCTAssertEqual(filesKept(), [])
    }

    func testAFileWhoseCopyCannotBeKept_isRefusedPlainlyAndLeavesNothing() async throws {
        // Where the store would keep its files there is a file, not a folder.
        let blocked = FileManager.default.temporaryDirectory.appendingPathComponent("blocked-\(UUID().uuidString)")
        try Data().write(to: blocked)
        defer { try? FileManager.default.removeItem(at: blocked) }
        let unwritable = AttachmentStore(directory: blocked)

        do {
            _ = try await unwritable.add(Data("text".utf8), named: "notes.txt", mimeType: "text/plain", toThread: threadID)
            XCTFail("Nothing is attached that could not be kept")
        } catch {
            XCTAssertEqual(error as? AttachmentStore.Failure, .notKept(name: "notes.txt"))
            XCTAssertEqual(error.localizedDescription, "notes.txt could not be attached.", "It was read; it is not said to be unreadable")
        }
        let userID = await MainActor.run { UserScope.currentUserID }
        let rows = try await store.ids(inThread: threadID, for: userID)
        XCTAssertEqual(rows, [], "No row is left for a file that is not there")
    }

    func testAThreadsAttachments_goWithIt() async throws {
        let userID = await MainActor.run { UserScope.currentUserID }
        let first = try await store.add(Data("one".utf8), named: "one.txt", mimeType: "text/plain", toThread: threadID)
        let second = try await store.add(Data("two".utf8), named: "two.txt", mimeType: "text/plain", toThread: threadID)
        try await store.markSent([first.id], with: "message-1", inThread: threadID)
        let ids = try await store.ids(inThread: threadID, for: userID)
        XCTAssertEqual(Set(ids), [first.id, second.id])

        // As deleting the thread does: its rows go with its row, then its files.
        try await ThreadRepository.shared.deleteThread(id: threadID, for: userID)
        await store.deleteFiles(ids, for: userID)

        XCTAssertEqual(filesKept(), [])
        let gone = try await row(first.id)
        XCTAssertNil(gone, "The rows went with the thread")

        // And an account's files all go with the account.
        let another = try await ThreadService.shared.createThread(title: "Attachments \(UUID().uuidString)").id
        addTeardownBlock { try? await ThreadService.shared.deleteThread(threadId: another) }
        _ = try await store.add(Data("three".utf8), named: "three.txt", mimeType: "text/plain", toThread: another)
        XCTAssertEqual(filesKept().count, 1)
        await store.deleteAllFiles(for: userID)
        XCTAssertEqual(filesKept(), [])
    }

    // MARK: - Pictures

    /// A picture as a camera writes it: `orientation` and where it was taken
    /// written into it.
    private func photo(width: Int, height: Int, orientation: Int = 1, type: UTType = .jpeg, hasAlpha: Bool = false) throws -> Data {
        let alpha: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : .noneSkipLast
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: alpha.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.4, alpha: hasAlpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 13.7563, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 100.5018, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Taken at home"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "A phone"],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func properties(of data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    func testAPhoto_isKeptUprightWithoutWhereAndHowItWasTaken() async throws {
        // Taken on its side: stored 40 wide and 20 high, to be shown turned.
        let taken = try photo(width: 40, height: 20, orientation: 6)
        let before = try properties(of: taken)
        XCTAssertNotNil(before[kCGImagePropertyGPSDictionary], "The photo as taken says where")

        let attached = try await store.add(taken, named: "IMG_0001.HEIC", mimeType: "image/heic", toThread: threadID)

        XCTAssertEqual(attached.name, "IMG_0001.jpg")
        XCTAssertEqual(attached.mimeType, "image/jpeg")
        XCTAssertEqual(attached.width, 20, "Upright, as it was taken")
        XCTAssertEqual(attached.height, 40)
        let kept = try await store.data(of: attached.id)
        XCTAssertEqual(attached.sizeBytes, kept.count)
        let after = try properties(of: kept)
        XCTAssertNil(after[kCGImagePropertyGPSDictionary], "Where it was taken is not kept")
        XCTAssertNil((after[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment])
        XCTAssertNil((after[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel])
        XCTAssertTrue([nil, 1].contains(after[kCGImagePropertyOrientation] as? Int), "Nothing left to turn")
        XCTAssertEqual(after[kCGImagePropertyPixelWidth] as? Int, 20)
    }

    func testPictures_keepWhatCanBeSeenThroughThemAndAreNoLargerThanAModelTakes() throws {
        // See-through stays see-through, as a PNG.
        let clear = try AttachmentImage.prepared(photo(width: 16, height: 16, type: .png, hasAlpha: true), name: "logo.png", mimeType: "image/png")
        XCTAssertEqual(clear.mimeType, "image/png")
        XCTAssertEqual(clear.name, "logo.png")
        XCTAssertNil(try properties(of: clear.data)[kCGImagePropertyGPSDictionary])

        // Larger than a kept picture is: made smaller, keeping its shape.
        let large = try AttachmentImage.prepared(photo(width: 6000, height: 3000), name: "pano.jpeg", mimeType: "image/jpeg")
        XCTAssertEqual(large.width, AttachmentImage.longestEdge)
        XCTAssertEqual(large.height, AttachmentImage.longestEdge / 2)
        XCTAssertEqual(large.name, "pano.jpg")

        // With no name of its own it still gets one.
        let unnamed = try AttachmentImage.prepared(photo(width: 8, height: 8), name: "", mimeType: nil)
        XCTAssertEqual(unnamed.name, "image.jpg")
    }

    func testWhatIsNotAPicture_isKeptAsItIs() throws {
        let text = Data("# Notes\nplain text".utf8)
        XCTAssertEqual(
            try AttachmentImage.prepared(text, name: "notes.md", mimeType: "text/markdown"),
            AttachmentImage.Prepared(data: text, name: "notes.md", mimeType: "text/markdown")
        )
        // Named as a picture, but not one: kept as the file it is.
        let notAPicture = try AttachmentImage.prepared(text, name: "fake.png", mimeType: "image/png")
        XCTAssertEqual(notAPicture.data, text)
        XCTAssertNil(notAPicture.width)

        XCTAssertEqual(AttachmentImage.mimeType(forFileNamed: "report.pdf"), "application/pdf")
        XCTAssertEqual(AttachmentImage.mimeType(forFileNamed: "notes.txt"), "text/plain")
        XCTAssertEqual(AttachmentImage.mimeType(forFileNamed: "archive.unknownkind"), "application/octet-stream")
        XCTAssertEqual(AttachmentImage.mimeType(forFileNamed: "no extension"), "application/octet-stream")
    }

    func testAPictureThatMoves_isKeptWhole() throws {
        // Two frames.
        let frames = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(frames, UTType.gif.identifier as CFString, 2, nil))
        for shade in [0.2, 0.8] {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: 12, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            context.setFillColor(CGColor(red: shade, green: shade, blue: shade, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 10))
            try CGImageDestinationAddImage(destination, XCTUnwrap(context.makeImage()), nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let moving = frames as Data

        let kept = try AttachmentImage.prepared(moving, name: "wave.gif", mimeType: nil)

        XCTAssertEqual(kept.data, moving, "Every frame of it")
        XCTAssertEqual(kept.name, "wave.gif")
        XCTAssertEqual(kept.mimeType, "image/gif")
        XCTAssertEqual(kept.width, 12)
        XCTAssertEqual(kept.height, 10)
    }
}
