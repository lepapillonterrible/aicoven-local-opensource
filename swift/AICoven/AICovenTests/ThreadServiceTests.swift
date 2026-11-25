import XCTest
@testable import AICoven

/// Tests for the local-only ThreadService, which keeps threads in the
/// encrypted local database.
@MainActor
final class ThreadServiceTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        await ThreadService.shared.reloadForCurrentUser()
    }

    override func tearDown() async throws {
        await ThreadService.shared.reloadForCurrentUser()
        await DataEncryptionService.shared.lock()
        try await super.tearDown()
    }

    func testCreateThreadAddsPersonalThreadAndCanBeLoaded() async throws {
        let service = ThreadService.shared

        // Capture existing IDs so we can look for the newly-created one.
        let existing = try await service.loadThreads(covenId: nil)
        let existingIDs = Set(existing.map(\.id))

        let title = "Test Thread " + UUID().uuidString
        let thread = try await service.createThread(title: title, covenId: nil, agentId: nil)

        XCTAssertEqual(thread.title, title)
        XCTAssertFalse(thread.id.isEmpty)

        let loaded = try await service.loadThreads(covenId: nil)
        XCTAssertTrue(loaded.contains(where: { $0.id == thread.id && $0.title == title }))
        // Sanity check that we actually added something new relative to the
        // snapshot at the start of the test.
        XCTAssertFalse(existingIDs.contains(thread.id))
    }

    func testAThreadChangedIsToldToWhatListsThreads_andAnArchivedOneIsNotAmongThoseNotArchived() async throws {
        let service = ThreadService.shared
        let created = try await service.createThread(title: "Told " + UUID().uuidString, covenId: nil, agentId: nil)
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await ThreadService.shared.deleteThread(threadId: created.id)
        }
        let before = try await service.threadsNotArchived()
        XCTAssertTrue(before.contains { $0.id == created.id }, "Across Strix and every coven")

        let archived = expectation(forNotification: ThreadService.threadChanged, object: nil)
        _ = try await service.updateThread(threadId: created.id, isArchived: true)
        await fulfillment(of: [archived], timeout: 10)
        let afterArchiving = try await service.threadsNotArchived()
        XCTAssertFalse(afterArchiving.contains { $0.id == created.id })

        let renamed = expectation(forNotification: ThreadService.threadChanged, object: nil)
        _ = try await service.updateThread(threadId: created.id, title: "Renamed", isArchived: false)
        await fulfillment(of: [renamed], timeout: 10)
        let afterRenaming = try await service.threadsNotArchived()
        XCTAssertEqual(afterRenaming.first { $0.id == created.id }?.title, "Renamed")
    }

    func testUpdateAndDeleteThreadAffectPersonalStore() async throws {
        let service = ThreadService.shared

        // Create a fresh personal thread for this test.
        let original = try await service.createThread(title: "Original Title", covenId: nil, agentId: nil)

        let updated = try await service.updateThread(
            threadId: original.id,
            title: "Updated Title",
            isPinned: true,
            isArchived: false
        )

        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.title, "Updated Title")
        XCTAssertTrue(updated.isPinned)

        // Now delete and ensure it no longer appears in the personal list.
        try await service.deleteThread(threadId: original.id)
        let afterDelete = try await service.loadThreads(covenId: nil)
        XCTAssertFalse(afterDelete.contains(where: { $0.id == original.id }))
    }

    func testThreadTitlesAreNormalizedOnCreateAndUpdate() async throws {
        let service = ThreadService.shared
        let longTitle = "  First line\n\nSecond line   " + String(repeating: "x", count: 200)

        let created = try await service.createThread(title: longTitle, covenId: nil, agentId: nil)

        XCTAssertFalse(created.title?.contains("\n") ?? true)
        XCTAssertLessThanOrEqual(created.title?.count ?? 0, ThreadInputValidator.maxTitleLength)
        XCTAssertTrue(created.title?.hasPrefix("First line Second line") == true)

        let unchanged = try await service.updateThread(threadId: created.id, title: "   \n  ")
        XCTAssertEqual(unchanged.title, created.title)

        try await service.deleteThread(threadId: created.id)
    }

    func testMissingThreadErrorDoesNotExposeOpaqueThreadID() async {
        let service = ThreadService.shared
        let missingID = "thread-1234567890abcdef"

        do {
            _ = try await service.getThread(threadId: missingID)
            XCTFail("Expected missing thread lookup to throw")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains(missingID))
            XCTAssertEqual(error.localizedDescription, "Thread not found")
        }
    }
}
