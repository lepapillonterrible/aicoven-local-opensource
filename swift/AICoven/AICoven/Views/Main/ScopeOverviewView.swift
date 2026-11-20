import SwiftUI

/// A scope's Overview, as the cloud app's: when the person was last here,
/// then the threads still open, the replies that came while they were
/// away, and the earlier threads, each only when it has something to show
/// (in two columns when there were replies), with the composer at the
/// foot; asking from it starts a thread and opens it, if the person is
/// still here when it is made.
///
/// What it knows is this device's: what moves or waits comes from the
/// turns this app is running, unsent messages and read marks from this
/// device, and the time of the last visit from this device.
struct ScopeOverviewView: View {
    @ObservedObject var navigator: ShellNavigator
    @ObservedObject var shellThreads: ShellThreads
    @ObservedObject var threadActions: ThreadActions
    /// What the scope's new-thread page holds unsent: the composer here
    /// holds the same.
    @ObservedObject var submission: DraftThreadSubmission
    /// The coven on screen; nil for Strix.
    let coven: Coven?
    let onOpenProviderKeys: () -> Void
    /// Told of a thread asked for from here once it is made. It opens,
    /// through the navigator, only if the person is still here.
    let onThreadAsked: (Thread) -> Void

    /// What is typed in the search field over the list, on a phone.
    var searchText = ""
    /// That search field is in use: the threads get the page, and the
    /// composer gives way to them.
    var isSearchFieldActive = false
    /// Opens one of the scope's places from the row of place buttons a
    /// phone's Overview shows (elsewhere the sidebar has them); nil shows
    /// no such row.
    var onOpenPlace: ((ShellSidebarItem) -> Void)?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// The archived threads are shown, on a phone, where they are listed
    /// here.
    @State private var showsArchived = false
    /// What each thread is doing, for its row and which section it is in.
    @ObservedObject private var activities = ThreadActivities.shared
    /// The latest ask from here: the thread it starts opens only if the
    /// person is still here and has asked nothing since.
    @State private var ask: UUID?

