import SwiftUI

/// The cloud app's shell: one split view, with the sidebar on the left and
/// the place open in the scope on screen beside it, under a toolbar and the
/// window's title. The Mac's window, and the iPad's layout at regular
/// width, where Settings is a place in it and not a window.
///
/// It has a second layout over the same state, for a phone: no sidebar,
/// the scope's Overview as the root of one stack. Being the same view, a
/// device that changes between the two keeps where it is.
struct ShellRootView: View {
    /// The split layout (sidebar and content); false is the phone's.
    var isSplit = true

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var authService: AuthService

    /// Where the shell is. It notes each arrival in a scope on this device,
    /// for the account signed in, so the Overview can say when the person
    /// was last there.
    @StateObject private var navigator = ShellNavigator(arrive: { scope in
        ScopeVisitStore().arrive(in: scope, at: Date(), for: UserScope.currentUserID)
    })
    @Environment(\.scenePhase) private var scenePhase
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
    /// Asks the split view itself whether its sidebar shows, where that
    /// can be read (the iPad; on the Mac the visibility says).
    @State private var splitViewProbe = SplitViewProbe()
    /// What each scope's new-thread page holds unsent.
    @StateObject private var drafts = DraftThreads()
    @State private var showCreateCoven = false
    /// The phone's search over the Overview's threads.
    @State private var threadSearch = ""
    @State private var isSearchingThreads = false
    /// The phone's switcher, a sheet from the bar; and what it was asked
    /// to open, done once the sheet has gone so nothing opens under it.
    @State private var showSwitcher = false
    @State private var switcherFollowUp: SwitcherFollowUp?

