@testable import AICoven
import GRDB
import XCTest

/// Threads and messages in the encrypted database, and the one-time move of
/// the JSON files earlier builds kept them in.
@MainActor
final class ChatHistoryStoreTests: XCTestCase {
    private let service = ThreadService.shared
    private let repository = ThreadRepository.shared
    private var created: [String] = []
    /// A folder of this test's own for the files an import reads, so no
    /// test touches an account's real ones.
    private var folder: URL!
    private var threadsFile: URL {
        folder.appendingPathComponent("personal_threads.json")
    }

    private var messagesFile: URL {
        folder.appendingPathComponent("messages.json")
    }

    override func setUp() async throws {
        try await super.setUp()
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        await service.reloadForCurrentUser()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("chat-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for id in created {
            try? await repository.deleteThread(id: id, for: UserScope.currentUserID)
        }
        await service.reloadForCurrentUser()
        await DataEncryptionService.shared.lock()
        try? FileManager.default.removeItem(at: folder)
        try await super.tearDown()
    }

    // MARK: - Threads

    func testThreads_surviveAReloadWithEveryFieldAndNoReadableTitle() async throws {
        let title = "Quarterly plan \(UUID().uuidString)"
        let thread = try await newThread(title: title, covenId: "coven-9", agentId: "agent-9")
        let pinned = try await service.updateThread(threadId: thread.id, isPinned: true)

        await service.reloadForCurrentUser()
        let reloaded = try await service.loadThreads(covenId: "coven-9").first { $0.id == thread.id }

        XCTAssertEqual(reloaded, pinned)
        XCTAssertEqual(reloaded?.title, title)
        XCTAssertEqual(reloaded?.agentId, "agent-9")
        let row = try await storedRow(threadID: thread.id)
        XCTAssertNil(row?.title)
        XCTAssertNil(row?.payloadCiphertext?.range(of: Data(title.utf8)))
    }

    func testThreads_cannotBeReadWhileLockedAndLoadOnceUnlocked() async throws {
        let thread = try await newThread(title: "Locked \(UUID().uuidString)")
        // Loaded, then locked: the list in memory must not be served either.
        _ = try await service.loadThreads()
        await DataEncryptionService.shared.lock()

        do {
            _ = try await service.getThread(threadId: thread.id)
            XCTFail("A loaded thread must not be read while the data is locked")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .dataLocked)
        }

        do {
            _ = try await service.loadThreads()
            XCTFail("Threads must not load while the data is locked")
        } catch {}

