import re

with open("swift/AICoven/AICoven/Views/Main/MobileHomeView.swift", "r") as f:
    content = f.read()

# Replace MobileRootView
old_root = """struct MobileRootView: View {
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
}"""

new_root = """struct MobileRootView: View {
    var body: some View {
        TabView {
            MobileChatsRootView()
                .tabItem {
                    Label("Chats", systemImage: "bubble.left.and.bubble.right.fill")
                }

            MobileProfileRootView()
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle")
                }
        }
        .tint(.aicovenTeal)
    }
}"""
content = content.replace(old_root, new_root)

# Find where MobileHomeView starts and where MobileCovenMemoryView starts
start_pattern = "// Mobile-optimized home view for iPhone (portrait)"
end_pattern = "/// Coven-wide memory & proposals view (mobile wrapper)"

start_idx = content.find(start_pattern)
end_idx = content.find(end_pattern)

new_chats_view = """// MARK: - Mobile Chats Root View

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
                                    Text("No chats in \\(scopeTitle) yet")
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Menu {
                        Button { selectedCovenId = nil } label: { Label("Strix", systemImage: selectedCovenId == nil ? "checkmark" : "") }
                        Divider()
                        ForEach(covens) { coven in
                            Button { selectedCovenId = coven.id } label: { Label(coven.name, systemImage: selectedCovenId == coven.id ? "checkmark" : "") }
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
                if let selectedCoven = selectedCoven {
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
                if let selectedCoven = selectedCoven {
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
        }
    }

    private func loadCovens() async {
        do {
            covens = try await CovenService.shared.loadCovens()
        } catch {
            print("❌ Failed to load covens: \\(error)")
        }
    }

    private func loadThreads() async {
        isLoading = true
        defer { isLoading = false }
        do {
            threads = try await ThreadService.shared.loadThreads(covenId: selectedCovenId)
        } catch {
            print("❌ Failed to load threads: \\(error)")
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
                print("❌ Failed to delete thread: \\(error)")
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
                        Text("• \\(agentName)")
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

        if let years = components.year, years > 0 { return "\\(years)y" }
        else if let months = components.month, months > 0 { return "\\(months)mo" }
        else if let days = components.day, days > 0 { return "\\(days)d" }
        else if let hours = components.hour, hours > 0 { return "\\(hours)h" }
        else if let minutes = components.minute, minutes > 0 { return "\\(minutes)m" }
        else { return "now" }
    }
}

"""

if start_idx != -1 and end_idx != -1:
    content = content[:start_idx] + new_chats_view + content[end_idx:]
    with open("swift/AICoven/AICoven/Views/Main/MobileHomeView.swift", "w") as f:
        f.write(content)
    print("Success")
else:
    print(f"Failed to find indices. Start: {start_idx}, End: {end_idx}")

