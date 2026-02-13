import SwiftUI

/// Root mobile UI: tab bar for Home / Covens / Profile
struct MobileRootView: View {
    var body: some View {
        TabView {
            MobileHomeView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }

            MobileCovensRootView()
                .tabItem {
                    Label("Covens", systemImage: "person.3.fill")
                }

            MobileProfileRootView()
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle")
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

// Mobile-optimized home view for iPhone (portrait)
// Uses navigation-based layout focused on personal (non-coven) chat
// MARK: - Navigation Destination

enum MobilePersonalDestination: Hashable {
    case threadsList
    case chat(Thread)
}

/// Mobile-optimized home view for iPhone (portrait)
/// Uses navigation-based layout focused on personal (non-coven) chat
struct MobileHomeView: View {
    @State private var personalThreads: [Thread] = []
    @State private var isLoadingThreads = true
    /// Simple navigation state for the mobile workspace. `nil` means we're on
    /// the welcome screen, otherwise we show either the threads list or a
    /// specific chat.
    @State private var currentDestination: MobilePersonalDestination? = nil

    var body: some View {
        Group {
            if isLoadingThreads {
                CauldronLoadingView(message: "Loading workspace...", size: 80)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.aicovenDark)
            } else {
                MobilePersonalWorkspace(
                    personalThreads: $personalThreads,
                    currentDestination: $currentDestination,
                    onRefreshThreads: loadPersonalThreads
                )
            }
        }
        .task {
            await loadPersonalThreads()
        }
    }

    @MainActor
    private func loadPersonalThreads() async {
        isLoadingThreads = true
        defer { isLoadingThreads = false }

        do {
            personalThreads = try await ThreadService.shared.loadThreads(covenId: nil)
        } catch {
            AppErrorReporter.log(error: error, context: "MobileHomeView.loadPersonalThreads")
            personalThreads = []
        }
    }
}

// MARK: - Mobile Personal Workspace

/// Mobile layout for personal workspace
struct MobilePersonalWorkspace: View {
    @Binding var personalThreads: [Thread]
    /// Simple destination state instead of using `NavigationStack` to avoid
    /// nested UINavigationController issues on iOS.
    @Binding var currentDestination: MobilePersonalDestination?

    let onRefreshThreads: () async -> Void

    @State private var showProviderKeys = false
    @State private var showStrixSettings = false

    var body: some View {
        ZStack {
            NebulaBackground()

            switch currentDestination {
            case .threadsList:
                MobileThreadsList(
                    threads: $personalThreads,
                    onSelectThread: { thread in
                        currentDestination = .chat(thread)
                    },
                    onRefresh: onRefreshThreads,
                    onBack: { currentDestination = nil }
                )
            case let .chat(thread):
                // Use .id(thread.id) to ensure view refreshes when switching threads
                PersonalChatView(
                    thread: thread,
                    onEditAgent: { showStrixSettings = true },
                    onBack: { currentDestination = .threadsList }
                )
                .id(thread.id)
            case nil:
                // Root is the welcome screen
                MobileWelcomeScreen(
                    onNewChat: handleNewThread,
                    onShowThreads: { currentDestination = .threadsList },
                    onOpenProviderKeys: { showProviderKeys = true }
                )
            }
        }
        .sheet(isPresented: $showProviderKeys) {
            NavigationStack {
                ProviderKeysView()
                    .navigationTitle("Provider Keys")
            }
        }
        .sheet(isPresented: $showStrixSettings) {
            NavigationStack {
                StrixSettingsView(onClose: {
                    // Close the sheet after saving the agent configuration.
                    showStrixSettings = false
                })
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
                // Navigate to the new chat on the main actor and refresh
                // threads so the sidebar/list stays in sync.
                await MainActor.run {
                    currentDestination = .chat(thread)
                }
                await onRefreshThreads()
            } catch {
                AppErrorReporter.log(error: error, context: "MobilePersonalWorkspace.handleNewThread")
            }
        }
    }
}

// MARK: - Mobile Welcome Screen

struct MobileWelcomeScreen: View {
    let onNewChat: () -> Void
    let onShowThreads: () -> Void
    let onOpenProviderKeys: () -> Void

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            // Icon
            IconBadge(icon: "sparkles", size: 100, color: .aicovenTeal)

