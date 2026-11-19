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

    override func setUp() async throws {
        try await super.setUp()
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        await service.reloadForCurrentUser()
    }

    override func tearDown() async throws {
        for id in created {
            try? await repository.deleteThread(id: id)
        }
        await service.reloadForCurrentUser()
        await DataEncryptionService.shared.lock()
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
        _ = try await newThread(title: "Locked \(UUID().uuidString)")
        await service.reloadForCurrentUser()
        await DataEncryptionService.shared.lock()

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

    func testImport_movesTheAccountsFilesIntoTheDatabaseOnceAndDeletesThem() async throws {
        let userID = UserScope.currentUserID
        let mine = thread(id: "legacy-mine-\(UUID().uuidString)", userId: userID, title: "From the file")
        let someoneElses = thread(id: "legacy-other-\(UUID().uuidString)", userId: "another-user", title: "Not mine")
        created.append(mine.id)
        let messages = [
            mine.id: [message("l1-\(mine.id)", in: mine.id, content: "First"), message("l2-\(mine.id)", in: mine.id, content: "Second")],
            someoneElses.id: [message("l3-\(mine.id)", in: someoneElses.id, content: "Other")],
            "a-deleted-thread": [message("l4-\(mine.id)", in: "a-deleted-thread", content: "Orphan")],
        ]
        let threadsFile = LegacyChatHistoryImport.threadsFileURL(for: userID)
        let messagesFile = LegacyChatHistoryImport.messagesFileURL(for: userID)
        try write([mine, someoneElses], to: threadsFile)
        try write(messages, to: messagesFile)

        try await LegacyChatHistoryImport.importFiles(for: userID)
        await service.reloadForCurrentUser()
        let threads = try await service.loadThreads()
        let imported = try await ChatService.shared.loadMessages(threadId: mine.id)
        let others = try await ChatService.shared.loadMessages(threadId: someoneElses.id)

        XCTAssertEqual(threads.first { $0.id == mine.id }, mine)
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
        let threadsFile = LegacyChatHistoryImport.threadsFileURL(for: userID)
        try write([mine], to: threadsFile)
        await DataEncryptionService.shared.lock()

        do {
            try await LegacyChatHistoryImport.importFiles(for: userID)
            XCTFail("Nothing can be stored while the data is locked")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: threadsFile.path))

        await DataEncryptionService.shared.unlockForTestingEphemeral()
        try await LegacyChatHistoryImport.importFiles(for: userID)
        let stored = try await repository.loadChatThreads()
        XCTAssertTrue(stored.contains { $0.id == mine.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: threadsFile.path))
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
