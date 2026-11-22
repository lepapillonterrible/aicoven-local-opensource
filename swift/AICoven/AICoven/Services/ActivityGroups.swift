import Foundation

/// A row on Activity: a thread, and why it is there.
nonisolated enum ActivityItem: Identifiable, Equatable {
    /// Its turn waits for the person's OK.
    case approval(Thread)
    /// Its turn stopped on a problem, or the app closed on it.
    case problem(Thread)
    /// An agent of the person's own was running its turn when the app
    /// closed: opened, the run is followed again.
    case paused(Thread)
    /// Work is under way, in the status line's words.
    case moving(Thread, words: String)
    /// A reply the person has not seen, and when it came.
    case finished(Thread, repliedAt: Date?)

    var thread: Thread {
        switch self {
        case let .approval(thread), let .problem(thread), let .paused(thread), let .moving(thread, _), let .finished(thread, _): thread
        }
    }

    var id: String {
        switch self {
        case let .approval(thread): "approval:\(thread.id)"
        case let .problem(thread): "problem:\(thread.id)"
        case let .paused(thread): "paused:\(thread.id)"
        case let .moving(thread, _): "moving:\(thread.id)"
        case let .finished(thread, _): "finished:\(thread.id)"
        }
    }
}

/// Activity's three groups, as the cloud app's, in the same words as the
/// rows: Waiting for you, Moving, Finished. Nothing is grouped by coven or
/// by time alone, and nothing is counted.
nonisolated struct ActivityGroups: Equatable {
    var waiting: [ActivityItem] = []
    var moving: [ActivityItem] = []
    var finished: [ActivityItem] = []

    /// The groups for `threads` (the account's, across Strix and every
    /// coven), from what each is doing (`activity`, by thread id) and when
    /// the reply not yet seen came (`unreadReplyAt`). A turn that asks for
    /// the person's OK waits for them, then one that stopped on a
    /// problem, then one paused; a turn under way is moving; a reply not
    /// yet seen is finished, the latest first. A thread with only an
    /// unsent message is in none, and neither is one that is archived.
    /// Within a kind, the thread last used comes first.
    static func make(threads: [Thread], activity: [String: ConversationActivity], unreadReplyAt: [String: Date]) -> ActivityGroups {
        var groups = ActivityGroups()
        var approvals: [ActivityItem] = []
        var problems: [ActivityItem] = []
        var paused: [ActivityItem] = []
        var finished: [(thread: Thread, repliedAt: Date?)] = []
        for thread in ThreadListRules.ordered(threads) where !thread.isArchived {
            switch activity[thread.id] {
            case .waiting: approvals.append(.approval(thread))
            case .broken: problems.append(.problem(thread))
            case .paused: paused.append(.paused(thread))
            case let .moving(words): groups.moving.append(.moving(thread, words: words))
            case .unread: finished.append((thread, unreadReplyAt[thread.id]))
            case .unsent, nil: break
            }
        }
        groups.waiting = approvals + problems + paused
        // Stable, so replies that came at the same moment (or at none
        // known) stay in the order of their threads.
        groups.finished = finished.enumerated()
            .sorted { one, other in
                let (first, second) = (one.element.repliedAt ?? .distantPast, other.element.repliedAt ?? .distantPast)
                return first == second ? one.offset < other.offset : first > second
            }
            .map { .finished($0.element.thread, repliedAt: $0.element.repliedAt) }
        return groups
    }

    /// What VoiceOver is told when the groups change while Activity is on
    /// screen: each thread that newly waits for the person, and each reply
    /// that newly finished, in one announcement (several at once would
    /// cut each other off). What a turn under way says is not told as it
    /// changes: its card reads it. Nor the thread whose approval is being
    /// asked on the page (`asking`): the approvals' spot says that one
    /// itself, once. Nil where nothing is new.
    static func announcement(from old: ActivityGroups, to new: ActivityGroups, asking: ToolApproval? = nil) -> String? {
        let before = Set((old.waiting + old.finished).map(\.id))
        let said = (waitingRows(new.waiting, asking: asking) + new.finished).filter { !before.contains($0.id) }.compactMap { item -> String? in
            let title = ThreadListRules.title(of: item.thread)
            return switch item {
            case .approval: "\(ConversationActivity.needsOKWords): \(title)"
            case .problem: "\(ConversationActivity.brokenWords): \(title)"
            case .paused: "Paused: \(title)"
            case .finished: "\(ThreadListRules.replyDetail(agentName: item.thread.agentName)): \(title)"
            case .moving: nil
            }
        }
        return said.isEmpty ? nil : said.joined(separator: ". ")
    }

    /// Waiting for you's rows while an approval is being asked on the
    /// page itself: without the row of the thread that asked it, whose
    /// approval the block above them shows, with the thread's name.
    static func waitingRows(_ waiting: [ActivityItem], asking approval: ToolApproval?) -> [ActivityItem] {
        guard let approval, approval.isOfATurn else { return waiting }
        return waiting.filter { $0 != .approval($0.thread) || $0.thread.id != approval.threadID }
    }

    /// Whether anything waits for the person.
    static func isAnythingWaiting(in activity: [String: ConversationActivity]) -> Bool {
        activity.values.contains { $0.isWaiting }
    }
}
