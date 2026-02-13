import XCTest
@testable import AICoven

/// Tests for the local-only ThreadService that manages personal threads
/// persisted to disk as JSON.
@MainActor
final class ThreadServiceTests: XCTestCase {

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
}
