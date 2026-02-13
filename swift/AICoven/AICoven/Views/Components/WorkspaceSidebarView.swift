import SwiftUI

/// Enhanced sidebar with coven selector, threads, and roles
struct WorkspaceSidebarView: View {
    @Binding var selectedCoven: Coven?
    @Binding var openTabs: [WorkspaceTab]
    @Binding var activeTabId: String?
    @Binding var threadRefreshTrigger: Bool
    /// Shared binding for showing the new thread sheet (controlled by parent WorkspaceView)
    @Binding var showNewThreadSheet: Bool
    let roles: [Role]
    let onAddRole: (String) -> Void
    let onEditRole: (Role) -> Void
    let onDeleteRole: (Role) -> Void
    let onTapRole: (Role) -> Void
    let onSwitchToHome: () -> Void
    @State private var covens: [Coven] = []
    @State private var threads: [Thread] = []
    @State private var searchText = ""
    @State private var showNewCovenSheet = false
    @State private var isExpanded = true // Expanded by default so users can select covens

    var body: some View {
        VStack(spacing: 0) {
            // Workspace switcher at top
            WorkspaceSwitcher(
                currentWorkspace: .covens,
                onSwitch: onSwitchToHome,
                isExpanded: isExpanded
            )
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.sm)

            GradientDivider()

            // Collapse button
            HStack {
                if isExpanded, let coven = selectedCoven {
                    IconBadge(
                        icon: "sparkles",
                        size: 20,
                        color: .aicovenTeal
                    )
                    Text(coven.name)
                        .font(.aicovenH3)
                        .foregroundColor(.aicovenTextPrimary)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "sidebar.left" : "sidebar.right")
                        .font(.system(size: 14))
                        .foregroundColor(.aicovenTextSecondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
            .padding(Spacing.md)

            GradientDivider()

            if isExpanded {
                // Coven selector
                CovenSelectorView(
                    selectedCoven: $selectedCoven,
                    covens: $covens,
                    showNewCovenSheet: $showNewCovenSheet
                )
                .padding(Spacing.md)

                GradientDivider()

                // Thread management section
                ThreadManagementView(
                    selectedCoven: $selectedCoven,
                    openTabs: $openTabs,
                    activeTabId: $activeTabId,
                    threads: $threads,
                    searchText: $searchText,
                    showNewThreadSheet: $showNewThreadSheet
                )

                GradientDivider()

                // Roles section (if coven selected)
                if selectedCoven != nil {
                    RoleManagementView(
                        selectedCoven: $selectedCoven,
                        roles: roles,
                        onAddRole: onAddRole,
                        onEditRole: onEditRole,
                        onDeleteRole: onDeleteRole,
                        onTapRole: onTapRole
                    )
                }
            }
        }
        .frame(width: isExpanded ? 280 : 60)
        .background(Color.aicovenGlass)
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
        .task {
            await loadCovens()
        }
        .onChange(of: selectedCoven) { _, newValue in
            Task {
                if let covenId = newValue?.id {
                    await loadThreads(covenId: covenId)
                }
            }
        }
        .onChange(of: threadRefreshTrigger) { _, _ in
            Task {
                if let covenId = selectedCoven?.id {
                    await loadThreads(covenId: covenId)
                }
            }
        }
        .sheet(isPresented: $showNewCovenSheet) {
            NavigationStack {
                NewCovenView {
                    Task {
                        await loadCovens()
                    }
                }
            }
        }
        .sheet(isPresented: $showNewThreadSheet) {
            NavigationStack {
                NewThreadView(covenId: selectedCoven?.id) { thread in
                    Task {
                        if let covenId = selectedCoven?.id {
                            await loadThreads(covenId: covenId)
                        }
                        // Open the newly created thread immediately in a
                        // workspace tab so the user can start chatting right
                        // away instead of returning to the thread list.
                        let tab = WorkspaceTab.thread(thread)
                        if !openTabs.contains(where: { $0.id == tab.id }) {
                            openTabs.append(tab)
                        }
                        activeTabId = tab.id
                    }
                }
            }
        }
    }

    /// Load covens from local database
    private func loadCovens() async {
        do {
            covens = try await CovenService.shared.loadCovens()
        } catch {
            print("❌ Failed to load covens: \(error.localizedDescription)")
        }
    }

    /// Load threads for a coven
    private func loadThreads(covenId: String) async {
        do {
            threads = try await ThreadService.shared.loadThreads(covenId: covenId)
        } catch {
            print("❌ Failed to load threads: \(error.localizedDescription)")
        }
    }

}

// MARK: - Coven Selector

/// Dropdown-style coven selector with actions
struct CovenSelectorView: View {
    @Binding var selectedCoven: Coven?
    @Binding var covens: [Coven]
    @Binding var showNewCovenSheet: Bool
    @State private var showCovenMenu = false

