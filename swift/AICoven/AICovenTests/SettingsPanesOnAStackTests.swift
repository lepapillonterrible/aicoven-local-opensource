#if os(iOS)
@testable import AICoven
internal import Combine
import SwiftUI
import UIKit
import XCTest

/// Off the Mac a Settings pane is pushed on a stack whose path the app
/// holds: the phone's one stack, and the Settings place's. A pane that
/// brings a stack of its own empties that path as it arrives and is gone
/// again, as Connected apps and Subscription were.
@MainActor
final class SettingsPanesOnAStackTests: XCTestCase {
    private final class Path: ObservableObject {
        @Published var panes: [SettingsPane] = []
    }

    private struct Stack: View {
        @ObservedObject var path: Path

        var body: some View {
            NavigationStack(path: $path.panes) {
                Text("Settings")
                    .navigationDestination(for: SettingsPane.self) { SettingsPaneView(pane: $0) }
            }
        }
    }

    func testEveryPaneStaysOnTheStackThatPushedIt() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let path = Path()
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(
            rootView: Stack(path: path)
                .environmentObject(AppState.shared)
                .environmentObject(AuthService.shared)
                .environmentObject(StoreService.shared)
        )
        window.rootViewController = host
        window.frame = scene.screen.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let stack = try await settled { Self.navigationController(in: host) }

        for pane in SettingsPane.available {
            path.panes = [pane]
            // The push has ended with the pane on the stack. A pane that
            // emptied the path is popped again, and never settles there.
            _ = try await settled("\(pane.title) left the stack as it arrived") {
                stack.viewControllers.count == 2 && stack.transitionCoordinator == nil ? stack : nil
            }
            XCTAssertEqual(path.panes, [pane], "\(pane.title) emptied the path that pushed it")

            path.panes = []
            _ = try await settled { stack.viewControllers.count == 1 && stack.transitionCoordinator == nil ? stack : nil }
        }
    }

    /// What `find` gives once it gives something; fails if it never does.
    private func settled<Found>(_ failure: String = "never settled", _ find: () -> Found?) async throws -> Found {
        for _ in 0 ..< 400 {
            if let found = find() { return found }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        return try XCTUnwrap(find(), failure)
    }

    private static func navigationController(in controller: UIViewController) -> UINavigationController? {
        if let found = controller as? UINavigationController { return found }
        return controller.children.lazy.compactMap { navigationController(in: $0) }.first
    }
}
#endif