        // The test key is new at each unlock, so what was stored before is
        // not readable now; the list must still load, and hold what is added.
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        let added = try await newThread(title: "Unlocked \(UUID().uuidString)")
        let loaded = try await service.loadThreads()
        XCTAssertTrue(loaded.contains { $0.id == added.id })
    }

    func testThreads_stillLoadWhenOneWasStoredUnderAnotherKey() async throws {
        let unreadable = try await newThread(title: "Old key \(UUID().uuidString)")
        await service.reloadForCurrentUser()
        // A fresh key, as after the data key was replaced.
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        let readable = try await newThread(title: "Current key \(UUID().uuidString)")
        await service.reloadForCurrentUser()

        let loaded = try await service.loadThreads()

        XCTAssertTrue(loaded.contains { $0.id == readable.id })
        XCTAssertFalse(loaded.contains { $0.id == unreadable.id })
    }

    func testAReadForAnAccount_stopsOnceItIsNoLongerTheCurrentOne() async throws {
        try await repository.requireKey(of: UserScope.currentUserID)

        // A switch of account: the key in memory is still the earlier
        // account's, and a read that began for it is still going.
        await DataEncryptionService.shared.unlockForTestingEphemeral(ownedBy: "earlier-account")
        do {
            try await repository.requireKey(of: "earlier-account")
            XCTFail("Nothing is read for an account that is not the current one, though its key is still in memory")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .accountChanged)
        }
        // And nothing of the new account's is read with the earlier one's key.
        do {
            try await repository.requireKey(of: UserScope.currentUserID)
            XCTFail("Nothing is read with another account's key")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .dataLocked)
        }

        await DataEncryptionService.shared.lock()
        do {
            try await repository.requireKey(of: UserScope.currentUserID)
            XCTFail("Nothing is read while the data is locked")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .dataLocked)
        }
        await DataEncryptionService.shared.unlockForTestingEphemeral()
    }

    func testAReadThatFindsNothing_stillThrowsWhileTheDataIsLocked() async throws {
        let empty = "empty-\(UUID().uuidString)"
        await DataEncryptionService.shared.lock()

        for read in [
            { _ = try await self.repository.loadChatThreads() },
            { _ = try await self.repository.loadChatMessages(threadID: empty, limit: 20, before: nil) },
            { _ = try await self.repository.loadChatMessages(threadID: empty, limit: 20, before: "no-such-message") },
            { _ = try await self.repository.loadWorkTraces(threadID: empty) },
        ] as [() async throws -> Void] {
            do {
                try await read()
                XCTFail("Nothing is read while the data is locked, not even that there is nothing")
            } catch {
                XCTAssertEqual(error as? RepositoryError, .dataLocked)
            }
        }

        await DataEncryptionService.shared.unlockForTestingEphemeral()
        let messages = try await repository.loadChatMessages(threadID: empty, limit: 20, before: nil)
        let traces = try await repository.loadWorkTraces(threadID: empty)
        XCTAssertEqual(messages, [])
        XCTAssertEqual(traces, [:])
    }

    func testAThreadOfAnotherAccount_isNotStoredUnderThisOne() async throws {
        let theirs = thread(id: "not-mine-\(UUID().uuidString)", userId: "another-user", title: "Theirs")

        do {
            try await repository.saveThread(theirs)
            XCTFail("A thread is stored only for the account it belongs to")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .accountChanged)
        }
        let row = try await storedRow(threadID: theirs.id)
        XCTAssertNil(row)
    }

    func testChangesStartedTogether_allLandAndNoneBringsBackADeletedThread() async throws {
        let thread = try await newThread(title: "Before \(UUID().uuidString)")

        async let renamed = service.updateThread(threadId: thread.id, title: "After")
        async let pinned = service.updateThread(threadId: thread.id, isPinned: true)
        _ = try await (renamed, pinned)
        await service.reloadForCurrentUser()
        let both = try await service.getThread(threadId: thread.id)
        XCTAssertEqual(both.title, "After")
        XCTAssertTrue(both.isPinned)

        async let deleted: Void = service.deleteThread(threadId: thread.id)
        async let archived = service.updateThread(threadId: thread.id, isArchived: true)
        try await deleted
        _ = try? await archived
        let row = try await storedRow(threadID: thread.id)
        XCTAssertNil(row)
    }

    // MARK: - Messages

    func testMessages_comeBackInOrderByPageAndGoWithTheirThread() async throws {
        let thread = try await newThread(title: "Paging \(UUID().uuidString)")
        let sent = (1 ... 5).map { message("m\($0)-\(thread.id)", in: thread.id, content: "Message \($0)") }
        for message in sent {
            await ChatService.shared.addLocalMessage(message)
        }

        let newest = try await ChatService.shared.loadMessages(threadId: thread.id, limit: 2)
        let older = try await ChatService.shared.loadMessages(threadId: thread.id, limit: 2, before: newest.first?.id)
        let all = try await ChatService.shared.loadMessages(threadId: thread.id)

        XCTAssertEqual(newest.map(\.content), ["Message 4", "Message 5"])
        XCTAssertEqual(older.map(\.content), ["Message 2", "Message 3"])
        XCTAssertEqual(all, sent)

        try await service.deleteThread(threadId: thread.id)
        let afterDelete = try await ChatService.shared.loadMessages(threadId: thread.id)
        XCTAssertTrue(afterDelete.isEmpty)
        let rows = try await DatabaseManager.shared.dbQueue?.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE thread_id = ?", arguments: [thread.id])
        }
        XCTAssertEqual(rows, 0)
    }

    func testMessages_addedOneAfterAnotherAreStoredInThatOrder() async throws {
        let thread = try await newThread(title: "Order \(UUID().uuidString)")
        let sent = (1 ... 30).map { message("o\($0)-\(thread.id)", in: thread.id, content: "Message \($0)") }

        // Started in order from the main actor, none waiting for the one
        // before it to finish.
        let adding = sent.map { message in Task { @MainActor in try await repository.appendChatMessage(message) } }
        for task in adding {
            try await task.value
        }

        let loaded = try await ChatService.shared.loadMessages(threadId: thread.id)
        XCTAssertEqual(loaded.map(\.content), sent.map(\.content))
    }

    func testMessages_pagePastOneThatCannotBeRead() async throws {
        let thread = try await newThread(title: "Damaged \(UUID().uuidString)")
        for number in 1 ... 5 {
            await ChatService.shared.addLocalMessage(message("d\(number)-\(thread.id)", in: thread.id, content: "Message \(number)"))
        }
        try await DatabaseManager.shared.dbQueue?.write { db in
            try db.execute(
                sql: "UPDATE messages SET content_ciphertext = ? WHERE id = ?",
                arguments: [Data(repeating: 7, count: 64), "d4-\(thread.id)"]
            )
        }

        let newest = try await ChatService.shared.loadMessages(threadId: thread.id, limit: 2)
        let older = try await ChatService.shared.loadMessages(threadId: thread.id, limit: 2, before: newest.first?.id)

        XCTAssertEqual(newest.map(\.content), ["Message 3", "Message 5"])
        XCTAssertEqual(older.map(\.content), ["Message 1", "Message 2"])
    }

    func testMessages_keepTheirMetadataAndAreNotReadableInTheDatabase() async throws {
        let thread = try await newThread(title: "Metadata \(UUID().uuidString)")
        let secret = "The launch code is \(UUID().uuidString)"
        let sent = ChatMessage(
            id: "meta-\(thread.id)",
            threadId: thread.id,
            role: "assistant",
            content: secret,
            metadata: ["model": .string("qwen-9"), "provider": .string("openai_compatible")],
            tokenUsage: TokenUsage(promptTokens: 3, completionTokens: 5, totalTokens: 8),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isEncrypted: false,
            keyFingerprint: nil
        )
        await ChatService.shared.addLocalMessage(sent)

        let loaded = try await ChatService.shared.loadMessages(threadId: thread.id)
        let stored = try await DatabaseManager.shared.dbQueue?.read { db in
            try Data.fetchOne(db, sql: "SELECT content_ciphertext FROM messages WHERE id = ?", arguments: [sent.id])
        }

        XCTAssertEqual(loaded, [sent])
        XCTAssertNotNil(stored)
        XCTAssertNil(stored?.range(of: Data(secret.utf8)))
    }

    // MARK: - The files earlier builds kept

    func testImport_movesTheAccountsFilesIntoTheDatabaseAndDeletesThem() async throws {
        let userID = UserScope.currentUserID
        let mine = thread(id: "legacy-mine-\(UUID().uuidString)", userId: userID, title: "From the file")
        let someoneElses = thread(id: "legacy-other-\(UUID().uuidString)", userId: "another-user", title: "Not mine")
        created.append(mine.id)
        try write([mine, someoneElses], to: threadsFile)
        try write([
            mine.id: [message("l1-\(mine.id)", in: mine.id, content: "First"), message("l2-\(mine.id)", in: mine.id, content: "Second")],
            someoneElses.id: [message("l3-\(mine.id)", in: someoneElses.id, content: "Other")],
            "a-deleted-thread": [message("l4-\(mine.id)", in: "a-deleted-thread", content: "Orphan")],
        ], to: messagesFile)

        try await LegacyChatHistoryImport.importFiles(for: userID, threadsFile: threadsFile, messagesFile: messagesFile)
        await service.reloadForCurrentUser()
        let threads = try await service.loadThreads()
        let imported = try await ChatService.shared.loadMessages(threadId: mine.id)
        let others = try await ChatService.shared.loadMessages(threadId: someoneElses.id)

        // As it was in the file, and as lately used as its last message.
        let read = try XCTUnwrap(threads.first { $0.id == mine.id })
        XCTAssertNotNil(read.lastMessageAt)
        XCTAssertEqual(read, mine.lastUsed(at: read.lastMessageAt))
        XCTAssertEqual(read.lastMessageAt, imported.compactMap(\.createdAt).max())
        XCTAssertFalse(threads.contains { $0.id == someoneElses.id })
        XCTAssertEqual(imported.map(\.content), ["First", "Second"])
        XCTAssertTrue(others.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: threadsFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: messagesFile.path))
    }

    func testImport_keepsTheFilesWhenTheDataIsLocked() async throws {
        let userID = UserScope.currentUserID
        let mine = thread(id: "legacy-locked-\(UUID().uuidString)", userId: userID, title: "Kept")
        created.append(mine.id)
        try write([mine], to: threadsFile)
        await DataEncryptionService.shared.lock()

        do {
            try await LegacyChatHistoryImport.importFiles(for: userID, threadsFile: threadsFile, messagesFile: messagesFile)
            XCTFail("Nothing can be stored while the data is locked")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: threadsFile.path))

        await DataEncryptionService.shared.unlockForTestingEphemeral()
        try await LegacyChatHistoryImport.importFiles(for: userID, threadsFile: threadsFile, messagesFile: messagesFile)
        let stored = try await repository.loadChatThreads()
        XCTAssertTrue(stored.contains { $0.id == mine.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: threadsFile.path))
    }

    func testImport_storesNothingAndKeepsTheFilesForAnAccountThatIsNotTheCurrentOne() async throws {
        let other = thread(id: "legacy-switched-\(UUID().uuidString)", userId: "another-user", title: "Theirs")
        try write([other], to: threadsFile)

        do {
            try await LegacyChatHistoryImport.importFiles(for: "another-user", threadsFile: threadsFile, messagesFile: messagesFile)
            XCTFail("History is only imported for the account that is signed in")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .accountChanged)
        }

        let row = try await storedRow(threadID: other.id)
        XCTAssertNil(row)
        XCTAssertTrue(FileManager.default.fileExists(atPath: threadsFile.path))
    }

    func testImport_keepsTheMessagesWhenTheThreadsFileCannotBeRead() async throws {
        let userID = UserScope.currentUserID
        try Data("not-json".utf8).write(to: threadsFile)
        let messages = ["some-thread": [message("kept-\(UUID().uuidString)", in: "some-thread", content: "Do not lose me")]]
        try write(messages, to: messagesFile)
        let written = try Data(contentsOf: messagesFile)

        try await LegacyChatHistoryImport.importFiles(for: userID, threadsFile: threadsFile, messagesFile: messagesFile)

        // Which threads exist is not known, so the messages are neither
        // imported nor deleted: both files are kept under other names.
        let kept = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(kept.count, 2)
        let keptMessages = try XCTUnwrap(kept.first { $0.lastPathComponent.hasPrefix("messages.json.unreadable-") })
        XCTAssertEqual(try Data(contentsOf: keptMessages), written)
    }

    func testImport_keepsBothFilesWhenTheMessagesCannotBeSetAside() async throws {
        let userID = UserScope.currentUserID
        try Data("not-json".utf8).write(to: threadsFile)
        let messages = ["some-thread": [message("stuck-\(UUID().uuidString)", in: "some-thread", content: "Still here")]]
        try write(messages, to: messagesFile)
        // A folder that cannot be written to refuses the move.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }

        try await LegacyChatHistoryImport.importFiles(for: userID, threadsFile: threadsFile, messagesFile: messagesFile)

        // Neither could be moved: both stay, so a later import still finds
        // the threads file unreadable and deletes nothing.
        XCTAssertTrue(FileManager.default.fileExists(atPath: threadsFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: messagesFile.path))
        try await LegacyChatHistoryImport.importFiles(for: userID, threadsFile: threadsFile, messagesFile: messagesFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: messagesFile.path))
    }

    func testImport_storesMessagesOfAThreadThatIsAlreadyInTheDatabase() async throws {
        let userID = UserScope.currentUserID
        let stored = try await newThread(title: "Already here \(UUID().uuidString)")
        try write([
            stored.id: [message("late-\(stored.id)", in: stored.id, content: "Arrived later")],
            "a-deleted-thread": [message("gone-\(stored.id)", in: "a-deleted-thread", content: "Orphan")],
        ], to: messagesFile)

        try await LegacyChatHistoryImport.importFiles(for: userID, threadsFile: threadsFile, messagesFile: messagesFile)

        let loaded = try await ChatService.shared.loadMessages(threadId: stored.id)
        XCTAssertEqual(loaded.map(\.content), ["Arrived later"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: messagesFile.path))
    }

    func testImport_setsAsideAFileItCannotReadAndStillImportsTheOther() async throws {
        let userID = UserScope.currentUserID
        let mine = thread(id: "legacy-partial-\(UUID().uuidString)", userId: userID, title: "Readable")
        created.append(mine.id)
        try write([mine], to: threadsFile)
        let damaged = Data("not-json".utf8)
        try damaged.write(to: messagesFile)

        try await LegacyChatHistoryImport.importFiles(for: userID, threadsFile: threadsFile, messagesFile: messagesFile)

        let stored = try await repository.loadChatThreads()
        XCTAssertTrue(stored.contains { $0.id == mine.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: threadsFile.path))
        // The damaged file is kept under another name, not deleted.
        let kept = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(kept.count, 1)
        XCTAssertTrue(kept[0].lastPathComponent.hasPrefix("messages.json.unreadable-"))
        XCTAssertEqual(try Data(contentsOf: kept[0]), damaged)
    }

    // MARK: - Helpers

    private func newThread(title: String, covenId: String? = nil, agentId: String? = nil) async throws -> AICoven.Thread {
        let thread = try await service.createThread(title: title, covenId: covenId, agentId: agentId)
        created.append(thread.id)
        return thread
    }

    private func thread(id: String, userId: String, title: String) -> AICoven.Thread {
        Thread(
            id: id,
            userId: userId,
            covenId: nil,
            title: title,
            agentId: nil,
            agentName: nil,
            agentModel: nil,
            isPinned: false,
            isArchived: false,
            messageCount: 0,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastMessageAt: nil
        )
    }

    private func message(_ id: String, in threadID: String, content: String) -> ChatMessage {
        ChatMessage(
            id: id,
            threadId: threadID,
            role: "user",
            content: content,
            metadata: nil,
            tokenUsage: nil,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            isEncrypted: false,
            keyFingerprint: nil
        )
    }

    private func write(_ value: some Encodable, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file)
    }

    private func storedRow(threadID: String) async throws -> ThreadRecord? {
        try await DatabaseManager.shared.dbQueue?.read { db in
            try ThreadRecord.fetchOne(db, key: threadID)
        }
    }
}
