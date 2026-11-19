import SwiftUI

/// The person's Settings: the standard Settings window on the Mac, a tab
/// per pane; on the iPad and iPhone, a list that pushes each pane.
struct SettingsWorkspaceView: View {
    #if os(macOS)
    @EnvironmentObject private var appState: AppState
    /// The request that opened Settings, when one named a place in it.
    @State private var request: WorkspaceTabType?
    /// The pane on screen, kept on this Mac: Settings reopens on it, and
    /// stays on it when a theme or typography change rebuilds this view.
    @AppStorage("settings.pane") private var selectedPaneID = SettingsPane.aiConnections.rawValue
    /// Counts requests for a legal page, so a repeated one opens the page
    /// afresh. Other requests only select their pane, and leave what is
    /// open in it alone.
    @State private var requestCount = 0
    #endif

    var body: some View {
        content
            .themedColorScheme()
            .onAppear { AnalyticsService.shared.trackSettingsOpened() }
    }

    #if os(macOS)
    private var selection: Binding<SettingsPane> {
        Binding(
            get: { SettingsPane(rawValue: selectedPaneID) ?? .aiConnections },
            set: { selectedPaneID = $0.rawValue }
        )
    }

    private var content: some View {
        TabView(selection: selection) {
            ForEach(SettingsPane.available) { pane in
                let requested = request.flatMap(SettingsPane.init) == pane
                NavigationStack {
                    SettingsPaneView(pane: pane, request: requested ? request : nil)
                }
                .id(requested ? "\(pane.id)-\(requestCount)" : pane.id)
                .tabItem { Label(pane.tabTitle, systemImage: pane.systemImage) }
                .tag(pane)
            }
        }
        .onAppear { showRequestedPane() }
        .onChange(of: appState.requestedSettingsPane) { _, _ in showRequestedPane() }
    }

    private func showRequestedPane() {
        guard let requested = appState.requestedSettingsPane else { return }
        appState.requestedSettingsPane = nil
        if let pane = SettingsPane(requested) {
            request = requested
            if LegalPage(requested) != nil {
                requestCount += 1
            }
            selectedPaneID = pane.rawValue
        }
    }
    #else
    private var content: some View {
        NavigationStack {
            SettingsList()
        }
    }
    #endif
}
