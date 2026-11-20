import SwiftUI

/// Main home view with personal threads and coven management
struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authService: AuthService
    #if os(macOS)
    @Environment(\.openSettings) private var openSettingsWindow
    #endif

    private let analytics = AnalyticsService.shared

    @State private var covens: [Coven] = []
    @State private var personalThreads: [Thread] = []
    /// Counts the loads of the personal threads, so that only the latest is shown.
    @State private var personalThreadsLoad = 0
    @State private var isLoadingCovens = true
    @State private var showCreateCoven = false

    // Active state
    @State private var selectedThread: Thread?
    @State private var activeTabId: String?
    @State private var openTabs: [WorkspaceTab] = []

    @State private var pendingCovenSelection: Coven?
    @State private var pendingThreadSelection: Thread?

    /// Workspace state - always start in home
    @State private var currentWorkspace: WorkspaceType = .home

    var body: some View {
        Group {
            if isLoadingCovens {
                // Loading state
                CauldronLoadingView(message: "Loading workspace...", size: 80)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.aicovenDark)
            } else if currentWorkspace == .home {
                // Personal workspace
                PersonalWorkspaceView(
                    personalThreads: $personalThreads,
                    selectedThread: $selectedThread,
                    openTabs: $openTabs,
                    activeTabId: $activeTabId,
                    covens: $covens,
                    onCreateCoven: { showCreateCoven = true },
                    onRefreshThreads: loadPersonalThreads,
                    onSwitchToCovens: {
                        if !covens.isEmpty {
                            currentWorkspace = .covens
                            analytics.trackTabSwitch(fromTab: "home", toTab: "covens")
                        } else {
                            showCreateCoven = true
                        }
                    },
                    onSelectCoven: { coven in
                        pendingCovenSelection = coven
                        pendingThreadSelection = nil
                        currentWorkspace = .covens
                        analytics.trackTabSwitch(fromTab: "home", toTab: "covens")
                    }
                )
            } else {
                // Coven workspace
                WorkspaceView(
                    initialCoven: pendingCovenSelection,
                    initialThread: pendingThreadSelection,
                    onSwitchToHome: {
                        currentWorkspace = .home
                        analytics.trackTabSwitch(fromTab: "covens", toTab: "home")
                        // Clear any selected coven state
                        openTabs = []
                        activeTabId = nil
                        pendingCovenSelection = nil
                        pendingThreadSelection = nil
                    }
                )
            }
        }
        .task {
            await loadInitialData()
            analytics.trackScreenView(screenName: "HomeView", screenClass: "HomeView")
        }
        .onChange(of: appState.pendingDeepLink) { _, newValue in
            guard let target = newValue else { return }
            handleDeepLink(target)
            _ = appState.consumeDeepLink()
        }
        #if os(macOS)
        .onChange(of: appState.settingsRequests) { _, _ in
            openSettingsWindow()
        }
        #endif
        .sheet(isPresented: $showCreateCoven) {
            // Pass StoreService so CreateCovenSheet can check entitlements
            CreateCovenSheet(onCreated: { _ in
                Task { await loadCovens() }
            })
            .environmentObject(StoreService.shared)
        }
    }

    private func loadInitialData() async {
        await loadCovens()
        await loadPersonalThreads()
    }

    private func loadCovens() async {
        isLoadingCovens = true
        defer { isLoadingCovens = false }

        do {
            covens = try await CovenService.shared.loadCovens()
            AppErrorReporter.log(message: "Loaded \(covens.count) covens", context: "HomeView.loadCovens")
        } catch {
            AppErrorReporter.log(error: error, context: "HomeView.loadCovens")
            covens = []
        }
    }

    private func loadPersonalThreads() async {
        // Only the latest request is shown: the list is read again on every
        // message stored and after every change, and an earlier reading can
        // come back after a later one.
        ThreadActivities.shared.reload()
        personalThreadsLoad += 1
        let request = personalThreadsLoad
        do {
            // With those archived: the sidebar shows them in a section of their own.
            let stored = try await ThreadService.shared.loadThreads(covenId: nil, includeArchived: true)
            guard request == personalThreadsLoad else { return }
            personalThreads = stored
        } catch {
            guard request == personalThreadsLoad else { return }
            AppErrorReporter.log(error: error, context: "HomeView.loadPersonalThreads")
            personalThreads = []
        }
    }

    private func handleDeepLink(_ target: DeepLinkTarget) {
        // Deep links are global; surface them in the home workspace.
        currentWorkspace = .home

        switch target {
        case .connectedApps:
            openPersonalTab(.connectedApps)
        case .providerKeys:
            openPersonalTab(.providerKeys)
        case .budgets:
            openPersonalTab(.budget)
        case .usage:
            openPersonalTab(.usage)
        case .settings:
            openPersonalTab(.settings)
        }
    }

    private func openPersonalTab(_ type: WorkspaceTabType) {
        if appState.openSettings(for: type) { return }

        if let existingTab = openTabs.first(where: { $0.type == type }) {
            activeTabId = existingTab.id
            return
        }

        let tab: WorkspaceTab
        switch type {
        case .personalStrixSettings:
            tab = WorkspaceTab.personalStrix
        default:
            return
        }

        openTabs.append(tab)
        activeTabId = tab.id
    }
}

