import SwiftUI

// MARK: - Memory List View (Desktop / Workspace)

/// View for displaying and managing saved memory chunks in the desktop workspace
/// Uses openTabs / activeTabId to open add/edit forms as separate tabs.
struct MemoryListView: View {
    let covenId: String?
    @Binding var openTabs: [WorkspaceTab]
    @Binding var activeTabId: String?

    @State private var memories: [Memory] = []
    @State private var searchText = ""
    @State private var selectedScope = "all"
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showDeleteConfirm = false
    @State private var memoryToDelete: Memory?

    let scopes = ["all", "user", "coven", "agent"]

    var filteredMemories: [Memory] {
        if searchText.isEmpty {
            return memories
        }
        return memories.filter { memory in
            memory.content.localizedCaseInsensitiveContains(searchText) ||
                (memory.title?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with search and actions
            VStack(spacing: Spacing.md) {
                // Title and actions
                HStack {
                    Text(covenId != nil ? "Memory" : "Personal Memory")
                        .font(.aicovenH2)
                        .foregroundColor(.aicovenTextPrimary)

                    Spacer()

                    // Add memory button
                    GradientButton("Add Memory", icon: "plus", style: .primary) {
                        openAddMemoryTab()
                    }
                    .frame(width: 140)
                }

                // Search bar
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "magnifyingglass")
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextTertiary)

                    TextField("Search memories...", text: $searchText)
                        .font(.aicovenBodySmall)
                        .textFieldStyle(.plain)
                }
                .padding(Spacing.sm)
                .background(Color.aicovenGlass)
                .cornerRadius(BorderRadius.sm)

                // Scope filter (only for coven memories)
                if covenId != nil {
                    HStack(spacing: Spacing.xs) {
                        ForEach(scopes, id: \.self) { scope in
                            Button {
                                selectedScope = scope
                                Task {
                                    await loadMemories()
                                }
                            } label: {
                                Text(scope.capitalized)
                                    .font(.aicovenCaption)
                                    .foregroundColor(selectedScope == scope ? .aicovenTeal : .aicovenTextSecondary)
                                    .padding(.horizontal, Spacing.sm)
                                    .padding(.vertical, Spacing.xs)
                                    .background(
                                        RoundedRectangle(cornerRadius: BorderRadius.sm)
                                            .fill(selectedScope == scope ? Color.aicovenGlass : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(Spacing.lg)

            GradientDivider()

            // Content area
            if isLoading {
                LoadingView(message: "Loading memories...")
            } else if let error = errorMessage {
                VStack(spacing: Spacing.md) {
                    ErrorBannerView(message: error)
                    Button("Retry") {
                        Task { await loadMemories() }
                    }
                    .buttonStyle(.bordered)
                }
            } else if filteredMemories.isEmpty {
                EmptyMemoryState(covenId: covenId, onAddMemory: openAddMemoryTab)
            } else {
                ScrollView {
                    LazyVStack(spacing: Spacing.sm) {
                        ForEach(filteredMemories) { memory in
                            MemoryCard(
                                memory: memory,
                                onEdit: { openEditMemoryTab(memory) },
                                onDelete: {
                                    memoryToDelete = memory
                                    showDeleteConfirm = true
                                },
                                onTogglePin: { isPinned in
                                    Task {
                                        await togglePin(memory: memory, isPinned: isPinned)
                                    }
                                }
                            )
                        }
                    }
                    .padding(Spacing.lg)
                }
            }
        }
        .task {
            await loadMemories()
        }
        .alert("Delete Memory", isPresented: $showDeleteConfirm, presenting: memoryToDelete) { memory in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    await deleteMemory(memory)
                }
            }
        } message: { _ in
            Text("Are you sure you want to delete this memory? This action cannot be undone.")
        }
    }

    // MARK: - Actions

    /// Load memories from API
    private func loadMemories() async {
        isLoading = true
        errorMessage = nil

        do {
            let scope = selectedScope == "all" ? nil : selectedScope
            memories = try await MemoryService.shared.searchMemory(
                covenId: covenId,
                query: searchText.isEmpty ? nil : searchText,
                scope: scope,
                limit: 100
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Toggle pin status
    private func togglePin(memory: Memory, isPinned: Bool) async {
        do {
            let updated = try await MemoryService.shared.togglePin(memoryId: memory.id, isPinned: isPinned)
            // Update in local list
            if let index = memories.firstIndex(where: { $0.id == updated.id }) {
                memories[index] = updated
            }
        } catch {
            errorMessage = "Failed to update pin status: \(error.localizedDescription)"
        }
    }

    /// Delete memory
    private func deleteMemory(_ memory: Memory) async {
        do {
            try await MemoryService.shared.deleteMemory(memoryId: memory.id)
            memories.removeAll { $0.id == memory.id }
        } catch {
            errorMessage = "Failed to delete memory: \(error.localizedDescription)"
        }
    }

    /// Open add memory tab
    private func openAddMemoryTab() {
        let tab = WorkspaceTab.addMemory(covenId: covenId)
        if !openTabs.contains(where: { $0.id == tab.id }) {
            openTabs.append(tab)
        }
        activeTabId = tab.id
    }

    /// Open edit memory tab
    private func openEditMemoryTab(_ memory: Memory) {
        let title = memory.title ?? String(memory.content.prefix(30))
        let tab = WorkspaceTab.editMemory(memoryId: memory.id, memoryTitle: title, covenId: covenId)
        if !openTabs.contains(where: { $0.id == tab.id }) {
            openTabs.append(tab)
        }
        activeTabId = tab.id
    }
}

// MARK: - Mobile Memory List View (Navigation + Sheets)

/// Mobile-first memory list with edit/delete via sheets instead of workspace tabs
struct MobileMemoryListView: View {
    let covenId: String?

    @State private var memories: [Memory] = []
    @State private var searchText = ""
    @State private var selectedScope = "all"
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showDeleteConfirm = false
    @State private var memoryToDelete: Memory?
    @State private var showAddSheet = false
    @State private var memoryToEdit: Memory?

    /// Available scopes for filtering. In the personal (no coven) view we only
    /// expose "all" and "user"; in coven contexts we also expose "coven" and
    /// "agent".
    private var scopes: [String] {
        covenId == nil ? ["all", "user"] : ["all", "user", "coven", "agent"]
    }

    private var filteredMemories: [Memory] {
        if searchText.isEmpty {
            return memories
        }
        return memories.filter { memory in
            memory.content.localizedCaseInsensitiveContains(searchText) ||
                (memory.title?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with search and actions
            VStack(spacing: Spacing.md) {
                HStack {
                    Text(covenId != nil ? "Memory" : "Personal Memory")
                        .font(.aicovenH2)
                        .foregroundColor(.aicovenTextPrimary)

                    Spacer()

                    Button {
                        showAddSheet = true
                    } label: {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "plus")
                            Text("Add")
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .background(Color.aicovenGlass)
                    .cornerRadius(BorderRadius.sm)
                }

                // Search bar
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "magnifyingglass")
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextTertiary)

                    TextField("Search memories...", text: $searchText)
                        .font(.aicovenBodySmall)
                        .textFieldStyle(.plain)
                }
                .padding(Spacing.sm)
                .background(Color.aicovenGlass)
                .cornerRadius(BorderRadius.sm)

                // Scope filter (only for coven memories)
                if covenId != nil {
                    HStack(spacing: Spacing.xs) {
                        ForEach(scopes, id: \.self) { scope in
                            Button {
                                selectedScope = scope
                                Task { await loadMemories() }
                            } label: {
                                Text(scope.capitalized)
                                    .font(.aicovenCaption)
                                    .foregroundColor(selectedScope == scope ? .aicovenTeal : .aicovenTextSecondary)
                                    .padding(.horizontal, Spacing.sm)
                                    .padding(.vertical, Spacing.xs)
                                    .background(
                                        RoundedRectangle(cornerRadius: BorderRadius.sm)
                                            .fill(selectedScope == scope ? Color.aicovenGlass : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(Spacing.lg)

            GradientDivider()

            // Content area
            if isLoading {
                LoadingView(message: "Loading memories...")
            } else if let error = errorMessage {
                MemoryErrorView(message: error) {
                    Task { await loadMemories() }
                }
            } else if filteredMemories.isEmpty {
                EmptyMemoryState(covenId: covenId) {
                    showAddSheet = true
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: Spacing.sm) {
                        ForEach(filteredMemories) { memory in
                            MemoryCard(
                                memory: memory,
                                onEdit: { memoryToEdit = memory },
                                onDelete: {
                                    memoryToDelete = memory
                                    showDeleteConfirm = true
                                },
                                onTogglePin: { isPinned in
                                    Task { await togglePin(memory: memory, isPinned: isPinned) }
                                }
                            )
                        }
                    }
                    .padding(Spacing.lg)
                }
            }
        }
        .task { await loadMemories() }
        // Add memory sheet
        .sheet(isPresented: $showAddSheet) {
            AddMemorySheetWrapper(covenId: covenId) {
                Task { await loadMemories() }
            }
        }
        // Edit memory sheet
        .sheet(item: $memoryToEdit) { memory in
            EditMemorySheetWrapper(memoryId: memory.id, covenId: covenId) {
                Task { await loadMemories() }
            }
        }
        .alert("Delete Memory", isPresented: $showDeleteConfirm, presenting: memoryToDelete) { memory in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await deleteMemory(memory) }
            }
        } message: { _ in
            Text("Are you sure you want to delete this memory? This action cannot be undone.")
        }
    }

    // MARK: - Data actions

    private func loadMemories() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let scope = selectedScope == "all" ? nil : selectedScope
            memories = try await MemoryService.shared.searchMemory(
                covenId: covenId,
                query: searchText.isEmpty ? nil : searchText,
                scope: scope,
                limit: 100
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func togglePin(memory: Memory, isPinned: Bool) async {
        do {
            let updated = try await MemoryService.shared.togglePin(memoryId: memory.id, isPinned: isPinned)
            if let index = memories.firstIndex(where: { $0.id == updated.id }) {
                memories[index] = updated
            }
        } catch {
            errorMessage = "Failed to update pin status: \(error.localizedDescription)"
        }
    }

    private func deleteMemory(_ memory: Memory) async {
        do {
            try await MemoryService.shared.deleteMemory(memoryId: memory.id)
            memories.removeAll { $0.id == memory.id }
        } catch {
            errorMessage = "Failed to delete memory: \(error.localizedDescription)"
        }
    }
}
