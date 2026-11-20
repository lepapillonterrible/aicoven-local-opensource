import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
import UniformTypeIdentifiers
#endif

/// Redesigned workspace with enhanced sidebar and profile menu
struct WorkspaceView: View {
    @EnvironmentObject var authService: AuthService

    let initialCoven: Coven?
    let initialThread: Thread?

    @State private var selectedCoven: Coven?
    @State private var openTabs: [WorkspaceTab] = []
    @State private var activeTabId: String?
    @State private var roles: [Role] = []
    /// Controls the new thread sheet presentation (shared between sidebar and content)
    @State private var showNewThreadSheet = false

    private let analytics = AnalyticsService.shared

    let onSwitchToHome: () -> Void

    init(initialCoven: Coven? = nil, initialThread: Thread? = nil, onSwitchToHome: @escaping () -> Void) {
        self.initialCoven = initialCoven
        self.initialThread = initialThread
        self.onSwitchToHome = onSwitchToHome
        // Initialize State with the passed initial values
        _selectedCoven = State(initialValue: initialCoven)

        if let thread = initialThread {
            let tab = WorkspaceTab.thread(thread)
            _openTabs = State(initialValue: [tab])
            _activeTabId = State(initialValue: tab.id)
        }
    }

    var body: some View {
        ZStack {
            // Nebula background
            NebulaBackground()

            // Main workspace layout
            HStack(spacing: 0) {
                // Enhanced sidebar with coven selector, threads, and roles
                WorkspaceSidebarView(
                    selectedCoven: $selectedCoven,
                    openTabs: $openTabs,
                    activeTabId: $activeTabId,
                    showNewThreadSheet: $showNewThreadSheet,
                    roles: roles,
                    onAddRole: handleAddRole,
                    onEditRole: handleEditRole,
                    onDeleteRole: handleDeleteRole,
                    onTapRole: handleTapRole,
                    onSwitchToHome: onSwitchToHome
                )

                // Vertical divider
                Rectangle()
                    .fill(Color.aicovenBorder)
                    .frame(width: 1)

                // Main content area with tabs and chat
                WorkspaceContentView(
                    selectedCoven: $selectedCoven,
                    openTabs: $openTabs,
                    activeTabId: $activeTabId,
                    roles: $roles,
                    onCreateThread: selectedCoven != nil ? { showNewThreadSheet = true } : nil
                )
            }
        }
        .themedColorScheme()
        .onAppear {
            analytics.trackScreenView(screenName: "WorkspaceView", screenClass: "WorkspaceView")
        }
        .onChange(of: selectedCoven) { _, newValue in
            pruneTabsForSelectedCoven(newValue?.id)
            if let coven = newValue {
                analytics.trackCovenView(covenId: coven.id)
                Task {
                    await loadRoles(covenId: coven.id)
                }
            } else {
                roles = []
            }
        }
    }

    private func pruneTabsForSelectedCoven(_ covenId: String?) {
        openTabs.removeAll { tab in
            switch tab.type {
            case let .thread(thread):
                thread.covenId != covenId
            case let .addRole(tabCovenId):
                tabCovenId != covenId
            case .editRole:
                true
            case let .memoryList(tabCovenId),
                 let .memoryProposals(tabCovenId),
                 let .addMemory(tabCovenId):
                tabCovenId != covenId
            case let .editMemory(_, tabCovenId):
                tabCovenId != covenId
            default:
                false
            }
        }

        if !openTabs.contains(where: { $0.id == activeTabId }) {
            activeTabId = openTabs.last?.id
        }
    }

    /// Load roles for the selected coven
    private func loadRoles(covenId: String) async {
        do {
            roles = try await RoleService.shared.loadRoles(covenId: covenId)
        } catch {
            AppErrorReporter.log(error: error, context: "WorkspaceView.loadRoles")
            roles = []
        }
    }

    /// Handle adding a new role
    private func handleAddRole(covenId: String) {
        let tab = WorkspaceTab.addRole(covenId: covenId)
        if !openTabs.contains(where: { $0.id == tab.id }) {
            openTabs.append(tab)
        }
        activeTabId = tab.id
        analytics.trackFeatureUsage(featureName: "add_role")
    }

    /// Handle editing a role
    private func handleEditRole(role: Role) {
        let tab = WorkspaceTab.editRole(roleId: role.id, roleName: role.name)
        if !openTabs.contains(where: { $0.id == tab.id }) {
            openTabs.append(tab)
        }
        activeTabId = tab.id
        analytics.trackRoleView(roleId: role.id)
    }

    /// Handle deleting a role
    private func handleDeleteRole(role: Role) {
        Task {
            do {
                try await RoleService.shared.deleteRole(roleId: role.id)
                analytics.trackRoleDelete(roleId: role.id)
                // Refresh roles list
                if let coven = selectedCoven {
                    await loadRoles(covenId: coven.id)
                }
                // Close any edit tab for this role
                openTabs.removeAll { tab in
                    if case let .editRole(roleId) = tab.type, roleId == role.id {
                        return true
                    }
                    return false
                }
            } catch {
                AppErrorReporter.log(error: error, context: "WorkspaceView.handleDeleteRole")
                analytics.trackError(errorType: "role_delete", errorMessage: error.localizedDescription, context: "WorkspaceView")
            }
        }
    }