    /// What the switcher sheet was asked to open as it closes.
    private enum SwitcherFollowUp {
        case createCoven
        case settings
    }

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
        layout
            .stoneWindowBar()
            .navigationTitle(shellWindowTitle(covenName: scopeName, personPlace: navigator.personPlace, covenPlaceTitle: navigator.placeTitle))
            .threadActionsHost(threadActions)
            // What this window offers the menu bar while it is in front.
            .focusedSceneValue(\.shellCommands, shellCommands)
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
                // Another scope's threads are another list, searched
                // afresh: in whichever layout the scope changed, since the
                // search is kept across a change of layout.
                threadSearch = ""
                isSearchingThreads = false
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
            // Coming back to the app is coming back to the scope on screen. The
            // phase the window opens in is told too, so the navigator knows
            // when the app was first in front.
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { navigator.appBecameActive() } else { navigator.appWentInactive() }
            }
            // A thread was used, or made: the list follows it.
            .onReceive(NotificationCenter.default.publisher(for: ThreadService.threadUsed)) { _ in
                shellThreads.reload()
            }
            .onReceive(NotificationCenter.default.publisher(for: .didCreateThread)) { _ in
                shellThreads.reload()
            }
            // A thread was deleted, by whatever did it (a new thread whose
            // files could not go into it is deleted again, with no list's
            // action behind it): it is no longer listed, open or marked.
            .onReceive(NotificationCenter.default.publisher(for: .didDeleteThread)) { deleted in
                if let id = deleted.userInfo?[Notification.Name.threadIDKey] as? String { navigator.removeThread(id: id) }
                shellThreads.reload()
                ThreadActivities.shared.reload()
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

    @ViewBuilder
    private var layout: some View {
        if isSplit {
            split
        } else {
            phone
        }
    }

    /// The phone's layout: one stack, its root the scope's Overview as a
    /// list with a search over its threads; the scope's place, and the
    /// person's own (Settings), are pushed on it. The stack is the
    /// navigator's: going back leaves what was popped.
    private var phone: some View {
        NavigationStack(path: Binding(
            get: { navigator.phonePath },
            set: { navigator.leavePhoneRoutes(notIn: $0) }
        )) {
            ScopeOverviewView(
                navigator: navigator,
                shellThreads: shellThreads,
                threadActions: threadActions,
                submission: drafts.submission(for: navigator.selected),
                coven: selectedCoven,
                onOpenProviderKeys: { openSettings(.providerKeys) },
                onThreadAsked: threadMade,
                searchText: threadSearch,
                isSearchFieldActive: isSearchingThreads,
                onOpenPlace: openPlace
            )
            .id(navigator.selected)
            .searchable(text: $threadSearch, isPresented: $isSearchingThreads, prompt: "Search threads")
            .navigationTitle(scopeName ?? "AICoven")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    StoneToolbarItem(placement: .principal) {
                        PhoneSwitcherTitle(
                            covens: orderedCovens, selected: navigator.selected, coven: selectedCoven, scopeName: scopeName
                        ) {
                            showSwitcher = true
                        }
                    }
                    StoneToolbarItem(placement: .primaryAction) {
                        Button(action: newThread) {
                            Label("New Thread", systemImage: "square.and.pencil")
                        }
                        .buttonStyle(.stoneToolbar)
                        .accessibilityIdentifier("new-thread")
                    }
                }
                .navigationDestination(for: ShellNavigator.PhoneRoute.self) { route in
                    switch route {
                    case .place: phonePlace
                    case .personPlace: phoneSettings
                    }
                }
        }
        .sheet(isPresented: $showSwitcher, onDismiss: runSwitcherFollowUp) { switcherSheet }
    }

    /// The scope's place, pushed: the same view the split layout shows in
    /// its content pane, with the phone's bar over a thread.
    private var phonePlace: some View {
        ShellContentView(
            navigator: navigator,
            shellThreads: shellThreads,
            threadActions: threadActions,
            drafts: drafts,
            coven: selectedCoven,
            onNewThreadWithAgent: newThread(with:),
            onThreadCreated: threadCreated,
            onThreadAsked: threadMade,
            onOpenProviderKeys: { openSettings(.providerKeys) },
            onOpenSwitcher: { showSwitcher = true }
        )
        .navigationTitle(navigator.phonePlaceTitle)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .stoneBackButton()
    }

    /// Settings, pushed: the list, or the pane a request named. The list's
    /// rows push their panes on this same stack.
    @ViewBuilder
    private var phoneSettings: some View {
        if case let .settings(request) = navigator.personPlace {
            Group {
                if let request, let pane = SettingsPane(request) {
                    SettingsPaneView(pane: pane, request: request)
                } else {
                    SettingsList()
                        .stoneBackButton()
                }
            }
            // Made anew for each ask, so it shows the pane now asked for.
            .id(navigator.personPlaceRequest)
            // Settings was opened: said as it is wherever Settings opens.
            .onAppear { AnalyticsService.shared.trackSettingsOpened() }
        }
    }

    private var switcherSheet: some View {
        PhoneSwitcherSheet(
            covens: orderedCovens,
            selected: navigator.selected,
            personName: ShellSidebar.personName(name: authService.currentUser?.name, email: authService.currentUser?.email),
            onSelect: { scope in
                showSwitcher = false
                navigator.select(scope)
            },
            onCreateCoven: {
                switcherFollowUp = .createCoven
                showSwitcher = false
            },
            onOpenSettings: {
                switcherFollowUp = .settings
                showSwitcher = false
            },
            onMoveCoven: moveCoven
        )
    }

    /// Opens what the switcher was asked for, now that its sheet has gone.
    private func runSwitcherFollowUp() {
        let followUp = switcherFollowUp
        switcherFollowUp = nil
        switch followUp {
        case .createCoven: showCreateCoven = true
        case .settings: openSettings(.settings)
        case nil: break
        }
    }

    private var split: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ShellSidebar(
                navigator: navigator,
                shellThreads: shellThreads,
                threadActions: threadActions,
                covens: orderedCovens,
                personName: ShellSidebar.personName(name: authService.currentUser?.name, email: authService.currentUser?.email),
                onOpenSettings: { openSettings(.settings) },
                onCreateCoven: { showCreateCoven = true },
                onOpenPlace: openPlace,
                onMoveCoven: moveCoven
            )
            // On the sidebar column's content, as Apple's example attaches
            // it; on the split view it does not remove the system toggle.
            .toolbar(removing: .sidebarToggle)
            .probingSplitView(splitViewProbe)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            ShellContentView(
                navigator: navigator,
                shellThreads: shellThreads,
                threadActions: threadActions,
                drafts: drafts,
                coven: selectedCoven,
                onNewThreadWithAgent: newThread(with:),
                onThreadCreated: threadCreated,
                onThreadAsked: threadMade,
                onOpenProviderKeys: { openSettings(.providerKeys) }
            )
            .toolbar {
                StoneSidebarToggle(visibility: $columnVisibility, systemShowsSidebar: splitViewProbe.sidebarIsShowing)
                StoneToolbarItem(placement: .primaryAction) {
                    Button(action: newThread) {
                        Label("New Thread", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.stoneToolbar)
                    // ⌘N is the File menu's New Thread.
                    .help("New Thread (⌘N)")
                    .accessibilityIdentifier("new-thread")
                }
            }
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
            // A coven that is gone, on screen or not, takes its place and
            // what was being written for it along.
            for covenID in CovenOrder.gone(known: covens, selected: navigator.selected, among: loaded) {
                navigator.handleCovenGone(covenID: covenID)
                drafts.forget(.coven(covenID))
                ScopeVisitStore().forget(.coven(covenID), for: account)
            }
            covens = loaded
            covenOrder = orderStore.ids(for: account)
        } catch {
            // The kind of failure only. The covens shown stay as they are.
            AppErrorReporter.log(message: "Could not read the covens (\(type(of: error)))", context: "ShellRootView.loadCovens")
        }
    }

    /// Moves a coven to a place in the person's order, and keeps the order
    /// on this device for the account signed in.
    private func moveCoven(_ covenID: String, to index: Int) {
        let ids = CovenOrder.moving(covenID, to: index, in: orderedCovens)
        covenOrder = ids
        orderStore.save(ids, for: UserScope.currentUserID)
    }

    /// The shell's actions for the menu bar: each does what its button in
    /// the window does.
    private var shellCommands: ShellCommandActions {
        ShellCommandActions(
            covens: orderedCovens,
            selected: navigator.selected,
            newThread: newThread,
            newCoven: { showCreateCoven = true },
            searchThreads: {
                // The search is in the sidebar: shown first, if it is hidden.
                columnVisibility = .all
                navigator.requestSearch()
            },
            openPlace: openPlace,
            select: { navigator.select($0) },
            moveSelectedCoven: { up in
                guard let target = ShellCommandRules.moveTarget(up: up, selected: navigator.selected, covens: orderedCovens) else { return }
                moveCoven(target.covenID, to: target.index)
            }
        )
    }

    /// Opens a place of the scope on screen, for its sidebar button and the
    /// Go menu alike. Strix uses every connection, so its Connections are
    /// the person's connected apps, in Settings.
    private func openPlace(_ item: ShellSidebarItem) {
        if item == .connectedApps, navigator.selected == .strix {
            openSettings(.connectedApps)
        } else {
            navigator.openPlace(item)
        }
    }

    /// Settings, or a place in it: the Settings window on the Mac, a place
    /// in the shell where there is no such window.
    private func openSettings(_ place: WorkspaceTabType) {
        #if os(macOS)
        _ = appState.openSettings(for: place)
        #else
        navigator.openPersonPlace(.settings(pane: place == .settings ? nil : place))
        #endif
    }

    /// New Thread: the scope's new-thread page. Its thread is made when
    /// its first message is sent.
    private func newThread() {
        // Where the shell is: the Mac's window, the iPad's layout, or the
        // phone's.
        #if os(macOS)
        AnalyticsService.shared.trackNewChatTapped(source: "mac_shell")
        #else
        AnalyticsService.shared.trackNewChatTapped(source: isSplit ? "ipad_shell" : "phone_shell")
        #endif
        navigator.requestNewThread()
    }

    /// The new-thread page, with one of the coven's agents as who it goes to.
    private func newThread(with role: Role) {
        navigator.requestNewThread(agentID: role.id)
    }

    /// The new-thread page made its thread: it takes the page's place
    /// (where the page still is).
    private func threadCreated(_ thread: Thread) {
        navigator.handleCreatedThread(thread)
        threadMade(thread)
    }

    /// A thread was made, by the new-thread page or from an Overview: the
    /// list shows it. Where it opens is the navigator's to say, for each
    /// of the two in its own way.
    private func threadMade(_ thread: Thread) {
        shellThreads.reload()
        if let covenID = thread.covenId {
            AnalyticsService.shared.trackThreadCreate(threadId: thread.id, covenId: covenID, hasTitle: thread.title != nil)
            if let agentID = thread.agentId { AnalyticsService.shared.trackRoleAssign(roleId: agentID, threadId: thread.id) }
        }
    }
}

