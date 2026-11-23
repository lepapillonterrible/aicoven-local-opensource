import Foundation

/// What one part of a task command asks for, as the cloud app reads a
/// command: a task to add, to finish, to move to a stage, or to give
/// another due day.
nonisolated enum TaskCommandAction: Equatable {
    /// Add a task, due on the day its words name, if they name one.
    case add(title: String, dueHint: String?)
    /// Mark the open task whose title holds these words done.
    case complete(title: String)
    /// Move it to a stage of the board; nil for Done.
    case move(title: String, stage: TaskStage?)
    /// Give it the due day these words name.
    case reschedule(title: String, when: String)
}

/// Reads a task command, by the cloud server's grammar: parts joined by
/// "and", "then" or a comma, each one of "add task …", "remind me to …",
/// "mark … done", "move … to <stage>" or "move … to <day>". Where this
/// reads a part otherwise than the server does, it says so there.
nonisolated enum TaskCommandReader {
    /// The most parts of one command that are read.
    static let mostActions = 10

    private static let days = "next week|this week|today|tomorrow(?: morning| afternoon| evening)?"
    private static let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    static func actions(in command: String) -> [TaskCommandAction] {
        let line = command.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return [] }
        let parts = pieces(of: line, splitBy: #"\s+(?:and|then)\s+|,\s*"#)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")) }
            .filter { !$0.isEmpty }
        var found: [TaskCommandAction] = []
        for part in parts {
            // "…, then move X to review": the joining word is not the part's own.
            let part = strip(part, #"^(?:and|then)\s+"#)
            // The same part twice is one, whatever its case, as on the server.
            guard let action = action(in: part), !found.contains(where: { isSame($0, action) }) else { continue }
            found.append(action)
            if found.count == mostActions { break }
        }
        return found
    }

    /// The stage a person's wording names: nil for none, and `.some(nil)`
    /// for Done.
    static func stage(named words: String) -> TaskStage?? {
        switch words.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") {
        case "backlog", "todo", "to do", "open": .some(.backlog)
        case "in progress", "doing": .some(.inProgress)
        case "review", "in review": .some(.review)
        case "done", "complete", "completed": .some(nil)
        default: nil
        }
    }

    /// The day free words name, read from `today`: today, tomorrow (also
    /// "tomorrow morning" and the like), this week (its Friday, or today
    /// once that has passed), next week (its Monday), or a weekday (the
    /// next one, today included). Nil for words that name no day.
    static func day(named hint: String, from today: Date, calendar: Calendar = .current) -> TaskDueDate? {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let words = hint.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Monday is 0, as the cloud server counts.
        let weekday = (gregorian.component(.weekday, from: today) + 5) % 7
        let ahead: Int
        if words == "today" {
            ahead = 0
        } else if words.hasPrefix("tomorrow"), ["tomorrow", "tomorrow morning", "tomorrow afternoon", "tomorrow evening"].contains(words) {
            ahead = 1
        } else if words == "this week" {
            ahead = max(0, 4 - weekday)
        } else if words == "next week" {
            ahead = 7 - weekday
        } else if let named = weekdays.firstIndex(of: words) {
            ahead = (named - weekday + 7) % 7
        } else {
            return nil
        }
        guard let day = gregorian.date(byAdding: .day, value: ahead, to: gregorian.startOfDay(for: today)) else { return nil }
        return TaskDueDate(day: day, in: gregorian)
    }

    private static let adding = [
        #"(?:remind me to)\s+(.+)$"#, #"(?:remember to)\s+(.+)$"#, #"(?:add|create)\s+(?:a\s+)?(?:new\s+)?task(?:\s+(?:to|for))?\s+(.+)$"#,
    ]

    private static func action(in part: String) -> TaskCommandAction? {
        // A part that begins by asking for a task is one to add, whatever
        // its title goes on to say ("add task finish the report" adds a
        // task; it does not finish one).
        if let added = add(in: part, patterns: adding.map { "^" + $0 }) { return added }
        let stages = "backlog|todo|to do|open|in progress|doing|review|in review|done|complete|completed"
        if let found = groups(in: part, #"^(?:move|set)\s+(?:the\s+)?(.+)\s+(?:to|as)\s+("# + stages + #")\s*$"#),
           let stage = stage(named: found[1]) {
            let title = cleaned(found[0])
            if !title.isEmpty { return .move(title: title, stage: stage) }
        }
        let when = days + "|" + weekdays.joined(separator: "|")
        if let found = groups(in: part, #"(?:move|defer|push|reschedule)\s+(?:the\s+)?(.+?)\s+(?:to|for|until)\s+("# + when + #")\b"#) {
            let title = cleaned(found[0])
            if !title.isEmpty { return .reschedule(title: title, when: found[1]) }
        }
        if let found = groups(in: part, #"(?:mark|complete|finish|done)\s+(?:the\s+)?(.+)$"#) {
            // "Mark X done" names X: the word that says so is not its title's.
            let title = cleaned(strip(found[0], #"\s+(?:as\s+)?(?:done|complete|completed|finished)$"#))
            if !title.isEmpty { return .complete(title: title) }
        }
        return add(in: part, patterns: adding)
    }

    private static func add(in part: String, patterns: [String]) -> TaskCommandAction? {
        for pattern in patterns {
            guard let found = groups(in: part, pattern) else { continue }
            var title = cleaned(found[0])
            guard !title.isEmpty else { continue }
            var hint: String?
            if let due = groups(in: title, #"\b("# + days + #")$"#) {
                let rest = cleaned(String(title.dropLast(due[0].count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,.")))
                // Words that are only a day are the title all the same,
                // and the day it is due, as on the server.
                if !rest.isEmpty { title = rest }
                hint = due[0]
            }
            return .add(title: title, dueHint: hint)
        }
        return nil
    }

    /// Whether two parts ask for the same thing: the same kind of thing,
    /// of the same title and day, whatever their case.
    private static func isSame(_ one: TaskCommandAction, _ other: TaskCommandAction) -> Bool {
        func key(_ action: TaskCommandAction) -> [String] {
            switch action {
            case let .add(title, hint): ["add", title.lowercased(), (hint ?? "").lowercased()]
            case let .complete(title): ["complete", title.lowercased(), ""]
            case let .move(title, stage): ["move", title.lowercased(), stage?.rawValue ?? "done"]
            case let .reschedule(title, when): ["reschedule", title.lowercased(), when.lowercased()]
            }
        }
        return key(one) == key(other)
    }

    /// A title without a leading article, on one line, with single spaces.
    private static func cleaned(_ words: String) -> String {
        strip(words.trimmingCharacters(in: .whitespaces), #"^(?:the|a|an)\s+"#)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// The groups a pattern captures in `text`; nil where it does not match.
    private static func groups(in text: String, _ pattern: String) -> [String]? {
        guard let match = regex(pattern)?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1 ..< match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    private static func strip(_ text: String, _ pattern: String) -> String {
        regex(pattern)?.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "") ?? text
    }

    private static func pieces(of text: String, splitBy pattern: String) -> [String] {
        guard let regex = regex(pattern) else { return [text] }
        var pieces: [String] = []
        var start = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            pieces.append(String(text[start ..< range.lowerBound]))
            start = range.upperBound
        }
        pieces.append(String(text[start...]))
        return pieces
    }
}
