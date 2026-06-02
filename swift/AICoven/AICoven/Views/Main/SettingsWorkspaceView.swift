import SwiftUI

/// Global settings workspace shown when the gear icon is selected in the icon
/// rail. Layout: a grouped settings list sidebar on the left + the selected
/// setting's content on the right.
///
/// Adapted from the cloud `SettingsWorkspaceView` for the local-first client:
/// no account/sign-out section (the local app has no user accounts) and only
/// the settings surfaces that exist locally are listed.
struct SettingsWorkspaceView: View {
    /// Settings surfaces available in the gear workspace.
    private enum Item: Hashable {
        case profile, preferences
        case providerKeys, usage, connectedApps, mcpServers
        case localModels, fileAccess
        case terms, privacy
    }

    /// The setting currently shown in the content pane.
    @State private var selectedSetting: Item = .providerKeys

    var body: some View {
        ZStack(alignment: .leading) {
            NebulaBackground()

            HStack(spacing: 0) {
                settingsSidebar

                Rectangle()
                    .fill(Color.aicovenBorder)
                    .frame(width: 1)

                renderSettingContent(selectedSetting)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .themedColorScheme()
    }

    // MARK: - Settings sidebar with grouped items

    private var settingsSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.aicovenTextPrimary)
                Text("Settings")
                    .font(.aicovenH3)
                    .foregroundColor(.aicovenTextPrimary)
                Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(Color.aicovenSurfaceElevated.opacity(0.45))

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    SettingsSidebarSection(title: "Account") {
                        SettingsSidebarRow(
                            icon: "person.crop.circle",
                            title: "Profile",
                            isSelected: selectedSetting == .profile,
                            action: { selectedSetting = .profile }
                        )
                        SettingsSidebarRow(
                            icon: "gear",
                            title: "Preferences",
                            isSelected: selectedSetting == .preferences,
                            action: { selectedSetting = .preferences }
                        )
                    }

                    SettingsSidebarSection(title: "Workspace") {
                        SettingsSidebarRow(
                            icon: "key",
                            title: "Provider Keys",
                            isSelected: selectedSetting == .providerKeys,
                            action: { selectedSetting = .providerKeys }
                        )
                        SettingsSidebarRow(
                            icon: "chart.bar.xaxis",
                            title: "Budgets & Usage",
                            isSelected: selectedSetting == .usage,
                            action: { selectedSetting = .usage }
                        )
                        SettingsSidebarRow(
                            icon: "link.circle.fill",
                            title: "Connected Apps",
                            isSelected: selectedSetting == .connectedApps,
                            action: { selectedSetting = .connectedApps }
                        )
                        SettingsSidebarRow(
                            icon: "server.rack",
                            title: "MCP Servers",
                            isSelected: selectedSetting == .mcpServers,
                            action: { selectedSetting = .mcpServers }
                        )
                    }

                    // Local Agent — on-device models and local file access,
                    // the core of the local-first client.
                    SettingsSidebarSection(title: "Local Agent") {
                        SettingsSidebarRow(
                            icon: "brain",
                            title: "On-Device Models",
                            isSelected: selectedSetting == .localModels,
                            action: { selectedSetting = .localModels }
                        )
                        #if os(macOS)
                        SettingsSidebarRow(
                            icon: "folder.badge.gearshape",
                            title: "File Access",
                            isSelected: selectedSetting == .fileAccess,
                            action: { selectedSetting = .fileAccess }
                        )
                        #endif
                    }

                    SettingsSidebarSection(title: "Legal") {
                        SettingsSidebarRow(
                            icon: "doc.text",
                            title: "Terms & Conditions",
                            isSelected: selectedSetting == .terms,
                            action: { selectedSetting = .terms }
                        )
                        SettingsSidebarRow(
                            icon: "hand.raised",
                            title: "Privacy Policy",
                            isSelected: selectedSetting == .privacy,
                            action: { selectedSetting = .privacy }
                        )
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.lg)
            }
        }
        .frame(width: 280)
        .background(Color.aicovenSurfaceElevated.opacity(0.62))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.aicovenBorder)
                .frame(width: 1)
        }
    }

    // MARK: - Render the selected setting's content view

    @ViewBuilder
    private func renderSettingContent(_ type: Item) -> some View {
        switch type {
        case .profile:
            EnhancedProfileView()
        case .preferences:
            EnhancedSettingsView()
        case .providerKeys:
            ProviderKeysView()
        case .usage:
            UsageSettingsView()
        case .connectedApps:
            ConnectedAppsView()
                .environmentObject(StoreService.shared)
        case .mcpServers:
            MCPServerManagementView()
        case .localModels:
            MLXModelSettingsView()
        case .fileAccess:
            #if os(macOS)
            ScrollView {
                FileAccessSettingsSection()
                    .padding(Spacing.lg)
            }
            #else
            Text("File Access is available on macOS.")
                .font(.aicovenBody)
                .foregroundColor(.aicovenTextSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            #endif
        case .terms:
            TermsOfServiceView()
        case .privacy:
            PrivacyPolicyView()
        }
    }
}

// MARK: - Sidebar components

/// A titled section group in the settings sidebar.
private struct SettingsSidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(.aicovenCaption)
                .foregroundColor(.aicovenTextTertiary)
                .padding(.horizontal, Spacing.sm)

            VStack(spacing: Spacing.xxs) {
                content
            }
        }
    }
}

/// A single row in the settings sidebar with icon, title, and selected state.
private struct SettingsSidebarRow: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? .aicovenTeal : .aicovenTextSecondary)
                    .frame(width: 20, alignment: .center)
                Text(title)
                    .font(.aicovenBody)
                    .foregroundColor(isSelected ? .aicovenTextPrimary : .aicovenTextSecondary)
                Spacer()
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: BorderRadius.sm)
                    .fill(
                        isSelected
                            ? Color.aicovenSurfaceElevated
                            : (isHovering ? Color.aicovenGlass.opacity(0.4) : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: BorderRadius.sm)
                    .stroke(isSelected ? Color.aicovenBorder : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
