#if os(macOS)
import SwiftUI

/// The Mac window as the cloud app's shell: one split view, with the
/// sidebar on the left and the place open in the scope on screen beside it,
/// under a toolbar and the window's title.
struct MacShellView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var authService: AuthService

    @StateObject private var navigator = ShellNavigator()
    @StateObject private var shellThreads = ShellThreads()
    /// Rename, archive, delete and copy, for the sidebar's threads. Owned
    /// here, not by the sidebar: its sheet and alerts show also while the
    /// sidebar is hidden.
    @StateObject private var threadActions = ThreadActions()

    @State private var covens: [Coven] = []
    /// Counts the readings of the covens, so that only the latest is kept.
    @State private var covensLoad = 0
    /// The person's own order for their covens, as kept on this device.
    @State private var covenOrder: [String] = []
    private let orderStore = CovenOrderStore()
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    /// What each scope's new-thread page holds unsent.
    @StateObject private var drafts = DraftThreads()
    @State private var showCreateCoven = false

    /// The covens in the person's order.
    private var orderedCovens: [Coven] {
        CovenOrder.ordered(covens, by: covenOrder)
    }

    /// The coven on screen; nil for Strix, or while the covens are not in.
    private var selectedCoven: Coven? {
        navigator.selected.covenID.flatMap { id in covens.first { $0.id == id } }
    }

    private var scopeName: String? {
        navigator.selected == .strix ? "Strix" : selectedCoven?.name
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ShellSidebar(
                navigator: navigator,
                shellThreads: shellThreads,
                threadActions: threadActions,
                covens: orderedCovens,
                personName: ShellSidebar.personName(name: authService.currentUser?.name, email: authService.currentUser?.email),
                onOpenSettings: { _ = appState.openSettings(for: .settings) },
                onCreateCoven: { showCreateCoven = true },
                onOpenConnectedApps: { _ = appState.openSettings(for: .connectedApps) },
                onMoveCoven: moveCoven
            )
            // On the sidebar column's content, as Apple's example attaches
            // it; on the split view it does not remove the system toggle.
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            ShellContentView(
                navigator: navigator,
                threadActions: threadActions,
                drafts: drafts,
                coven: selectedCoven,
                onNewThread: newThread,
                onNewThreadWithAgent: newThread(with:),
                onThreadCreated: threadCreated,
                onCreateCoven: { showCreateCoven = true },
                onOpenProviderKeys: { _ = appState.openSettings(for: .providerKeys) }
            )
            .toolbar {
                StoneSidebarToggle(visibility: $columnVisibility)
                StoneToolbarItem(placement: .primaryAction) {
                    Button(action: newThread) {
                        Label("New Thread", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.stoneToolbar)
                    .keyboardShortcut("n", modifiers: .command)
                    .help("New Thread (⌘N)")
                    .accessibilityIdentifier("new-thread")
                }
            }
        }
        .stoneWindowBar()
        .navigationTitle(shellWindowTitle(covenName: scopeName, covenPlaceTitle: navigator.placeTitle))
        .threadActionsHost(threadActions)
        .sheet(isPresented: $showCreateCoven) {
            CreateCovenSheet(onCreated: { _ in
                Task { await loadCovens() }
            })
            .environmentObject(StoreService.shared)
        }
        .task {
            // What each thread is doing, as stored for this account. Read
            // again from here on whenever a message is stored.
            ThreadActivities.shared.reload()
            await loadCovens()
        }
        .task(id: navigator.selected) {
            // Another scope's threads are another list.
            threadActions.invalidate()
            shellThreads.load(navigator.selected)
            if let covenID = navigator.selected.covenID { AnalyticsService.shared.trackCovenView(covenId: covenID) }
        }
        // The events the window's tabs sent when one was opened.
        .onChange(of: navigator.place?.id) { _, _ in
            if let place = navigator.place { AnalyticsService.shared.trackTabOpened(tabType: place.type.analyticsName) }
        }
        .onAppear {
            threadActions.onChanged = { [shellThreads] in shellThreads.reload() }
            // A thread deleted or archived is no longer open.
            threadActions.onLeft = { [navigator] in navigator.removeThread(id: $0.id) }
        }
        // A thread was used, or made: the list follows it.
        .onReceive(NotificationCenter.default.publisher(for: ThreadService.threadUsed)) { _ in
            shellThreads.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .didCreateThread)) { _ in
            shellThreads.reload()
        }
        // A thread renamed in the sidebar goes by its new name in the
        // window's title too, and one brought back from the archive is
        // offered Archive again in its menu.
        .onChange(of: shellThreads.threads) { _, threads in
            guard let open = navigator.place?.threadValue,
                  let now = threads.first(where: { $0.id == open.id }),
                  now.title != open.title || now.isArchived != open.isArchived else { return }
            navigator.updateThread(now)
        }
    }

    private func loadCovens() async {
        // Only the latest reading is kept: one begun before a coven was
        // made can land after the one begun for it, without that coven.
        covensLoad += 1
        let reading = covensLoad
        let account = UserScope.currentUserID
        do {
            let loaded = try await CovenService.shared.loadCovens()
            guard reading == covensLoad, UserScope.currentUserID == account else { return }
            covens = loaded
            covenOrder = orderStore.ids(for: account)
            // The coven on screen can be gone by now.
            if let covenID = navigator.selected.covenID, !loaded.contains(where: { $0.id == covenID }) {
                navigator.handleCovenGone(covenID: covenID)
                drafts.forget(.coven(covenID))
            }
        } catch {
            // The kind of failure only. The covens shown stay as they are.
            AppErrorReporter.log(message: "Could not read the covens (\(type(of: error)))", context: "MacShellView.loadCovens")
        }
    }

    /// Moves a coven to a place in the person's order, and keeps the order
    /// on this device for the account signed in.
    private func moveCoven(_ covenID: String, to index: Int) {
        let ids = CovenOrder.moving(covenID, to: index, in: orderedCovens)
        covenOrder = ids
        orderStore.save(ids, for: UserScope.currentUserID)
    }

    /// New Thread: the scope's new-thread page. Its thread is made when
    /// its first message is sent.
    private func newThread() {
        AnalyticsService.shared.trackNewChatTapped(source: "mac_shell")
        navigator.requestNewThread()
    }

    /// The new-thread page, with one of the coven's agents as who it goes to.
    private func newThread(with role: Role) {
        AnalyticsService.shared.trackNewChatTapped(source: "mac_shell_agent")
        navigator.requestNewThread(agentID: role.id)
    }

    /// The new-thread page made its thread: it takes the page's place
    /// (where the page still is), and the list shows it.
    private func threadCreated(_ thread: Thread) {
        navigator.handleCreatedThread(thread)
        shellThreads.reload()
        if let covenID = thread.covenId {
            AnalyticsService.shared.trackThreadCreate(threadId: thread.id, covenId: covenID, hasTitle: thread.title != nil)
            if let agentID = thread.agentId { AnalyticsService.shared.trackRoleAssign(roleId: agentID, threadId: thread.id) }
        }
    }
}
#endif
