@testable import AICoven
import CoreGraphics
import CryptoKit
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

    /// The ids of the thread's attachments, as the database holds them.
    private func attachmentIDs() async throws -> [String] {
        let threadID = threadID
        return try await MainActor.run { DatabaseManager.shared.dbQueue }?.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM attachments WHERE thread_id = ?", arguments: [threadID])
        } ?? []
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
        do {
            try await store.markSent([othersAttachment], with: "message", inThread: othersThread)
            XCTFail("Another account's attachment is not this account's to send")
        } catch {
            XCTAssertEqual(error as? AttachmentStore.Failure, .missing)
        }
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
        // Sent with a message that is in the thread.
        let message = TurnProgress.message(in: threadID, role: "user", content: "With a file")
        try await ThreadRepository.shared.appendChatMessage(message)
        try await store.markSent([sent.id], with: message.id, inThread: threadID)
        // Marked for a message that was then never stored.
        let neverStored = try await store.add(Data("lost".utf8), named: "lost.txt", mimeType: "text/plain", toThread: threadID)
        try await store.markSent([neverStored.id], with: "message-never-stored", inThread: threadID)
        // And a file with no row: one whose thread went as it was written.
        let strayFile = try XCTUnwrap(filesKept().first).deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data("nobody's".utf8).write(to: strayFile)

        // The next run of the app: a store that has cleared nothing yet.
        let nextRun = AttachmentStore(directory: folder)
        await nextRun.clearLeftovers(for: userID)
        XCTAssertEqual(filesKept().map(\.lastPathComponent), [sent.id], "Only what was sent is left")
        let cleared = try await row(unsent.id)
        XCTAssertNil(cleared)
        let alsoCleared = try await row(neverStored.id)
        XCTAssertNil(alsoCleared)

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
        let rows = try await attachmentIDs()
        XCTAssertEqual(rows, [], "No row is left for a file that is not there")
    }

    func testFilesThatAreNoLongerThere_areNotMarkedAsSentWithAMessage() async throws {
        let kept = try await store.add(Data("kept".utf8), named: "kept.txt", mimeType: "text/plain", toThread: threadID)
        let removed = try await store.add(Data("removed".utf8), named: "removed.txt", mimeType: "text/plain", toThread: threadID)
        // Taken out in another window as the message was sent.
        await store.removeUnsent([removed.id])

        do {
            try await store.markSent([kept.id, removed.id], with: "message-1", inThread: threadID)
            XCTFail("A message is not sent with a file that is gone")
        } catch {
            XCTAssertEqual(error as? AttachmentStore.Failure, .missing)
        }
        let unmarked = try await row(kept.id)
        XCTAssertNil(unmarked?["message_id"] as String?, "Nothing of that message is marked")
    }

    func testAThreadsAttachments_goWithIt() async throws {
        let userID = await MainActor.run { UserScope.currentUserID }
        let first = try await store.add(Data("one".utf8), named: "one.txt", mimeType: "text/plain", toThread: threadID)
        let second = try await store.add(Data("two".utf8), named: "two.txt", mimeType: "text/plain", toThread: threadID)
        try await store.markSent([first.id], with: "message-1", inThread: threadID)

        // As deleting the thread does: its attachments are listed as its
        // row goes, theirs with it, and then their files.
        let ids = try await ThreadRepository.shared.deleteThread(id: threadID, for: userID)
        XCTAssertEqual(Set(ids), [first.id, second.id])
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

    func testDeletingAThreadInTheApp_deletesItsAttachedFiles() async throws {
        // Through the app's own store and thread service, as a person does.
        let shared = AttachmentStore.shared
        let attached = try await shared.add(Data("with the thread".utf8), named: "notes.txt", mimeType: "text/plain", toThread: threadID)
        let read = try await shared.data(of: attached.id)
        XCTAssertEqual(String(decoding: read, as: UTF8.self), "with the thread")
        let userID = await MainActor.run { UserScope.currentUserID }
        let base = await MainActor.run { DatabaseManager.shared.databaseURL.deletingLastPathComponent() }
        let digest = SHA256.hash(data: Data(userID.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = base.appendingPathComponent("Attachments").appendingPathComponent(digest).appendingPathComponent(attached.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        try await ThreadService.shared.deleteThread(threadId: threadID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Its file went with the thread")
        do {
            _ = try await shared.data(of: attached.id)
            XCTFail("It is gone")
        } catch {
            XCTAssertEqual(error as? AttachmentStore.Failure, .missing)
        }
    }

    // MARK: - For a thread that is not made yet

    func testFilesForAThreadThatIsNotMadeYet_areKeptUnderARowThatIsNoThread_andMovedToTheThreadMadeForThem() async throws {
        let userID = await MainActor.run { UserScope.currentUserID }
        let holding = try await store.holdingThread()
        XCTAssertEqual(holding, AttachmentStore.holdingThreadID(for: userID))
        XCTAssertTrue(holding.hasPrefix("unsent-files-"))
        XCTAssertEqual(holding.count, "unsent-files-".count + 64, "A digest, not the account's id")
        XCTAssertFalse(holding.contains(userID))
        // Asked for again: the same row, once.
        let again = try await store.holdingThread()
        XCTAssertEqual(again, holding)
        let rows = try await MainActor.run { DatabaseManager.shared.dbQueue }?.read { db in
            try Row.fetchAll(db, sql: "SELECT user_id, payload_ciphertext FROM threads WHERE id = ?", arguments: [holding])
        } ?? []
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["user_id"] as String?, userID)
        XCTAssertNil(rows.first?["payload_ciphertext"] as Data?, "It holds no thread")
        // It is no thread to list, mark or count.
        let listed = try await ThreadRepository.shared.loadChatThreads()
        XCTAssertFalse(listed.contains { $0.id == holding })
        let marks = try await ThreadRepository.shared.threadMarks(for: userID)
        XCTAssertNil(marks[holding])
        await ThreadService.shared.reloadForCurrentUser()
        let shown = try await ThreadService.shared.loadThreads(covenId: nil, includeArchived: true)
        XCTAssertFalse(shown.contains { $0.id == holding })
        // Nor to the older readers, which read every row of the account's: the agents' own threads, which hold no
        // payload either, are still theirs to read.
        let agentThread = try await ThreadRepository.shared.createThread(title: "An agent's thread \(UUID().uuidString)")
        let all = try await ThreadRepository.shared.fetchAllThreads()
        XCTAssertFalse(all.contains { $0.id == holding })
        XCTAssertTrue(all.contains { $0.id == agentThread.id })
        let opened = try await ThreadRepository.shared.loadThread(id: holding)
        XCTAssertNil(opened)
        let agentOpened = try await ThreadRepository.shared.loadThread(id: agentThread.id)
        XCTAssertEqual(agentOpened?.id, agentThread.id)
        let isOne = try await ThreadRepository.shared.isThread(holding, of: userID)
        XCTAssertFalse(isOne)
        let agentIsOne = try await ThreadRepository.shared.isThread(agentThread.id, of: userID)
        XCTAssertTrue(agentIsOne)
        _ = try await ThreadRepository.shared.deleteThread(id: agentThread.id, for: userID)

        // A file attached there is read like any other, and moves to the thread made for it without its bytes moving.
        let kept = try await store.add(Data("first".utf8), named: "first.txt", mimeType: "text/plain", toThread: holding)
        let other = try await store.add(Data("second".utf8), named: "second.txt", mimeType: "text/plain", toThread: holding)
        let before = Set(filesKept().map(\.lastPathComponent))
        try await store.moveUnsent([kept.id, other.id], toThread: threadID, for: userID)
        let moved = try await attachmentIDs()
        XCTAssertEqual(Set(moved), [kept.id, other.id])
        XCTAssertEqual(Set(filesKept().map(\.lastPathComponent)), before)
        let read = try await store.data(of: kept.id)
        XCTAssertEqual(String(decoding: read, as: UTF8.self), "first")
        // The thread's now: sent with a message of it.
        try await store.markSent([kept.id, other.id], with: "m1", inThread: threadID)
    }

    func testOnlyUnsentFilesOfTheAccountsHoldingRowAreMoved_allOrNone() async throws {
        let userID = await MainActor.run { UserScope.currentUserID }
        let holding = try await store.holdingThread()
        let waiting = try await store.add(Data("waiting".utf8), named: "waiting.txt", mimeType: "text/plain", toThread: holding)
        let elsewhere = try await store.add(Data("elsewhere".utf8), named: "elsewhere.txt", mimeType: "text/plain", toThread: threadID)

        func threadOf(_ id: String) async throws -> String? {
            try await row(id)?["thread_id"]
        }
        // One that is not under the holding row: nothing is moved, the one before it either.
        do {
            try await store.moveUnsent([waiting.id, elsewhere.id], toThread: threadID, for: userID)
            XCTFail("Moved a file that was not waiting for a thread")
        } catch {
            XCTAssertEqual(error as? AttachmentStore.Failure, .missing)
        }
        let stillWaiting = try await threadOf(waiting.id)
        XCTAssertEqual(stillWaiting, holding)
        // One that is not there, and one asked for as another account.
        for (ids, account) in [([waiting.id, UUID().uuidString], userID), ([waiting.id], "someone-else")] {
            do {
                try await store.moveUnsent(ids, toThread: threadID, for: account)
                XCTFail("Moved")
            } catch {
                XCTAssertEqual(error as? AttachmentStore.Failure, .missing)
            }
        }
        // To a thread that is not there: refused by the store, and it stays where it was.
        do {
            try await store.moveUnsent([waiting.id], toThread: "no-such-thread", for: userID)
            XCTFail("Moved to a thread that is not the account's")
        } catch {
            XCTAssertNotEqual(error as? AttachmentStore.Failure, .missing)
        }
        let afterAll = try await threadOf(waiting.id)
        XCTAssertEqual(afterAll, holding)
        // None to move is nothing to do.
        try await store.moveUnsent([], toThread: threadID, for: userID)

        // While the data is locked there is no row to keep files under.
        await DataEncryptionService.shared.lock()
        do {
            _ = try await store.holdingThread()
            XCTFail("Made while the data is locked")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .dataLocked)
        }
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        await store.removeUnsent([waiting.id, elsewhere.id])
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

        // A photo whose redrawn copy would carry an alpha channel it never
        // had is still a photo: kept as a JPEG, as it says of itself.
        let opaque = try AttachmentImage.prepared(photo(width: 16, height: 16, type: .png), name: "scan.png", mimeType: "image/png")
        XCTAssertEqual(opaque.mimeType, "image/jpeg")
        XCTAssertEqual(opaque.name, "scan.jpg")

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