    /// Handle tapping a role to create a new thread
    private func handleTapRole(role: Role) {
        Task {
            do {
                guard let coven = selectedCoven else { return }
                let thread = try await ThreadService.shared.createThread(
                    title: "Chat with \(role.name)",
                    covenId: coven.id,
                    agentId: role.id,
                    agentName: role.name
                )
                analytics.trackThreadCreate(threadId: thread.id, covenId: coven.id, hasTitle: true)
                analytics.trackRoleAssign(roleId: role.id, threadId: thread.id)
                let tab = WorkspaceTab.thread(thread)
                openTabs.append(tab)
                activeTabId = tab.id
            } catch {
                AppErrorReporter.log(error: error, context: "WorkspaceView.handleTapRole")
                analytics.trackError(errorType: "thread_create", errorMessage: error.localizedDescription, context: "WorkspaceView")
            }
        }
    }
}

/// Main content area for the coven workspace with tabs and chat
struct WorkspaceContentView: View {
    @Binding var selectedCoven: Coven?
    @Binding var openTabs: [WorkspaceTab]
    @Binding var activeTabId: String?
    @EnvironmentObject var authService: AuthService
    @Binding var roles: [Role]
    /// Optional callback to create a new thread (passed to empty state CTA)
    var onCreateThread: (() -> Void)?

    var activeTab: WorkspaceTab? {
        openTabs.first(where: { $0.id == activeTabId })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar with profile menu (when no tabs open)
            if openTabs.isEmpty {
                HStack {
                    Spacer()
                    ProfileMenuView(onOpenTab: openTab)
                        .frame(width: 44, height: 44)
                        .padding(.trailing, Spacing.xs)
                }
                .frame(height: 44)
                .background(Color.aicovenGlass)
            } else {
                // Tab bar for open tabs with profile menu integrated
                HStack(spacing: 0) {
                    WorkspaceTabBar(
                        openTabs: $openTabs,
                        activeTabId: $activeTabId
                    )
                    .frame(maxWidth: .infinity)

                    ProfileMenuView(onOpenTab: openTab)
                        .frame(width: 44, height: 44)
                        .padding(.trailing, Spacing.xs)
                }
                .frame(height: 44)
                .background(
                    VStack(spacing: 0) {
                        Color.aicovenGlass
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.aicovenBorder,
                                        Color.clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: 1)
                    }
                )
            }

            // Content area - render based on active tab type
            if let tab = activeTab {
                renderTabContent(tab)
            } else if selectedCoven != nil {
                // Coven selected but no tab open - show CTA to create new thread
                StartConversationPrompt(onCreateThread: onCreateThread)
            } else {
                // No coven selected
                VStack(spacing: Spacing.lg) {
                    Spacer()
                    IconBadge(icon: "sparkles", size: 60, color: .aicovenTeal)
                    Text("Select a coven to get started")
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Render appropriate view based on tab type
    @ViewBuilder
    private func renderTabContent(_ tab: WorkspaceTab) -> some View {
        switch tab.type {
        case let .thread(thread):
            // Reuse PersonalChatView for coven threads (same local chat flow)
            PersonalChatView(
                thread: thread,
                onEditAgent: nil,
                onBack: nil
            )
            .id(thread.id)
        case .mcpServers:
            MCPServerManagementView()
        case let .addRole(covenId):
            AddRoleView(covenId: covenId, roles: roles) {
                // Refresh roles list and close tab
                Task {
                    if let coven = selectedCoven {
                        do {
                            roles = try await RoleService.shared.loadRoles(covenId: coven.id)
                        } catch {
                            AppErrorReporter.log(error: error, context: "WorkspaceContentView.addRole.refreshRoles")
                        }
                    }
                }
                // Close this tab
                if let tabIndex = openTabs.firstIndex(where: { $0.id == tab.id }) {
                    openTabs.remove(at: tabIndex)
                    if activeTabId == tab.id {
                        activeTabId = openTabs.last?.id
                    }
                }
            }
        case let .editRole(roleId):
            EditRoleView(roleId: roleId, roles: roles) {
                // Refresh roles list and close tab
                Task {
                    if let coven = selectedCoven {
                        do {
                            roles = try await RoleService.shared.loadRoles(covenId: coven.id)
                        } catch {
                            AppErrorReporter.log(error: error, context: "WorkspaceContentView.editRole.refreshRoles")
                        }
                    }
                }
                // Close this tab
                if let tabIndex = openTabs.firstIndex(where: { $0.id == tab.id }) {
                    openTabs.remove(at: tabIndex)
                    if activeTabId == tab.id {
                        activeTabId = openTabs.last?.id
                    }
                }
            }
            .id(roleId)
        case let .memoryList(covenId):
            MemoryListView(
                covenId: covenId,
                openTabs: $openTabs,
                activeTabId: $activeTabId
            )
        case let .memoryProposals(covenId):
            MemoryProposalsView(
                covenId: covenId,
                openTabs: $openTabs,
                activeTabId: $activeTabId
            )
        default:
            EmptyView()
        }
    }

    /// Open a new tab
    private func openTab(_ type: WorkspaceTabType) {
        if AppState.shared.openSettings(for: type) { return }

        // Only thread tabs may be open more than once
        if case .thread = type {
            // Allow multiple thread tabs
        } else {
            if let existingTab = openTabs.first(where: { $0.type == type }) {
                activeTabId = existingTab.id
                return
            }
        }

        let tab: WorkspaceTab
        switch type {
        case let .thread(thread):
            tab = .thread(thread)
        case .mcpServers:
            tab = .mcpServers
        case .personalStrixSettings:
            tab = WorkspaceTab.personalStrix
        case let .memoryList(covenId):
            tab = WorkspaceTab.memoryList(covenId: covenId)
        case let .memoryProposals(covenId):
            tab = WorkspaceTab.memoryProposals(covenId: covenId)
        default:
            return
        }

        openTabs.append(tab)
        activeTabId = tab.id
    }
}

#Preview {
    WorkspaceView(onSwitchToHome: {})
        .environmentObject(AuthService.shared)
        .environmentObject(AppState.shared)
}
