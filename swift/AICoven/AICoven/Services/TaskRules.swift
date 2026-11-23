import Foundation

/// The ways a person can order the tasks inside each part of the list, as
/// the cloud app's. The raw values are kept on the device, so they stay.
nonisolated enum TaskSort: String, CaseIterable, Identifiable {
    static let storageKey = "tasks.sortOrder.v1"

    case recentlyUpdated = "recently_updated"
    case dueDate = "due_date"
    case newest
    case oldest

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .recentlyUpdated: "Recently updated"
        case .dueDate: "Due date"
        case .newest: "Newest"
        case .oldest: "Oldest"
        }
    }

    /// The order until the person picks one: what is pinned, then the
    /// soonest due, then the rest by when they were last changed.
    static let standard = TaskSort.dueDate

    static func resolve(_ stored: String) -> TaskSort {
        TaskSort(rawValue: stored) ?? standard
    }
}

/// How a task's pin stands at a moment.
nonisolated enum TaskPinState: Equatable {
    /// Pinned for today, or for this week, and the pin has not run out.
    case today
    case week
    /// Pinned for a day that is over: "Still on today?".
    case review
    case none

    /// The period the task is pinned for now.
    var activePeriod: TaskPinPeriod? {
        switch self {
        case .today: .today
        case .week: .week
        case .review, .none: nil
        }
    }
}

/// Where a task handed to an agent stands, from the turn it was handed
/// over in.
nonisolated enum TaskHandoffState: Equatable {
    /// The agent is working on it.
    case working
    /// The agent's own run goes on where it runs, and is not followed
    /// here just now.
    case paused
    /// The turn waits for the person to allow something.
    case needsOK
    /// The agent's turn has ended with its reply.
    case finished

    /// The state in words, naming the agent where it is known.
    func words(agent: String?) -> String {
        switch self {
        case .working: "\(agent ?? "An agent") is on it"
        case .paused: agent.map { "\($0) is paused" } ?? "Paused"
        case .needsOK: "Needs your OK"
        case .finished: "\(agent ?? "An agent") finished"
        }
    }

    /// Whether it waits for the person: to allow something, or to look at
    /// what the agent did.
    var waitsForThePerson: Bool {
        self == .needsOK || self == .finished
    }
}

/// The turn the app is running in a thread now, as far as a task follows it.
nonisolated struct TaskLiveTurn: Equatable {
    let turnID: String
    /// Whether it waits to be allowed something.
    var needsOK = false
    var isStopping = false
}

/// When a task is due, in words: "Due today", "Due tomorrow", "Due Mon 3
/// Nov", "Due 3 Nov 2028", with the time of day if it has one, and
/// "Overdue · " before it for an open task whose day has passed.
nonisolated struct TaskDueLine: Equatable {
    let text: String
    let isOverdue: Bool

    init?(task: TaskItem, now: Date, calendar: Calendar = .current, locale: Locale = .current) {
        guard let due = task.due, let date = due.date.date(in: calendar) else { return nil }
        isOverdue = !task.isFinished && due.date.isOverdue(asOf: now, calendar: calendar)
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        var words: String = if calendar.isDate(date, inSameDayAs: now) {
            "today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            "tomorrow"
        } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            date.formatted(style.weekday(.abbreviated).day().month(.abbreviated))
        } else {
            date.formatted(style.day().month(.abbreviated).year())
        }
        if let at = due.time.flatMap({ Self.timeWords($0, locale: locale) }) {
            words += ", \(at)"
        }
        text = isOverdue ? "Overdue · Due \(words)" : "Due \(words)"
    }

    /// A time of day, `HH:mm`, as the person's locale writes one. It is
    /// the hour and minute that were kept, whatever the day: on a day the
    /// clocks change, a time the clock skips is still said as it was set.
    static func timeWords(_ clock: String, locale: Locale = .current) -> String? {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        // Told on a day and in a zone where every time of day exists.
        var plain = Calendar(identifier: .gregorian)
        plain.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let at = plain.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: parts[0], minute: parts[1])) else { return nil }
        return at.formatted(Date.FormatStyle(locale: locale, calendar: plain, timeZone: plain.timeZone).hour().minute())
    }
}