    var body: some View {
        VStack(spacing: Spacing.sm) {
            // Selected coven display
            if let coven = selectedCoven {
                Button {
                    showCovenMenu.toggle()
                } label: {
                    HStack(spacing: Spacing.xs) {
                        IconBadge(
                            icon: "sparkles",
                            size: 28,
                            color: .aicovenTeal
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(coven.name)
                                .font(.aicovenH3)
                                .foregroundColor(.aicovenTextPrimary)

                            Text("\(covens.count) covens")
                                .font(.aicovenCaption)
                                .foregroundColor(Color(hex: "#9CA3AF"))
                        }

                        Spacer()

                        Image(systemName: "chevron.down")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)
                    }
                }
                .buttonStyle(.plain)
                .glassMorphism(cornerRadius: BorderRadius.md, padding: Spacing.sm)
            } else if covens.isEmpty {
                // No covens exist - show create coven prompt
                EmptyCovenView(showNewCovenSheet: $showNewCovenSheet)
            } else {
                // Covens exist but none selected - show selection prompt
                SelectCovenPrompt(covens: covens, onSelect: { coven in
                    selectedCoven = coven
                })
            }

            // Quick actions
            HStack(spacing: Spacing.xs) {
                // New coven button
                Button {
                    showNewCovenSheet = true
                } label: {
                    HStack(spacing: Spacing.xxs) {
                        Image(systemName: "plus")
                            .font(.system(size: 10))
                        Text("New")
                            .font(.aicovenCaption)
                    }
                    .foregroundColor(.aicovenTeal)
                }
                .buttonStyle(.plain)

                Spacer()

                // Edit coven button
                if selectedCoven != nil {
                    Button {
                        // TODO: Edit coven
                    } label: {
                        HStack(spacing: Spacing.xxs) {
                            Image(systemName: "gear")
                                .font(.system(size: 10))
                            Text("Edit")
                                .font(.aicovenCaption)
                        }
                        .foregroundColor(.aicovenTextSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .popover(isPresented: $showCovenMenu) {
            CovenListPopover(
                covens: covens,
                selectedCoven: $selectedCoven,
                showCovenMenu: $showCovenMenu
            )
        }
    }
}

/// Popover showing all covens for selection
struct CovenListPopover: View {
    let covens: [Coven]
    @Binding var selectedCoven: Coven?
    @Binding var showCovenMenu: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(covens) { coven in
                CovenMenuItem(
                    coven: coven,
                    isSelected: selectedCoven?.id == coven.id,
                    onSelect: {
                        selectedCoven = coven
                        showCovenMenu = false
                    }
                )
            }
        }
        .padding(Spacing.xs)
        .frame(width: 240)
    }
}

/// Individual coven menu item with hover state
struct CovenMenuItem: View {
    let coven: Coven
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack {
                IconBadge(
                    icon: "sparkles",
                    size: 24,
                    color: .aicovenTeal
                )

                Text(coven.name)
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextPrimary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTeal)
                }
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: BorderRadius.sm)
                    .fill(isHovering ? Color.aicovenGlass.opacity(0.5) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

/// Empty state when no coven is selected
struct EmptyCovenView: View {
    @Binding var showNewCovenSheet: Bool

    var body: some View {
        VStack(spacing: Spacing.md) {
            IconBadge(icon: "sparkles", size: 40, color: .aicovenTeal)

            Text("No Covens")
                .font(.aicovenH2)
                .foregroundColor(.aicovenTextPrimary)

            Text("Create your first coven to start collaborating")
                .font(.aicovenBodySmall)
                .foregroundColor(.aicovenTextSecondary)
                .multilineTextAlignment(.center)

            GradientButton("Create Coven", icon: "plus", style: .primary) {
                showNewCovenSheet = true
            }
        }
        .padding(Spacing.lg)
    }
}

/// Prompt to select a coven when covens exist but none is selected
struct SelectCovenPrompt: View {
    let covens: [Coven]
    let onSelect: (Coven) -> Void

    var body: some View {
        VStack(spacing: Spacing.md) {
            IconBadge(icon: "sparkles", size: 40, color: .aicovenTeal)

            Text("Select a Coven")
                .font(.aicovenH2)
                .foregroundColor(.aicovenTextPrimary)

            Text("Choose one of your \(covens.count) covens to start working")
                .font(.aicovenBodySmall)
                .foregroundColor(.aicovenTextSecondary)
                .multilineTextAlignment(.center)

            // Show list of covens as buttons
            VStack(spacing: Spacing.xs) {
                ForEach(covens.prefix(3)) { coven in
                    Button(action: { onSelect(coven) }) {
                        HStack(spacing: Spacing.xs) {
                            IconBadge(icon: "sparkles", size: 24, color: .aicovenTeal)
                            Text(coven.name)
                                .font(.aicovenBody)
                                .foregroundColor(.aicovenTextPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextSecondary)
                        }
                        .padding(Spacing.sm)
                        .background(Color.aicovenGlass)
                        .cornerRadius(BorderRadius.sm)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(Spacing.lg)
    }
}

// MARK: - Thread Management

/// Thread list with search and actions
struct ThreadManagementView: View {
    @Binding var selectedCoven: Coven?
    @Binding var openTabs: [WorkspaceTab]
    @Binding var activeTabId: String?
    @Binding var threads: [Thread]
    @Binding var searchText: String
    @Binding var showNewThreadSheet: Bool

    var filteredThreads: [Thread] {
        if searchText.isEmpty {
            return threads
        }
        return threads.filter { $0.title?.localizedCaseInsensitiveContains(searchText) ?? false }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Threads")
                    .font(.aicovenH3)
                    .foregroundColor(.aicovenTextPrimary)

                Spacer()

                Button {
                    showNewThreadSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                        .foregroundColor(.aicovenTeal)
                }
                .buttonStyle(.plain)
                .disabled(selectedCoven == nil)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)

            // Search bar
            HStack(spacing: Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.aicovenCaption)
                    .foregroundColor(.aicovenTextTertiary)

                TextField("Search threads", text: $searchText)
                    .font(.aicovenBodySmall)
                    .textFieldStyle(.plain)
            }
            .padding(Spacing.sm)
            .background(Color.aicovenGlass)
            .cornerRadius(BorderRadius.sm)
            .padding(.horizontal, Spacing.md)
            .padding(.bottom, Spacing.sm)

            // Thread list
            ScrollView {
                LazyVStack(spacing: Spacing.xxs) {
                    ForEach(filteredThreads) { thread in
                        ThreadListItem(
                            thread: thread,
                            isSelected: activeTabId == thread.id,
                            onDelete: {
                                deleteThread(thread)
                            }
                        )
                        .onTapGesture {
                            // Create a tab for this thread
                            let tab = WorkspaceTab.thread(thread)
                            // Open thread in new tab if not already open
                            if !openTabs.contains(where: { $0.id == thread.id }) {
                                openTabs.append(tab)
                            }
                            // Set as active tab
                            activeTabId = thread.id
                        }
                    }
                }
                .padding(.horizontal, Spacing.sm)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func deleteThread(_ thread: Thread) {
        Task {
            do {
                try await ThreadService.shared.deleteThread(threadId: thread.id)

                if let index = threads.firstIndex(where: { $0.id == thread.id }) {
                    threads.remove(at: index)
                }

                openTabs.removeAll { tab in
                    if case let .thread(t) = tab.type {
                        return t.id == thread.id
                    }
                    return false
                }

                if activeTabId == thread.id {
                    activeTabId = openTabs.last?.id
                }
            } catch {
                print("❌ Failed to delete thread: \(error.localizedDescription)")
            }
        }
    }
}

/// Individual thread list item with hover state
struct ThreadListItem: View {
    let thread: Thread
    let isSelected: Bool
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Spacing.xs) {
            IconBadge(
                icon: "message",
                size: 24,
                color: isSelected ? .aicovenTeal : .aicovenPurple
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(thread.title ?? "Untitled")
                    .font(.aicovenBodySmall)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundColor(isSelected ? .aicovenTextPrimary : .aicovenTextSecondary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if let agentName = thread.agentName {
                        Text(agentName)
                            .font(.aicovenCaption)
                            .foregroundColor(isSelected ? .aicovenTextSecondary : .aicovenTextTertiary)

                        Text("•")
                            .font(.aicovenCaption)
                            .foregroundColor(isSelected ? .aicovenTextSecondary : .aicovenTextTertiary)
                    }

                    if let model = thread.agentModel {
                        Text(model)
                            .font(.aicovenCaption)
                            .foregroundColor(isSelected ? .aicovenTextSecondary : .aicovenTextTertiary)

                        Text("•")
                            .font(.aicovenCaption)
                            .foregroundColor(isSelected ? .aicovenTextSecondary : .aicovenTextTertiary)
                    }

                    if let updatedAt = thread.updatedAt {
                        Text(relativeTime(from: updatedAt))
                            .font(.aicovenCaption)
                            .foregroundColor(Color(hex: "#9CA3AF"))
                    }
                }
                .lineLimit(1)
            }

            Spacer()
        }
        .padding(Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: BorderRadius.sm)
                .fill(isSelected ? Color.aicovenGlass : (isHovering ? Color.aicovenGlass.opacity(0.5) : Color.clear))
        )
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    /// Format relative time without seconds
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

// MARK: - Role Management

/// Role management section with list and actions
struct RoleManagementView: View {
    @Binding var selectedCoven: Coven?
    let roles: [Role]
    let onAddRole: (String) -> Void
    let onEditRole: (Role) -> Void
    let onDeleteRole: (Role) -> Void
    let onTapRole: (Role) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Agent Roles")
                    .font(.aicovenH3)
                    .foregroundColor(.aicovenTextPrimary)

                Spacer()

                Button {
                    if let coven = selectedCoven {
                        onAddRole(coven.id)
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                        .foregroundColor(.aicovenTeal)
                }
                .buttonStyle(.plain)
                .disabled(selectedCoven == nil)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)

            // Role list
            ScrollView {
                LazyVStack(spacing: Spacing.xxs) {
                    if roles.isEmpty {
                        EmptyRolesView()
                    } else {
                        ForEach(roles) { role in
                            RoleListItemWithMenu(
                                role: role,
                                onTap: { onTapRole(role) },
                                onEdit: { onEditRole(role) },
                                onDelete: { onDeleteRole(role) }
                            )
                        }
                    }
                }
                .padding(.horizontal, Spacing.sm)
            }
        }
        .frame(maxHeight: 200)
    }
}

/// Role list item with context menu
struct RoleListItemWithMenu: View {
    let role: Role
    let onTap: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Spacing.xs) {
            // Emoji or default icon
            Text(role.emoji ?? "🤖")
                .font(.system(size: 24))

            VStack(alignment: .leading, spacing: 2) {
                Text(role.name)
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextPrimary)

                if let model = role.model {
                    Text(model)
                        .font(.aicovenCaption)
                        .foregroundColor(Color(hex: "#9CA3AF"))
                }
            }

            Spacer()
        }
        .padding(Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: BorderRadius.sm)
                .fill(isHovering ? Color.aicovenGlass.opacity(0.5) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .contextMenu {
            Button {
                onEdit()
            } label: {
                Label("Edit", systemImage: "pencil")
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

/// Empty state for roles
struct EmptyRolesView: View {
    var body: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "person.3")
                .font(.system(size: 32))
                .foregroundColor(.aicovenTextTertiary)

            Text("No agent roles yet")
                .font(.aicovenCaption)
                .foregroundColor(.aicovenTextSecondary)
        }
        .padding(Spacing.lg)
    }
}
