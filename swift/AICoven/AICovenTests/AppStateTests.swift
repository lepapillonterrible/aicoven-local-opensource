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

    func testALinkThatIsWaiting_staysThroughASignIn() throws {
        let state = AppState.shared
        // Opened before anyone is signed in: it is what the app was opened with.
        try state.handleDeepLink(XCTUnwrap(URL(string: "aicoven://providers")))
        state.clearUserData()
        XCTAssertEqual(state.pendingDeepLink, .providerKeys, "Signing in keeps it for the main view")
        XCTAssertEqual(state.consumeDeepLink(), .providerKeys)

        // A link that is none of this app's is not held, and takes the place of nothing.
        try state.handleDeepLink(XCTUnwrap(URL(string: "aicoven://usage")))
        try state.handleDeepLink(XCTUnwrap(URL(string: "aicoven://oauth/google/callback?code=abc")))
        XCTAssertEqual(state.consumeDeepLink(), .usage)
    }

    func testALinkThatWaitedUnderAnAccount_isNotKeptForTheNext() throws {
        let state = AppState.shared
        let link = try XCTUnwrap(URL(string: "aicoven://connected-apps"))
        addTeardownBlock { await MainActor.run { state.accountReported(nil) } }

        // The app is opened with a link; the sign-in service's first report is that nobody is signed in.
        state.accountReported(nil)
        state.handleDeepLink(link)
        state.accountReported(nil)
        XCTAssertEqual(state.pendingDeepLink, .connectedApps, "Nobody signed in at the start is no account leaving")
        state.accountReported("ada")
        XCTAssertEqual(state.pendingDeepLink, .connectedApps, "Signing in keeps it for the main view")

        // It is still waiting (the data is locked, say) when the account signs out.
        state.accountReported(nil)
        XCTAssertNil(state.pendingDeepLink, "The next account is not led anywhere by it")

        // One waiting under an account is dropped too when another takes its place without a sign-out between.
        state.accountReported("ada")
        state.handleDeepLink(link)
        state.accountReported("ada")
        XCTAssertEqual(state.pendingDeepLink, .connectedApps, "The same account reported again")
        state.accountReported("grace")
        XCTAssertNil(state.pendingDeepLink)
    }

    func testOnlyALinkIntoSettingsNamesAPlaceInSettings() {
        XCTAssertEqual(HomeView.settingsPlace(for: .connectedApps), .connectedApps)
        XCTAssertEqual(HomeView.settingsPlace(for: .budgets), .budget)
        XCTAssertEqual(HomeView.settingsPlace(for: .settings), .settings)
        XCTAssertNil(HomeView.settingsPlace(for: .newThread), "The shell takes that one")
    }

    func testCreateNewThreadAppendsAndSelectsThread() async throws {
        // Threads are stored encrypted, so the data must be unlocked.
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        await ThreadService.shared.reloadForCurrentUser()
        let state = AppState.shared

        // Start from current list; we only assert that a new thread is added and
        // selected, not the absolute count.
        let initialCount = state.threads.count

        state.createNewThread()

        // createNewThread does its work in a task of its own: wait for the
        // thread to be there, for as long as a slow machine may take, and
        // not for a fixed moment.
        for _ in 0 ..< 200 where state.threads.count <= initialCount || state.selectedThread == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertGreaterThan(state.threads.count, initialCount)
        XCTAssertNotNil(state.selectedThread)
    }
}
