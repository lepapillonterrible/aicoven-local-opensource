import SwiftUI

/// Root mobile UI: tab bar for Home / Workspace / Activity / Profile
struct MobileRootView: View {
    var body: some View {
        TabView {
            MobileChatsRootView()
                .tabItem {
                    Label("Chats", systemImage: "bubble.left.and.bubble.right.fill")
                }

            MobileWorkspaceRootView()
                .tabItem {
                    Label("Workspace", systemImage: "briefcase.fill")
                }

            MobileActivityRootView()
                .tabItem {
                    Label("Activity", systemImage: "bell.fill")
                }

            MobileProfileRootView()
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle.fill")
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
    @State private var errorMessage: String?

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
                                ForEach(threads) { thread in
                                    Button {
                                        selectedThread = thread
                                    } label: {
                                        ThreadRowView(thread: thread)
                                    }
                                    .listRowBackground(Color.aicovenGlass)
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            deleteThread(thread)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
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
                            Button { selectedCovenId = nil } label: {
                                if selectedCovenId == nil {
                                    Label("Strix", systemImage: "checkmark")
                                } else {
                                    Text("Strix")
                                }
                            }
                            Divider()
                            ForEach(covens) { coven in
                                Button { selectedCovenId = coven.id } label: {
                                    if selectedCovenId == coven.id {
                                        Label(coven.name, systemImage: "checkmark")
                                    } else {
                                        Text(coven.name)
                                    }
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
                .task(id: selectedCovenId) { await loadThreads() }
                .sheet(isPresented: $showCreateCoven) {
                    CreateCovenSheet(onCreated: { coven in
                        Task {
                            await loadCovens()
                            selectedCovenId = coven.id
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
                    if let errorMessage { Text(errorMessage) }
                }
        }
    }

    private func loadCovens() async {
        do {
            covens = try await CovenService.shared.loadCovens()
        } catch {
            AppErrorReporter.log(error: error, context: "MobileHomeView.loadCovens")
            covens = []
        }
    }

    private func loadThreads() async {
        isLoading = true
        defer { isLoading = false }
        do {
            threads = try await ThreadService.shared.loadThreads(covenId: selectedCovenId)
        } catch {
            AppErrorReporter.log(error: error, context: "MobileHomeView.loadThreads")
            threads = []
            errorMessage = error.localizedDescription
        }
    }

    private func deleteThread(_ thread: Thread) {
        Task {
            do {
                try await ThreadService.shared.deleteThread(threadId: thread.id)
                if let index = threads.firstIndex(where: { $0.id == thread.id }) {
                    threads.remove(at: index)
                }
            } catch {
                AppErrorReporter.log(error: error, context: "MobileHomeView.deleteThread")
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct ThreadRowView: View {
    let thread: Thread
    var body: some View {
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
                    if let updatedAt = thread.updatedAt {
                        if thread.agentModel != nil {
                            Text("•")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextTertiary)
                        }
                        Text(relativeTime(from: updatedAt))
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.aicovenCaption)
                .foregroundColor(.aicovenTextTertiary)
        }
        .padding(.vertical, Spacing.xs)
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

struct MobileProfileRootView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                NebulaBackground().ignoresSafeArea()
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
                    }

                    Section("Premium") {
                        NavigationLink(destination: StoreView()) {
                            Label("Upgrade", systemImage: "sparkles")
                                .foregroundColor(.aicovenTeal)
                        }
                    }

                    Section("Legal") {
                        NavigationLink(destination: TermsOfServiceView()) {
                            Label("Terms & Conditions", systemImage: "doc.text")
                        }
                        NavigationLink(destination: PrivacyPolicyView()) {
                            Label("Privacy Policy", systemImage: "hand.raised")
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

// MARK: - Mobile Workspace Root

struct MobileWorkspaceRootView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                NebulaBackground().ignoresSafeArea()
                List {
                    Section {
                        NavigationLink(destination: ProviderKeysView()) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Provider Keys", systemImage: "key.fill")
                                    .font(.headline)
                                Text("Connect and manage API keys")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }

                        NavigationLink(destination: UsageSettingsView()) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Budgets & Usage", systemImage: "chart.bar.xaxis")
                                    .font(.headline)
                                Text("Set limits and monitor usage")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }

                        NavigationLink(destination: ConnectedAppsView().environmentObject(StoreService.shared)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Connected Apps", systemImage: "app.connected.to.app.below.fill")
                                    .font(.headline)
                                Text("Manage external integrations")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }

                        NavigationLink(destination: MCPServerManagementView()) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("MCP Servers", systemImage: "server.rack")
                                    .font(.headline)
                                Text("Manage connected MCP servers")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("Workspace")
        }
    }
}

// MARK: - Mobile Activity Root

struct MobileActivityRootView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                NebulaBackground().ignoresSafeArea()

                VStack(spacing: Spacing.lg) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 60))
                        .foregroundColor(.aicovenTextSecondary)

                    Text("No Activity Yet")
                        .font(.aicovenH2)

                    Text("Local-first notifications and activity logs will appear here.")
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Activity")
        }
    }
}
