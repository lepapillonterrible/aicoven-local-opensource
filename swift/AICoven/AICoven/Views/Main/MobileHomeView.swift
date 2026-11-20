import SwiftUI

/// Root mobile UI: tab bar for Home / Covens / Profile
struct MobileRootView: View {
    var body: some View {
        TabView {
            MobileChatsRootView()
                .tabItem {
                    Label("Chats", systemImage: "bubble.left.and.bubble.right.fill")
                }

            SettingsWorkspaceView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .tint(.aicovenTeal)
    }
}

/// Root wrapper for the personal memory list on iOS. This surfaces a
/// dedicated Memory tab next to Home so users can browse and manage their
/// personal memories outside of any specific thread.
struct MobileMemoryRootView: View {
    @State private var showProposals = false
    @State private var openTabs: [WorkspaceTab] = []
    @State private var activeTabId: String?

    var body: some View {
        NavigationStack {
            ZStack {
                NebulaBackground()

                MobileMemoryListView(covenId: nil)
                #if os(iOS)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                showProposals = true
                            } label: {
                                Image(systemName: "doc.text.magnifyingglass")
                            }
                        }
                    }
                #endif
                    .navigationTitle("Memory")
            }
        }
        .sheet(isPresented: $showProposals) {
            NavigationStack {
                ZStack {
                    NebulaBackground()

                    // Reuse the desktop proposals view on iOS inside a sheet.
                    MemoryProposalsView(
                        covenId: nil,
                        openTabs: $openTabs,
                        activeTabId: $activeTabId
                    )
                }
                .navigationTitle("Memory Proposals")
            }
        }
    }
}

// MARK: - Mobile Chats Root View

struct MobileChatsRootView: View {
    @State private var covens: [Coven] = []
    @State private var selectedCovenId: String? = nil // nil == Strix
    @State private var threads: [Thread] = []
    @State private var isLoading = true
    @State private var showCreateCoven = false
    @State private var showNewThread = false
    @State private var showStrixSettings = false
    @State private var selectedThread: Thread?
    @State private var showMemory = false
    @State private var showConnections = false
    @State private var errorMessage: String?
    /// Rename, archive, delete and copy, for this list's threads.
    @StateObject private var threadActions = ThreadActions()
    /// What each thread is doing, for its row and the list's order.
    @ObservedObject private var activities = ThreadActivities.shared
    @State private var showArchived = false
    /// Counts the list's loads, so that only the latest one is shown.
    @State private var threadsLoad = 0
    /// Whether the scope's threads have been shown since it was chosen.
    @State private var hasLoadedScope = false

    private var selectedCoven: Coven? {
        guard let selectedCovenId else { return nil }
        return covens.first(where: { $0.id == selectedCovenId })
    }

