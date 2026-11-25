internal import Combine
import SwiftUI

/// A place's Tasks, or On me (every place's tasks, each row naming its
/// place, with no New task line). A place's tasks have two views, the List
/// and the Board (`TaskBoard`); On me has the List. The List, as the cloud
/// app's: what is pinned for today and
/// for this week first (and before them "Still on today?", for pins whose
/// day is over), then the open tasks under "Open", which starts with the
/// New task line, and the finished ones under "Done · N", closed until
/// asked for. A task is ticked done, closed without being done, opened
/// again, pinned and unpinned; Sort orders each part.
struct TasksView: View {
    @ObservedObject var navigator: ShellNavigator
    @StateObject private var model: TasksModel
    /// The person's covens, which name each task's place in On me, and
    /// whether they are read yet.
    private let covens: [Coven]
    private let covensAreKnown: Bool

    @State private var newTaskTitle = ""
    @FocusState private var newTaskFocused: Bool
    /// The cursor is owed to the New task line, which takes it once it is
    /// on screen: the tasks are read and the list has scrolled to it.
    @State private var focusesNewTaskWhenShown = false
    /// How many New task lines are built (the List's, the Board's): the
    /// Mac's list builds its rows as they come on screen.
    @State private var newTaskLinesUp = 0
    /// Counts the times the Mac's list is asked to scroll to the New task line.
    @State private var scrollsToNewTask = 0
    /// Which view of a place's tasks shows: the window's own choice, kept
    /// as the person goes from place to place and comes back to Tasks.
    @SceneStorage(Layout.storageKey) private var storedLayout = Layout.list.rawValue
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
    /// The thread being opened for a task, until it is: leaving the page,
    /// or asking for another, drops it.
    @State private var pendingTalk: UUID?
    /// The page's width, which says whether the iPad has room for the
    /// details beside the list.
    @State private var pageWidth: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.isPadLayout) private var isPadLayout

    /// A place's tasks (`.place`), or every place's (`.onMe`), where
    /// `covens` names each task's place once they are known.
    init(scope: TasksModel.Scope, navigator: ShellNavigator, covens: [Coven] = [], covensAreKnown: Bool = true) {
        self.navigator = navigator
        self.covens = covens
        self.covensAreKnown = covensAreKnown
        _model = StateObject(wrappedValue: TasksModel(scope: scope))
    }

    /// The two views of a place's tasks.
    enum Layout: String, CaseIterable, Identifiable {
        case list = "List"
        case board = "Board"

        /// Where a window keeps its choice.
        static let storageKey = "tasks.layout"

        /// The view a kept choice names; the List for one that names none.
        static func resolve(_ kept: String) -> Layout {
            Layout(rawValue: kept) ?? .list
        }

        var id: String {
            rawValue
        }

        var symbol: String {
            self == .list ? "list.bullet" : "rectangle.split.3x1"
        }
    }

    private var isOnMe: Bool {
        model.scope == .onMe
    }

    private var layout: Layout {
        Layout.resolve(storedLayout)
    }

    private func show(_ chosen: Layout) {
        guard chosen != layout else { return }
        storedLayout = chosen.rawValue
        AccessibilityNotification.Announcement("Showing the \(chosen.rawValue)").post()
    }

    /// Whether the New task line is built. Counted, not flagged: going
    /// from the List to the Board, the Board's line can come before the
    /// List's has gone.
    private var newTaskLineShows: Bool {
        newTaskLinesUp > 0
    }

    /// The name of the place a task is in, as On me says it on each row.
    /// Nil on a place's own page.
    private func placeName(of task: TaskItem) -> String? {
        guard isOnMe else { return nil }
        return Self.placeName(ofCoven: task.covenID, among: covens, known: covensAreKnown)
    }

    /// Strix for the person's own, a coven's name, and "Another coven"
    /// for a coven that is not among those read; nothing for a coven
    /// while the covens are not read yet (it is not another's then).
    static func placeName(ofCoven covenID: String?, among covens: [Coven], known: Bool) -> String? {
        guard let covenID else { return "Strix" }
        if let coven = covens.first(where: { $0.id == covenID }) { return coven.name }
        return known ? "Another coven" : nil
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
        // come up by itself over the next ones. And opening or closing a
        // task's details is asking for something else: a thread still
        // being opened for an earlier task stays closed.
        .onChange(of: model.detailsOf) {
            editingDue = false
            pendingTalk = nil
        }
        .onAppear { model.cameOnScreen() }
        .onDisappear {
            pendingTalk = nil
            model.leftScreen()
        }
        // The tasks handed to an agent follow the turns the app runs: told
        // once the change has been made, not as it is about to be.
        .onReceive(Self.turns.receive(on: RunLoop.main)) { _ in model.turnsChanged() }
        .onReceive(ToolApprovals.shared.$askingThreadIDs.receive(on: RunLoop.main)) { _ in model.turnsChanged() }
        #if os(macOS)
            .sheet(item: Binding(get: { model.detailsOf.map(OpenTask.init) }, set: { model.detailsOf = $0?.id })) { open in
                details(of: open.id, host: .sheet)
            }
            .focusedSceneValue(\.taskSort, TaskSortActions(selected: sort, select: select))
            .focusedSceneValue(\.taskLayout, isOnMe ? nil : TaskLayoutActions(selected: layout, select: show))
            .focusedSceneValue(\.taskCommands, taskCommands)
        #else
            // Set only by the stack itself, as the details are popped: when the
            // pane takes them over the pushed screen goes, and the details stay.
            .navigationDestination(item: Binding(get: { showsPane ? nil : model.detailsOf }, set: { if !showsPane { model.detailsOf = $0 } })) { id in
                details(of: id, host: .page)
                    .navigationBarTitleDisplayMode(.inline)
                    .stoneBackButton()
                    // A screen of the place's own: what is said of a hand-off is still said here.
                    .onAppear { model.cameOnScreen() }
                    .onDisappear { model.leftScreen() }
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
            onTalk: talkItThrough,
            lead: lead,
            placeName: placeName,
            editingDue: $editingDue,
            onClose: { model.detailsOf = nil }
        )
    }

    /// Opens the task's thread, unless the person has left the page or
    /// asked for something else meanwhile: another thread, another task's
    /// details, or anything of the shell (New Task, Search Threads), and
    /// only while the account that asked is signed in.
    private func talkItThrough(_ task: TaskItem) {
        let request = UUID()
        pendingTalk = request
        let account = UserScope.currentUserID
        let moves = navigator.personMoves
        Task {
            guard let thread = await model.talkItThrough(task, as: account), pendingTalk == request else { return }
            pendingTalk = nil
            guard Self.stillOpensThread(askedAt: moves, in: navigator, as: account, signedIn: UserScope.currentUserID) else { return }
            navigator.open(thread)
        }
    }

    /// The turns the app runs, as far as a task follows them: told when
    /// one starts, ends or is being stopped, not with each word of a reply.
    private static var turns: AnyPublisher<[String: TaskLiveTurn], Never> {
        TurnEngine.shared.$running
            .map { $0.mapValues { TaskLiveTurn(turnID: $0.turnID, isStopping: $0.isStopping) } }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    /// Whether a thread made ready for a task is still to be opened: the
    /// person has done nothing in the shell since they asked (New Task
    /// and Search Threads are moves, also where they leave Tasks open),
    /// and the account that asked is the one signed in.
    static func stillOpensThread(askedAt moves: Int, in navigator: ShellNavigator, as account: String, signedIn: String) -> Bool {
        navigator.isStill(at: moves) && signedIn == account
    }

    /// Do it for me… and Change Lead Agent… for a task.
    private func lead(for task: TaskItem) -> TaskLead {
        TaskLead(
            hasLead: task.leadAgentID != nil,
            choices: model.leadChoices(for: task),
            failedToLoad: model.agentsFailed(for: task),
            onRetry: { Task { await model.loadAgents() } },
            onDoIt: { agent in
                let account = UserScope.currentUserID
                Task { await model.doItForMe(task, agent: agent, as: account) }
            },
            onChange: { agent in
                let account = UserScope.currentUserID
                Task { await model.changeLeadAgent(task, to: agent, as: account) }
            }
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

            if isOnMe || layout == .list {
                list
            } else if model.hasRead {
                board
            } else {
                // Not read yet: as the List says it.
                if model.errorMessage == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, Spacing.xl)
                }
                Spacer(minLength: 0)
            }
        }
        .background(Color.aicovenSurface.ignoresSafeArea())
        .toolbar { barItems }
        .task { await model.load() }
        .task {
            now = Date()
            while await (try? Task.sleep(for: .seconds(30))) != nil {
                now = Date()
            }
        }
        // New Task asked for the cursor in the New task line (of a place's
        // own page: the ask is never On me's to take).
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
        // A task was made or changed in the store, by this page or by
        // something else (an agent's turn in a thread): the list is read
        // again, also while a change of the page's own is under way, whose
        // own reading may have been made before the other change. Only
        // the latest reading is shown.
        .onReceive(NotificationCenter.default.publisher(for: TaskItem.didChange).receive(on: RunLoop.main)) { _ in
            Task { await model.load() }
        }
        // A reminder of one of this place's tasks was tapped: its details open.
        .onChange(of: navigator.taskAsked, initial: true) { _, _ in
            guard case let .place(covenID) = model.scope, let id = navigator.takeTaskAsk(in: ShellScope(covenID: covenID)) else { return }
            model.detailsOf = id
        }
    }

    private var header: some View {
        // At compact width (the iPhone) the bar names the page, so the
        // title is drawn once.
        Group {
            if horizontalSizeClass != .compact {
                Text(isOnMe ? "On me" : "Tasks")
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

    /// One menu in the bar for Sort and View: at phone width, and on the
    /// iPad when the bar has no room for both controls.
    private var usesBarMenu: Bool {
        horizontalSizeClass == .compact || (isPadLayout && pageWidth < Self.splitMinimumWidth)
    }

    /// Sort and List/Board sit in the bar: a pop-up that says the order
    /// and a two-part control where there is room, one menu otherwise. On
    /// me has the List only, and so Sort alone.
    @ToolbarContentBuilder
    private var barItems: some ToolbarContent {
        if usesBarMenu {
            StoneToolbarItem(placement: .primaryAction) {
                Menu {
                    Section("Sort") { sortPicker }
                    if !isOnMe {
                        Section("View") {
                            Picker("View", selection: Binding(get: { layout }, set: show)) {
                                ForEach(Layout.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        }
                    }
                } label: {
                    Label(isOnMe ? "Sort tasks" : "Sort and view", systemImage: "ellipsis.circle")
                }
                .stoneToolbarMenu()
            }
        } else {
            StoneToolbarItem(placement: .primaryAction) {
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
            if !isOnMe {
                StoneToolbarItem(placement: .primaryAction) { layoutControl }
            }
        }
    }

    /// List or Board: two parts in one control, the one showing marked.
    private var layoutControl: some View {
        HStack(spacing: 2) {
            ForEach(Layout.allCases) { choice in
                let isSelected = choice == layout
                Button {
                    show(choice)
                } label: {
                    HStack(spacing: Spacing.xxs) {
                        Image(systemName: choice.symbol)
                            .accessibilityHidden(true)
                        Text(choice.rawValue)
                    }
                    .font(.aicovenBodySmall.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.aicovenTextPrimary : Color.aicovenTextSecondary)
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, Spacing.xxs)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? Color.aicovenChrome : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.rawValue)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.aicovenSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.aicovenBorder, lineWidth: 1)
                )
        )
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View")
    }

    // MARK: - Board

    private var board: some View {
        TaskBoard(
            open: model.open, finished: model.finished, finishedCount: model.finishedCount, sort: sort, now: now, showsDone: $showsDone,
            scrollsToNewTask: scrollsToNewTask,
            onDrop: { taskID, column in
                // Not a card of this Board, or a column it cannot go to
                // (Done, while an agent is on it, which the model says):
                // the drop is refused.
                guard let task = model.task(taskID) else { return false }
                let moves = model.canMove(task, to: column)
                move(task, to: column)
                return moves
            },
            card: card,
            newTaskLine: { newTaskField }
        )
        #if !os(macOS)
        .refreshable { await model.load() }
        #endif
    }

    private func move(_ task: TaskItem, to column: TaskBoardColumn) {
        let account = UserScope.currentUserID
        Task { await model.move(task, to: column, as: account) }
    }

    private func card(_ task: TaskItem) -> some View {
        let handoff = model.handoff(of: task)
        let pin = TaskRules.pinState(of: task, now: now)
        let column = TaskBoardColumn.of(task)
        let others = TaskRules.moveTargets(for: task, handoff: handoff)
        let actions = actions(for: task)
        return TaskCard(
            task: task,
            context: TaskRules.context(of: task, now: now, handoff: handoff, agent: model.agentName(for: task)),
            value: [pin.activePeriod?.title, column.title].compactMap(\.self).joined(separator: ", "),
            isSaving: model.saving.contains(task.id),
            onDetails: actions.onDetails,
            menu: {
                TaskMenu(
                    task: task, pin: pin, handoff: handoff, moveTargets: others, onMove: { move(task, to: $0) }, onTick: actions.onTick,
                    onClose: actions.onClose, onPin: actions.onPin, onUnpin: actions.onUnpin, onAnswer: actions.onAnswer,
                    onDetails: actions.onDetails, onTalk: actions.onTalk, lead: actions.lead
                )
            },
            voiceOverActions: {
                TaskPinActions(task: task, pin: pin, onPin: actions.onPin, onUnpin: actions.onUnpin, onAnswer: actions.onAnswer)
                ForEach(others) { column in
                    Button("Move to \(column.title)") { move(task, to: column) }
                }
                if !task.isFinished, TaskRules.canBeTalkedThrough(task) {
                    Button(handoff == nil ? "Talk it through" : "Open thread", action: actions.onTalk)
                }
            }
        )
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
                ContentUnavailableView(
                    "No tasks", systemImage: "checklist",
                    description: Text(isOnMe ? "Tasks from your threads in every coven show here." : "Add one with New task.")
                )
                .frame(maxWidth: .infinity)
                .taskListRow()
            }
            let parts = TaskRules.parts(open: model.open, finished: model.finished, sort: sort, now: now, handoff: model.handoff)
            if !parts.review.isEmpty {
                reviewRows(parts.review)
            }
            if !parts.today.isEmpty {
                heading(TaskPinPeriod.today.title)
                rows(parts.today, in: .today)
            }
            if !parts.week.isEmpty {
                heading(TaskPinPeriod.week.title)
                rows(parts.week, in: .week)
            }
            if !parts.needsYou.isEmpty {
                heading("Needs you")
                rows(parts.needsYou, in: .needsYou)
            }
            if !parts.agentsOnIt.isEmpty {
                heading("Agents are on it")
                rows(parts.agentsOnIt, in: .agentsOnIt)
            }
            // A place's own page has the New task line under Open, also
            // with no open task; On me, which adds none, has Open only
            // where there is one.
            if !isOnMe {
                heading("Open")
                newTaskField
                    .id(Self.newTaskLineID)
                    .taskListRow(vertical: 0)
            } else if !parts.open.isEmpty {
                heading("Open")
            }
            rows(parts.open, in: .open)
            if model.finishedCount > 0 {
                doneHeading.taskListRow(vertical: 0)
                if showsDone {
                    rows(parts.finished, in: .finished)
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
                task: task, place: placeName(of: task), isSaving: model.saving.contains(task.id), onKeep: { answer([task], keep: true) },
                onClear: { answer([task], keep: false) }
            )
            .taskListRow()
        }
    }

    private func answer(_ tasks: [TaskItem], keep: Bool) {
        let account = UserScope.currentUserID
        Task { await model.answerLapsedPins(of: tasks, keep: keep, as: account) }
    }

    /// What a task's row or card lets the person do with it, each as the
    /// account signed in when it is asked.
    private struct TaskActions {
        /// Ticks an open task done (true), or opens a finished one again.
        let onTick: (Bool) -> Void
        let onClose: () -> Void
        let onPin: (TaskPinPeriod) -> Void
        let onUnpin: () -> Void
        /// Keeps a pin that has run out for today (true), or clears it.
        let onAnswer: (Bool) -> Void
        let onDetails: () -> Void
        /// Opens the task's thread, which is made for it if it has none.
        let onTalk: () -> Void
        let lead: TaskLead
    }

    private func actions(for task: TaskItem) -> TaskActions {
        TaskActions(
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
            onDetails: { model.detailsOf = task.id },
            onTalk: { talkItThrough(task) },
            lead: lead(for: task)
        )
    }

    /// The rows of one part of the list. A row's id is the task's in
    /// that part: a lazy stack keeps a row by its id, and a task that
    /// moved to another part under the same id kept the row it had there,
    /// which its old part no longer drew anew (handed to an agent, it
    /// still said "Led by …" under "Agents are on it").
    private func rows(_ tasks: [TaskItem], in part: ListPart) -> some View {
        ForEach(tasks.map { PartRow(part: part, task: $0) }) { partRow in
            row(partRow.task).taskListRow(vertical: 0)
        }
    }

    private func row(_ task: TaskItem) -> some View {
        let handoff = model.handoff(of: task)
        let actions = actions(for: task)
        return TaskRow(
            task: task,
            pin: TaskRules.pinState(of: task, now: now),
            handoff: handoff,
            context: TaskRules.context(of: task, now: now, handoff: handoff, agent: model.agentName(for: task), place: placeName(of: task)),
            isSaving: model.saving.contains(task.id),
            onTick: actions.onTick,
            onClose: actions.onClose,
            onPin: actions.onPin,
            onUnpin: actions.onUnpin,
            onAnswer: actions.onAnswer,
            onDetails: actions.onDetails,
            onTalk: actions.onTalk,
            lead: actions.lead
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
            newTaskLinesUp += 1
            focusNewTaskWhenShown()
        }
        .onDisappear { newTaskLinesUp = max(0, newTaskLinesUp - 1) }
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
enum TaskListMetrics {
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

/// A task pinned for a day that is over, with the two answers. In On me
/// it names the task's place under its title, so that two tasks of one
/// title in two places are told apart.
struct TaskReviewRow: View {
    let task: TaskItem
    /// The name of the task's place, where the page is of every place's.
    let place: String?
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
        .accessibilityLabel(Self.label(for: task, place: place))
    }

    /// What VoiceOver calls the row: the task, and its place where it is named.
    static func label(for task: TaskItem, place: String?) -> String {
        "Still on today: \(TasksModel.name(of: task))" + (place.map { ", \($0)" } ?? "")
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(task.isUnreadable ? TasksModel.unreadable : task.title)
                .font(.aicovenH2)
                .foregroundStyle(Color.aicovenTextPrimary)
            if let place {
                Text(place)
                    .font(.aicovenBodySmall)
                    .foregroundStyle(Color.aicovenTextSecondary)
            }
        }
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

/// The parts of the List whose rows are tasks.
private enum ListPart: String {
    case today, week, needsYou, agentsOnIt, open, finished
}

/// A task's row in one part of the List, known by both.
private struct PartRow: Identifiable {
    let part: ListPart
    let task: TaskItem
    var id: String {
        "\(part.rawValue)-\(task.id)"
    }
}

private extension TaskItem {
    /// What tells a task's row under "Still on today?" from its row in Open.
    var reviewRowID: String {
        "review-\(id)"
    }
}

/// Do it for me… and Change Lead Agent… for one task: the agents it can
/// be handed to, and whether it has a lead agent.
struct TaskLead {
    let hasLead: Bool
    /// Nil while the place's agents are not read.
    let choices: TaskRules.LeadChoices<TasksModel.Agent>?
    let failedToLoad: Bool
    let onRetry: () -> Void
    let onDoIt: (TasksModel.Agent) -> Void
    let onChange: (TasksModel.Agent) -> Void
}

/// The agents a task can be handed to, each with where it runs: its lead
/// agent first under Lead agent, or else the agent the place's latest
/// hand-off went to under Last used. Nothing is chosen until the person
/// picks one.
struct LeadAgentChoices: View {
    let lead: TaskLead
    let onChoose: (TasksModel.Agent) -> Void

    /// What the menu says besides the agents.
    enum Note: Equatable {
        /// They could not be read: said also over those read before,
        /// which stay, with Try Again.
        case failed
        /// They are being read, and none was read before.
        case loading
    }

    static func note(hasChoices: Bool, failedToLoad: Bool) -> Note? {
        if failedToLoad { return .failed }
        return hasChoices ? nil : .loading
    }

    var body: some View {
        switch Self.note(hasChoices: lead.choices != nil, failedToLoad: lead.failedToLoad) {
        case .failed:
            Text("Couldn't load the agents")
            Button("Try Again", action: lead.onRetry)
        case .loading:
            Text("Loading agents…")
        case nil:
            EmptyView()
        }
        if let choices = lead.choices {
            if let marked = choices.marked {
                Section(choices.reason == .lead ? "Lead agent" : "Last used") { choice(marked) }
            }
            Section {
                ForEach(choices.others) { choice($0) }
            }
        }
    }

    private func choice(_ agent: TasksModel.Agent) -> some View {
        Button {
            onChoose(agent)
        } label: {
            Text(agent.name)
            if !agent.runsOn.isEmpty { Text(agent.runsOn) }
        }
    }
}

/// One task in the List: its mark (the tick, or where it stands with the
/// agent it was handed to), its title and one line of what helps (its
/// pin, its due day, the agent on it, that it was closed). What else can
/// be done with it is in its menu and its swipes.
private struct TaskRow: View {
    let task: TaskItem
    let pin: TaskPinState
    /// Where it stands with the agent it was handed to, if it was.
    let handoff: TaskHandoffState?
    let context: [TaskRules.Context]
    let isSaving: Bool
    /// Ticks an open task done (true), or opens a finished one again.
    let onTick: (Bool) -> Void
    let onClose: () -> Void
    let onPin: (TaskPinPeriod) -> Void
    let onUnpin: () -> Void
    let onAnswer: (Bool) -> Void
    let onDetails: () -> Void
    /// Opens the task's thread, which is made for it if it has none.
    let onTalk: () -> Void
    let lead: TaskLead
    @State private var isHovering = false

    /// The line under the title, its pieces joined by a middle dot.
    private var contextLine: Text? {
        TaskContextText.joined(context)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            glyph
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
            button
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
        .contextMenu { menu(showsDoItForMe: true) }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !task.isFinished, TaskRules.canBeMarkedDone(handoff) {
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
                if handoff == nil, TaskRules.canBeHandedOver(task) {
                    Menu("Do it for me…") { LeadAgentChoices(lead: lead, onChoose: lead.onDoIt) }
                        .tint(.aicovenWater)
                }
                // Do it for me… has its own button beside this one.
                Menu("More…") { menu(showsDoItForMe: false) }
                    .tint(.aicovenSwipeNeutral)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Details", onDetails)
        .accessibilityActions {
            pinActions
            if !task.isFinished, TaskRules.canBeTalkedThrough(task) {
                Button(handoff == nil ? "Talk it through" : "Open thread", action: onTalk)
            }
        }
    }

    private var pinActions: some View {
        TaskPinActions(task: task, pin: pin, onPin: onPin, onUnpin: onUnpin, onAnswer: onAnswer)
    }

    /// The task's menu, the same as its card's on the Board.
    private func menu(showsDoItForMe: Bool) -> some View {
        TaskMenu(
            task: task, pin: pin, handoff: handoff, showsDoItForMe: showsDoItForMe, onTick: onTick, onClose: onClose, onPin: onPin,
            onUnpin: onUnpin, onAnswer: onAnswer, onDetails: onDetails, onTalk: onTalk, lead: lead
        )
    }

    /// The row's mark: a ring while an agent is on the task (still while
    /// its run is paused), the waiting mark while the task waits for the
    /// person, and the tick otherwise.
    @ViewBuilder
    private var glyph: some View {
        switch handoff {
        case .working, .paused:
            StatusRing(isTurning: handoff == .working)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        case .needsOK, .finished:
            WaitingMark()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        case nil:
            tick
        }
    }

    /// The one button of a row that waits for the person: Mark done once
    /// the agent has finished, Open thread while its turn waits for an OK.
    @ViewBuilder
    private var button: some View {
        switch handoff {
        case .finished:
            Button("Mark done") { onTick(true) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .fixedSize()
                .accessibilityValue(TasksModel.name(of: task))
        case .needsOK:
            Button("Open thread", action: onTalk)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .accessibilityValue(TasksModel.name(of: task))
        case .working, .paused, nil:
            EmptyView()
        }
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
