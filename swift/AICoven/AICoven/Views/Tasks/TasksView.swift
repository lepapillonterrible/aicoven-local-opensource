import SwiftUI

/// A place's Tasks, as the cloud app's List: the open tasks under "Open",
/// which starts with the New task line, and the finished ones under
/// "Done · N", closed until asked for. A task is ticked done, closed
/// without being done, or opened again.
struct TasksView: View {
    @ObservedObject var navigator: ShellNavigator
    @StateObject private var model: TasksModel

    @State private var newTaskTitle = ""
    @FocusState private var newTaskFocused: Bool
    /// The cursor is owed to the New task line, which takes it once it is
    /// on screen: the tasks are read and the list has scrolled to it.
    @State private var focusesNewTaskWhenShown = false
    /// Whether the New task line is built: the Mac's list builds its rows
    /// as they come on screen.
    @State private var newTaskLineShows = false
    /// Counts the times the Mac's list is asked to scroll to the New task line.
    @State private var scrollsToNewTask = 0
    /// Whether Done shows its tasks; closed until asked for.
    @State private var showsDone = false
    /// Whether Try again's reading is under way.
    @State private var isTryingAgain = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.isPadLayout) private var isPadLayout

    init(covenID: String?, navigator: ShellNavigator) {
        self.navigator = navigator
        _model = StateObject(wrappedValue: TasksModel(covenID: covenID))
    }

    /// The page's own reading column, centred.
    fileprivate static let readingWidth: CGFloat = 780
    private static let newTaskLineID = "task-new-line"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let error = model.errorMessage {
                    HStack(spacing: Spacing.sm) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.aicovenBodySmall)
                            .foregroundStyle(Color.aicovenError)
                        if !model.hasRead {
                            Button("Try again") {
                                isTryingAgain = true
                                Task {
                                    await model.load()
                                    isTryingAgain = false
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isTryingAgain)
                            if isTryingAgain {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .padding(.bottom, Spacing.sm)
                }
            }
            .padding(.horizontal, TaskListMetrics.pageMargin(isPadLayout: isPadLayout))
            .frame(maxWidth: Self.readingWidth + 2 * TaskListMetrics.pageMargin(isPadLayout: isPadLayout), alignment: .leading)
            .frame(maxWidth: .infinity)

            list
        }
        .background(Color.aicovenSurface.ignoresSafeArea())
        .task { await model.load() }
        // New Task asked for the cursor in the New task line.
        .onChange(of: navigator.newTaskAsked, initial: true) { _, _ in
            guard navigator.takeNewTaskRequest() else { return }
            focusesNewTaskWhenShown = true
            // A line that is built can still be scrolled out of view.
            scrollsToNewTask += 1
            if newTaskLineShows { focusNewTaskWhenShown() }
        }
        .onChange(of: model.hasRead) {
            if focusesNewTaskWhenShown, !newTaskLineShows { scrollsToNewTask += 1 }
        }
    }

    private var header: some View {
        // At compact width (the iPhone) the bar names the page, so the
        // title is drawn once.
        Group {
            if horizontalSizeClass != .compact {
                Text("Tasks")
                    .font(.aicovenDisplayLarge)
                    .foregroundStyle(Color.aicovenTextPrimary)
                    .padding(.top, Spacing.lg)
                    .padding(.bottom, Spacing.xs)
                    .accessibilityAddTraits(.isHeader)
            } else {
                Color.clear.frame(height: Spacing.xs)
            }
        }
    }

    // MARK: - List

    /// Both containers are as wide as the window, so the list scrolls from
    /// anywhere and its scroll bar and swipe actions are at the window's
    /// edge. The Mac's rows are in a scroll view, not a `List`: a `List`
    /// outlines the whole window-wide row for a context menu, not the row's
    /// own column.
    @ViewBuilder
    private var list: some View {
        #if os(macOS)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) { listRows }
                    .padding(.horizontal, TaskListMetrics.pageMargin(isPadLayout: isPadLayout))
                    .padding(.bottom, Spacing.lg)
            }
            .onChange(of: scrollsToNewTask) {
                proxy.scrollTo(Self.newTaskLineID)
            }
        }
        #else
        List { listRows }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // The system's row height is taller than a one-line row; each
            // row sets its own.
            .environment(\.defaultMinListRowHeight, 0)
            .refreshable { await model.load() }
        #endif
    }

    @ViewBuilder
    private var listRows: some View {
        if model.hasRead {
            if model.isEmpty {
                ContentUnavailableView("No tasks", systemImage: "checklist", description: Text("Add one with New task."))
                    .frame(maxWidth: .infinity)
                    .taskListRow()
            }
            heading("Open")
            newTaskField
                .id(Self.newTaskLineID)
                .taskListRow(vertical: 0)
            ForEach(model.open) { task in
                row(task).taskListRow(vertical: 0)
            }
            if model.finishedCount > 0 {
                doneHeading.taskListRow(vertical: 0)
                if showsDone {
                    ForEach(model.finished) { task in
                        row(task).taskListRow(vertical: 0)
                    }
                    if model.finishedCount > model.finished.count {
                        Text("The \(model.finished.count) finished last are listed.")
                            .font(.aicovenBodySmall)
                            .foregroundStyle(Color.aicovenTextSecondary)
                            .padding(.leading, TaskListMetrics.titleInset)
                            .padding(.vertical, Spacing.xs)
                            .taskListRow(vertical: 0)
                    }
                }
            }
        } else if model.errorMessage == nil {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, Spacing.xl)
                .taskListRow()
        }
    }

    /// A group's heading, a step larger than a row's title and starting
    /// where the titles start.
    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.aicovenH1)
            .foregroundStyle(Color.aicovenTextPrimary)
            .padding(.leading, TaskListMetrics.titleInset)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.xxs)
            .accessibilityAddTraits(.isHeader)
            .taskListRow(vertical: 0)
    }

    /// Done, closed to its heading and the number finished until opened.
    private var doneHeading: some View {
        Button {
            showsDone.toggle()
        } label: {
            HStack(spacing: 0) {
                Image(systemName: showsDone ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.aicovenTextSecondary)
                    .frame(width: TaskListMetrics.titleInset, alignment: .leading)
                    .accessibilityHidden(true)
                Text("Done · \(model.finishedCount)")
                    .font(.aicovenH1)
                    .foregroundStyle(Color.aicovenTextPrimary)
                Spacer(minLength: 0)
            }
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Done, \(model.finishedCount)")
        .accessibilityValue(showsDone ? "Shown" : "Hidden")
        .accessibilityHint("Shows or hides the finished tasks")
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ task: TaskItem) -> some View {
        TaskRow(
            task: task,
            isSaving: model.saving.contains(task.id),
            onTick: { done in
                let account = UserScope.currentUserID
                Task { await model.setDone(task, done, as: account) }
            },
            onClose: {
                let account = UserScope.currentUserID
                Task { await model.close(task, as: account) }
            }
        )
    }

    private var newTaskField: some View {
        HStack(spacing: 0) {
            Image(systemName: "plus")
                .foregroundStyle(Color.aicovenTextSecondary)
                .frame(width: TaskListMetrics.titleInset, alignment: .leading)
                .accessibilityHidden(true)
            TextField("New task", text: $newTaskTitle)
                .textFieldStyle(.plain)
                .font(.aicovenBody)
                .foregroundStyle(Color.aicovenTextPrimary)
                .focused($newTaskFocused)
                .onSubmit(addTask)
        }
        .frame(minHeight: TaskListMetrics.rowMinHeight)
        .onAppear {
            newTaskLineShows = true
            focusNewTaskWhenShown()
        }
        .onDisappear { newTaskLineShows = false }
    }

    /// Gives the New task line the cursor it is owed, unless the person
    /// has gone on to something else while the line was not yet there.
    private func focusNewTaskWhenShown() {
        guard focusesNewTaskWhenShown else { return }
        focusesNewTaskWhenShown = false
        guard navigator.newTaskAskStands else { return }
        newTaskFocused = true
    }

    /// Adds what the line holds, and empties it unless something else was
    /// typed meanwhile. The cursor stays in the line, for the next task:
    /// the line is not turned off while one is added (the model adds one
    /// at a time), since a field turned off gives the cursor up.
    private func addTask() {
        let title = newTaskTitle
        let account = UserScope.currentUserID
        newTaskFocused = true
        Task {
            guard await model.add(title: title, as: account) else { return }
            if newTaskTitle == title { newTaskTitle = "" }
        }
    }
}

