import SwiftUI

/// The panes of Settings, in order: tabs in the Mac Settings window, rows
/// in the Settings list on the iPad and iPhone.
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case aiConnections
    case connectedApps
    case usage
    case subscription
    case thisMac
    case appearance
    case account
    case about

    var id: String {
        rawValue
    }

    nonisolated var title: String {
        switch self {
        case .aiConnections: "AI connections"
        case .connectedApps: "Connected apps"
        case .usage: "Usage and budget"
        case .subscription: "Subscription"
        case .thisMac: "This Mac"
        case .appearance: "Appearance"
        case .account: "Profile and account"
        case .about: "About"
        }
    }

    /// The Mac Settings window's tab label: short, so every tab fits the
    /// toolbar.
    nonisolated var tabTitle: String {
        switch self {
        case .aiConnections: "AI"
        case .connectedApps: "Apps"
        case .usage: "Usage"
        case .subscription: "Subscription"
        case .thisMac: "This Mac"
        case .appearance: "Appearance"
        case .account: "Account"
        case .about: "About"
        }
    }

    /// The pane's name where this device lists it: the tab on the Mac, the
    /// row on the iPad and iPhone. Text that sends someone to a pane uses it.
    nonisolated var listedTitle: String {
        #if os(macOS)
        tabTitle
        #else
        title
        #endif
    }

    var systemImage: String {
        switch self {
        case .aiConnections: "key"
        case .connectedApps: "puzzlepiece.extension"
        case .usage: "chart.bar.xaxis"
        case .subscription: "creditcard"
        case .thisMac: "laptopcomputer"
        case .appearance: "paintbrush"
        case .account: "person.crop.circle"
        case .about: "info.circle"
        }
    }

    /// The panes this device shows: This Mac is the Mac's.
    static var available: [SettingsPane] {
        #if os(macOS)
        allCases
        #else
        allCases.filter { $0 != .thisMac }
        #endif
    }

    /// The pane an in-app request names; `nil` when it names none, and
    /// Settings opens where it otherwise would.
    init?(_ type: WorkspaceTabType) {
        switch type {
        case .providerKeys: self = .aiConnections
        case .connectedApps: self = .connectedApps
        case .usage, .budget: self = .usage
        case .store: self = .subscription
        case .profile: self = .account
        case .terms, .privacy: self = .about
        default: return nil
        }
    }
}

/// One pane's content. `request` is the in-app request that opened this
/// pane, when one did: Terms or Privacy open About on that page.
struct SettingsPaneView: View {
    let pane: SettingsPane
    var request: WorkspaceTabType?

    var body: some View {
        content
            .navigationTitle(pane.title)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            // Wherever a pane is pushed (from the Settings list, or at a
            // request that names it), its back button is the stone one.
            .stoneBackButton()
            .onAppear { trackOpened() }
    }

    /// The open events the panes' screens sent when they were tabs.
    private func trackOpened() {
        switch pane {
        case .connectedApps: AnalyticsService.shared.trackConnectedAppsOpened()
        case .usage: AnalyticsService.shared.trackUsageViewed()
        case .account: AnalyticsService.shared.trackProfileOpened()
        case .aiConnections, .subscription, .thisMac, .appearance, .about: break
        }
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .aiConnections:
            ProviderKeysView()
        case .connectedApps:
            ConnectedAppsView()
        case .usage:
            UsageSettingsView()
        case .subscription:
            StoreView()
        case .thisMac:
            #if os(macOS)
            ScrollView {
                FileAccessSettingsSection()
                    .padding(.vertical, Spacing.lg)
            }
            .background(Color.aicovenDark)
            #else
            EmptyView()
            #endif
        case .appearance:
            AppearanceSettingsPane()
        case .account:
            EnhancedProfileView()
        case .about:
            AboutSettingsPane(initialPage: request.flatMap(LegalPage.init))
        }
    }
}

/// The Settings list on the iPad and iPhone: every pane this device shows,
/// pushed.
struct SettingsList: View {
    /// The request Settings was opened with, when it named a place.
    var request: WorkspaceTabType?

    var body: some View {
        List {
            Group {
                Section {
                    rows(.aiConnections, .connectedApps)
                }
                Section {
                    rows(.usage, .subscription)
                }
                Section {
                    rows(.appearance)
                }
                Section {
                    rows(.account, .about)
                }
            }
            .listRowBackground(Color.aicovenSurfaceElevated)
        }
        .scrollContentBackground(.hidden)
        .background(Color.aicovenDark)
        .font(.aicovenBody)
        .navigationTitle("Settings")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            // The pane a request opened arrives on the navigation path.
            .navigationDestination(for: SettingsPane.self) { pane in
                SettingsPaneView(pane: pane, request: request.flatMap { SettingsPane($0) } == pane ? request : nil)
            }
    }

    /// The rows push their pane directly, not by value.
    private func rows(_ panes: SettingsPane...) -> some View {
        ForEach(panes) { pane in
            NavigationLink {
                SettingsPaneView(pane: pane)
            } label: {
                Label(pane.title, systemImage: pane.systemImage)
            }
        }
    }
}
