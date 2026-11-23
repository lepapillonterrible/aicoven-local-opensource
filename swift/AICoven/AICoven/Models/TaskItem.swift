import Foundation

/// Whether a task is still to do, as in the cloud app: open, done, or
/// closed without being done.
nonisolated enum TaskStatus: String {
    case open
    case done
    case closed
}

/// How far along a task is, as the cloud app's board has it.
nonisolated enum TaskStage: String {
    case backlog
    case inProgress = "in_progress"
    case review
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
}
