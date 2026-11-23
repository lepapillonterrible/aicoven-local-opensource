import SwiftUI

/// The Board: a place's tasks in four columns, as the cloud app's. "To
/// do", "In progress" and "Review" hold the open tasks by stage, each
/// ordered as the List orders a part; "Done" holds the finished ones, and
/// is closed to its heading and count until asked for. The New task line
/// is at the top of "To do". A card is dragged to another column, or moved
/// from its menu.
struct TaskBoard<Card: View, NewTaskLine: View>: View {
    let open: [TaskItem]
    /// The finished tasks as listed: the ones last changed.
    let finished: [TaskItem]
    /// How many are finished in all, listed or not.
    let finishedCount: Int
    let sort: TaskSort
    let now: Date
    @Binding var showsDone: Bool
    /// Counts the times the New task line is asked to be brought on
    /// screen: New Task was asked for, and the Board can be scrolled away
    /// from it, down or sideways.
    let scrollsToNewTask: Int
    /// A card was dropped on a column, by its task's id. Answers whether
    /// it was a task of this Board that can go there.
    let onDrop: (_ taskID: String, TaskBoardColumn) -> Bool
    @ViewBuilder let card: (TaskItem) -> Card
    @ViewBuilder let newTaskLine: () -> NewTaskLine

    @State private var width: CGFloat = 0
    @Environment(\.isPadLayout) private var isPadLayout

    private static var gap: CGFloat {
        Spacing.sm
    }

    /// A column's width with its padding: the Mac fits the four columns to
    /// its width; the iPad's are a readable 280 pt and scroll sideways;
    /// the iPhone's fill the width with the next column showing at the edge.
    static func columnWidth(boardWidth: CGFloat, isMac: Bool, isPadLayout: Bool) -> CGFloat {
        if isMac {
            guard boardWidth > 0 else { return 240 }
            return max(220, (boardWidth - 3 * gap) / 4)
        }
        if isPadLayout { return 280 }
        return max(220, boardWidth - Spacing.xxl)
    }

    private var columnWidth: CGFloat {
        Self.columnWidth(boardWidth: width, isMac: PlatformCapabilities.current.platform == .macOS, isPadLayout: isPadLayout)
    }

