import SwiftUI

/// Enhanced sidebar with coven selector, threads, and roles
struct WorkspaceSidebarView: View {
    @Binding var selectedCoven: Coven?
    @Binding var openTabs: [WorkspaceTab]
    @Binding var activeTabId: String?
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
    @State private var threadsSectionExpanded = true
    @State private var rolesSectionExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if isExpanded {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.aicovenTextPrimary)
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
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(Color.aicovenSurfaceElevated.opacity(0.45))

            if isExpanded {
                ScrollView {
                    VStack(spacing: Spacing.lg) {
                        // Coven workspace tools — coven switching now lives in
                        // the icon rail, so no coven dropdown here (cloud parity).
                        VStack(spacing: Spacing.xs) {
                            // Knowledge Hub (memory) — available for coven and Strix.
                            sidebarToolButton(
                                icon: "brain",
                                title: "Knowledge Hub",
                                trailing: selectedCoven?.name ?? "Strix"
                            ) {
                                openMemoryTab(covenId: selectedCoven?.id)
                            }

                            // Coven Settings — only when a coven is selected.
                            // Opens as a workspace tab (cloud parity).
                            if let coven = selectedCoven {
                                sidebarToolButton(
                                    icon: "gearshape",
                                    title: "Coven Settings",
                                    trailing: nil
                                ) {
                                    let tab = WorkspaceTab.covenSettings(covenId: coven.id)
                                    if !openTabs.contains(where: { $0.id == tab.id }) {
                                        openTabs.append(tab)
                                    }
                                    activeTabId = tab.id
                                }
                            }
                        }

                        ThreadManagementView(
                            selectedCoven: $selectedCoven,
                            openTabs: $openTabs,
                            activeTabId: $activeTabId,
                            threads: $threads,
                            searchText: $searchText,
                            showNewThreadSheet: $showNewThreadSheet,
                            isSectionExpanded: $threadsSectionExpanded
                        )

                        if selectedCoven != nil {
                            RoleManagementView(
                                selectedCoven: $selectedCoven,
                                roles: roles,
                                onAddRole: onAddRole,
                                onEditRole: onEditRole,
                                onDeleteRole: onDeleteRole,
                                onTapRole: onTapRole,
                                isSectionExpanded: $rolesSectionExpanded
                            )
                        }

                        // WorkspaceToolsSection removed to avoid menu duplication
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, Spacing.md)
                    .padding(.bottom, Spacing.lg)
                }
            }
        }
        .frame(width: isExpanded ? 300 : 64)
        .background(Color.aicovenSurfaceElevated.opacity(0.62))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.aicovenBorder)
                .frame(width: 1)
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
        .task {
            await loadCovens()
        }
        // Load threads for whatever coven is selected — including the first
        // paint when ``WorkspaceView`` was constructed with
        // ``initialCoven``/``initialThread`` from the home "Recent" list.
        // ``onChange(of: selectedCoven)`` alone misses that case because there
        // is no transition (nil → coven) for the binding to observe.
        .task(id: selectedCoven?.id) {
            guard let covenId = selectedCoven?.id else {
                threads = []
                return
            }
            await loadThreads(covenId: covenId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .didCreateThread)) { _ in
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

    /// A glassy sidebar tool button used for Knowledge Hub, Coven Settings, etc.
    private func sidebarToolButton(
        icon: String,
        title: String,
        trailing: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.aicovenBodyMedium)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm)
            .padding(.horizontal, Spacing.sm)
            .background(Color.aicovenGlass)
            .overlay(
                RoundedRectangle(cornerRadius: BorderRadius.md)
                    .strokeBorder(Color.aicovenBorder, lineWidth: 1)
            )
            .cornerRadius(BorderRadius.md)
        }
        .buttonStyle(.plain)
        .foregroundColor(.aicovenTextPrimary)
    }

    /// Load covens from API
    private func loadCovens() async {
        do {
            let loadedCovens = try await CovenService.shared.loadCovens()
            await MainActor.run {
                covens = loadedCovens
                if let selected = selectedCoven,
                   !loadedCovens.contains(where: { $0.id == selected.id }) {
                    selectedCoven = loadedCovens.first
                } else if selectedCoven == nil {
                    selectedCoven = loadedCovens.first
                }
            }
            if loadedCovens.isEmpty {
                await MainActor.run {
                    onSwitchToHome()
                }
            }
        } catch {
            print("❌ Failed to load covens: \(error.localizedDescription)")
            await MainActor.run {
                covens = []
                selectedCoven = nil
                onSwitchToHome()
            }
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

    private func openSidebarTab(_ type: WorkspaceTabType) {
        if let existingTab = openTabs.first(where: { $0.type == type }) {
            activeTabId = existingTab.id
            return
        }

        let tab: WorkspaceTab
        switch type {
        case .profile:
            tab = .profile
        case .settings:
            tab = .settings
        case .providerKeys:
            tab = .providerKeys
        case .budget:
            tab = .budget
        case .usage:
            tab = .usage
        case .connectedApps:
            tab = .connectedApps
        case .terms:
            tab = .terms
        case .privacy:
            tab = .privacy
        default:
            return
        }

        openTabs.append(tab)
        activeTabId = tab.id
    }

    private func openMemoryTab(covenId: String?) {
        let type = WorkspaceTabType.memoryList(covenId: covenId)
        if let existingTab = openTabs.first(where: { $0.type == type }) {
            activeTabId = existingTab.id
            return
        }

        let tab = WorkspaceTab.memoryList(covenId: covenId)
        openTabs.append(tab)
        activeTabId = tab.id
    }
}

// MARK: - Coven Selector

/// Dropdown-style coven selector with actions
struct CovenSelectorView: View {
    @Binding var selectedCoven: Coven?
    @Binding var covens: [Coven]
    @Binding var showNewCovenSheet: Bool
    let onSwitchToHome: () -> Void
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

                            Text("\(covens.count) available")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextTertiary)
                        }

                        Spacer()

                        Image(systemName: "chevron.down")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
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
        }
        .popover(isPresented: $showCovenMenu) {
            CovenListPopover(
                covens: covens,
                selectedCoven: $selectedCoven,
                showCovenMenu: $showCovenMenu,
                onSwitchToHome: onSwitchToHome,
                onCreateCoven: { showNewCovenSheet = true }
            )
        }
    }
}

