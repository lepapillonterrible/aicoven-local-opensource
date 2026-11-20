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
    /// newest first.
    static func sections(_ threads: [Thread]) -> (open: [Thread], archived: [Thread]) {
        let ordered = ordered(threads)
        return (ordered.filter { !$0.isArchived }, ordered.filter(\.isArchived))
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

    /// Whole days from the day of `earlier` to the day of `later`.
    static func daysBetween(_ earlier: Date, _ later: Date, _ calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: earlier), to: calendar.startOfDay(for: later)).day ?? 0
    }
}
