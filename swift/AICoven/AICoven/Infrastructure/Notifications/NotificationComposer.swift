import Foundation
import NaturalLanguage

/// What a notification is about.
nonisolated enum NotificationEvent: Equatable {
    /// A turn waits for the person's OK; `question` is what it asks
    /// ("Run this command?").
    case needsOK(question: String)
    /// A reply came; `reply` is its text.
    case finished(reply: String)
    /// The turn stopped on a problem; `reason` is what it said.
    case problem(reason: String)
}

/// A notification as it is shown.
nonisolated struct ComposedNotification: Equatable {
    let title: String
    /// Where it happened ("Client work · Q4 board pack"); empty where
    /// details are kept out.
    let subtitle: String
    let body: String
}

/// The words of a notification, as the cloud app's: who it is about in
/// the title, where in the subtitle, and one line of what.
///
/// Details are another matter here than there: a notification is shown
/// on the Lock Screen and kept by the system, outside this app's
/// encrypted store. So unless the person asks for details, it says only
/// which agent it is about, and nothing of the thread's name or of what
/// was said.
nonisolated enum NotificationComposer {
    /// The most characters of a body.
    static let longestBody = 200
    static let reviewFallback = "Open AICoven to review."
    static let answerFallback = "Open AICoven to read the answer."
    static let problemFallback = "Open AICoven to see what went wrong."

    static func compose(
        _ event: NotificationEvent, agentName: String?, threadTitle: String, placeName: String, showsDetails: Bool
    ) -> ComposedNotification {
        let named = agentName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A thread with no agent of its own is answered by Strix.
        let agent = named.isEmpty ? "Strix" : named
        let (title, fallback): (String, String) = switch event {
        case .needsOK: ("\(agent) needs your OK", reviewFallback)
        case .finished: ("\(agent) finished", answerFallback)
        case .problem: ("\(agent) stopped on a problem", problemFallback)
        }
        guard showsDetails else { return ComposedNotification(title: title, subtitle: "", body: fallback) }
        // What was said is read only where it is to be shown.
        let detail: String? = switch event {
        case let .needsOK(question): oneLine(question)
        case let .finished(said), let .problem(said): firstSentence(of: said)
        }
        return ComposedNotification(title: title, subtitle: "\(placeName) · \(threadTitle)", body: detail.map(capped) ?? fallback)
    }

    static let reminderTitle = "Reminder"
    static let reminderFallback = "Open AICoven to see the task."

    /// A task's reminder, titled as the cloud app's push. It names the
    /// task only where the person asked for details (and the title can
    /// be read): a notification is shown on the Lock Screen and kept by
    /// the system, outside this app's encrypted store.
    static func reminder(taskTitle: String?, showsDetails: Bool) -> ComposedNotification {
        let named = showsDetails ? taskTitle.flatMap(oneLine) : nil
        return ComposedNotification(title: reminderTitle, subtitle: "", body: named.map(capped) ?? reminderFallback)
    }

    /// The first sentence of a text, on one line; nil for a text that
    /// says nothing. Sentence boundaries come from `NLTokenizer`, so
    /// "README.md" or "Dr." do not end one.
    static func firstSentence(of text: String) -> String? {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var first: Range<String.Index>?
        tokenizer.enumerateTokens(in: text.startIndex ..< text.endIndex) { range, _ in
            first = range
            return false
        }
        return oneLine(first.map { String(text[$0]) } ?? text)
    }

    /// A text on one line, with single spaces; nil where nothing is left.
    static func oneLine(_ text: String) -> String? {
        let line = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return line.isEmpty ? nil : line
    }

    /// A body no longer than the longest, cut with an ellipsis.
    static func capped(_ body: String) -> String {
        body.count > longestBody ? "\(body.prefix(longestBody - 1))…" : body
    }
}