/// What the Tasks list decides, apart from how it is drawn: when a pin
/// ends, how one stands, the order inside each part, the parts themselves,
/// and the line under a task's title.
nonisolated enum TaskRules {
    /// When a pin made now runs out: at the start of the person's next
    /// day, or of their next week. Calendar days are added (not hours),
    /// and the day reached is taken from its own start, so that the end is
    /// right through a change of the clocks, also where a day does not
    /// start at midnight; the week starts on the person's own first weekday.
    static func pinEnd(for period: TaskPinPeriod, now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        func start(daysOn days: Int) -> Date {
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: days, to: today) ?? today.addingTimeInterval(Double(days) * 86400))
        }
        switch period {
        case .today:
            return start(daysOn: 1)
        case .week:
            let weekday = calendar.component(.weekday, from: today)
            let sinceWeekStart = (weekday - calendar.firstWeekday + 7) % 7
            return start(daysOn: 7 - sinceWeekStart)
        }
    }

    /// How a task's pin stands at `now`. A finished task has none; a pin
    /// for today that has run out waits to be answered; one for the week
    /// that has run out is no pin.
    static func pinState(of task: TaskItem, now: Date) -> TaskPinState {
        guard !task.isFinished, let pin = task.pin else { return .none }
        if pin.expiresAt <= now { return pin.period == .today ? .review : .none }
        return pin.period == .today ? .today : .week
    }

    /// Tasks in the order `sort` gives, what is pinned for today first and
    /// for the week after it; of two that `sort` cannot tell apart, the one
    /// that came first stays first.
    static func ordered(_ tasks: [TaskItem], by sort: TaskSort, now: Date) -> [TaskItem] {
        func rank(_ task: TaskItem) -> Int {
            switch pinState(of: task, now: now) {
            case .today: 0
            case .week: 1
            case .review, .none: 2
            }
        }
        return tasks.enumerated().sorted { first, second in
            let (one, other) = (first.element, second.element)
            if rank(one) != rank(other) { return rank(one) < rank(other) }
            switch sort {
            case .recentlyUpdated:
                if one.updatedAt != other.updatedAt { return one.updatedAt > other.updatedAt }
            case .newest:
                if one.createdAt != other.createdAt { return one.createdAt > other.createdAt }
            case .oldest:
                if one.createdAt != other.createdAt { return one.createdAt < other.createdAt }
            case .dueDate:
                switch (one.due?.date, other.due?.date) {
                case let (first?, second?) where first != second: return first < second
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    if one.updatedAt != other.updatedAt { return one.updatedAt > other.updatedAt }
                }
            }
            return first.offset < second.offset
        }.map(\.element)
    }

    /// Where a task handed to an agent stands. `live` is the turn the app
    /// runs in the task's thread now, if it runs one: where that is the
    /// turn the task was handed over in, the task follows it; otherwise
    /// it stands as that turn is stored. A turn that failed, was stopped,
    /// was cut off, or is gone is no hand-off any more: the task is the
    /// person's again. A finished task has none.
    static func handoff(of task: TaskItem, live: TaskLiveTurn?) -> TaskHandoffState? {
        guard !task.isFinished, let handoff = task.handoff else { return nil }
        if let live, live.turnID == handoff.turnID {
            // A Stop outranks the approval it interrupted.
            return live.needsOK && !live.isStopping ? .needsOK : .working
        }
        return switch handoff.outcome {
        case .completed: .finished
        // Recorded as running, and not run here: an agent's own run went
        // on; any other was lost when the app closed.
        case .running: handoff.hasRun ? .paused : nil
        case .failed, .cancelled, .interrupted, nil: nil
        }
    }

    /// The list's parts.
    struct Parts: Equatable {
        /// Pinned for a day that is over: asked about first. Each is also
        /// in the part it belongs to below.
        var review: [TaskItem] = []
        var today: [TaskItem] = []
        var week: [TaskItem] = []
        /// Not pinned now, and handed to an agent whose turn waits for the
        /// person or has ended.
        var needsYou: [TaskItem] = []
        /// Not pinned now, and with an agent at work on them.
        var agentsOnIt: [TaskItem] = []
        /// The other open tasks not pinned now.
        var open: [TaskItem] = []
        var finished: [TaskItem] = []
    }

    /// The parts of the list at `now`, each in the order `sort` gives.
    /// `handoff` says where a task handed to an agent stands.
    static func parts(
        open: [TaskItem], finished: [TaskItem], sort: TaskSort, now: Date, handoff: (TaskItem) -> TaskHandoffState? = { _ in nil }
    ) -> Parts {
        func those(_ state: TaskPinState) -> [TaskItem] {
            ordered(open.filter { pinState(of: $0, now: now) == state }, by: sort, now: now)
        }
        let unpinned = open.filter { pinState(of: $0, now: now).activePeriod == nil }
        var (needsYou, agentsOnIt, plain): ([TaskItem], [TaskItem], [TaskItem]) = ([], [], [])
        for task in unpinned {
            switch handoff(task) {
            case let state? where state.waitsForThePerson: needsYou.append(task)
            case .some: agentsOnIt.append(task)
            case nil: plain.append(task)
            }
        }
        return Parts(
            review: those(.review), today: those(.today), week: those(.week),
            needsYou: ordered(needsYou, by: sort, now: now), agentsOnIt: ordered(agentsOnIt, by: sort, now: now),
            open: ordered(plain, by: sort, now: now), finished: ordered(finished, by: sort, now: now)
        )
    }

    /// A piece of the line under a task's title.
    enum Context: Equatable {
        case plain(String)
        /// What it is pinned for.
        case pin(String)
        /// Its due day, passed.
        case overdue(String)
        /// The agent at work on it.
        case agent(String)
    }

    /// The line under a task's title, which says only what helps: its pin,
    /// its due day, and that it was closed. Empty for a task with none.
    /// `handoff` is where the task stands with the agent it was handed
    /// to, and `agent` that agent's name; with no hand-off, an open task
    /// with a lead agent says who leads it. `place` names the place the
    /// task is in, first, where the list is of every place's (On me).
    static func context(
        of task: TaskItem, now: Date, handoff: TaskHandoffState? = nil, agent: String? = nil, place: String? = nil,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> [Context] {
        var pieces: [Context] = []
        if let place { pieces.append(.plain(place)) }
        if let period = pinState(of: task, now: now).activePeriod { pieces.append(.pin(period.title)) }
        if let due = TaskDueLine(task: task, now: now, calendar: calendar, locale: locale) {
            pieces.append(due.isOverdue ? .overdue(due.text) : .plain(due.text))
        }
        if let handoff {
            pieces.append(handoff == .working ? .agent(handoff.words(agent: agent)) : .plain(handoff.words(agent: agent)))
        } else if let words = leadWords(for: task, agent: agent) {
            pieces.append(.plain(words))
        }
        if task.status == .closed { pieces.append(.plain("Closed")) }
        return pieces
    }

    /// "Led by <agent>", for an open task with a lead agent whose name is
    /// known.
    static func leadWords(for task: TaskItem, agent: String?) -> String? {
        guard !task.isFinished, task.leadAgentID != nil, let agent else { return nil }
        return "Led by \(agent)"
    }

    /// The agents a task can be handed to: its lead agent first, or else
    /// the agent last used in its coven, then the others as they come.
    struct LeadChoices<Agent: Equatable>: Equatable {
        enum Reason: Equatable { case lead, lastUsed }

        /// Listed first and marked; chosen only when the person picks it.
        var marked: Agent?
        var reason: Reason?
        var others: [Agent]
    }

    static func leadChoices<Agent: Equatable>(
        among agents: [Agent], id: (Agent) -> String, leadAgentID: String?, lastUsedID: String?
    ) -> LeadChoices<Agent> {
        if let lead = agents.first(where: { id($0) == leadAgentID && leadAgentID != nil }) {
            return LeadChoices(marked: lead, reason: .lead, others: agents.filter { id($0) != id(lead) })
        }
        if let last = agents.first(where: { id($0) == lastUsedID && lastUsedID != nil }) {
            return LeadChoices(marked: last, reason: .lastUsed, others: agents.filter { id($0) != id(last) })
        }
        return LeadChoices(marked: nil, reason: nil, others: agents)
    }

    /// Whether a task can be handed to an agent: an open one whose title
    /// can be read, since its title is what the agent is told.
    static func canBeHandedOver(_ task: TaskItem) -> Bool {
        !task.isFinished && !task.isUnreadable
    }

    /// Whether a task can be talked through: one that has a thread to
    /// open, or whose title can be read to start one with.
    static func canBeTalkedThrough(_ task: TaskItem) -> Bool {
        task.threadID != nil || !task.isUnreadable
    }

    /// What an agent is told when a task is handed to it, and when the
    /// person wants to talk one through, in the cloud app's words.
    static func request(for task: TaskItem) -> String {
        "Please do this for me: \(task.title)"
    }

    static func talkThrough(_ task: TaskItem) -> String {
        "I'd like to talk this task through: \(task.title)"
    }
}