    var body: some View {
        let scope = navigator.selected
        // What the loader says is of the scope it read, which for a moment
        // after switching is not yet the one on screen.
        let isRead = shellThreads.scope == scope
        let listed = isRead ? shellThreads.threads : []
        let canAsk = Self.canAsk(in: scope, coven: coven)
        let lists = ThreadListRules.overview(listed) { activities.activity[$0.id]?.isStillOpen == true }
        let away = ThreadListRules.away(listed, unreadReplyAt: activities.unreadReplyAt, since: navigator.previousVisit(in: scope))
        let nothingListed = listed.contains { !$0.isArchived } == false
        let state = (failed: isRead && shellThreads.failed, hasLoaded: isRead && shellThreads.hasLoaded)
        let emptyLine = Self.emptyLine(hasArchived: !listed.isEmpty, canAsk: canAsk)
        Group {
            if usesList {
                compactList(
                    scope: scope, listed: listed, away: away, nothingListed: nothingListed, state: state, emptyLine: emptyLine
                )
            } else {
                regularScroll(scope: scope, lists: lists, away: away, nothingListed: nothingListed, state: state, emptyLine: emptyLine)
            }
        }
        #if os(iOS)
        // On a phone, scrolling puts the keyboard away.
        .scrollDismissesKeyboard(usesList ? .interactively : .automatic)
        #endif
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // No asking in a coven that is not in yet: there is no saying
            // whose agents it would go to, and it must not go to Strix.
            if canAsk {
                composer
                    // While the search field is in use the composer gives
                    // its place to what is found. It stays in the tree,
                    // collapsed, so the agent chosen in it survives.
                    .frame(height: isSearchFieldActive ? 0 : nil)
                    .clipped()
                    .opacity(isSearchFieldActive ? 0 : 1)
                    .allowsHitTesting(!isSearchFieldActive)
                    .accessibilityHidden(isSearchFieldActive)
            }
        }
        .background(Color.aicovenSurface)
        // Said when it comes, and on coming to an Overview that already
        // shows it, as well as shown.
        .onChange(of: shellThreads.failed, initial: true) { _, failed in
            if failed, shellThreads.scope == navigator.selected {
                AccessibilityNotification.Announcement("Couldn't load threads.").post()
            }
        }
    }

    /// A phone's Overview is a list, so its thread rows can be swiped;
    /// wider, and on the Mac, it is a scrolling page (the sidebar's rows
    /// are swiped there).
    private var usesList: Bool {
        #if os(iOS)
        horizontalSizeClass != .regular
        #else
        false
        #endif
    }

    private func regularScroll(
        scope: ShellScope, lists: (stillOpen: [Thread], earlier: [Thread]), away: [(thread: Thread, repliedAt: Date)],
        nothingListed: Bool, state: (failed: Bool, hasLoaded: Bool), emptyLine: String
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                // Strix says how to get an answer where none can be had yet.
                if scope == .strix {
                    AddProviderKeysCard(onOpenProviderKeys: onOpenProviderKeys)
                }
                if let lastVisit = navigator.previousVisit(in: scope) {
                    Text(VisitWords.lastHere(lastVisit))
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextSecondary)
                }
                if away.isEmpty {
                    // Nothing for a second column: one column, no blank half.
                    stillOpen(lists.stillOpen)
                    earlier(lists.earlier, nothingListed: nothingListed, state: state, emptyLine: emptyLine)
                } else {
                    HStack(alignment: .top, spacing: Spacing.xxl) {
                        VStack(alignment: .leading, spacing: Spacing.lg) {
                            stillOpen(lists.stillOpen)
                            earlier(lists.earlier, nothingListed: nothingListed, state: state, emptyLine: emptyLine)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        awaySection(away)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Spacing.xxl)
            .padding(.vertical, Spacing.lg)
        }
    }

    // MARK: - A phone's list

    /// The phone's layout. Each block that is no list of threads is one
    /// plain row; thread rows are rows of their own, with their swipe.
    private func compactList(
        scope: ShellScope, listed: [Thread], away: [(thread: Thread, repliedAt: Date)],
        nothingListed: Bool, state: (failed: Bool, hasLoaded: Bool), emptyLine: String
    ) -> some View {
        let found = ThreadListRules.compactOverview(listed, query: searchText) { activities.activity[$0.id]?.isStillOpen == true }
        let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // While the search field is in use the threads get the page: the
        // first one starts under the field.
        let searchHasThePage = isSearchFieldActive || isSearching
        return List {
            if !searchHasThePage {
                if let lastVisit = navigator.previousVisit(in: scope) {
                    blockRow {
                        Text(VisitWords.lastHere(lastVisit))
                            .font(.aicovenBody)
                            .foregroundColor(.aicovenTextSecondary)
                    }
                }
                if let onOpenPlace {
                    blockRow { placesRow(onOpenPlace) }
                }
                // Strix says how to get an answer where none can be had
                // yet. No row at all where the card has nothing to say.
                if scope == .strix {
                    AddProviderKeysCard(onOpenProviderKeys: onOpenProviderKeys)
                        .listRowInsets(EdgeInsets(top: 0, leading: Spacing.md, bottom: Spacing.lg, trailing: Spacing.md))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            if !found.stillOpen.isEmpty {
                headerRow("Still open")
                threadRows(found.stillOpen, isLast: true)
            }
            // Only of threads that were read: a search says nothing of
            // threads that could not be, or are still on their way.
            if found.noMatch, state.hasLoaded, !state.failed {
                blockRow {
                    Text("No threads match.")
                        .font(.aicovenBodySmall)
                        .foregroundColor(.aicovenTextSecondary)
                }
            }
            if !searchHasThePage, !away.isEmpty {
                blockRow { awaySection(away) }
            }
            if nothingListed, state.failed || !state.hasLoaded || !isSearching {
                blockRow { earlier([], nothingListed: true, state: state, emptyLine: emptyLine) }
            } else if !found.earlier.isEmpty {
                headerRow("Earlier")
                threadRows(found.earlier, isLast: true)
            }
            if !found.archived.isEmpty {
                archivedHeaderRow(isOpen: showsArchived || isSearching)
                // A search that finds something there shows it.
                if showsArchived || isSearching {
                    threadRows(found.archived, isLast: false)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .contentMargins(.top, Spacing.lg, for: .scrollContent)
        .contentMargins(.bottom, Spacing.sm, for: .scrollContent)
    }

    private func blockRow(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: 0, leading: Spacing.md, bottom: Spacing.lg, trailing: Spacing.md))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private func headerRow(_ title: String) -> some View {
        Text(title)
            .font(.aicovenBodySmall.weight(.semibold))
            .foregroundColor(.aicovenTextSecondary)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: 0, leading: Spacing.md, bottom: Spacing.xxs * 2, trailing: Spacing.md))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// Archived stays closed until the person opens it, or searches.
    private func archivedHeaderRow(isOpen: Bool) -> some View {
        Button {
            showsArchived.toggle()
        } label: {
            HStack(spacing: Spacing.xxs) {
                Text("Archived")
                    .font(.aicovenBodySmall.weight(.semibold))
                    .foregroundColor(.aicovenTextSecondary)
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.aicovenCaption)
                    .foregroundColor(.aicovenTextSecondary)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        .listRowInsets(EdgeInsets(top: 0, leading: Spacing.md, bottom: 0, trailing: Spacing.md))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// One row for each thread; the last of a section that is followed by
    /// another has that section's space beneath it.
    private func threadRows(_ threads: [Thread], isLast: Bool) -> some View {
        ForEach(threads) { thread in
            row(thread)
                .listRowInsets(EdgeInsets(
                    top: 0, leading: Spacing.md, bottom: isLast && thread.id == threads.last?.id ? Spacing.lg : Spacing.xxs,
                    trailing: Spacing.md
                ))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }

    /// The scope's places as one row of icon buttons of equal width, as in
    /// the sidebar: Memory, Agents, Connections.
    private func placesRow(_ open: @escaping (ShellSidebarItem) -> Void) -> some View {
        let places: [(item: ShellSidebarItem, name: String, symbol: String)] = [
            (.memory, "Memory", "books.vertical"),
            (.agents, "Agents", "person.crop.circle"),
            (.connectedApps, "Connections", "puzzlepiece.extension"),
        ]
        return HStack(spacing: Spacing.xxxs) {
            ForEach(places, id: \.item) { place in
                Button {
                    open(place.item)
                } label: {
                    Image(systemName: place.symbol)
                        .font(.system(size: 20))
                        .foregroundColor(.aicovenTextSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: BorderRadius.sm).fill(Color.aicovenSurfaceElevated))
                        .overlay(RoundedRectangle(cornerRadius: BorderRadius.sm).strokeBorder(Color.aicovenBorder, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(place.name)
            }
        }
    }

    /// Whether a thread can be asked for here: on Strix, and in a coven
    /// that is in.
    static func canAsk(in scope: ShellScope, coven: Coven?) -> Bool {
        scope == .strix || coven != nil
    }

    /// What is said where no thread is listed: there are none, or none
    /// that is not archived; and to ask below only where that can be done.
    static func emptyLine(hasArchived: Bool, canAsk: Bool) -> String {
        let none = hasArchived ? "No open threads." : "No threads yet."
        return canAsk ? none + " Ask below to start one." : none
    }

    /// Reads the threads again, and says so if they still cannot be read
    /// (nothing on screen changes then).
    private func tryAgain() {
        let scope = navigator.selected
        guard let reading = shellThreads.reload() else { return }
        Task {
            await reading.value
            // Only while this Overview is still what is on screen.
            let isStillHere = navigator.selected == scope && navigator.place == nil && navigator.personPlace == nil
            if shellThreads.failed, shellThreads.scope == scope, isStillHere {
                AccessibilityNotification.Announcement("Couldn't load threads.").post()
            }
        }
    }

    private var composer: some View {
        NewThreadComposer(
            coven: coven,
            askedAgentID: nil,
            submission: submission,
            autoFocus: false,
            onSend: { ask = navigator.askFromOverview() },
            onThreadCreated: { thread in
                onThreadAsked(thread)
                if let ask { navigator.openThreadAskedFromOverview(thread, ask: ask) }
            }
        )
        .frame(maxWidth: 800)
        .frame(maxWidth: .infinity)
        .padding(Spacing.md)
        .background(Color.aicovenSurface)
    }

    @ViewBuilder
    private func stillOpen(_ threads: [Thread]) -> some View {
        if !threads.isEmpty {
            section("Still open") {
                ForEach(threads) { thread in row(thread) }
            }
        }
    }

    /// The replies that came since the person was last here, the latest
    /// first: each opens its thread.
    private func awaySection(_ away: [(thread: Thread, repliedAt: Date)]) -> some View {
        section("While you were away") {
            ForEach(away, id: \.thread.id) { reply in
                OverviewRow(
                    activity: .unread,
                    title: ThreadListRules.title(of: reply.thread),
                    date: reply.repliedAt,
                    detail: ThreadListRules.replyDetail(agentName: reply.thread.agentName)
                ) {
                    navigator.open(reply.thread)
                }
            }
        }
    }

    /// The earlier threads; or, with no threads at all, why: they could
    /// not be read, they are on their way, or there are none yet.
    @ViewBuilder
    private func earlier(
        _ earlier: [Thread], nothingListed: Bool, state: (failed: Bool, hasLoaded: Bool), emptyLine: String
    ) -> some View {
        if nothingListed, state.failed {
            section("Earlier") {
                HStack(spacing: Spacing.sm) {
                    Text("Couldn't load threads.")
                        .font(.aicovenBodySmall)
                        .foregroundStyle(Color.aicovenError)
                    Button("Try again") { tryAgain() }
                        .buttonStyle(.bordered)
                }
            }
        } else if nothingListed, !state.hasLoaded {
            section("Earlier") {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading threads")
            }
        } else if nothingListed {
            Text(emptyLine)
                .font(.aicovenBodySmall)
                .foregroundColor(.aicovenTextSecondary)
        } else if !earlier.isEmpty {
            section("Earlier") {
                ForEach(earlier) { thread in row(thread) }
            }
        }
    }

    private func row(_ thread: Thread) -> some View {
        OverviewRow(
            activity: activities.activity[thread.id],
            title: ThreadListRules.title(of: thread),
            date: ThreadListRules.lastUsed(thread)
        ) {
            navigator.open(thread)
        }
        .threadRowActions(thread, threadActions)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title)
                .font(.aicovenBodySmall.weight(.semibold))
                .foregroundColor(.aicovenTextSecondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, Spacing.xxs)
            content()
        }
    }
}

/// A row on the Overview: the state mark, the title, a trailing date, and
/// a line beneath in the turn's own words for a thread still open.
private struct OverviewRow: View {
    let activity: ConversationActivity?
    let title: String
    let date: Date
    /// A line under the title, above what the thread is doing if that has
    /// words: who replied, on a reply's row (an unread reply has none).
    var detail: String?
    let action: () -> Void

    /// 44 pt targets on touch; Mac rows are 28 pt at least.
    private var minHeight: CGFloat {
        #if os(iOS)
        44
        #else
        28
        #endif
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                ConversationActivityGlyph(activity: activity) { Color.clear }
                    .frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title)
                            .font(.aicovenBodyMedium)
                            .foregroundColor(.aicovenTextPrimary)
                            .lineLimit(1)
                        Spacer(minLength: Spacing.xs)
                        ThreadRowDate(date: date)
                    }
                    if let detail {
                        Text(detail)
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)
                            .lineLimit(1)
                    }
                    ConversationActivityCaption(activity: activity)
                }
            }
            .padding(.vertical, Spacing.xxs)
            .frame(minHeight: minHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .threadActivityValue(activity)
    }
}
