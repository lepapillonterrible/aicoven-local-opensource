import SwiftUI

/// The shell's sidebar, as the cloud app's: the scope on screen at the top
/// with its Overview row, then its threads (those archived in a section of
/// their own) with a search of their titles, and the person's row at the
/// bottom. Only the threads scroll.
struct ShellSidebar: View {
    @ObservedObject var navigator: ShellNavigator
    @ObservedObject var shellThreads: ShellThreads
    @ObservedObject var threadActions: ThreadActions
    /// The coven on screen; nil for Strix.
    let coven: Coven?
    /// The name of the scope on screen; nil while it is not known.
    let scopeName: String?
    let personName: String
    let onOpenSettings: () -> Void

    /// What each thread is doing, for its row and the list's order.
    @ObservedObject private var activities = ThreadActivities.shared
    @State private var showsArchived = false
    /// The Threads section's search box is open, and what it holds.
    @State private var isSearching = false
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    /// A pinned row's height, growing with the text size.
    @ScaledMetric(relativeTo: .body) private var pinnedRowHeight: CGFloat = 34

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
        .environment(\.defaultMinListRowHeight, 34)
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
            .help("Search Threads")
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

    /// The scope on screen, then its Overview as a row of a small list of
    /// its own: pinned above the thread list, so only the threads scroll.
    /// The list selects through the same binding as the thread list and
    /// does not scroll, so it is as tall as its row.
    private var scopeZone: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.xs) {
                CovenIcon(coven: coven, size: 22)
                Text(scopeName ?? "")
                    .font(.aicovenH2)
                    .foregroundColor(.aicovenTextPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Coven: \(scopeName ?? "")")
            List(selection: selection) {
                Label("Overview", systemImage: "square.grid.2x2")
                    .pinnedRow(height: pinnedRowHeight)
                    .tag(ShellSidebarItem.overview)
            }
            .pinnedSidebarList(rows: 1, rowHeight: pinnedRowHeight)
        }
    }

    // MARK: - Bottom: the person

    private var personZone: some View {
        VStack(spacing: 0) {
            Divider()
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

private extension View {
    /// A sidebar list that does not scroll and is exactly its rows tall: each
    /// row is `pinnedRow(height: rowHeight)`.
    func pinnedSidebarList(rows: Int, rowHeight: CGFloat) -> some View {
        listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .contentMargins(.vertical, 0, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, rowHeight)
            .frame(height: CGFloat(rows) * rowHeight)
    }

    /// A row of a pinned sidebar list: `height` tall, with no vertical inset,
    /// so the cell is exactly that tall.
    func pinnedRow(height: CGFloat) -> some View {
        frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .listRowInsets(EdgeInsets(top: 0, leading: Spacing.sm, bottom: 0, trailing: Spacing.sm))
    }
}