/// The scope's name in the phone's bar, which opens the switcher, with one
/// line beneath for another scope where something moves or waits. A view of
/// its own: what moves is read here, not by the root both layouts share.
private struct PhoneSwitcherTitle: View {
    let covens: [Coven]
    let selected: ShellScope
    let coven: Coven?
    let scopeName: String?
    let action: () -> Void
    @ObservedObject private var activities = ThreadActivities.shared

    var body: some View {
        let other = ShellSidebar.othersCurrent(covens: covens, selected: selected, current: activities.current).first
        Button(action: action) {
            VStack(spacing: 0) {
                HStack(spacing: Spacing.xxs) {
                    CovenIcon(coven: coven, size: 30)
                        .padding(.trailing, Spacing.xxs)
                    Text(scopeName ?? "Loading…")
                        .font(.aicovenH2)
                        .foregroundColor(.aicovenTextPrimary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.aicovenCaption.weight(.semibold))
                        .foregroundColor(.aicovenTextSecondary)
                }
                if let other {
                    OtherCovenCurrentLine(name: other.name, current: other.current)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Coven: \(scopeName ?? "loading")")
        .accessibilityValue(other.map { "\($0.name), \($0.current.accessibilityWords)" } ?? "")
        .accessibilityHint("Switch coven")
        .accessibilityIdentifier("coven-switcher")
    }
}

/// The phone's switcher: the switcher's list in a sheet, with what moves or
/// waits in each scope and which hold an unread reply, read here.
private struct PhoneSwitcherSheet: View {
    let covens: [Coven]
    let selected: ShellScope
    let personName: String
    let onSelect: (ShellScope) -> Void
    let onCreateCoven: () -> Void
    let onOpenSettings: () -> Void
    let onMoveCoven: (_ covenID: String, _ index: Int) -> Void
    @ObservedObject private var activities = ThreadActivities.shared

    var body: some View {
        CovenSwitcherList(
            covens: covens,
            rowMinHeight: 56,
            popoverWidth: nil,
            selected: selected,
            current: { activities.current[$0] },
            hasUnread: { activities.scopesWithUnread.contains($0) },
            personName: personName,
            onSelect: onSelect,
            onCreateCoven: onCreateCoven,
            onOpenSettings: onOpenSettings,
            onMoveCoven: onMoveCoven
        )
        .padding(.top, Spacing.md)
        .background(Color.aicovenSurfaceElevated.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
