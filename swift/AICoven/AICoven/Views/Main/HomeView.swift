#if os(macOS)
import SwiftUI

/// The Mac's main window: the shell (one split view, as the cloud app's),
/// with the Settings window opened on request and deep links, which all
/// lead into Settings.
struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authService: AuthService
    @Environment(\.openSettings) private var openSettingsWindow

    var body: some View {
        // Its state is one account's: another account starts afresh.
        MacShellView()
            .id(authService.currentUser?.id ?? UserScope.localUserID)
            .task {
                AnalyticsService.shared.trackScreenView(screenName: "HomeView", screenClass: "HomeView")
            }
            .onChange(of: appState.pendingDeepLink) { _, newValue in
                guard let target = newValue else { return }
                _ = appState.openSettings(for: HomeView.settingsPlace(for: target))
                _ = appState.consumeDeepLink()
            }
            .onChange(of: appState.settingsRequests) { _, _ in
                openSettingsWindow()
            }
    }

    /// The place in Settings a deep link leads to.
    static func settingsPlace(for target: DeepLinkTarget) -> WorkspaceTabType {
        switch target {
        case .connectedApps: .connectedApps
        case .providerKeys: .providerKeys
        case .budgets: .budget
        case .usage: .usage
        case .settings: .settings
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(AppState.shared)
        .environmentObject(AuthService.shared)
}
#endif