    private var scopeTitle: String {
        selectedCoven?.name ?? "Strix"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                NebulaBackground()

                if isLoading {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.aicovenTeal)
                } else {
                    List {
                        Section {
                            Button {
                                selectedThread = nil
                                showStrixSettings = false
                                showMemory = true
                            } label: {
                                HStack(spacing: Spacing.sm) {
                                    Image(systemName: "brain")
                                        .foregroundColor(.aicovenTeal)
                                    Text("Memory")
                                        .font(.aicovenBody)
                                        .foregroundColor(.aicovenTextPrimary)
                                    Spacer()
                                    Text(scopeTitle)
                                        .font(.aicovenCaption)
                                        .foregroundColor(.aicovenTextTertiary)
                                }
                                .padding(.vertical, Spacing.xs)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.aicovenGlass)

                            // What of the person's connections this
                            // coven's agents may use. Strix uses them all.
                            if selectedCoven != nil {
                                Button {
                                    selectedThread = nil
                                    showStrixSettings = false
                                    showConnections = true
                                } label: {
                                    HStack(spacing: Spacing.sm) {
                                        Image(systemName: "link")
                                            .foregroundColor(.aicovenTeal)
                                        Text("Connections")
                                            .font(.aicovenBody)
                                            .foregroundColor(.aicovenTextPrimary)
                                        Spacer()
                                        Text(scopeTitle)
                                            .font(.aicovenCaption)
                                            .foregroundColor(.aicovenTextTertiary)
                                    }
                                    .padding(.vertical, Spacing.xs)
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(Color.aicovenGlass)
                                .accessibilityIdentifier("coven-connections-open")
                            }
                        }

                        Section {
                            if threads.isEmpty {
                                VStack(alignment: .leading, spacing: Spacing.sm) {
                                    Text("No chats in \(scopeTitle) yet")
                                        .font(.aicovenBody)
                                        .foregroundColor(.aicovenTextPrimary)
                                    HStack(spacing: Spacing.sm) {
                                        Button {
                                            showNewThread = true
                                        } label: {
                                            Label("New Chat", systemImage: "plus.message")
                                                .font(.aicovenCaption)
                                                .foregroundColor(.black)
                                                .padding(.horizontal, Spacing.sm)
                                                .padding(.vertical, Spacing.xxs)
                                                .background(Color.aicovenTeal)
                                                .cornerRadius(BorderRadius.md)
                                        }
                                    }
                                }
                                .padding(.vertical, Spacing.sm)
                                .listRowBackground(Color.clear)
                            } else {
                                // Newest first, then those archived, under a header of their own.
                                let sections = ThreadListRules.sections(threads) { activities.activity[$0.id]?.isStillOpen == true }
                                ForEach(sections.open) { thread in
                                    threadRow(thread)
                                }
                                if !sections.archived.isEmpty {
                                    ArchivedThreadsHeader(isExpanded: $showArchived)
                                        .listRowBackground(Color.clear)
                                    if showArchived {
                                        ForEach(sections.archived) { thread in
                                            threadRow(thread)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle(scopeTitle)
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Menu {
                            Button {
                                setSelectedScope(covenId: nil)
                            } label: {
                                scopeMenuLabel("Strix", isSelected: selectedCovenId == nil)
                            }
                            Divider()
                            ForEach(covens) { coven in
                                Button {
                                    setSelectedScope(covenId: coven.id)
                                } label: {
                                    scopeMenuLabel(coven.name, isSelected: selectedCovenId == coven.id)
                                }
                            }
                            Divider()
                            Button { showCreateCoven = true } label: { Label("New Coven", systemImage: "plus") }
                        } label: {
                            HStack(spacing: 4) {
                                Text(scopeTitle)
                                    .font(.headline)
                                Image(systemName: "chevron.down")
                                    .font(.caption)
                            }
                            .foregroundColor(.aicovenTextPrimary)
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { showNewThread = true } label: { Image(systemName: "square.and.pencil") }
                            .foregroundColor(.aicovenTeal)
                    }
                }
                .task { await loadCovens() }
                .task(id: selectedCovenId) {
                    // Another scope's threads are another list.
                    threadActions.invalidate()
                    await loadThreads()
                }
                .threadActionsHost(threadActions)
                // A thread was used: the order follows it.
                .onReceive(NotificationCenter.default.publisher(for: ThreadService.threadUsed)) { _ in
                    Task { await loadThreads() }
                }
                .onAppear {
                    threadActions.onChanged = { Task { await loadThreads() } }
                    threadActions.onLeft = { left in
                        if selectedThread?.id == left.id { selectedThread = nil }
                    }
                }
                .sheet(isPresented: $showCreateCoven) {
                    CreateCovenSheet(onCreated: { coven in
                        Task {
                            await loadCovens()
                            setSelectedScope(covenId: coven.id)
                        }
                    })
                    .environmentObject(StoreService.shared)
                }
                .sheet(isPresented: $showNewThread) {
                    NewThreadView(covenId: selectedCovenId) { thread in
                        Task {
                            await loadThreads()
                            selectedThread = thread
                        }
                    }
                }
                .navigationDestination(item: $selectedThread) { thread in
                    if let selectedCoven {
                        MobileCovenChatView(thread: thread, coven: selectedCoven)
                    } else {
                        PersonalChatView(
                            thread: thread,
                            onEditAgent: { showStrixSettings = true },
                            onBack: { selectedThread = nil }
                        )
                    }
                }
                .navigationDestination(isPresented: $showConnections) {
                    if let selectedCoven {
                        CovenConnectionsView(coven: selectedCoven)
                    }
                }
                .navigationDestination(isPresented: $showMemory) {
                    if let selectedCoven {
                        MobileCovenMemoryView(coven: selectedCoven)
                    } else {
                        MobileMemoryRootView()
                    }
                }
                .sheet(isPresented: $showStrixSettings) {
                    NavigationStack {
                        StrixSettingsView(onClose: { showStrixSettings = false })
                            .environmentObject(StoreService.shared)
                    }
                }
                .alert("Error", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    if let errorMessage {
                        Text(errorMessage)
                    }
                }
        }
    }

    private func loadCovens() async {
        do {
            covens = try await CovenService.shared.loadCovens()
        } catch {
            AppErrorReporter.log(error: error, context: "MobileChatsRootView.loadCovens")
            covens = []
            threads = []
            selectedThread = nil
            setSelectedScope(covenId: nil)
            errorMessage = "Couldn’t load covens right now."
        }
    }

    private func loadThreads() async {
        // Whose threads these are: the list can have moved to another
        // scope by the time they are read, and they are then not shown, nor
        // is anything of that other scope's touched.
        // And only the latest request for a scope is shown: one asked for
        // before the list left and came back is not.
        activities.reload()
        let scope = selectedCovenId
        threadsLoad += 1
        let request = threadsLoad
        // The list gives way to a spinner only until a scope's threads are
        // first shown: read again after that, it stays as it is (where it
        // was scrolled to, an open menu) until the new reading is in.
        if !hasLoadedScope { isLoading = true }
        do {
            // With those archived: the list shows them in a section of their own.
            let stored = try await ThreadService.shared.loadThreads(covenId: scope, includeArchived: true)
            guard request == threadsLoad, selectedCovenId == scope else { return }
            threads = stored
        } catch {
            guard request == threadsLoad, selectedCovenId == scope else { return }
            AppErrorReporter.log(error: error, context: "MobileChatsRootView.loadThreads")
            threads = []
            selectedThread = nil
            errorMessage = "Couldn’t load chats for this workspace."
        }
        hasLoadedScope = true
        isLoading = false
    }

    private func threadRow(_ thread: Thread) -> some View {
        Button {
            selectedThread = thread
        } label: {
            ThreadRowView(thread: thread, activity: activities.activity[thread.id])
        }
        .listRowBackground(Color.aicovenGlass)
        .threadRowActions(thread, threadActions)
    }

    @ViewBuilder
    private func scopeMenuLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func setSelectedScope(covenId: String?) {
        guard selectedCovenId != covenId else { return }
        selectedCovenId = covenId
        selectedThread = nil
        threads = []
        hasLoadedScope = false
    }
}

struct ThreadRowView: View {
    let thread: Thread
    /// What the thread is doing, if a row says it.
    var activity: ConversationActivity?
    var body: some View {
        HStack(spacing: Spacing.sm) {
            ConversationActivityGlyph(activity: activity) {
                IconBadge(icon: "message", size: 28, color: .aicovenTeal)
            }
            .frame(width: 28)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: 4) {
                    Text(ThreadListRules.title(of: thread))
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextPrimary)
                    if let agentName = thread.agentName {
                        Text("• \(agentName)")
                            .font(.aicovenBody)
                            .foregroundColor(.aicovenTextSecondary)
                    }
                }
                HStack(spacing: 4) {
                    if let model = thread.agentModel {
                        Text(model)
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTeal)
                    }
                    if thread.agentModel != nil {
                        Text("•")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextTertiary)
                    }
                    Text(VisitWords.rowDate(ThreadListRules.lastUsed(thread)))
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextSecondary)
                }
                ConversationActivityCaption(activity: activity)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.aicovenCaption)
                .foregroundColor(.aicovenTextTertiary)
        }
        .padding(.vertical, Spacing.xs)
        .threadActivityValue(activity)
    }
}