    private static var newTaskLineID: String {
        "board-new-task-line"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Self.gap) {
                        ForEach(TaskBoardColumn.all) { column in
                            self.column(column)
                        }
                    }
                    // As tall as its tallest column, which the open columns
                    // then all are: a card is dropped anywhere in a short one.
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, TaskListMetrics.pageMargin(isPadLayout: isPadLayout))
                .padding(.bottom, Spacing.lg)
            }
            .onChange(of: scrollsToNewTask) {
                proxy.scrollTo(Self.newTaskLineID, anchor: .topLeading)
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { width = proxy.size.width - 2 * TaskListMetrics.pageMargin(isPadLayout: isPadLayout) }
                    .onChange(of: proxy.size.width) { _, new in width = new - 2 * TaskListMetrics.pageMargin(isPadLayout: isPadLayout) }
            }
        )
    }

    private func column(_ column: TaskBoardColumn) -> some View {
        let tasks = TaskRules.tasks(in: column, open: open, finished: finished, sort: sort, now: now)
        // Done counts every finished task, listed or not, as the List's does.
        let count = column == .done ? finishedCount : tasks.count
        let collapsed = column == .done && !showsDone
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            heading(column, count: count)
            if !collapsed {
                if column == .stage(.backlog) {
                    newTaskLine()
                        .padding(.horizontal, Spacing.xs)
                        .id(Self.newTaskLineID)
                }
                ForEach(tasks) { task in
                    card(task)
                }
                if column == .done, finishedCount > finished.count {
                    Text("Older finished tasks are not listed.")
                        .font(.aicovenBodySmall)
                        .foregroundStyle(Color.aicovenTextSecondary)
                        .padding(.horizontal, Spacing.xs)
                }
                Spacer(minLength: Spacing.md)
            }
        }
        // `columnWidth` is the column with its padding.
        .frame(width: columnWidth - 2 * TaskCardMetrics.inset, alignment: .topLeading)
        .frame(maxHeight: collapsed ? nil : .infinity, alignment: .top)
        .padding(TaskCardMetrics.inset)
        .background(
            // The cards sit in from the column's corner by their inset, so
            // each card's corner is concentric with it.
            RoundedRectangle(cornerRadius: TaskCardMetrics.radius + TaskCardMetrics.inset, style: .continuous)
                .fill(Color.aicovenChrome)
        )
        .dropDestination(for: String.self) { taskIDs, _ in
            guard let taskID = taskIDs.first else { return false }
            return onDrop(taskID, column)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(column.title), \(count) \(count == 1 ? "task" : "tasks")")
        .accessibilityIdentifier("board-column:\(column.id)")
    }

    /// A column's name; Done's is a button that shows or hides its cards,
    /// with the number finished.
    @ViewBuilder
    private func heading(_ column: TaskBoardColumn, count: Int) -> some View {
        if column == .done {
            Button {
                showsDone.toggle()
            } label: {
                HStack(spacing: Spacing.xxs) {
                    Image(systemName: showsDone ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                    Text("Done · \(count)")
                    Spacer(minLength: 0)
                }
                .font(.aicovenH2)
                .foregroundStyle(Color.aicovenTextPrimary)
                .padding(.horizontal, Spacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done, \(count)")
            .accessibilityValue(showsDone ? "Shown" : "Hidden")
            .accessibilityHint("Shows or hides the finished tasks")
            .accessibilityAddTraits(.isHeader)
        } else {
            Text(column.title)
                .font(.aicovenH2)
                .foregroundStyle(Color.aicovenTextPrimary)
                .padding(.horizontal, Spacing.xs)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// A card's corner and the room around what is in it.
enum TaskCardMetrics {
    /// How far a card is in from its column's edge, and its ⋯ button from
    /// the card's: so their corners are concentric.
    static let inset: CGFloat = 6

    static var radius: CGFloat {
        PlatformCapabilities.current.platform == .macOS ? 10 : 12
    }

    /// The ⋯ button's side: 24 pt for a pointer, 32 pt to touch.
    static var menuSide: CGFloat {
        PlatformCapabilities.current.platform == .macOS ? 24 : 32
    }
}

/// One task on the Board: its title, which opens its details, and the
/// line the List's row has. It is dragged to another column, or moved with
/// Move to from its menu or VoiceOver's actions. The menu opens from the
/// card's ⋯ button, which the keyboard reaches, and with a secondary click
/// on the Mac or a long press on the iPhone and iPad.
struct TaskCard<Actions: View, VoiceOverActions: View>: View {
    let task: TaskItem
    let context: [TaskRules.Context]
    /// What VoiceOver reads after the title: its pin, and its column.
    let value: String
    let isSaving: Bool
    let onDetails: () -> Void
    /// The card's menu: the row's actions and Move to.
    @ViewBuilder let menu: () -> Actions
    /// VoiceOver's actions besides Details.
    @ViewBuilder let voiceOverActions: () -> VoiceOverActions
    @State private var isHoveringMenu = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button(action: onDetails) {
                Text(task.isUnreadable ? TasksModel.unreadable : task.title)
                    .font(.aicovenBody)
                    .foregroundStyle(task.isFinished || task.isUnreadable ? Color.aicovenTextSecondary : Color.aicovenTextPrimary)
                    .strikethrough(task.status == .done)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Details for \(TasksModel.name(of: task))")
            if let line = TaskContextText.joined(context) {
                line
                    .font(.aicovenBodySmall)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Spacing.xs)
        .padding(.leading, Spacing.sm)
        .padding(.trailing, TaskCardMetrics.inset * 2 + TaskCardMetrics.menuSide)
        .frame(minHeight: TaskCardMetrics.inset * 2 + TaskCardMetrics.menuSide)
        .background(
            RoundedRectangle(cornerRadius: TaskCardMetrics.radius, style: .continuous)
                .fill(Color.aicovenSurfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: TaskCardMetrics.radius, style: .continuous)
                        .strokeBorder(Color.aicovenBorder, lineWidth: 1)
                )
        )
        .overlay(alignment: .topTrailing) {
            Menu {
                menu()
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Color.aicovenTextSecondary)
                    .frame(width: TaskCardMetrics.menuSide, height: TaskCardMetrics.menuSide)
                    .background(
                        RoundedRectangle(cornerRadius: TaskCardMetrics.radius - TaskCardMetrics.inset, style: .continuous)
                            .fill(isHoveringMenu ? Color.aicovenChrome : .clear)
                    )
                    .contentShape(Rectangle().inset(by: -TaskCardMetrics.inset))
            }
            .buttonStyle(.plain)
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { isHoveringMenu = $0 }
            .padding(TaskCardMetrics.inset)
            .accessibilityLabel("Actions for \(TasksModel.name(of: task))")
        }
        // A tap anywhere on the card that is not one of its controls opens
        // the task's details, as in the List.
        .contentShape(Rectangle())
        .onTapGesture(perform: onDetails)
        .disabled(isSaving)
        .draggable(task.id)
        .contextMenu { menu() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TasksModel.name(of: task))
        .accessibilityValue(value)
        .accessibilityAction(named: "Details", onDetails)
        .accessibilityActions { voiceOverActions() }
    }
}

/// The line under a task's title, in the List's row and on the Board's
/// card: its pieces joined by a middle dot, each in its own ink.
enum TaskContextText {
    static func joined(_ context: [TaskRules.Context]) -> Text? {
        context.map { piece -> Text in
            switch piece {
            case let .plain(words): Text(words).foregroundStyle(Color.aicovenTextSecondary)
            case let .pin(words): Text("\(Image(systemName: "pin.fill")) \(words)").foregroundStyle(Color.aicovenTextSecondary)
            case let .overdue(words): Text(words).foregroundStyle(Color.aicovenError)
            case let .agent(words): Text(words).foregroundStyle(Color.aicovenWater)
            }
        }
        .reduce(nil as Text?) { joined, next in
            joined.map { $0 + Text(" · ").foregroundStyle(Color.aicovenTextSecondary) + next } ?? next
        }
    }
}

/// A task's menu, the same on a List row and a Board card, as the cloud
/// app's: what can be done with it by where it stands, then its details
/// and its pin. The Board adds Move to for its other columns.
struct TaskMenu: View {
    let task: TaskItem
    let pin: TaskPinState
    /// Where it stands with the agent it was handed to, if it was.
    let handoff: TaskHandoffState?
    /// A swipe's More… leaves Do it for me… out: it has its own button.
    var showsDoItForMe = true
    var moveTargets: [TaskBoardColumn] = []
    var onMove: (TaskBoardColumn) -> Void = { _ in }
    /// Ticks an open task done (true), or opens a finished one again.
    let onTick: (Bool) -> Void
    let onClose: () -> Void
    let onPin: (TaskPinPeriod) -> Void
    let onUnpin: () -> Void
    let onAnswer: (Bool) -> Void
    let onDetails: () -> Void
    let onTalk: () -> Void
    let lead: TaskLead

    var body: some View {
        if task.isFinished {
            Button("Reopen") { onTick(false) }
        } else if handoff == .finished {
            Button("Mark done") { onTick(true) }
            Button("Open thread", action: onTalk)
        } else if handoff == nil {
            // A task whose title cannot be read has nothing to tell an agent.
            if showsDoItForMe, TaskRules.canBeHandedOver(task) {
                Menu("Do it for me…") { LeadAgentChoices(lead: lead, onChoose: lead.onDoIt) }
            }
            if TaskRules.canBeTalkedThrough(task) { Button("Talk it through", action: onTalk) }
            Button("Close", action: onClose)
        } else {
            Button("Open thread", action: onTalk)
        }
        if !task.isFinished, lead.hasLead {
            Menu("Change Lead Agent…") { LeadAgentChoices(lead: lead, onChoose: lead.onChange) }
        }
        Divider()
        Button("Details…", action: onDetails)
        TaskPinActions(task: task, pin: pin, onPin: onPin, onUnpin: onUnpin, onAnswer: onAnswer)
        ForEach(moveTargets) { column in
            Button("Move to \(column.title)") { onMove(column) }
        }
    }
}