            // Title & subtitle
            VStack(spacing: Spacing.md) {
                Text("Welcome to AICoven")
                    .font(.aicovenDisplayMedium)
                    .foregroundColor(.aicovenTextPrimary)

                Text("Start a new conversation with Strix, your personal assistant.")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
            }

            // Action cards
            VStack(spacing: Spacing.md) {
                // Start a brand new chat
                Button(action: onNewChat) {
                    HStack(spacing: Spacing.md) {
                        IconBadge(icon: "message", size: 48, color: .aicovenTeal)

                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text("Personal Chat")
                                .font(.aicovenH2)
                                .foregroundColor(.aicovenTextPrimary)
                            Text("One-on-one with Strix")
                                .font(.aicovenBodySmall)
                                .foregroundColor(.aicovenTextTertiary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .foregroundColor(.aicovenTextSecondary)
                    }
                    .padding(Spacing.md)
                    .frame(maxWidth: .infinity)
                    .glassMorphism(cornerRadius: BorderRadius.lg, padding: 0)
                }
                .buttonStyle(.plain)

                // Open existing conversations (replaces the old toolbar hamburger)
                Button(action: onShowThreads) {
                    HStack(spacing: Spacing.md) {
                        IconBadge(icon: "line.3.horizontal", size: 40, color: .aicovenTeal)

                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text("Your Chats")
                                .font(.aicovenH3)
                                .foregroundColor(.aicovenTextPrimary)
                            Text("Browse and reopen previous conversations")
                                .font(.aicovenBodySmall)
                                .foregroundColor(.aicovenTextTertiary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .foregroundColor(.aicovenTextSecondary)
                    }
                    .padding(Spacing.md)
                    .frame(maxWidth: .infinity)
                    .glassMorphism(cornerRadius: BorderRadius.lg, padding: 0)
                }
                .buttonStyle(.plain)

                // Provider keys call-to-action when no keys are configured
                AddProviderKeysCard(onOpenProviderKeys: onOpenProviderKeys)
            }
            .padding(.horizontal, Spacing.xl)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Mobile Threads List

struct MobileThreadsList: View {
    @Binding var threads: [Thread]
    let onSelectThread: (Thread) -> Void
    let onRefresh: () async -> Void
    /// Optional back handler used on iOS mobile to return to the welcome
    /// screen without relying on a NavigationStack.
    let onBack: (() -> Void)?

    var body: some View {
        ZStack {
            NebulaBackground()

            VStack(spacing: Spacing.md) {
                // Lightweight header with an optional back button so users can
                // return to the welcome screen.
                HStack(spacing: Spacing.md) {
                    if let onBack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.aicovenTeal)
                        }
                        .buttonStyle(.plain)
                    }

                    Text("Your Chats")
                        .font(.aicovenH2)
                        .foregroundColor(.aicovenTextPrimary)

                    Spacer()
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.lg)

                if threads.isEmpty {
                    VStack(spacing: Spacing.lg) {
                        IconBadge(icon: "message", size: 60, color: .aicovenTeal)

                        Text("No conversations yet")
                            .font(.aicovenH2)
                            .foregroundColor(.aicovenTextPrimary)

                        Text("Start a new chat to begin")
                            .font(.aicovenBody)
                            .foregroundColor(.aicovenTextSecondary)
                    }
                } else {
                    List {
                        ForEach(threads) { thread in
                            Button(action: {
                                onSelectThread(thread)
                            }) {
                                HStack(spacing: Spacing.sm) {
                                    IconBadge(
                                        icon: "message.fill",
                                        size: 32,
                                        color: .aicovenTeal
                                    )

                                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                                        HStack(spacing: 4) {
                                            Text(thread.title ?? "Untitled Chat")
                                                .font(.aicovenBody)
                                                .foregroundColor(.aicovenTextPrimary)

                                            // Concisely show Agent Name if available or fallback
                                            if let agentName = thread.agentName {
                                                Text("• \(agentName)")
                                                    .font(.aicovenBody)
                                                    .foregroundColor(.aicovenTextSecondary)
                                            } else {
                                                Text("• Strix")
                                                    .font(.aicovenBody)
                                                    .foregroundColor(.aicovenTextSecondary)
                                            }
                                        }

                                        HStack(spacing: 4) {
                                            // Only show model if thread has one stored
                                            if let model = thread.agentModel {
                                                Text(model)
                                                    .font(.aicovenCaption)
                                                    .foregroundColor(.aicovenTeal)

                                                if thread.updatedAt != nil {
                                                    Text("•")
                                                        .font(.aicovenCaption)
                                                        .foregroundColor(.aicovenTextTertiary)
                                                }
                                            }

                                            if let updatedAt = thread.updatedAt {
                                                Text(relativeTime(from: updatedAt))
                                                    .font(.aicovenCaption)
                                                    .foregroundColor(.aicovenTextTertiary)
                                            }
                                        }
                                    }

                                    Spacer()
                                    #if os(iOS)
                                    Image(systemName: "chevron.right")
                                        .font(.aicovenCaption)
                                        .foregroundColor(.aicovenTextTertiary)
                                    #endif
                                }
                                .padding(.vertical, Spacing.xs)
                            }
                            .listRowBackground(Color.aicovenGlass)
                        }
                        .onDelete(perform: deleteThreads)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
        }
    }

    private func deleteThreads(at offsets: IndexSet) {
        let idsToDelete = offsets.map { threads[$0].id }

        Task {
            for id in idsToDelete {
                do {
                    try await ThreadService.shared.deleteThread(threadId: id)
                    if let index = threads.firstIndex(where: { $0.id == id }) {
                        threads.remove(at: index)
                    }
                } catch {
                    AppErrorReporter.log(error: error, context: "MobileThreadsList.deleteThreads")
                }
            }
        }
    }

    private func relativeTime(from date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date, to: now)

        if let years = components.year, years > 0 {
            return "\(years)y ago"
        } else if let months = components.month, months > 0 {
            return "\(months)mo ago"
        } else if let days = components.day, days > 0 {
            return "\(days)d ago"
        } else if let hours = components.hour, hours > 0 {
            return "\(hours)h ago"
        } else if let minutes = components.minute, minutes > 0 {
            return "\(minutes)m ago"
        } else {
            return "Just now"
        }
    }
}

// Mobile personal chats now reuse PersonalChatView for a unified experience

// MARK: - Mobile Coven Workspace

/// Root coven tab for mobile – list covens, then threads, then chat
struct MobileCovensRootView: View {
    @State private var covens: [Coven] = []
    @State private var isLoading = true
    @State private var showCreateCoven = false
    @State private var errorMessage: String?
    /// When the user first opens the Covens tab and has no covens yet,
    /// automatically present the create-coven flow once.
    @State private var hasPresentedFirstCovenOnboarding = false
    /// Currently selected coven for navigation into its threads view.
    @State private var selectedCovenItem: Coven?

