import XCTest
@testable import AICoven

/// Tests for the global AppState singleton (deep links + basic thread flows).
@MainActor
final class AppStateTests: XCTestCase {

    override func tearDown() async throws {
        // Reset deep link state between tests.
        AppState.shared.pendingDeepLink = nil
        try await super.tearDown()
    }

    func testHandleDeepLink_parsesConnectedAppsURL() throws {
        let url = try XCTUnwrap(URL(string: "aicoven://settings/connected-apps"))
        AppState.shared.handleDeepLink(url)

        let target = AppState.shared.consumeDeepLink()
        XCTAssertEqual(target, .connectedApps)
        // After consume, there should be no pending deep link.
        XCTAssertNil(AppState.shared.consumeDeepLink())
    }

    func testCreateNewThreadAppendsAndSelectsThread() async throws {
        let state = AppState.shared

        // Start from current list; we only assert that a new thread is added and
        // selected, not the absolute count.
        let initialCount = state.threads.count

        state.createNewThread()

        // Give the async Task launched inside createNewThread a brief window to
        // complete. In practice this is very fast since it only touches the
        // local ThreadService.
        try await Task.sleep(nanoseconds: 300_000_000) // 0.3s

        XCTAssertGreaterThan(state.threads.count, initialCount)
        XCTAssertNotNil(state.selectedThread)
    }
}
