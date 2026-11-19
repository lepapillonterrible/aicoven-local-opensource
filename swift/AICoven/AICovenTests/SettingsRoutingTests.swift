@testable import AICoven
import XCTest

@MainActor
final class SettingsRoutingTests: XCTestCase {
    override func tearDown() async throws {
        AppState.shared.requestedSettingsPane = nil
        try await super.tearDown()
    }

    func testOpenSettings_takesThePlacesSettingsHoldsAndLeavesOtherTabsAlone() {
        let appState = AppState.shared
        let before = appState.settingsRequests

        XCTAssertTrue(appState.openSettings(for: .providerKeys))
        XCTAssertEqual(appState.requestedSettingsPane, .providerKeys)
        XCTAssertEqual(appState.requestedSettingsPane.flatMap(SettingsPane.init), .aiConnections)

        XCTAssertTrue(appState.openSettings(for: .settings))
        XCTAssertNil(appState.requestedSettingsPane)

        XCTAssertFalse(appState.openSettings(for: .mcpServers))
        XCTAssertFalse(appState.openSettings(for: .personalStrixSettings))
        XCTAssertEqual(appState.settingsRequests, before + 2)
    }

    func testEveryFormerSettingsTab_namesAPane() {
        XCTAssertEqual(SettingsPane(.connectedApps), .connectedApps)
        XCTAssertEqual(SettingsPane(.usage), .usage)
        XCTAssertEqual(SettingsPane(.budget), .usage)
        XCTAssertEqual(SettingsPane(.store), .subscription)
        XCTAssertEqual(SettingsPane(.profile), .account)
        XCTAssertEqual(SettingsPane(.terms), .about)
        XCTAssertEqual(SettingsPane(.privacy), .about)
    }
}
