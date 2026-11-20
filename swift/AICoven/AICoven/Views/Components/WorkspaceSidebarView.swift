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
    /// The coven whose Connections are open, if any.
    @State private var connectionsCoven: Coven?
    @State private var isExpanded = true // Expanded by default so users can select covens
    @State private var threadsSectionExpanded = true
    /// Counts the loads of the coven's threads, so that only the latest is shown.
    @State private var threadsLoad = 0
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
                        CovenSelectorView(
                            selectedCoven: $selectedCoven,
                            covens: $covens,
                            showNewCovenSheet: $showNewCovenSheet,
                            onSwitchToHome: onSwitchToHome
                        )

                        // Show Memory CTA for both Covens and Strix
                        Button {
                            openMemoryTab(covenId: selectedCoven?.id)
                        } label: {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: "brain")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Memory")
                                    .font(.aicovenBodyMedium)
                                Spacer()
                                Text(selectedCoven?.name ?? "Strix")
                                    .font(.aicovenCaption)
                                    .foregroundColor(.aicovenTextTertiary)
                                    .lineLimit(1)
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

                        // What of the person's connections this coven's
                        // agents may use. Strix (no coven) uses them all.
                        if let coven = selectedCoven {
                            Button {
                                connectionsCoven = coven
                            } label: {
                                HStack(spacing: Spacing.xs) {
                                    Image(systemName: "link")
                                        .font(.system(size: 14, weight: .semibold))
                                    Text("Connections")
                                        .font(.aicovenBodyMedium)
                                    Spacer()
                                    Text(coven.name)
                                        .font(.aicovenCaption)
                                        .foregroundColor(.aicovenTextTertiary)
                                        .lineLimit(1)
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
                            .accessibilityIdentifier("coven-connections-open")
                        }

                        ThreadManagementView(
                            selectedCoven: $selectedCoven,
                            openTabs: $openTabs,
                            activeTabId: $activeTabId,
                            threads: $threads,
                            searchText: $searchText,
                            showNewThreadSheet: $showNewThreadSheet,
                            isSectionExpanded: $threadsSectionExpanded,
                            onReload: {
                                if let covenID = selectedCoven?.id { await loadThreads(covenId: covenID) }
                            }
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
        // A thread was used: the order follows it. Heard here, where the
        // threads are held, so they are current when the sidebar is opened
        // out again after being folded away.
        .onReceive(NotificationCenter.default.publisher(for: ThreadService.threadUsed)) { _ in
            guard let covenID = selectedCoven?.id else { return }
            Task { await loadThreads(covenId: covenID) }
        }
        // A thread renamed in the list goes by its new name on its tab and
        // over its messages too.
        .onChange(of: threads) { _, threads in
            if openTabs.showsAnOldName(among: threads) { openTabs = openTabs.showing(threads) }
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
            // What each thread is doing, as stored for this account. Read
            // again from here on whenever a message is stored.
            ThreadActivities.shared.reload()
            await loadThreads(covenId: covenId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .didCreateThread)) { _ in
            Task {
                if let covenId = selectedCoven?.id {
                    await loadThreads(covenId: covenId)
                }
            }
        }
        .sheet(item: $connectionsCoven) { coven in
            NavigationStack {
                CovenConnectionsView(coven: coven)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { connectionsCoven = nil }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 520)
            #endif
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
        // Only the latest request is shown: one asked for before the
        // sidebar left this coven and came back is not.
        threadsLoad += 1
        let request = threadsLoad
        do {
            // With those archived: the list shows them in a section of their own.
            let stored = try await ThreadService.shared.loadThreads(covenId: covenId, includeArchived: true)
            // The sidebar can be showing another coven by now: these are not its threads.
            guard request == threadsLoad, selectedCoven?.id == covenId else { return }
            threads = stored
        } catch {
            AppErrorReporter.log(error: error, context: "WorkspaceSidebarView.loadThreads")
            // The list stays as it is, unless the data is locked or the
            // account another's by now.
            guard request == threadsLoad, selectedCoven?.id == covenId, !ThreadListRules.keepsShownList(after: error) else { return }
            threads = []
        }
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
                        CovenIcon(coven: coven, size: 28)

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
                CovenIcon(coven: coven, size: 24)

                Text(coven.name)
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextPrimary)

                Spacer()

                CovenUnreadDot(covenID: coven.id)

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
                            CovenIcon(coven: coven, size: 24)
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
    /// Reads the coven's threads again, as they are stored now.
    let onReload: () async -> Void
    /// Rename, archive, delete and copy, for this list's threads.
    @StateObject private var threadActions = ThreadActions()
    /// What each thread is doing, for its row and the list's order.
    @ObservedObject private var activities = ThreadActivities.shared
    @State private var showArchived = false

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
                Text("\(filteredThreads.count(where: { !$0.isArchived }))")
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
                            // Newest first, then those archived, under a header of their own.
                            let sections = ThreadListRules.sections(filteredThreads) { activities.activity[$0.id]?.isStillOpen == true }
                            ForEach(sections.open) { thread in
                                threadRow(thread)
                            }
                            if !sections.archived.isEmpty {
                                // A search shows what it found among them: the
                                // section is then open, says so, and stays open
                                // (not disabled, which VoiceOver would call dimmed).
                                ArchivedThreadsHeader(isExpanded: searchText.isEmpty ? $showArchived : .constant(true))
                                    .padding(.horizontal, Spacing.sm)
                                    .padding(.top, Spacing.sm)
                                if showArchived || !searchText.isEmpty {
                                    ForEach(sections.archived) { thread in
                                        threadRow(thread)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.xs)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .threadActionsHost(threadActions)
        .onAppear {
            threadActions.onChanged = { Task { await onReload() } }
            threadActions.onLeft = { close($0) }
        }
        // The list is left: a copy under way is called off, and nothing
        // more is told to a list that is not there.
        .onDisappear {
            threadActions.invalidate()
            threadActions.onChanged = nil
            threadActions.onLeft = nil
        }
        // Another coven's threads are another list.
        .onChange(of: selectedCoven?.id) { _, _ in threadActions.invalidate() }
    }

    private func threadRow(_ thread: Thread) -> some View {
        ThreadListItem(
            thread: thread,
            activity: activities.activity[thread.id],
            isSelected: activeTabId == thread.id
        )
        .onTapGesture {
            let tab = WorkspaceTab.thread(thread)
            if !openTabs.contains(where: { $0.id == thread.id }) {
                openTabs.append(tab)
            }
            activeTabId = thread.id
        }
        .threadRowActions(thread, threadActions)
    }

    /// A thread was deleted or archived: it is no longer open here.
    private func close(_ thread: Thread) {
        openTabs.removeAll { tab in
            if case let .thread(open) = tab.type {
                return open.id == thread.id
            }
            return false
        }
        if activeTabId == thread.id {
            activeTabId = openTabs.last?.id
        }
    }
}

/// Individual thread list item with hover state
struct ThreadListItem: View {
    let thread: Thread
    /// What the thread is doing, if a row says it.
    var activity: ConversationActivity?
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Spacing.sm) {
            ConversationActivityGlyph(activity: activity) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isSelected ? .aicovenTeal : .aicovenTextTertiary)
            }
            .frame(width: 16, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(ThreadListRules.title(of: thread))
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

                    Text(VisitWords.rowDate(ThreadListRules.lastUsed(thread)))
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextTertiary)
                }
                .lineLimit(1)

                ConversationActivityCaption(activity: activity)
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
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        // One thing to VoiceOver: its name, its agent and date, and what it is doing.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .threadActivityValue(activity)
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
            role.face(size: 28)

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