    var body: some View {
        NavigationStack {
            ZStack {
                NebulaBackground()

                if isLoading {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.aicovenTeal)
                } else if covens.isEmpty {
                    VStack(spacing: Spacing.lg) {
                        IconBadge(icon: "sparkles", size: 60, color: .aicovenTeal)
                        Text("No Covens Yet")
                            .font(.aicovenH2)
                            .foregroundColor(.aicovenTextPrimary)
                        Text("Create a coven to collaborate with multiple AI roles.")
                            .font(.aicovenBody)
                            .foregroundColor(.aicovenTextSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Spacing.lg)
                        Button {
                            showCreateCoven = true
                        } label: {
                            GradientButton("Create Coven", icon: "plus", style: .primary) {}
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(Spacing.xl)
                    // First-time coven onboarding: when the user opens the
                    // Covens tab and has no covens yet, automatically present
                    // the create-coven flow once.
                    .task {
                        if !hasPresentedFirstCovenOnboarding {
                            hasPresentedFirstCovenOnboarding = true
                            showCreateCoven = true
                        }
                    }
                } else {
                    List {
                        ForEach(covens) { coven in
                            Button {
                                selectedCovenItem = coven
                            } label: {
                                HStack(spacing: Spacing.md) {
                                    IconBadge(icon: "sparkles", size: 40, color: .aicovenTeal)
                                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                                        Text(coven.name)
                                            .font(.aicovenH2)
                                            .foregroundColor(.aicovenTextPrimary)
                                        if let description = coven.description {
                                            Text(description)
                                                .font(.aicovenBodySmall)
                                                .foregroundColor(.aicovenTextSecondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, Spacing.xs)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.aicovenGlass)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Covens")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showCreateCoven = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .foregroundColor(.aicovenTeal)
                }
            }
            .sheet(isPresented: $showCreateCoven) {
                CreateCovenSheet(onCreated: { coven in
                    Task {
                        await loadCovens()
                        selectedCovenItem = coven
                    }
                })
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                if let errorMessage { Text(errorMessage) }
            }
            .navigationDestination(item: $selectedCovenItem) { coven in
                MobileCovenThreadsView(coven: coven)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await loadCovens() }
    }

    private func loadCovens() async {
        isLoading = true
        defer { isLoading = false }

        do {
            covens = try await CovenService.shared.loadCovens()
        } catch {
            errorMessage = error.localizedDescription
            covens = []
        }
    }
}

/// Threads list for a specific coven
struct MobileCovenThreadsView: View {
    let coven: Coven
    @State private var threads: [Thread] = []
    @State private var isLoading = true
    @State private var showNewThread = false
    @State private var errorMessage: String?
    @State private var selectedThread: Thread?

    var body: some View {
        ZStack {
            NebulaBackground()

            List {
                ForEach(threads) { thread in
                    Button {
                        selectedThread = thread
                    } label: {
                        HStack(spacing: Spacing.sm) {
                            IconBadge(icon: "message", size: 28, color: .aicovenTeal)
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                HStack(spacing: 4) {
                                    Text(thread.title ?? "Untitled Chat")
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

                                    if thread.agentModel != nil, thread.updatedAt != nil {
                                        Text("•")
                                            .font(.aicovenCaption)
                                            .foregroundColor(.aicovenTextTertiary)
                                    }

                                    if let updatedAt = thread.updatedAt {
                                        Text(relativeTime(from: updatedAt))
                                            .font(.aicovenCaption)
                                            .foregroundColor(.aicovenTextSecondary)
                                    }
                                }
                            }
                            Spacer()
                            #if os(iOS)
                            Image(systemName: "chevron.right")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextTertiary)
                            #endif
                        }
                        .padding(.vertical, Spacing.xs)
                    }
                    .listRowBackground(Color.aicovenGlass)
                }
                .onDelete(perform: deleteThreads)
            }
            .scrollContentBackground(.hidden)

            if !isLoading, threads.isEmpty {
                VStack(spacing: Spacing.lg) {
                    IconBadge(icon: "sparkles", size: 60, color: .aicovenTeal)
                    Text("This coven is ready")
                        .font(.aicovenH2)
                        .foregroundColor(.aicovenTextPrimary)
                    Text("Start a new chat, or add agent roles from the … menu in the top right.")
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.lg)
                    GradientButton("Start New Chat", icon: "square.and.pencil", style: .primary) {
                        showNewThread = true
                    }
                }
                .padding(Spacing.xl)
            }
        }
        .navigationTitle(coven.name)
        .toolbar {
            // New thread
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showNewThread = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .foregroundColor(.aicovenTeal)
            }
            #if os(iOS)
            // Coven tools: memory & roles
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    NavigationLink(destination: MobileCovenMemoryView(coven: coven)) {
                        Label("Memory", systemImage: "brain")
                    }
                    NavigationLink(destination: MobileCovenRolesView(coven: coven)) {
                        Label("Agent Roles", systemImage: "person.3")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.aicovenTeal)
                }
            }
            #endif
        }
        .sheet(isPresented: $showNewThread) {
            NewThreadView(covenId: coven.id) { thread in
                Task {
                    await loadThreads()
                    selectedThread = thread
                }
            }
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let errorMessage { Text(errorMessage) }
        }
        .task { await loadThreads() }
        .navigationDestination(item: $selectedThread) { thread in
            MobileCovenChatView(thread: thread, coven: coven)
        }
    }

