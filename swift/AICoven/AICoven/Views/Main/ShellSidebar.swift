import SwiftUI

/// The shell's sidebar, as the cloud app's: the switcher at the top, naming
/// the scope on screen, with its Overview row and its places (Memory,
/// Agents, Connections), then its threads (those archived in a section of
/// their own) with a search of their titles, and the person's row at the
/// bottom. Only the threads scroll.
struct ShellSidebar: View {
    @ObservedObject var navigator: ShellNavigator
    @ObservedObject var shellThreads: ShellThreads
    @ObservedObject var threadActions: ThreadActions
    /// The person's covens, in their own order. Strix is not among them.
    let covens: [Coven]
    let personName: String
    let onOpenSettings: () -> Void
    let onCreateCoven: () -> Void
    /// Opens a place of the scope on screen (Memory, Agents, Assets, Connections),
    /// as the menu bar's Go menu does: the shell says where each leads.
    let onOpenPlace: (ShellSidebarItem) -> Void
    /// Moves a coven to a place in the person's order.
    let onMoveCoven: (_ covenID: String, _ index: Int) -> Void

    /// What each thread is doing, for its row and the list's order.
    @ObservedObject private var activities = ThreadActivities.shared
    @State private var showsArchived = false
    /// The Threads section's search box is open, and what it holds.
    @State private var isSearching = false
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #endif
    @State private var showSwitcher = false
    /// The switcher row's width, margins included, for its popover.
    @State private var switcherRowWidth: CGFloat = 0
    /// Whether rows and buttons take the iPad's sizes, for a finger.
    @Environment(\.isPadLayout) private var isPadLayout
    /// A pinned row's height, growing with the text size: 34 pt for a
    /// pointer, 44 pt for a finger.
    @ScaledMetric(relativeTo: .body) private var pointerRowHeight: CGFloat = 34
    @ScaledMetric(relativeTo: .body) private var touchRowHeight: CGFloat = 44
    /// A place button and its icon, growing with the text size like the
    /// row above them: 32 pt and 17 pt for a pointer, 40 pt and 20 pt for
    /// a finger.
    @ScaledMetric(relativeTo: .body) private var pointerPlaceButtonHeight: CGFloat = 32
    @ScaledMetric(relativeTo: .body) private var touchPlaceButtonHeight: CGFloat = 40
    @ScaledMetric(relativeTo: .body) private var pointerPlaceIconSize: CGFloat = 17
    @ScaledMetric(relativeTo: .body) private var touchPlaceIconSize: CGFloat = 20

    private var pinnedRowHeight: CGFloat {
        isPadLayout ? touchRowHeight : pointerRowHeight
    }

    private var placeButtonHeight: CGFloat {
        isPadLayout ? touchPlaceButtonHeight : pointerPlaceButtonHeight
    }

    private var placeIconSize: CGFloat {
        isPadLayout ? touchPlaceIconSize : pointerPlaceIconSize
    }

    /// A thread row's least height, and a switcher row's.
    private var rowMinHeight: CGFloat {
        isPadLayout ? 44 : 34
    }

    /// The pinned zones' text sizes: past xxxLarge they would leave the
    /// threads no room. The threads keep every size.
    private static let pinnedZoneTypeSizes = DynamicTypeSize.xSmall ... DynamicTypeSize.xxxLarge

