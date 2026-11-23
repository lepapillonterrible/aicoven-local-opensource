import SwiftUI

/// A place's Tasks, as the cloud app's List: what is pinned for today and
/// for this week first (and before them "Still on today?", for pins whose
/// day is over), then the open tasks under "Open", which starts with the
/// New task line, and the finished ones under "Done · N", closed until
/// asked for. A task is ticked done, closed without being done, opened
/// again, pinned and unpinned; Sort orders each part.
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
    @AppStorage(TaskSort.storageKey) private var storedSort = TaskSort.standard.rawValue
    /// The time the list is drawn for: pins run out and days pass while
    /// the page is open, so it is told again as time goes.
    @State private var now = Date()
    /// Whether the due day's sheet of the task whose details are open is up.
    @State private var editingDue = false
    /// The page's width, which says whether the iPad has room for the
    /// details beside the list.
    @State private var pageWidth: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.isPadLayout) private var isPadLayout

    init(covenID: String?, navigator: ShellNavigator) {
        self.navigator = navigator
        _model = StateObject(wrappedValue: TasksModel(covenID: covenID))
    }

    /// The page's own reading column, centred.
    fileprivate static let readingWidth: CGFloat = 780
    private static let newTaskLineID = "task-new-line"

    private static let paneWidth: CGFloat = 340
    /// The narrowest the page can be and leave the list a readable row
    /// beside the pane: a landscape iPad mini with the sidebar showing has
    /// it, a portrait one does not.
    private static let splitMinimumWidth: CGFloat = 760

    /// The iPad's layout shows a task's details in a pane beside the list
    /// when the list keeps a readable width; otherwise, and on the iPhone,
    /// they are pushed. On the Mac they are a sheet.
    private var showsPane: Bool {
        #if os(macOS)
        false
        #else
        isPadLayout && horizontalSizeClass == .regular && pageWidth >= Self.splitMinimumWidth
        #endif
    }

    var body: some View {
        HStack(spacing: 0) {
            page
            if showsPane, let id = model.detailsOf {
                Divider()
                details(of: id, host: .pane)
                    .frame(width: Self.paneWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { pageWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in pageWidth = width }
            }
        )
        // The due day's sheet is of the details that were open: it does not
        // come up by itself over the next ones.
        .onChange(of: model.detailsOf) { editingDue = false }
        #if os(macOS)
            .sheet(item: Binding(get: { model.detailsOf.map(OpenTask.init) }, set: { model.detailsOf = $0?.id })) { open in
                details(of: open.id, host: .sheet)
            }
            .focusedSceneValue(\.taskSort, TaskSortActions(selected: sort, select: select))
            .focusedSceneValue(\.taskCommands, taskCommands)
        #else
            // Set only by the stack itself, as the details are popped: when the
            // pane takes them over the pushed screen goes, and the details stay.
            .navigationDestination(item: Binding(get: { showsPane ? nil : model.detailsOf }, set: { if !showsPane { model.detailsOf = $0 } })) { id in
                details(of: id, host: .page)
                    .navigationBarTitleDisplayMode(.inline)
            }
        #endif
    }

    private func details(of id: String, host: TaskDetailView.Host) -> some View {
        TaskDetailView(
            host: host, taskID: id, model: model, now: now,
            onPin: { task, period in
                let account = UserScope.currentUserID
                Task { await model.pin(task, for: period, as: account) }
            },
            onUnpin: { task in
                let account = UserScope.currentUserID
                Task { await model.unpin(task, as: account) }
            },
            onAnswer: { task, keep in answer([task], keep: keep) },
            editingDue: $editingDue,
            onClose: { model.detailsOf = nil }
        )
    }

    #if os(macOS)
    /// What the Tasks menu offers for the task whose details are open.
    private var taskCommands: TaskCommandActions? {
        guard let task = model.detailsOf.flatMap(model.task) else { return nil }
        func offered(_ task: TaskItem) -> [TaskCommand] {
            TaskCommand.offered(for: TaskRules.pinState(of: task, now: Date()), isFinished: task.isFinished)
        }
        return TaskCommandActions(offered: offered(task)) { command in
            // As the task stands when the item is chosen.
            guard let current = model.task(task.id), offered(current).contains(command) else { return }
            let account = UserScope.currentUserID
            switch command {
            case .pinToday: Task { await model.pin(current, for: .today, as: account) }
            case .pinWeek: Task { await model.pin(current, for: .week, as: account) }
            case .unpin: Task { await model.unpin(current, as: account) }
            case .keepToday: answer([current], keep: true)
            case .notToday: answer([current], keep: false)
            case .setDueDate: editingDue = true
            }
        }
    }
    #endif

    private var page: some View {
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
        .toolbar { sortItem }
        .task { await model.load() }
        .task {
            now = Date()
            while await (try? Task.sleep(for: .seconds(30))) != nil {
                now = Date()
            }
        }
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

    // MARK: - Sort

    private var sort: TaskSort {
        TaskSort.resolve(storedSort)
    }

    private func select(_ chosen: TaskSort) {
        guard chosen != sort else { return }
        storedSort = chosen.rawValue
        AccessibilityNotification.Announcement("Sorted by \(chosen.title.lowercased())").post()
    }

    private var sortPicker: some View {
        Picker("Sort", selection: Binding(get: { sort }, set: select)) {
            ForEach(TaskSort.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    /// Sort sits in the bar: a pop-up that says the order where there is
    /// room, a menu button at phone width.
    @ToolbarContentBuilder
    private var sortItem: some ToolbarContent {
        StoneToolbarItem(placement: .primaryAction) {
            if horizontalSizeClass == .compact {
                Menu {
                    Section("Sort") { sortPicker }
                } label: {
                    Label("Sort tasks", systemImage: "ellipsis.circle")
                }
                .stoneToolbarMenu()
            } else {
                Menu {
                    sortPicker
                } label: {
                    StonePopUpLabel(icon: "arrow.up.arrow.down", text: "Sort: \(sort.title)")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Sort tasks")
                .accessibilityValue(sort.title)
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
            let parts = TaskRules.parts(open: model.open, finished: model.finished, sort: sort, now: now)
            if !parts.review.isEmpty {
                reviewRows(parts.review)
            }
            if !parts.today.isEmpty {
                heading(TaskPinPeriod.today.title)
                ForEach(parts.today) { task in
                    row(task).taskListRow(vertical: 0)
                }
            }
            if !parts.week.isEmpty {
                heading(TaskPinPeriod.week.title)
                ForEach(parts.week) { task in
                    row(task).taskListRow(vertical: 0)
                }
            }
            heading("Open")
            newTaskField
                .id(Self.newTaskLineID)
                .taskListRow(vertical: 0)
            ForEach(parts.open) { task in
                row(task).taskListRow(vertical: 0)
            }
            if model.finishedCount > 0 {
                doneHeading.taskListRow(vertical: 0)
                if showsDone {
                    ForEach(parts.finished) { task in
                        row(task).taskListRow(vertical: 0)
                    }
                    if model.finishedCount > model.finished.count {
                        Text("Older finished tasks are not listed.")
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

    /// "Still on today?": the tasks pinned for a day that is over, each to
    /// be kept for today or not, or all at once. Each is in Open too.
    @ViewBuilder
    private func reviewRows(_ tasks: [TaskItem]) -> some View {
        heading("Still on today?")
        HStack(spacing: Spacing.xs) {
            Button("Keep all") { answer(tasks, keep: true) }
                .buttonStyle(.borderedProminent)
            Button("Clear") { answer(tasks, keep: false) }
                .buttonStyle(.bordered)
            Spacer(minLength: 0)
        }
        .disabled(tasks.contains { model.saving.contains($0.id) })
        .taskListRow()
        // Each of these tasks has its row in Open too: this one is told
        // apart from that one, or the list takes the two for one row.
        ForEach(tasks, id: \.reviewRowID) { task in
            TaskReviewRow(
                task: task, isSaving: model.saving.contains(task.id), onKeep: { answer([task], keep: true) }, onClear: { answer([task], keep: false) }
            )
            .taskListRow()
        }
    }

    private func answer(_ tasks: [TaskItem], keep: Bool) {
        let account = UserScope.currentUserID
        Task { await model.answerLapsedPins(of: tasks, keep: keep, as: account) }
    }

    private func row(_ task: TaskItem) -> some View {
        TaskRow(
            task: task,
            pin: TaskRules.pinState(of: task, now: now),
            context: TaskRules.context(of: task, now: now),
            isSaving: model.saving.contains(task.id),
            onTick: { done in
                let account = UserScope.currentUserID
                Task { await model.setDone(task, done, as: account) }
            },
            onClose: {
                let account = UserScope.currentUserID
                Task { await model.close(task, as: account) }
            },
            onPin: { period in
                let account = UserScope.currentUserID
                Task { await model.pin(task, for: period, as: account) }
            },
            onUnpin: {
                let account = UserScope.currentUserID
                Task { await model.unpin(task, as: account) }
            },
            onAnswer: { keep in answer([task], keep: keep) },
            onDetails: { model.detailsOf = task.id }
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

#if os(macOS)
/// The task whose details the Mac's sheet shows.
private struct OpenTask: Identifiable {
    let id: String
}
#endif

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

/// A task's pin in its menu, its swipe, its details and VoiceOver's
/// actions, by how the pin stands, as the cloud app offers it.
struct TaskPinActions: View {
    let task: TaskItem
    let pin: TaskPinState
    let onPin: (TaskPinPeriod) -> Void
    let onUnpin: () -> Void
    /// Keeps a pin that has run out for today (true), or clears it.
    let onAnswer: (Bool) -> Void

    var body: some View {
        ForEach(TaskCommand.pins(for: pin, isFinished: task.isFinished)) { command in
            Button(command.title) {
                switch command {
                case .pinToday: onPin(.today)
                case .pinWeek: onPin(.week)
                case .unpin: onUnpin()
                case .keepToday: onAnswer(true)
                case .notToday: onAnswer(false)
                case .setDueDate: break
                }
            }
        }
    }
}

/// A task pinned for a day that is over, with the two answers.
private struct TaskReviewRow: View {
    let task: TaskItem
    let isSaving: Bool
    let onKeep: () -> Void
    let onClear: () -> Void

    var body: some View {
        Panel(padding: Spacing.sm, cornerRadius: BorderRadius.md) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Spacing.sm) {
                    title
                    Spacer(minLength: Spacing.sm)
                    answers
                }
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    title
                    answers
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(isSaving)
        .contextMenu {
            Button("Keep for today", action: onKeep)
            Button("Not today", action: onClear)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Still on today: \(TasksModel.name(of: task))")
    }

    private var title: some View {
        Text(task.isUnreadable ? TasksModel.unreadable : task.title)
            .font(.aicovenH2)
            .foregroundStyle(Color.aicovenTextPrimary)
    }

    private var answers: some View {
        HStack(spacing: Spacing.xs) {
            Button("Keep for today", action: onKeep)
                .buttonStyle(.borderedProminent)
            Button("Not today", action: onClear)
                .buttonStyle(.bordered)
        }
        .fixedSize()
        #if os(macOS)
            .controlSize(.small)
        #endif
    }
}

private extension TaskItem {
    /// What tells a task's row under "Still on today?" from its row in Open.
    var reviewRowID: String {
        "review-\(id)"
    }
}

/// One task in the List: its tick, its title and one line of what helps
/// (its pin, its due day, that it was closed). What else can be done with
/// it is in its menu and its swipes.
private struct TaskRow: View {
    let task: TaskItem
    let pin: TaskPinState
    let context: [TaskRules.Context]
    let isSaving: Bool
    /// Ticks an open task done (true), or opens a finished one again.
    let onTick: (Bool) -> Void
    let onClose: () -> Void
    let onPin: (TaskPinPeriod) -> Void
    let onUnpin: () -> Void
    let onAnswer: (Bool) -> Void
    let onDetails: () -> Void
    @State private var isHovering = false

    /// The line under the title, its pieces joined by a middle dot.
    private var contextLine: Text? {
        context.map { piece -> Text in
            switch piece {
            case let .plain(words): Text(words).foregroundStyle(Color.aicovenTextSecondary)
            case let .pin(words): Text("\(Image(systemName: "pin.fill")) \(words)").foregroundStyle(Color.aicovenTextSecondary)
            case let .overdue(words): Text(words).foregroundStyle(Color.aicovenError)
            }
        }
        .reduce(nil as Text?) { joined, next in
            joined.map { $0 + Text(" · ").foregroundStyle(Color.aicovenTextSecondary) + next } ?? next
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            tick
                .frame(width: TaskListMetrics.titleInset, alignment: .leading)
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
                if let contextLine {
                    contextLine
                        .font(.aicovenBodySmall)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            // Room around a title that runs to a second line, or has the
            // line under it; one line is no taller for it than the row
            // already is.
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
        // A tap anywhere on the row that is not one of its controls opens
        // the task's details.
        .contentShape(Rectangle())
        .onTapGesture(perform: onDetails)
        .disabled(isSaving)
        .contextMenu {
            if task.isFinished {
                Button("Reopen") { onTick(false) }
            } else {
                Button("Close", action: onClose)
            }
            Divider()
            Button("Details…", action: onDetails)
            pinActions
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
                Button("Details…", action: onDetails)
                    .tint(.aicovenSwipeNeutral)
            } else {
                Menu("More…") {
                    Button("Close", action: onClose)
                    Divider()
                    Button("Details…", action: onDetails)
                    pinActions
                }
                .tint(.aicovenSwipeNeutral)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Details", onDetails)
        .accessibilityActions { pinActions }
    }

    private var pinActions: some View {
        TaskPinActions(task: task, pin: pin, onPin: onPin, onUnpin: onUnpin, onAnswer: onAnswer)
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