/// Popover showing all covens for selection
struct CovenListPopover: View {
    let covens: [Coven]
    @Binding var selectedCoven: Coven?
    @Binding var showCovenMenu: Bool
    let onSwitchToHome: () -> Void
    let onCreateCoven: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Covens")
                .font(.aicovenCaption)
                .foregroundColor(.aicovenTextTertiary)
                .padding(.horizontal, Spacing.sm)
                .padding(.top, Spacing.xs)

            Button {
                showCovenMenu = false
                onSwitchToHome()
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "sparkles")
                        .font(.aicovenBodySmall)
                        .foregroundColor(.aicovenTeal)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Strix")
                            .font(.aicovenBody)
                            .foregroundColor(.aicovenTextPrimary)
                        Text("Default coven")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextTertiary)
                    }
                    .font(.aicovenBody)
                    Spacer()
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: BorderRadius.sm)
                        .fill(Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color.aicovenBorder)
                .frame(height: 1)
                .padding(.vertical, Spacing.xs)

            Text("Covens Pro")
                .font(.aicovenCaption)
                .foregroundColor(.aicovenTextTertiary)
                .padding(.horizontal, Spacing.sm)

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

            Button {
                showCovenMenu = false
                onCreateCoven()
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "plus.circle.fill")
                        .font(.aicovenBodySmall)
                        .foregroundColor(.aicovenTeal)
                    Text("New Coven")
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextPrimary)
                    Spacer()
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
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
    @Binding var isSectionExpanded: Bool

    var filteredThreads: [Thread] {
        if searchText.isEmpty {
            return threads
        }
        return threads.filter { $0.title?.localizedCaseInsensitiveContains(searchText) ?? false }
    }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            HStack {
                Text("Threads")
                    .font(.aicovenH3)
                    .foregroundColor(.aicovenTextPrimary)
                Text("\(filteredThreads.count)")
                    .font(.aicovenCaption)
                    .foregroundColor(.aicovenTextTertiary)

                Spacer()

                Button {
                    showNewThreadSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(selectedCoven == nil ? .aicovenTextTertiary : .aicovenTeal)
                }
                .buttonStyle(.plain)
                .disabled(selectedCoven == nil)

                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        isSectionExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isSectionExpanded ? "chevron.down" : "chevron.right")
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.sm)

            if isSectionExpanded {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "magnifyingglass")
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextTertiary)

                    TextField("Search threads", text: $searchText)
                        .font(.aicovenBodySmall)
                        .textFieldStyle(.plain)
                }
                .padding(Spacing.sm)
                .background(Color.aicovenSurfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: BorderRadius.sm)
                        .stroke(Color.aicovenBorder, lineWidth: 1)
                )
                .cornerRadius(BorderRadius.sm)
                .padding(.horizontal, Spacing.sm)

                ScrollView {
                    LazyVStack(spacing: Spacing.xxs) {
                        if selectedCoven == nil {
                            EmptyThreadsView(message: "Select a coven to browse threads")
                        } else if filteredThreads.isEmpty {
                            EmptyThreadsView(message: "No threads yet, create one to begin")
                        } else {
                            ForEach(filteredThreads) { thread in
                                ThreadListItem(
                                    thread: thread,
                                    isSelected: activeTabId == thread.id,
                                    onDelete: {
                                        deleteThread(thread)
                                    }
                                )
                                .onTapGesture {
                                    let tab = WorkspaceTab.thread(thread)
                                    if !openTabs.contains(where: { $0.id == thread.id }) {
                                        openTabs.append(tab)
                                    }
                                    activeTabId = thread.id
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.xs)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
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
        HStack(spacing: Spacing.sm) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isSelected ? .aicovenTeal : .aicovenTextTertiary)
                .frame(width: 16, alignment: .center)

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
                            .foregroundColor(.aicovenTextTertiary)
                    }
                }
                .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: BorderRadius.sm)
                .fill(
                    isSelected
                        ? Color.aicovenSurfaceElevated
                        : (isHovering ? Color.aicovenGlass.opacity(0.4) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: BorderRadius.sm)
                .stroke(isSelected ? Color.aicovenBorder : Color.clear, lineWidth: 1)
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
    @Binding var isSectionExpanded: Bool

    var body: some View {
        VStack(spacing: Spacing.sm) {
            HStack {
                Text("Agents")
                    .font(.aicovenH3)
                    .foregroundColor(.aicovenTextPrimary)
                Text("\(roles.count)")
                    .font(.aicovenCaption)
                    .foregroundColor(.aicovenTextTertiary)

                Spacer()

                Button {
                    if let coven = selectedCoven {
                        onAddRole(coven.id)
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.aicovenTeal)
                }
                .buttonStyle(.plain)
                .disabled(selectedCoven == nil)

                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        isSectionExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isSectionExpanded ? "chevron.down" : "chevron.right")
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.sm)

            if isSectionExpanded {
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
                    .padding(.horizontal, Spacing.xs)
                }
            }
        }
        .frame(maxHeight: 220, alignment: .top)
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
            ZStack {
                Circle()
                    .fill(Color.aicovenGlass)
                    .frame(width: 28, height: 28)
                Text(role.emoji ?? "🤖")
                    .font(.system(size: 16))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(role.name)
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextPrimary)

                if let model = role.model {
                    Text(model)
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextTertiary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: BorderRadius.sm)
                .fill(isHovering ? Color.aicovenGlass.opacity(0.4) : Color.clear)
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

            Text("No agents yet")
                .font(.aicovenCaption)
                .foregroundColor(.aicovenTextSecondary)
        }
        .padding(Spacing.lg)
    }
}