    private func deleteThreads(at offsets: IndexSet) {
        let idsToDelete = offsets.map { threads[$0].id }

        Task {
            for id in idsToDelete {
                do {
                    try await ThreadService.shared.deleteThread(threadId: id)
                    if let index = threads.firstIndex(where: { $0.id == id }) {
                        threads.remove(at: index)
                    }
                    if selectedThread?.id == id {
                        selectedThread = nil
                    }
                } catch {
                    AppErrorReporter.log(error: error, context: "MobileCovenThreadsView.deleteThreads")
                }
            }
        }
    }

    private func loadThreads() async {
        isLoading = true
        defer { isLoading = false }
        do {
            threads = try await ThreadService.shared.loadThreads(covenId: coven.id)
        } catch {
            errorMessage = error.localizedDescription
            threads = []
        }
    }

    private func relativeTime(from date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date, to: now)

        if let years = components.year, years > 0 {
            return "\(years)y"
        } else if let months = components.month, months > 0 {
            return "\(months)mo"
        } else if let days = components.day, days > 0 {
            return "\(days)d"
        } else if let hours = components.hour, hours > 0 {
            return "\(hours)h"
        } else if let minutes = components.minute, minutes > 0 {
            return "\(minutes)m"
        } else {
            return "now"
        }
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
                        Text(role.emoji ?? "🤖")
                            .font(.system(size: 24))
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

