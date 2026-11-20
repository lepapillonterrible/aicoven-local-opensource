import Foundation

/// How a list of threads is ordered, sectioned and worded, as the cloud
/// app's lists are.
nonisolated enum ThreadListRules {
    /// When a thread was last used: its last message, or when it was made.
    static func lastUsed(_ thread: Thread) -> Date {
        thread.lastMessageAt ?? thread.createdAt
    }

    /// Threads newest first by when they were last used (those used at
    /// the same moment in a fixed order, so a list does not shuffle).
    static func ordered(_ threads: [Thread]) -> [Thread] {
        threads.sorted { one, other in
            let (first, second) = (lastUsed(one), lastUsed(other))
            return first == second ? one.id < other.id : first > second
        }
    }

    /// A list's two sections: the threads, and those archived, each
    /// newest first. Among the threads, those still open (`isStillOpen`:
    /// working, waiting for the person, stopped on a problem, or holding
    /// an unsent message) come before the rest.
    static func sections(
        _ threads: [Thread], isStillOpen: (Thread) -> Bool = { _ in false }
    ) -> (open: [Thread], archived: [Thread]) {
        let ordered = ordered(threads)
        let listed = ordered.filter { !$0.isArchived }
        return (listed.filter(isStillOpen) + listed.filter { !isStillOpen($0) }, ordered.filter(\.isArchived))
    }

    /// A scope's threads as its Overview lists them, those archived left
    /// out: the threads still open (`isStillOpen`), then the earlier ones,
    /// each newest first.
    static func overview(_ threads: [Thread], isStillOpen: (Thread) -> Bool) -> (stillOpen: [Thread], earlier: [Thread]) {
        let listed = ordered(threads).filter { !$0.isArchived }
        return (listed.filter(isStillOpen), listed.filter { !isStillOpen($0) })
    }

    /// The threads with a reply that came while the person was away from
    /// the scope: those not archived whose reply not yet seen (`unreadReplyAt`,
    /// by thread id) was stored after `lastVisit`, the latest reply first.
    /// None when this device does not know the last visit.
    static func away(_ threads: [Thread], unreadReplyAt: [String: Date], since lastVisit: Date?) -> [(thread: Thread, repliedAt: Date)] {
        guard let lastVisit else { return [] }
        return threads
            .compactMap { thread -> (thread: Thread, repliedAt: Date)? in
                guard !thread.isArchived, let at = unreadReplyAt[thread.id], at > lastVisit else { return nil }
                return (thread, at)
            }
            .sorted { $0.repliedAt == $1.repliedAt ? $0.thread.id < $1.thread.id : $0.repliedAt > $1.repliedAt }
    }

    /// What a reply's row says under the thread's title: who replied.
    static func replyDetail(agentName: String?) -> String {
        let name = agentName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "New reply" : "\(name) replied"
    }

    /// The threads a search for `query` shows: those whose title, as a row
    /// shows it, holds what was typed, whatever its case or accents. All
    /// of them while nothing is typed.
    static func matching(_ threads: [Thread], query: String) -> [Thread] {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return threads }
        return threads.filter {
            title(of: $0).range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// A thread's title as a row shows it.
    static func title(of thread: Thread) -> String {
        let title = thread.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Untitled" : title
    }

    /// The name a thread is given from what was typed, as it is kept
    /// (`ThreadInputValidator`): on one line, its runs of white space as
    /// one space, 120 characters at most; nil if nothing is left.
    static func name(from typed: String) -> String? {
        let name = ThreadInputValidator.normalizedTitle(typed, defaultTitle: "")
        return name.isEmpty ? nil : name
    }

    /// Whether a list already shown stays when reading it again failed
    /// with `error`. Not when the account's data is locked or the account
    /// changed: what is shown is then not this reader's to see.
    static func keepsShownList(after error: Error) -> Bool {
        switch error as? RepositoryError {
        case .dataLocked, .accountChanged: false
        case .databaseUnavailable, nil: true
        }
    }

    /// What is asked before a thread is deleted.
    static func deleteQuestion(for thread: Thread) -> String {
        "Delete “\(title(of: thread))”?"
    }

    static let deleteConsequence = "The thread and its messages are removed."
}

/// The dates on thread rows, as the cloud app words them.
nonisolated enum VisitWords {
    /// A thread row's date: the time today, the weekday within the past
    /// week, else the day and month, with the year when it is not this
    /// year.
    static func rowDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if daysBetween(date, now, calendar) < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// When the person was last in a scope: "You were last here earlier
    /// today.", "… yesterday.", "… on Friday.", "… on 12 September.", with
    /// the year when it is not this year.
    static func lastHere(_ lastVisit: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        "You were last here \(when(lastVisit, now: now, calendar: calendar))."
    }

    private static func when(_ date: Date, now: Date, calendar: Calendar) -> String {
        // The day is named in the calendar the days were counted in, and
        // its time zone: one visit is not Friday by one and Saturday by
        // the other.
        var style = Date.FormatStyle.dateTime
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        switch daysBetween(date, now, calendar) {
        case ..<1: return "earlier today"
        case 1: return "yesterday"
        case ..<7: return "on " + date.formatted(style.weekday(.wide))
        default:
            if calendar.isDate(date, equalTo: now, toGranularity: .year) {
                return "on " + date.formatted(style.day().month(.wide))
            }
            return "on " + date.formatted(style.day().month(.wide).year())
        }
    }

    /// Whole days from the day of `earlier` to the day of `later`.
    static func daysBetween(_ earlier: Date, _ later: Date, _ calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: earlier), to: calendar.startOfDay(for: later)).day ?? 0
    }
}