struct WorkspaceToolsSection: View {
    let onOpenTab: (WorkspaceTabType) -> Void
    var isCollapsible: Bool = false
    @State private var expanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Button {
                if isCollapsible {
                    withAnimation(.easeOut(duration: 0.18)) {
                        expanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Text("Workspace")
                        .font(.aicovenH3)
                        .foregroundColor(.aicovenTextPrimary)
                    Spacer()
                    if isCollapsible {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextTertiary)
                    }
                }
                .padding(.horizontal, Spacing.sm)
            }
            .buttonStyle(.plain)
            .disabled(!isCollapsible)

            if expanded {
                WorkspaceToolRow(icon: "key", title: "Provider Keys") { onOpenTab(.providerKeys) }
                WorkspaceToolRow(icon: "chart.bar", title: "Budgets & Usage") { onOpenTab(.usage) }
                WorkspaceToolRow(
                    icon: "app.connected.to.app.below.fill",
                    title: "Connected Apps"
                ) { onOpenTab(.connectedApps) }
            }
        }
        .padding(Spacing.sm)
        .background(Color.aicovenSurfaceElevated.opacity(0.55))
        .overlay(
            RoundedRectangle(cornerRadius: BorderRadius.md)
                .stroke(Color.aicovenBorder, lineWidth: 1)
        )
        .cornerRadius(BorderRadius.md)
        .onAppear {
            if isCollapsible {
                expanded = false
            }
        }
    }
}

struct WorkspaceToolRow: View {
    let icon: String
    let title: String
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: icon)
                    .font(.aicovenBodySmall)
                    .frame(width: 16)
                Text(title)
                    .font(.aicovenBodySmall)
                Spacer()
            }
            .foregroundColor(isDestructive ? .aicovenError : .aicovenTextSecondary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: BorderRadius.sm)
                    .fill(isHovering ? Color.aicovenGlass.opacity(0.35) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

struct EmptyThreadsView: View {
    let message: String

    var body: some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                .font(.system(size: 20))
                .foregroundColor(.aicovenTextTertiary)
            Text(message)
                .font(.aicovenCaption)
                .foregroundColor(.aicovenTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.lg)
    }
}