    var body: some View {
        PersonalChatView(
            thread: thread,
            onEditAgent: nil,
            onBack: nil
        )
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .background(NebulaBackground())
    }
}

// MARK: - Mobile Profile Root

struct MobileProfileRootView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                NebulaBackground()

                List {
                    Section("Account") {
                        NavigationLink(destination: EnhancedProfileView()) {
                            Label("Profile", systemImage: "person.crop.circle")
                        }
                    }

                    Section("Preferences") {
                        NavigationLink(destination: EnhancedSettingsView()) {
                            Label("Settings", systemImage: "gearshape")
                        }
                        NavigationLink(destination: ProviderKeysView()) {
                            Label("Provider Keys", systemImage: "key.fill")
                        }
                        NavigationLink(destination: UsageSettingsView()) {
                            Label("Budgets & Usage", systemImage: "chart.bar.xaxis")
                        }
                        NavigationLink(destination: StrixSettingsView()) {
                            Label("Default Agent", systemImage: "sparkles")
                        }
                    }

                    Section("Premium") {
                        NavigationLink(destination: StoreView()) {
                            Label("Upgrade", systemImage: "sparkles")
                                .foregroundColor(.aicovenTeal)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("Profile")
        }
    }
}

#Preview {
    MobileRootView()
        .environmentObject(AppState.shared)
        .environmentObject(AuthService.shared)
}
