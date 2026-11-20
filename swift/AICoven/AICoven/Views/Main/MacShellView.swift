#if os(macOS)
import SwiftUI

/// The Mac window as the cloud app's shell: one split view, with the
/// sidebar on the left and the place open in the scope on screen beside it,
/// under a toolbar and the window's title. Built beside the two workspaces
/// the window has had, which it replaces once its places are in.
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
    /// The person's own order for their covens, as kept on this device.
    @State private var covenOrder: [String] = []
    private let orderStore = CovenOrderStore()
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    /// The New Thread sheet on screen, if one is: each showing is its own.
    @State private var newThreadSheet: NewThreadSheet?
    @State private var showCreateCoven = false
    /// A thread is being made for New Thread in Strix: a second click makes
    /// no second one.
    @State private var isMakingThread = false

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
                coven: selectedCoven,
                onNewThread: newThread,
                onNewThreadWithAgent: newThread(with:),
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
                    .help("New Thread")
                    .accessibilityIdentifier("new-thread")
                }
            }
        }
        .stoneWindowBar()
        .navigationTitle(shellWindowTitle(covenName: scopeName, covenPlaceTitle: navigator.placeTitle))
        .threadActionsHost(threadActions)
        .sheet(item: $newThreadSheet) { sheet in
            NewThreadView(covenId: sheet.covenID) { thread in
                // The sheet can have been cancelled while the thread was
                // being made: it is then in the list, and not opened over
                // wherever the person has gone, even if they have opened
                // the sheet again since.
                if sheet.opensItsThread(whileShowing: newThreadSheet) { navigator.open(thread) }
                shellThreads.reload()
            }
        }
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
        let account = UserScope.currentUserID
        do {
            let loaded = try await CovenService.shared.loadCovens()
            guard UserScope.currentUserID == account else { return }
            covens = loaded
            covenOrder = orderStore.ids(for: account)
            // The coven on screen can be gone by now.
            if let covenID = navigator.selected.covenID, !loaded.contains(where: { $0.id == covenID }) {
                navigator.handleCovenGone(covenID: covenID)
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

    /// A thread with one of the coven's agents, made at once and opened
    /// (unless the person has gone elsewhere meanwhile), as tapping an agent
    /// did in the window before.
    private func newThread(with role: Role) {
        guard !isMakingThread else { return }
        isMakingThread = true
        let account = UserScope.currentUserID
        let asked = navigator.placeGeneration
        Task {
            defer { isMakingThread = false }
            do {
                let thread = try await ThreadService.shared.createThread(
                    title: "Chat with \(role.name)", covenId: role.covenId, agentId: role.id, agentName: role.name
                )
                guard UserScope.currentUserID == account, navigator.placeGeneration == asked else { return }
                navigator.open(thread)
            } catch {
                AppErrorReporter.log(message: "Could not make a thread (\(type(of: error)))", context: "MacShellView.newThreadWithAgent")
            }
        }
    }

    /// New Thread: in Strix a thread is made at once and opened; in a coven
    /// the sheet asks which agent it is for.
    private func newThread() {
        guard navigator.selected == .strix else {
            newThreadSheet = NewThreadSheet(covenID: navigator.selected.covenID)
            return
        }
        guard !isMakingThread else { return }
        isMakingThread = true
        let account = UserScope.currentUserID
        let asked = navigator.placeGeneration
        Task {
            defer { isMakingThread = false }
            do {
                let thread = try await ThreadService.shared.createThread(title: "New Chat", covenId: nil, agentId: nil)
                // Opened only for the account that asked, and only if the
                // person has not gone elsewhere meanwhile: it is in the list
                // either way.
                guard UserScope.currentUserID == account, navigator.placeGeneration == asked else { return }
                navigator.open(thread)
            } catch {
                AppErrorReporter.log(message: "Could not make a thread (\(type(of: error)))", context: "MacShellView.newThread")
            }
        }
    }
}

/// One showing of the New Thread sheet, for the coven it was asked in.
struct NewThreadSheet: Identifiable, Equatable {
    let id = UUID()
    let covenID: String?

    /// Whether the thread this sheet made is opened: only while this very
    /// showing is still the one on screen.
    func opensItsThread(whileShowing shown: NewThreadSheet?) -> Bool {
        shown?.id == id
    }
}
#endif
