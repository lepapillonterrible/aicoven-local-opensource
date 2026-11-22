import SwiftUI

/// Activity, as the cloud app's: the one place across Strix and every
/// coven, grouped by what each thing needs: Waiting for you, Moving,
/// Finished, with no counts and no clock. On the Mac and the iPad, Waiting
/// for you fills the left column and Moving and Finished the right; at
/// compact width, and in an iPad pane too narrow for both, they stack.
struct ActivityView: View {
    @ObservedObject var navigator: ShellNavigator
    /// The person's covens, which name each row's place.
    let covens: [Coven]

    @StateObject private var model = ActivityModel()
    @ObservedObject private var activities = ThreadActivities.shared
    @ObservedObject private var engine = TurnEngine.shared
    @ObservedObject private var approvals = ToolApprovals.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.isPadLayout) private var isPadLayout
    @State private var isOnScreen = false

    static let loadFailure = "Couldn't load Activity."

    /// The approval the spot on this page is asking now.
    private var asking: ToolApproval? {
        approvals.showing.flatMap { $0.phase == .asking ? $0.approval : nil }
    }

    /// The groups, once the threads are read.
    private var groups: ActivityGroups? {
        model.shown.map { ActivityGroups.make(threads: $0, activity: activities.activity, unreadReplyAt: activities.unreadReplyAt) }
    }

    var body: some View {
        ScrollView {
            Group {
                if let groups {
                    if horizontalSizeClass == .compact {
                        stacked(groups)
                    } else if isPadLayout {
                        // Side by side only while Waiting for you keeps at
                        // least 360 pt beside the 400 pt column; a narrower
                        // pane stacks the groups.
                        ViewThatFits(in: .horizontal) {
                            columns(groups, waitingMinWidth: 360)
                            stacked(groups)
                        }
                    } else {
                        columns(groups, waitingMinWidth: nil)
                    }
                } else if model.loadFailed {
                    loadFailedLine
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, Spacing.xl)
                }
            }
            .padding(Spacing.lg)
        }
        .background(Color.aicovenSurface.ignoresSafeArea())
        .task { await model.load() }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        // A thread made, renamed, archived or deleted, or a message
        // stored: the threads are read again.
        .onReceive(NotificationCenter.default.publisher(for: ThreadService.threadUsed)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: ThreadService.threadChanged)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .didCreateThread)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .didDeleteThread)) { _ in reload() }
        // Said to VoiceOver while the page is on screen: what newly waits
        // for the person, and each reply that newly finished.
        .onChange(of: groups) { old, new in
            // Not the approval the spot is asking: the spot says it itself.
            guard isOnScreen, let old, let new,
                  let words = ActivityGroups.announcement(from: old, to: new, asking: asking) else { return }
            AccessibilityNotification.Announcement(words).post()
        }
        .onChange(of: model.loadFailed) { _, failed in
            if isOnScreen, failed, model.shown == nil { AccessibilityNotification.Announcement(Self.loadFailure).post() }
        }
    }

    private func reload() {
        Task { await model.load() }
    }

    private var loadFailedLine: some View {
        HStack(spacing: Spacing.sm) {
            Text(Self.loadFailure)
                .font(.aicovenBodySmall)
                .foregroundStyle(Color.aicovenError)
            Button("Try again", action: reload)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("activity-try-again")
        }
    }

    // MARK: - Groups

    private func columns(_ groups: ActivityGroups, waitingMinWidth: CGFloat?) -> some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            waitingSection(groups.waiting)
                .frame(minWidth: waitingMinWidth, idealWidth: waitingMinWidth, maxWidth: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: Spacing.lg) {
                movingSection(groups.moving)
                finishedSection(groups.finished)
            }
            .frame(width: 400, alignment: .topLeading)
        }
    }

    private func stacked(_ groups: ActivityGroups) -> some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            waitingSection(groups.waiting)
            movingSection(groups.moving)
            finishedSection(groups.finished)
        }
        // An empty section is only as wide as its words: the stack fills
        // the width whatever its sections hold.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section(_ title: String, empty: String, items: [ActivityItem], identifier: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title)
                .font(.aicovenH2)
                .foregroundStyle(Color.aicovenTextPrimary)
                .accessibilityAddTraits(.isHeader)
            if items.isEmpty {
                Text(empty)
                    .font(.aicovenBodySmall)
                    .foregroundStyle(Color.aicovenTextSecondary)
            } else {
                ForEach(items) { row($0) }
            }
        }
        .accessibilityIdentifier(identifier)
    }

    /// Waiting for you: what is being asked of the person, answered here
    /// as beside a thread (the approvals' one spot: one at a time, the
    /// rest behind it), then the threads that wait.
    private func waitingSection(_ items: [ActivityItem]) -> some View {
        let rows = ActivityGroups.waitingRows(items, asking: asking)
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Waiting for you")
                .font(.aicovenH2)
                .foregroundStyle(Color.aicovenTextPrimary)
                .accessibilityAddTraits(.isHeader)
            if approvals.showing != nil {
                ApprovalSpot(approvals: approvals)
                    .frame(maxWidth: ApprovalBlock.spansTheWidth ? .infinity : 262, alignment: .leading)
            }
            if rows.isEmpty, approvals.showing == nil {
                Text("Nothing is waiting for you.")
                    .font(.aicovenBodySmall)
                    .foregroundStyle(Color.aicovenTextSecondary)
            } else {
                ForEach(rows) { row($0) }
            }
        }
        .accessibilityIdentifier("activity-waiting")
    }

    private func movingSection(_ items: [ActivityItem]) -> some View {
        section("Moving", empty: "Nothing is moving.", items: items, identifier: "activity-moving")
    }

    private func finishedSection(_ items: [ActivityItem]) -> some View {
        section("Finished", empty: "Nothing new has finished.", items: items, identifier: "activity-finished")
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ item: ActivityItem) -> some View {
        let thread = item.thread
        switch item {
        case .approval:
            opening(thread, item) {
                card(thread, glyph: WaitingMark(), detail: ConversationActivity.needsOKWords, style: .ink)
            }
        case .problem:
            opening(thread, item) {
                card(
                    thread,
                    glyph: Image(systemName: "exclamationmark.triangle").font(.aicovenCaption).foregroundStyle(Color.aicovenError),
                    detail: ConversationActivity.brokenWords, style: .rust
                )
            }
        case .paused:
            opening(thread, item) {
                card(thread, glyph: StatusRing(isTurning: false), detail: "Paused", style: .secondary)
            }
        case let .moving(_, words):
            movingRow(thread, item, words: words)
        case let .finished(_, repliedAt):
            opening(thread, item) {
                card(
                    thread, glyph: ActivityDot(), detail: ThreadListRules.replyDetail(agentName: thread.agentName), style: .secondary,
                    trailing: repliedAt.map { VisitWords.rowDate($0) }
                )
            }
        }
    }

    /// A row that opens its thread.
    private func opening(_ thread: Thread, _ item: ActivityItem, @ViewBuilder label: () -> some View) -> some View {
        Button {
            navigator.open(thread)
        } label: {
            label().activityCardFrame()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the thread")
        .accessibilityIdentifier("activity-\(item.id)")
    }

    /// A turn under way: its words, and Stop beside them where there is
    /// room (on the iPhone, Stop is in the thread).
    private func movingRow(_ thread: Thread, _ item: ActivityItem, words: String) -> some View {
        let isStopping = engine.running[thread.id]?.isStopping ?? false
        return HStack(alignment: .top, spacing: Spacing.sm) {
            Button {
                navigator.open(thread)
            } label: {
                card(thread, glyph: StatusRing(isTurning: true), detail: words, style: .water)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the thread")
            if horizontalSizeClass != .compact, !isStopping {
                Button("Stop") { engine.stop(threadID: thread.id) }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Stop \(ThreadListRules.title(of: thread))")
                    .accessibilityIdentifier("activity-stop:\(thread.id)")
            }
        }
        .activityCardFrame()
        // The card's margins open the thread too; Stop keeps its own action.
        .onTapGesture { navigator.open(thread) }
        .accessibilityIdentifier("activity-\(item.id)")
    }

    private func card(
        _ thread: Thread, glyph: some View, detail: String, style: ActivityCard.DetailStyle, trailing: String? = nil
    ) -> some View {
        let coven = thread.covenId.flatMap { id in covens.first { $0.id == id } }
        return ActivityCard(
            glyph: AnyView(glyph),
            title: ThreadListRules.title(of: thread),
            // Strix, which is no stored coven here, for a thread in none.
            place: thread.covenId == nil ? "Strix" : coven?.name ?? "",
            coven: coven,
            detail: detail,
            detailStyle: style,
            trailing: trailing
        )
    }
}

/// A row's card: the mark, the thread's title, where it is, and one or two
/// lines of what it is doing.
private struct ActivityCard: View {
    enum DetailStyle {
        case water, ink, rust, secondary
    }

    let glyph: AnyView
    let title: String
    /// The scope's name: Strix, or the coven's.
    let place: String
    /// The coven, for its icon; nil for Strix, or where it is not known here.
    let coven: Coven?
    let detail: String
    let detailStyle: DetailStyle
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            ZStack { glyph }
                .frame(width: 12)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.aicovenH2)
                        .foregroundStyle(Color.aicovenTextPrimary)
                        .lineLimit(1)
                    Spacer(minLength: Spacing.xs)
                    if let trailing {
                        Text(trailing)
                            .font(.aicovenCaption)
                            .foregroundStyle(Color.aicovenTextTertiary)
                    }
                }
                HStack(spacing: Spacing.xs) {
                    CovenIcon(coven: coven, size: 20)
                    Text(place)
                        .font(.aicovenCaption)
                        .foregroundStyle(Color.aicovenTextSecondary)
                }
                Text(detail)
                    .font(detailStyle == .ink ? .aicovenBodySmall.weight(.semibold) : .aicovenBodySmall)
                    .foregroundStyle(detailColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var detailColor: Color {
        switch detailStyle {
        case .water: .aicovenWater
        case .ink, .secondary: .aicovenTextSecondary
        case .rust: .aicovenError
        }
    }
}

private extension View {
    /// The card's padding, surface and border.
    func activityCardFrame() -> some View {
        padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: BorderRadius.md)
                    .fill(Color.aicovenSurfaceElevated)
                    .overlay(RoundedRectangle(cornerRadius: BorderRadius.md).strokeBorder(Color.aicovenBorder, lineWidth: 1))
            )
            .contentShape(RoundedRectangle(cornerRadius: BorderRadius.md))
    }
}
