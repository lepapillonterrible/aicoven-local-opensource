import SwiftUI

/// The person's Settings: the standard Settings window on the Mac, a tab
/// per pane; on the iPad and iPhone, a list that pushes each pane.
struct SettingsWorkspaceView: View {
    /// The place in Settings this was opened at, where a request named one.
    private let initialPane: WorkspaceTabType?
    #if !os(macOS)
    /// The panes pushed over the list: the one asked for, to begin with.
    @State private var path: [SettingsPane]
    #endif

    /// Opens at the pane `initialPane` names (Provider Keys, Connected
    /// Apps, …); otherwise the Mac shows the pane its window last showed,
    /// and the iPad and iPhone the list.
    init(initialPane: WorkspaceTabType? = nil) {
        self.initialPane = initialPane
        #if !os(macOS)
        _path = State(initialValue: initialPane.flatMap { SettingsPane($0) }.map { [$0] } ?? [])
        #endif
    }

    #if os(macOS)
    @EnvironmentObject private var appState: AppState
    /// The last request for a legal page, which About opens on.
    @State private var request: WorkspaceTabType?
    /// The pane on screen, kept on this Mac: Settings reopens on it, and
    /// stays on it when a typography change rebuilds this view.
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
        .onAppear {
            // Opened at a pane: shown as any request for one is.
            if let initialPane { appState.requestedSettingsPane = initialPane }
            showRequestedPane()
        }
        .onChange(of: appState.requestedSettingsPane) { _, _ in showRequestedPane() }
    }

    private func showRequestedPane() {
        guard let requested = appState.requestedSettingsPane else { return }
        appState.requestedSettingsPane = nil
        if let pane = SettingsPane(requested) {
            if LegalPage(requested) != nil {
                request = requested
                requestCount += 1
            }
            selectedPaneID = pane.rawValue
        }
    }
    #else
    private var content: some View {
        NavigationStack(path: $path) {
            SettingsList()
                // The pane a request opened arrives on the path. Declared
                // here, at the root of the stack whose path holds panes:
                // the list is also pushed on the phone's stack, where a
                // destination of its own would not be the root's.
                .navigationDestination(for: SettingsPane.self) { pane in
                    SettingsPaneView(pane: pane, request: initialPane.flatMap { SettingsPane($0) } == pane ? initialPane : nil)
                }
        }
    }
    #endif
}
