import SwiftUI

/// A task's details, as the cloud app's: its title (which renames it), how
/// it stands, its pin and its due day as two small pop-ups, and what can be
/// done with it. The same content in three places: a compact sheet on the
/// Mac, a pane beside the list on the iPad, and a screen pushed on the
/// iPhone. It reads the task from the page's model each time it is drawn,
/// and keeps no copy of it.
struct TaskDetailView: View {
    enum Host { case sheet, pane, page }

    let host: Host
    let taskID: String
    @ObservedObject var model: TasksModel
    /// The time the page is drawn for.
    let now: Date
    let onPin: (TaskItem, TaskPinPeriod) -> Void
    let onUnpin: (TaskItem) -> Void
    /// Keeps a pin that has run out for today (true), or clears it.
    let onAnswer: (TaskItem, Bool) -> Void
    /// Whether the due day's sheet is up: the Mac's Tasks menu opens it too.
    @Binding var editingDue: Bool
    /// Closes the pane.
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var renaming = false
    @State private var newTitle = ""

    private var task: TaskItem? {
        model.task(taskID)
    }

    var body: some View {
        switch host {
        case .sheet: sheet
        case .pane: pane
        case .page: page
        }
    }

    // MARK: Hosts

    /// The Mac's sheet: 480 pt wide and only as tall as its content, with
    /// stone bars above and below.
    private var sheet: some View {
        VStack(spacing: 0) {
            Text("Task")
                .font(.aicovenH2)
                .foregroundStyle(Color.aicovenTextPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color.aicovenChrome)
                .accessibilityAddTraits(.isHeader)
            StoneHairline()
            // As tall as the detail, up to 520 pt, then it scrolls.
            ScrollView { detail }
                .frame(maxHeight: 520)
                .fixedSize(horizontal: false, vertical: true)
            StoneHairline()
            HStack {
                Spacer(minLength: 0)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Spacing.sm)
            .background(Color.aicovenChrome)
        }
        .frame(width: 480)
        .background(Color.aicovenSurface)
    }

    /// The iPad's pane: no bar, and a plain cross at its corner.
    private var pane: some View {
        ScrollView {
            detail
                .padding(.top, Spacing.xl)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.aicovenTextSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close details")
        }
        .background(Color.aicovenSurface.ignoresSafeArea())
    }

    /// The iPhone's pushed screen.
    private var page: some View {
        ScrollView { detail }
            .background(Color.aicovenSurface.ignoresSafeArea())
            .navigationTitle("Task")
    }

    // MARK: Content

    @ViewBuilder
    private var detail: some View {
        if let task {
            VStack(alignment: .leading, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    title(task)
                    if let words = Self.stateWords(for: task) {
                        Text(words)
                            .font(.aicovenBodySmall)
                            .foregroundStyle(Color.aicovenTextSecondary)
                    }
                }

                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.aicovenBodySmall)
                        .foregroundStyle(Color.aicovenError)
                }

                properties(task)