/// What the Mac's Tasks menu offers for the task whose details are open,
/// in the cloud app's words.
nonisolated enum TaskCommand: String, Identifiable, Equatable {
    case pinToday
    case pinWeek
    case unpin
    case keepToday
    case notToday
    case setDueDate

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .pinToday: "Pin for today"
        case .pinWeek: "Pin for this week"
        case .unpin: "Unpin"
        case .keepToday: "Keep for today"
        case .notToday: "Not today"
        case .setDueDate: "Set Due Date…"
        }
    }

    /// What a task's pin can be offered, by how it stands: nothing for a
    /// finished task. A row's menu, its swipe, its details and the Mac's
    /// Tasks menu all offer these.
    static func pins(for pin: TaskPinState, isFinished: Bool) -> [TaskCommand] {
        guard !isFinished else { return [] }
        return switch pin {
        case .none: [.pinToday, .pinWeek]
        case .today: [.pinWeek, .unpin]
        case .week: [.pinToday, .unpin]
        case .review: [.keepToday, .notToday]
        }
    }

    /// What the Tasks menu offers a task: its pin's commands and the due
    /// day; none of it for a finished task.
    static func offered(for pin: TaskPinState, isFinished: Bool) -> [TaskCommand] {
        isFinished ? [] : pins(for: pin, isFinished: false) + [.setDueDate]
    }
}