/// The sizes the Tasks list is drawn by, as the cloud app's.
private enum TaskListMetrics {
    /// Where a row's title starts: the tick's column, which the group
    /// headings start at too.
    static var titleInset: CGFloat {
        #if os(macOS)
        return 30
        #else
        return 40
        #endif
    }

    /// A row with a title alone: 44 pt to touch, 28 pt on the Mac.
    static var rowMinHeight: CGFloat {
        #if os(macOS)
        return 28
        #else
        return 44
        #endif
    }

    /// The side margin of the page and of every row in it.
    static func pageMargin(isPadLayout: Bool) -> CGFloat {
        #if os(macOS)
        return Spacing.lg
        #else
        return isPadLayout ? Spacing.lg : Spacing.md
        #endif
    }
}

private struct TaskListRow: ViewModifier {
    let vertical: CGFloat
    @Environment(\.isPadLayout) private var isPadLayout

    /// The row is the reading column, centred; its own content, and so its
    /// context menu, is no wider.
    func body(content: Content) -> some View {
        let row = content
            .frame(maxWidth: TasksView.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        #if os(macOS)
        // In a scroll view, not a List: the margin is the stack's.
        row.padding(.vertical, vertical)
        #else
        let margin = TaskListMetrics.pageMargin(isPadLayout: isPadLayout)
        row
            .listRowInsets(EdgeInsets(top: vertical, leading: margin, bottom: vertical, trailing: margin))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        #endif
    }
}

private extension View {
    func taskListRow(vertical: CGFloat = Spacing.xs) -> some View {
        modifier(TaskListRow(vertical: vertical))
    }
}

/// One task in the List: its tick and its title. What else can be done
/// with it is in its menu and its swipes.
private struct TaskRow: View {
    let task: TaskItem
    let isSaving: Bool
    /// Ticks an open task done (true), or opens a finished one again.
    let onTick: (Bool) -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            tick
                .frame(width: TaskListMetrics.titleInset, alignment: .leading)
            Text(task.isUnreadable ? TasksModel.unreadable : task.title)
                .font(.aicovenBody)
                .foregroundStyle(task.isFinished || task.isUnreadable ? Color.aicovenTextSecondary : Color.aicovenTextPrimary)
                .strikethrough(task.status == .done)
                .multilineTextAlignment(.leading)
                // Room around a title that runs to a second line; one
                // line is no taller for it than the row already is.
                .padding(.vertical, 3)
            Spacer(minLength: Spacing.xs)
        }
        .frame(minHeight: TaskListMetrics.rowMinHeight)
        .background(
            RoundedRectangle(cornerRadius: BorderRadius.sm, style: .continuous)
                .fill(isHovering ? Color.aicovenChrome : .clear)
                .padding(.horizontal, -Spacing.xs)
        )
        .onHover { isHovering = $0 }
        .contentShape(Rectangle())
        .disabled(isSaving)
        .contextMenu {
            if task.isFinished {
                Button("Reopen") { onTick(false) }
            } else {
                Button("Close", action: onClose)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !task.isFinished {
                Button("Mark done") { onTick(true) }
                    .tint(.aicovenWater)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if task.isFinished {
                Button("Reopen") { onTick(false) }
                    .tint(.aicovenSwipeNeutral)
            } else {
                Button("Close", action: onClose)
                    .tint(.aicovenSwipeNeutral)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Ticks an open task done; opens a done or closed one again.
    private var tick: some View {
        Button {
            onTick(!task.isFinished)
        } label: {
            Image(systemName: tickSymbol)
                .font(.title3)
                .foregroundStyle(task.isFinished ? Color.aicovenTextSecondary : Color.aicovenTextTertiary)
                .frame(width: TaskListMetrics.titleInset, height: TaskListMetrics.rowMinHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(task.isFinished ? "Reopen" : "Mark done")
        .accessibilityValue(TasksModel.name(of: task))
    }

    private var tickSymbol: String {
        switch task.status {
        case .done: "checkmark.circle.fill"
        case .closed: "xmark.circle"
        case .open: "circle"
        }
    }
}