/// Coven-wide memory & proposals view (mobile wrapper)
struct MobileCovenMemoryView: View {
    let coven: Coven
    @State private var showProposals = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Memory View", selection: $showProposals) {
                Text("Saved").tag(false)
                Text("Proposals").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(Spacing.md)

            if showProposals {
                MemoryProposalsView(covenId: coven.id, openTabs: .constant([]), activeTabId: .constant(nil))
            } else {
                MobileMemoryListView(covenId: coven.id)
            }
        }
        .navigationTitle("Memory")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .background(NebulaBackground())
    }
}

/// Coven roles management view for mobile
struct MobileCovenRolesView: View {
    let coven: Coven
    @State private var roles: [Role] = []
    @State private var isLoading = true
    @State private var showAddRole = false
    @State private var selectedRole: Role?
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(roles) { role in
                Button {
                    selectedRole = role
                } label: {
                    HStack(spacing: Spacing.sm) {
                        role.face(size: 28)
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(role.name)
                                .font(.aicovenBody)
                                .foregroundColor(.aicovenTextPrimary)
                            if let model = role.model {
                                Text(model)
                                    .font(.aicovenCaption)
                                    .foregroundColor(.aicovenTextSecondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, Spacing.xs)
                }
                .listRowBackground(Color.aicovenGlass)
            }
        }
        .scrollContentBackground(.hidden)
        .background(NebulaBackground())
        .navigationTitle("Agent Roles")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddRole = true
                } label: {
                    Image(systemName: "plus")
                }
                .foregroundColor(.aicovenTeal)
            }
        }
        .sheet(isPresented: $showAddRole) {
            AddRoleView(covenId: coven.id, roles: roles) {
                Task {
                    await loadRoles()
                    await MainActor.run {
                        showAddRole = false
                    }
                }
            }
        }
        .navigationDestination(item: $selectedRole) { role in
            EditRoleView(roleId: role.id, roles: roles) {
                Task { await loadRoles() }
            }
        }
        .task { await loadRoles() }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let errorMessage { Text(errorMessage) }
        }
    }

    private func loadRoles() async {
        isLoading = true
        defer { isLoading = false }
        do {
            roles = try await RoleService.shared.loadRoles(covenId: coven.id)
        } catch {
            errorMessage = error.localizedDescription
            roles = []
        }
    }
}

/// Coven chat screen using PersonalChatView for mobile (local chat flow)
struct MobileCovenChatView: View {
    let thread: Thread
    let coven: Coven
    @Environment(\.dismiss) private var dismiss
    @State private var showEditRole = false
    @State private var covenRoles: [Role] = []

    var body: some View {
        PersonalChatView(
            thread: thread,
            onEditAgent: {
                if thread.agentId != nil {
                    showEditRole = true
                }
            },
            onBack: { dismiss() }
        )
        #if os(iOS)
        .navigationBarHidden(true)
        #endif
        .background(NebulaBackground())
        .task {
            do {
                covenRoles = try await RoleService.shared.loadRoles(covenId: coven.id)
            } catch {}
        }
        .sheet(isPresented: $showEditRole) {
            if let roleId = thread.agentId {
                NavigationStack {
                    EditRoleView(roleId: roleId, roles: covenRoles) {
                        showEditRole = false
                    }
                }
            }
        }
    }
}

// MARK: - Mobile Profile Root

#Preview {
    MobileRootView()
        .environmentObject(AppState.shared)
        .environmentObject(AuthService.shared)
}
