import SwiftUI

/// The app's main view once signed in: the shell, as the cloud app's. On
/// the Mac it is one split view, with the Settings window opened on request
/// and deep links, which all lead into Settings. On the iPad and iPhone it
/// is the split layout where there is room for it (an iPad unless its
/// width is compact) and the phone's layout otherwise: one view either way,
/// so a device that changes between them keeps where it is.
struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authService: AuthService
    #if os(macOS)
    @Environment(\.openSettings) private var openSettingsWindow
    #else
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    /// Whether the shell (sidebar and content) is on screen rather than
    /// the phone's layout.
    private var usesSplitLayout: Bool {
        #if os(macOS)
        true
        #else
        PlatformCapabilities.usesSplitLayout(
            isPhone: PlatformCapabilities.isPhone, horizontal: horizontalSizeClass, vertical: verticalSizeClass
        )
        #endif
    }

    var body: some View {
        root
            // Its state is one account's: another account starts afresh.
            .id(authService.currentUser?.id ?? UserScope.localUserID)
        #if os(macOS)
            // The Mac's window, as it has always been reported: the iPhone
            // and iPad report no such screen.
            .task {
                AnalyticsService.shared.trackScreenView(screenName: "HomeView", screenClass: "HomeView")
            }
            // A link into Settings opens the Settings window (the shell
            // takes the others). Also the link that was waiting when the
            // window came up.
            .onChange(of: appState.pendingDeepLink, initial: true) { _, newValue in
                guard let place = newValue.flatMap(HomeView.settingsPlace(for:)) else { return }
                _ = appState.consumeDeepLink()
                _ = appState.openSettings(for: place)
            }
            .onChange(of: appState.settingsRequests) { _, _ in
                openSettingsWindow()
            }
        #endif
            // Controls take the iPad's shape in the iPad's layout, an
            // iPhone in the split layout included. Last in the chain, so
            // what the shell presents inherits it.
            .environment(\.isPadLayout, PlatformCapabilities.isPad || (PlatformCapabilities.isPhone && usesSplitLayout))
    }

    @ViewBuilder
    private var root: some View {
        #if os(macOS)
        ShellRootView()
        #else
        // One view for both layouts, so a device that changes between them
        // keeps where it is. The phone's layout always sees compact width,
        // as on any iPhone: a large one in landscape is regular wide, and
        // its views would otherwise draw their wide shapes.
        ShellRootView(isSplit: usesSplitLayout)
            .environment(\.horizontalSizeClass, usesSplitLayout ? horizontalSizeClass : .compact)
        #endif
    }

    /// The place in Settings a deep link leads to; nil for a link that
    /// leads elsewhere.
    static func settingsPlace(for target: DeepLinkTarget) -> WorkspaceTabType? {
        switch target {
        case .connectedApps: .connectedApps
        case .providerKeys: .providerKeys
        case .budgets: .budget
        case .usage: .usage
        case .settings: .settings
        case .newThread: nil
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(AppState.shared)
        .environmentObject(AuthService.shared)
}