                HStack(spacing: Spacing.xs) {
                    if task.isFinished {
                        Button("Reopen") { setDone(task, false) }
                    } else {
                        Button("Close") { close(task) }
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(Spacing.lg)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
            .disabled(model.saving.contains(task.id))
            .alert("Rename Task", isPresented: $renaming) {
                TextField("Title", text: $newTitle)
                Button("Rename") { rename(task) }
                    .disabled(TaskRepository.keptTitle(newTitle).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $editingDue) {
                TaskDueSheet(task: task) { due in
                    let account = UserScope.currentUserID
                    Task { await model.setDue(task, to: due, as: account) }
                }
            }
        } else {
            ContentUnavailableView("Task unavailable", systemImage: "checklist")
                .padding(Spacing.lg)
        }
    }

    /// The title, large; pressed, it is renamed.
    private func title(_ task: TaskItem) -> some View {
        Button {
            newTitle = task.title
            renaming = true
        } label: {
            Text(task.isUnreadable ? TasksModel.unreadable : task.title)
                .font(.aicovenDisplayMedium)
                .foregroundStyle(Color.aicovenTextPrimary)
                .multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Renames the task")
        .accessibilityAddTraits(.isHeader)
    }

    /// Where the task stands, when that is more than open.
    static func stateWords(for task: TaskItem) -> String? {
        switch task.status {
        case .open: nil
        case .done: "Done"
        case .closed: "Closed"
        }
    }

    // MARK: Properties

    /// The iPhone and the iPad's pane keep to one line by leading with a
    /// symbol and dropping the labels.
    private var isCompact: Bool {
        host != .sheet && (horizontalSizeClass == .compact || host == .pane)
    }

    /// The task's pin and its due day on one line, as two small pop-ups.
    private func properties(_ task: TaskItem) -> some View {
        let pin = TaskRules.pinState(of: task, now: now)
        return HStack(spacing: Spacing.xs) {
            Menu {
                TaskPinActions(
                    task: task, pin: pin, onPin: { onPin(task, $0) }, onUnpin: { onUnpin(task) }, onAnswer: { onAnswer(task, $0) }
                )
            } label: {
                StonePopUpLabel(icon: isCompact ? "pin" : nil, text: Self.pinWords(pin, isCompact: isCompact))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(task.isFinished)
            .accessibilityLabel("Pin: \(Self.pinWords(pin, isCompact: false))")

            Button {
                editingDue = true
            } label: {
                StonePopUpLabel(icon: isCompact ? "calendar" : nil, text: Self.dueWords(for: task, now: now, isCompact: isCompact))
            }
            .buttonStyle(.plain)
            .disabled(task.isFinished)
            .accessibilityLabel(Self.dueWords(for: task, now: now, isCompact: false))
            .accessibilityHint("Sets the due date")
            Spacer(minLength: 0)
        }
    }

    static func pinWords(_ pin: TaskPinState, isCompact: Bool) -> String {
        if let period = pin.activePeriod { return isCompact ? period.title : "Pinned: \(period.title)" }
        if pin == .review { return "Still on today?" }
        return isCompact ? "Pin" : "Not pinned"
    }

    static func dueWords(
        for task: TaskItem, now: Date, isCompact: Bool, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        guard let due = TaskDueLine(task: task, now: now, calendar: calendar, locale: locale) else { return "Add due date" }
        return isCompact ? due.text.replacingOccurrences(of: "Due ", with: "") : due.text
    }

    // MARK: Actions

    private func setDone(_ task: TaskItem, _ done: Bool) {
        let account = UserScope.currentUserID
        Task { await model.setDone(task, done, as: account) }
    }

    private func close(_ task: TaskItem) {
        let account = UserScope.currentUserID
        Task { await model.close(task, as: account) }
    }

    private func rename(_ task: TaskItem) {
        let title = newTitle
        let account = UserScope.currentUserID
        Task { await model.rename(task, to: title, as: account) }
    }
}

/// Choosing a task's due day and, if it has one, its time of day.
struct TaskDueSheet: View {
    let task: TaskItem
    /// Saves the day chosen, or takes the day away (nil).
    let onSave: (TaskDue?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var day: Date
    @State private var hasTime: Bool
    @State private var time: Date

    init(task: TaskItem, onSave: @escaping (TaskDue?) -> Void) {
        self.task = task
        self.onSave = onSave
        let start = task.due?.date.date() ?? Calendar.current.startOfDay(for: Date())
        _day = State(initialValue: start)
        _hasTime = State(initialValue: task.due?.time != nil)
        _time = State(initialValue: Self.pickerTime(task.due?.time))
    }

    /// Where the time picker starts: the task's time of day, or nine in
    /// the morning for a task with none. It is a time of day only, told
    /// on a day of its own on which the clocks do not change, not on the
    /// due day: there a time the clock skips would be moved on, and saved
    /// so without the person having touched it.
    static func pickerTime(_ clock: String?, calendar: Calendar = .current) -> Date {
        let parts = clock?.split(separator: ":").compactMap { Int($0) } ?? []
        let (hour, minute) = parts.count == 2 ? (parts[0], parts[1]) : (9, 0)
        return calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute)) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    var body: some View {
        NavigationStack {
            SettingsForm {
                DatePicker("Due", selection: $day, displayedComponents: .date)
                Toggle("Time", isOn: $hasTime)
                if hasTime {
                    DatePicker("At", selection: $time, displayedComponents: .hourAndMinute)
                }
                if task.due != nil {
                    Button("Remove Due Date", role: .destructive) {
                        onSave(nil)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Due Date")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if let due = Self.due(day: day, time: hasTime ? time : nil) { onSave(due) }
                            dismiss()
                        }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 260)
        #endif
    }

    /// The day `day` falls on for the person, with the time of day of
    /// `time` if one is given.
    static func due(day: Date, time: Date?, calendar: Calendar = .current) -> TaskDue? {
        guard let date = TaskDueDate(day: day, in: calendar) else { return nil }
        let clock = time.map { time -> String in
            let parts = calendar.dateComponents([.hour, .minute], from: time)
            return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        }
        return TaskDue(date: date, time: clock)
    }
}
