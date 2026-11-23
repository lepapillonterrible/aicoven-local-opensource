import Foundation

/// Whether a task is still to do, as in the cloud app: open, done, or
/// closed without being done.
nonisolated enum TaskStatus: String {
    case open
    case done
    case closed
}

/// How far along a task is, as the cloud app's board has it.
nonisolated enum TaskStage: String, CaseIterable {
    case backlog
    case inProgress = "in_progress"
    case review

    /// The stage as the Board names its column, in the cloud app's words.
    var title: String {
        switch self {
        case .backlog: "To do"
        case .inProgress: "In progress"
        case .review: "Review"
        }
    }
}

/// The day a task is due: a day on the calendar, not a moment, so it is
/// the same day wherever the person is. Written as the cloud app writes
/// it, `YYYY-MM-DD`.
nonisolated struct TaskDueDate: Equatable, Comparable {
    let rawValue: String

    /// A day that exists, written `YYYY-MM-DD`; nil for anything else.
    init?(rawValue: String) {
        let parts = rawValue.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.unicodeScalars.allSatisfy { ("0" ... "9").contains($0) } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components), calendar.dateComponents([.year, .month, .day], from: date) == components else { return nil }
        self.rawValue = rawValue
    }

    /// The day `day` falls on in `calendar`'s time zone.
    init?(day: Date, in calendar: Calendar = .current) {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: day)
        guard let year = parts.year, let month = parts.month, let date = parts.day else { return nil }
        self.init(rawValue: String(format: "%04d-%02d-%02d", year, month, date))
    }

    static func < (lhs: TaskDueDate, rhs: TaskDueDate) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The start of the day in `calendar`'s time zone.
    func date(in calendar: Calendar = .current) -> Date? {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = rawValue.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return gregorian.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Whether the day is before today.
    func isOverdue(asOf now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let today = TaskDueDate(day: now, in: calendar) else { return false }
        return self < today
    }
}

/// How long a task is pinned for: today, or this week.
nonisolated enum TaskPinPeriod: String {
    case today
    case week

    /// As a section and a row name it.
    var title: String {
        switch self {
        case .today: "Today"
        case .week: "This week"
        }
    }
}

/// A task pinned for today or for this week, until the pin runs out.
nonisolated struct TaskPin: Equatable {
    let period: TaskPinPeriod
    let expiresAt: Date
}

/// When a task is due: a day, and a time of day if it has one.
nonisolated struct TaskDue: Equatable {
    let date: TaskDueDate
    /// The time of day, `HH:mm` on the 24-hour clock.
    let time: String?

    /// Nil for a time that does not read as a time of day.
    init?(date: TaskDueDate, time: String? = nil) {
        if let time {
            let parts = time.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
                  parts.allSatisfy({ $0.unicodeScalars.allSatisfy { ("0" ... "9").contains($0) } }),
                  let hour = Int(parts[0]), let minute = Int(parts[1]), hour < 24, minute < 60 else { return nil }
        }
        self.date = date
        self.time = time
    }
}

/// When a reminder reminds, measured from the task's due time: at it, an
/// hour before it, or a day before it. In the cloud app's words.
nonisolated enum TaskReminderPreset: String, CaseIterable, Identifiable {
    case atDue = "at_due"
    case hourBefore = "hour_before"
    case dayBefore = "day_before"

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .atDue: "At the due time"
        case .hourBefore: "1 hour before"
        case .dayBefore: "1 day before"
        }
    }
}

/// The person's reminder on a task: when it reminds, and how that was
/// said. One whose time has come has reminded, and stays with the task
/// until it is changed or removed.
nonisolated struct TaskReminder: Equatable {
    /// The preset it was set by, which moves it with the task's due day;
    /// nil for a time the person picked, which stays.
    let preset: TaskReminderPreset?
    let remindAt: Date
    /// The time zone it was set in, by its identifier: a due day with no
    /// time of day is taken as 9:00 there.
    let timeZone: String

    /// The time of day a due day with none is taken to be due at.
    static let hourOfADayWithNoTime = 9

    /// Whether its time has come.
    func hasPassed(asOf now: Date) -> Bool {
        remindAt <= now
    }

    /// When a preset reminds for a task due on `due`, in the time zone
    /// named: at the due time (9:00 for a day with no time of day), 3,600
    /// seconds before it, or at the same time of day on the day before.
    /// Nil for a time zone that is none.
    static func time(for preset: TaskReminderPreset, due: TaskDue, timeZone: String) -> Date? {
        guard let zone = TimeZone(identifier: timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let day = due.date.date(in: calendar) else { return nil }
        let parts = due.time?.split(separator: ":").compactMap { Int($0) } ?? [hourOfADayWithNoTime, 0]
        guard parts.count == 2, let dueAt = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day) else { return nil }
        switch preset {
        case .atDue: return dueAt
        case .hourBefore: return dueAt.addingTimeInterval(-3600)
        case .dayBefore: return calendar.date(byAdding: .day, value: -1, to: dueAt)
        }
    }
}

/// What is asked for a task's reminder: a preset, or a time the person
/// picked; each with the time zone it is asked in.
nonisolated enum TaskReminderAsk: Equatable {
    case preset(TaskReminderPreset, timeZone: String)
    case at(Date, timeZone: String)
}

/// The turn a task was handed to an agent in, as the store has it.
nonisolated struct TaskHandoff: Equatable {
    let turnID: String
    /// How the turn stands; nil for a turn that is no longer there.
    var outcome: TurnOutcome?
    /// Whether it is an agent's own run, which goes on without this app.
    var hasRun = false
    /// The agent it was handed to; nil for Strix, which is no stored
    /// agent. An agent deleted since is still named here, by an id that
    /// is nobody's any more.
    var agentID: String?
}

/// A task: something to do, in a coven or with Strix, as the cloud app's.
nonisolated struct TaskItem: Identifiable, Equatable {
    let id: String
    /// The coven it is in; nil for Strix's.
    let covenID: String?
    /// Its title; empty for a task that is unreadable.
    let title: String
    let status: TaskStatus
    let stage: TaskStage
    let due: TaskDue?
    let pin: TaskPin?
    /// Whether its title cannot be opened with the account's key.
    var isUnreadable = false
    /// The thread the task is talked through in, once it has one.
    var threadID: String?
    /// The agent that leads the task: the one it is handed to.
    var leadAgentID: String?
    /// The turn the task was last handed to an agent in, and how that
    /// turn stands as it is stored.
    var handoff: TaskHandoff?
    /// The person's reminder on it, if they set one.
    var reminder: TaskReminder?
    let createdAt: Date
    let updatedAt: Date

    /// Done, or closed without being done.
    var isFinished: Bool {
        status != .open
    }
}

/// What one change sets of a task. What it does not name stays as it is.
nonisolated struct TaskChange: Equatable {
    /// A value to set, or to take away.
    enum Setting<Value: Equatable>: Equatable {
        case to(Value)
        case cleared
    }

    var title: String?
    var status: TaskStatus?
    var stage: TaskStage?
    var due: Setting<TaskDue>?
    var pin: Setting<TaskPin>?
    /// The thread the task is talked through in: given once.
    var threadID: String?
    var leadAgentID: Setting<String>?
    /// The turn the task was handed to an agent in: a turn of its thread.
    var handoffTurnID: String?
    /// The agent it was handed to in that turn, an agent of its coven;
    /// nil for Strix. Read only with the turn.
    var handoffAgentID: String?
    /// Its reminder: set, or taken away.
    var reminder: Setting<TaskReminderAsk>?
}