/// Personal workspace for a single local user
struct PersonalWorkspaceView: View {
    @Binding var personalThreads: [Thread]
    @Binding var selectedThread: Thread?
    @Binding var openTabs: [WorkspaceTab]
    @Binding var activeTabId: String?
    @Binding var covens: [Coven]

    @State private var isSidebarExpanded = false // Collapsed by default

    let onCreateCoven: () -> Void
    let onRefreshThreads: () async -> Void
    let onSwitchToCovens: () -> Void
    let onSelectCoven: (Coven) -> Void

    var body: some View {
        ZStack {
            NebulaBackground()

            HStack(spacing: 0) {
                // Personal threads sidebar
                PersonalThreadsSidebar(
                    threads: $personalThreads,
                    covens: covens,
                    selectedThread: $selectedThread,
                    isExpanded: $isSidebarExpanded,
                    onNewThread: handleNewThread,
                    onCreateCoven: onCreateCoven,
                    onSelectThread: handleOpenThread,
                    onThreadLeft: handleThreadLeft,
                    onRefresh: onRefreshThreads,
                    onSwitchToCovens: onSwitchToCovens,
                    onSelectCoven: { coven in
                        onSelectCoven(coven)
                    },
                    onOpenWorkspaceTab: { tab in
                        openTab(tab)
                    }
                )

                Rectangle()
                    .fill(Color.aicovenBorder)
                    .frame(width: 1)

                // Main content area
                PersonalContentView(
                    selectedThread: $selectedThread,
                    openTabs: $openTabs,
                    activeTabId: $activeTabId,
                    onNewChat: handleNewThread,
                    onCreateCoven: onCreateCoven
                )
            }
        }
        .themedColorScheme()
        .onChange(of: activeTabId) { _, newValue in
            guard
                let id = newValue,
                let tab = openTabs.first(where: { $0.id == id })
            else {
                selectedThread = nil
                return
            }

            if case let .thread(thread) = tab.type {
                selectedThread = thread
            } else {
                selectedThread = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didCreateThread)) { _ in
            Task {
                await onRefreshThreads()
            }
        }
        // A thread renamed in the sidebar goes by its new name where it is
        // open too: on its tab and over its messages.
        .onChange(of: personalThreads) { _, threads in
            if openTabs.showsAnOldName(among: threads) { openTabs = openTabs.showing(threads) }
            if let open = selectedThread, let now = threads.first(where: { $0.id == open.id }), now.title != open.title {
                selectedThread = now
            }
        }
    }

    private func handleNewThread() {
        Task {
            do {
                let thread = try await ThreadService.shared.createThread(
                    title: "New Chat",
                    covenId: nil,
                    agentId: nil
                )
                // Update local state and open the new thread.
                personalThreads.append(thread)
                handleOpenThread(thread)
            } catch {
                AppErrorReporter.log(error: error, context: "HomeView.handleNewThread")
            }
        }
    }

    private func handleOpenThread(_ thread: Thread) {
        // Create tab for thread
        let tab = WorkspaceTab.thread(thread)

        // Add to tabs if not already open
        if !openTabs.contains(where: { $0.id == tab.id }) {
            openTabs.append(tab)
        }

        // Make it active
        activeTabId = tab.id
        selectedThread = thread
    }

    private func openTab(_ type: WorkspaceTabType) {
        if AppState.shared.openSettings(for: type) { return }

        if let existingTab = openTabs.first(where: { $0.type == type }) {
            activeTabId = existingTab.id
            return
        }

        let tab: WorkspaceTab
        switch type {
        case .mcpServers:
            tab = .mcpServers
        case let .memoryList(covenId):
            tab = WorkspaceTab.memoryList(covenId: covenId)
        case let .memoryProposals(covenId):
            tab = WorkspaceTab.memoryProposals(covenId: covenId)
        case .personalStrixSettings:
            tab = WorkspaceTab.personalStrix
        default:
            return
        }

        openTabs.append(tab)
        activeTabId = tab.id
    }

    /// A thread was deleted or archived from the sidebar: it is no longer
    /// open here.
    private func handleThreadLeft(_ thread: Thread) {
        if selectedThread?.id == thread.id {
            selectedThread = nil
        }
        openTabs.removeAll { tab in
            if case let .thread(tabThread) = tab.type {
                return tabThread.id == thread.id
            }
            return false
        }
        if activeTabId == thread.id {
            activeTabId = openTabs.last?.id
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(AppState.shared)
        .environmentObject(AuthService.shared)
}