    /// The person's name on their row: their name, else their email, else
    /// "Account".
    static func personName(name: String?, email: String?) -> String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty { return email }
        return "Account"
    }

    /// The coven on screen; nil for Strix, or while the covens are not in.
    private var coven: Coven? {
        navigator.selected.covenID.flatMap { id in covens.first { $0.id == id } }
    }

    /// The name of the scope on screen; nil for a coven that is not in yet.
    private var scopeName: String? {
        navigator.selected == .strix ? "Strix" : coven?.name
    }

    /// Up to two other scopes with something moving or waiting, in the
    /// switcher's order (Strix first), for the lines under the name of the
    /// scope on screen.
    static func othersCurrent(
        covens: [Coven], selected: ShellScope, current: [ShellScope: ConversationActivity]
    ) -> [(name: String, current: ConversationActivity)] {
        let scopes: [(scope: ShellScope, name: String)] = [(.strix, "Strix")] + covens.map { (.coven($0.id), $0.name) }
        let busy = scopes.compactMap { item -> (name: String, current: ConversationActivity)? in
            guard item.scope != selected, let activity = current[item.scope] else { return nil }
            return (item.name, activity)
        }
        return Array(busy.prefix(2))
    }

    /// The scope's threads as the search leaves them, in their two sections:
    /// those still open first, then the rest, each newest first; then those
    /// archived.
    private var sections: (open: [Thread], archived: [Thread]) {
        let shown = isSearching ? ThreadListRules.matching(shellThreads.threads, query: searchText) : shellThreads.threads
        return ThreadListRules.sections(shown) { activities.activity[$0.id]?.isStillOpen == true }
    }

    /// A query is typed: the search is narrowing the list.
    private var isNarrowing: Bool {
        isSearching && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Nothing matches the query, among the threads or those archived.
    /// Not said while the threads are not in, or could not be read: then
    /// it is not known whether anything matches.
    private func noThreadsMatch(in sections: (open: [Thread], archived: [Thread])) -> Bool {
        isNarrowing && shellThreads.hasLoaded && !shellThreads.failed && sections.open.isEmpty && sections.archived.isEmpty
    }

    var body: some View {
        let sections = sections
        let noThreadsMatch = noThreadsMatch(in: sections)
        List(selection: selection) {
            Section {
                if isSearching {
                    searchBox
                }
                if shellThreads.failed {
                    couldNotLoad
                }
                ForEach(sections.open) { thread in
                    threadRow(thread, activity: activities.activity[thread.id])
                        .tag(ShellSidebarItem.thread(thread.id))
                        .threadRowActions(thread, threadActions)
                }
            } header: {
                threadsHeader
            }

            if !sections.archived.isEmpty {
                Section(isExpanded: archivedExpanded) {
                    ForEach(sections.archived) { thread in
                        threadRow(thread, activity: activities.activity[thread.id])
                            .tag(ShellSidebarItem.thread(thread.id))
                            .threadRowActions(thread, threadActions)
                    }
                } header: {
                    Text("Archived")
                }
            }

            if noThreadsMatch {
                Section {
                    Text("No threads match.")
                        .font(.aicovenBodySmall)
                        .foregroundColor(.aicovenTextSecondary)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, rowMinHeight)
        .safeAreaInset(edge: .top, spacing: 0) {
            scopeZone
                .dynamicTypeSize(Self.pinnedZoneTypeSizes)
                .background(Color.aicovenChrome)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            personZone
                .dynamicTypeSize(Self.pinnedZoneTypeSizes)
                .background(Color.aicovenChrome)
        }
        .background(Color.aicovenChrome)
        .onChange(of: noThreadsMatch) { _, shown in
            if shown { AccessibilityNotification.Announcement("No threads match.").post() }
        }
        // Another scope's threads are not this search's: the box closes.
        .onChange(of: navigator.selected) { _, _ in closeSearch() }
        // Search Threads (⌘K), also one asked for while the sidebar was
        // hidden: it is answered as the sidebar comes on screen.
        .onChange(of: navigator.searchAsked, initial: true) { _, _ in
            if navigator.takeSearchRequest() { openSearch() }
        }
    }

    // MARK: - Selection

    private var selection: Binding<ShellSidebarItem?> {
        Binding(
            get: { navigator.sidebarItem },
            set: { item in
                if let item { navigate(to: item) }
            }
        )
    }

    private func navigate(to item: ShellSidebarItem) {
        if case let .thread(threadID) = item {
            if let thread = shellThreads.threads.first(where: { $0.id == threadID }) {
                navigator.open(thread)
            }
        } else {
            navigator.openPlace(item)
        }
    }

    // MARK: - Rows

    /// The state mark, title, and date, with the caption line beneath for a
    /// thread that is moving, waiting, paused, broken, or has an unsent
    /// message.
    private func threadRow(_ thread: Thread, activity: ConversationActivity?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            ConversationActivityGlyph(activity: activity) { Color.clear }
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text(ThreadListRules.title(of: thread))
                        .font(.aicovenH3)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    ThreadRowDate(date: ThreadListRules.lastUsed(thread))
                }
                ConversationActivityCaption(activity: activity)
            }
        }
        .accessibilityElement(children: .combine)
        .threadActivityValue(activity)
    }

    /// The scope's threads could not be read, and none are shown.
    private var couldNotLoad: some View {
        HStack(spacing: Spacing.xs) {
            Text("Couldn't load threads.")
                .font(.aicovenBodySmall)
                .foregroundColor(.aicovenTextSecondary)
            Spacer(minLength: 0)
            Button("Try again") { shellThreads.reload() }
                .buttonStyle(.textLink)
                .font(.aicovenBodySmall)
        }
        .listRowSeparator(.hidden)
    }

    // MARK: - Search

    private var threadsHeader: some View {
        HStack {
            Text("Threads")
            Spacer(minLength: Spacing.xs)
            Button {
                if isSearching { closeSearch() } else { openSearch() }
            } label: {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.aicovenTextSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search threads")
            .accessibilityAddTraits(isSearching ? .isSelected : [])
            .help("Search Threads (⌘K)")
        }
    }

    /// Unfurls the box under the Threads header and focuses it.
    private func openSearch() {
        isSearching = true
        isSearchFocused = true
    }

    /// Empties the query and puts back the full list.
    private func closeSearch() {
        isSearching = false
        searchText = ""
        isSearchFocused = false
    }

    /// Archived shows open while the search finds something in it.
    private var archivedExpanded: Binding<Bool> {
        Binding(
            get: { isNarrowing || showsArchived },
            set: { if !isNarrowing { showsArchived = $0 } }
        )
    }

    private var searchBox: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.aicovenTextSecondary)
            TextField("Search threads", text: $searchText)
                .textFieldStyle(.plain)
                .font(.aicovenBody)
                .focused($isSearchFocused)
                .onAppear { isSearchFocused = true }
                .onKeyPress(.escape) {
                    closeSearch()
                    return .handled
                }
            if !searchText.isEmpty {
                Button {
                    closeSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.aicovenTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close search")
            }
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs)
        .background(Color.aicovenSurface, in: RoundedRectangle(cornerRadius: BorderRadius.sm))
        .listRowSeparator(.hidden)
    }

    // MARK: - Top: this scope

    /// The switcher, then the scope's Overview row and its places: pinned
    /// above the thread list, so only the threads scroll. The Overview row
    /// is drawn by hand, like the places under it, selected as the list
    /// draws a selected row: a list of one row kept room above its row and
    /// ran into the places.
    private var scopeZone: some View {
        VStack(spacing: 0) {
            switcherButton
            overviewRow
                .padding(.horizontal, Spacing.sm)
                .padding(.bottom, Spacing.xxs)
            tasksRow
                .padding(.horizontal, Spacing.sm)
                .padding(.bottom, Spacing.xxs)
            placesRow
                .padding(.horizontal, Spacing.sm)
                .padding(.bottom, Spacing.xs)
        }
    }

    private var overviewRow: some View {
        pinnedRow("Overview", symbol: "square.grid.2x2", item: .overview)
            .accessibilityIdentifier("sidebar-overview")
    }

    /// Tasks, a row of its own under the Overview's, as in the cloud app.
    private var tasksRow: some View {
        pinnedRow(ShellSidebarItem.tasksPlace.name, symbol: ShellSidebarItem.tasksPlace.symbol, item: .tasks)
            .accessibilityIdentifier("sidebar-tasks")
    }

    /// A row pinned above the threads, drawn by hand and selected as the
    /// list draws a selected row.
    private func pinnedRow(_ title: String, symbol: String, item: ShellSidebarItem) -> some View {
        let isSelected = navigator.sidebarItem == item
        return Button {
            navigate(to: item)
        } label: {
            Label {
                Text(title)
                    .foregroundStyle(SidebarSelection.ink(.aicovenTextPrimary, selected: isSelected, isKey: isKeyWindow))
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(SidebarSelection.ink(.accentColor, selected: isSelected, isKey: isKeyWindow))
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: pinnedRowHeight, alignment: .leading)
            .padding(.horizontal, Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: BorderRadius.sm)
                    .fill(SidebarSelection.fill(isSelected, isKey: isKeyWindow))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The scope's places as one row of icon-only buttons.
    private var placesRow: some View {
        HStack(spacing: Spacing.xxxs) {
            ForEach(ShellSidebarItem.scopePlaces, id: \.item) { place in
                let isSelected = navigator.sidebarItem == place.item
                Button {
                    onOpenPlace(place.item)
                } label: {
                    Image(systemName: place.symbol)
                        .font(.system(size: placeIconSize))
                        .foregroundStyle(SidebarSelection.ink(.accentColor, selected: isSelected, isKey: isKeyWindow))
                        .frame(maxWidth: .infinity, minHeight: placeButtonHeight)
                        .background(
                            RoundedRectangle(cornerRadius: BorderRadius.sm)
                                .fill(SidebarSelection.fill(isSelected, isKey: isKeyWindow))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(place.name)
                .accessibilityLabel(place.name)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    /// Whether the window is key, as the list draws a selection in accent then.
    private var isKeyWindow: Bool {
        #if os(macOS)
        controlActiveState == .key
        #else
        true
        #endif
    }

    // MARK: - Top: the switcher

    private var switcherButton: some View {
        let others = Self.othersCurrent(covens: covens, selected: navigator.selected, current: activities.current)
        return Button {
            showSwitcher = true
        } label: {
            HStack(spacing: Spacing.xs) {
                CovenIcon(coven: coven, size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(scopeName ?? "Loading…")
                        .font(.aicovenH2)
                        .foregroundColor(.aicovenTextPrimary)
                        .lineLimit(1)
                    ForEach(others.indices, id: \.self) { index in
                        OtherCovenCurrentLine(name: others[index].name, current: others[index].current)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.aicovenCaption)
                    .foregroundColor(.aicovenTextTertiary)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.xs)
        .padding(.bottom, Spacing.xs)
        .accessibilityLabel("Coven: \(scopeName ?? "loading")")
        .accessibilityValue(others.map { "\($0.name), \($0.current.accessibilityWords)" }.joined(separator: "; "))
        .accessibilityHint("Switch coven")
        .accessibilityIdentifier("coven-switcher")
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { switcherRowWidth = $0 }
        // Below the button and as wide as it, so it never overhangs the
        // sidebar's left edge, which is the window's.
        .popover(isPresented: $showSwitcher, arrowEdge: .bottom) {
            CovenSwitcherList(
                covens: covens,
                rowMinHeight: rowMinHeight,
                popoverWidth: max(switcherRowWidth - Spacing.xs * 2, 220),
                selected: navigator.selected,
                current: { activities.current[$0] },
                hasUnread: { activities.scopesWithUnread.contains($0) },
                personName: personName,
                onSelect: { scope in
                    showSwitcher = false
                    navigator.select(scope)
                },
                onCreateCoven: {
                    showSwitcher = false
                    onCreateCoven()
                },
                onOpenSettings: {
                    showSwitcher = false
                    onOpenSettings()
                },
                onMoveCoven: onMoveCoven
            )
            .presentationBackground(Color.aicovenSurfaceElevated)
        }
    }

    // MARK: - Bottom: the person

    /// Activity's row: drawn by hand like the Overview's, and selected as
    /// the list draws a selected row, with the waiting mark while
    /// anything waits for the person, else the dot while a reply is not
    /// yet seen.
    private var activityRow: some View {
        let isSelected = navigator.sidebarItem == .activity
        let isWaiting = ActivityGroups.isAnythingWaiting(in: activities.activity)
        let hasUnread = !activities.scopesWithUnread.isEmpty
        return Button {
            navigate(to: .activity)
        } label: {
            HStack(spacing: Spacing.xs) {
                Label {
                    Text("Activity")
                        .foregroundStyle(SidebarSelection.ink(.aicovenTextPrimary, selected: isSelected, isKey: isKeyWindow))
                } icon: {
                    Image(systemName: "bell")
                        .foregroundStyle(SidebarSelection.ink(.accentColor, selected: isSelected, isKey: isKeyWindow))
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                ActivityRowMark(isWaiting: isWaiting, hasUnread: hasUnread)
                    .environment(\.backgroundProminence, isSelected && isKeyWindow ? .increased : .standard)
            }
            .frame(maxWidth: .infinity, minHeight: pinnedRowHeight, alignment: .leading)
            .padding(.horizontal, Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: BorderRadius.sm)
                    .fill(SidebarSelection.fill(isSelected, isKey: isKeyWindow))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(ActivityRowMark.words(isWaiting: isWaiting, hasUnread: hasUnread))
        .accessibilityIdentifier("sidebar-activity")
    }

    private var personZone: some View {
        VStack(spacing: 0) {
            Divider()
            activityRow
                .padding(.horizontal, Spacing.sm)
                .padding(.top, Spacing.xxs)
            // Settings has no sidebar item, so this row opens it without
            // being selectable.
            Button {
                onOpenSettings()
            } label: {
                HStack(spacing: 0) {
                    Label {
                        Text(personName)
                    } icon: {
                        Image(systemName: "person.crop.circle")
                            .foregroundStyle(.tint)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                // The whole row takes the click, not only the text.
                .frame(maxWidth: .infinity, minHeight: pinnedRowHeight, alignment: .leading)
                .padding(.horizontal, Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Settings")
            .accessibilityIdentifier("sidebar-person")
        }
    }
}

/// How a selected place button, drawn by hand, looks: what the list draws
/// for a selected row. On the Mac it is the accent colour with white ink
/// while the window is key, and the grey unemphasized selection with the
/// usual ink otherwise. On iOS the fill is the sidebar cell's selected
/// background, read from UIKit in the current appearance.
enum SidebarSelection {
    static func fill(_ isSelected: Bool, isKey: Bool) -> Color {
        guard isSelected else { return .clear }
        #if os(macOS)
        return isKey ? .accentColor : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        #else
        return Color(uiColor: UIColor { traits in
            var state = UICellConfigurationState(traitCollection: traits)
            state.isSelected = true
            return UIBackgroundConfiguration.listSidebarCell()
                .updated(for: state)
                .resolvedBackgroundColor(for: .tintColor)
        })
        #endif
    }

    static func ink(_ ink: Color, selected isSelected: Bool, isKey: Bool) -> Color {
        #if os(macOS)
        return isSelected && isKey ? .white : ink
        #else
        return ink
        #endif
    }
}
