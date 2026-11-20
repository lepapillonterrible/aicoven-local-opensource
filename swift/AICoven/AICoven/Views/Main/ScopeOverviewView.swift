import SwiftUI

/// A scope's Overview, as the cloud app's: when the person was last here,
/// then the threads still open and the earlier ones, each only when it has
/// something to show, with the composer at the foot; asking from it starts
/// a thread and opens it, if the person is still here when it is made.
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
                if !lists.stillOpen.isEmpty {
                    section("Still open") {
                        ForEach(lists.stillOpen) { thread in row(thread) }
                    }
                }
                earlier(
                    lists.earlier,
                    nothingListed: listed.contains { !$0.isArchived } == false,
                    state: (failed: isRead && shellThreads.failed, hasLoaded: isRead && shellThreads.hasLoaded),
                    emptyLine: Self.emptyLine(hasArchived: !listed.isEmpty, canAsk: canAsk)
                )
            }
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Spacing.xxl)
            .padding(.vertical, Spacing.lg)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // No asking in a coven that is not in yet: there is no saying
            // whose agents it would go to, and it must not go to Strix.
            if canAsk {
                composer
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
            if shellThreads.failed, shellThreads.scope == scope, navigator.selected == scope {
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
