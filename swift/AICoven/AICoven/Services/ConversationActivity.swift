import Foundation

/// What a thread is doing, as its row in a list says it: from the turn
/// this app is running in it, else how its latest turn stands as stored,
/// an unsent message kept for it, and a reply not yet seen. As the cloud
/// app's rows say it, without what only a server knows.
nonisolated enum ConversationActivity: Equatable {
    /// Work is under way, in the status line's words.
    case moving(String)
    /// The turn waits for the person's OK, in the status line's words.
    case waiting(String)
    /// An agent of the person's own was running the turn when the app
    /// closed: the run went on there, and is followed again when the
    /// thread is opened.
    case paused
    /// The turn stopped on a problem, or the app closed on it.
    case broken(String)
    /// A message the person started here and has not sent.
    case unsent
    /// A reply the person has not seen.
    case unread

    static let needsOKWords = "Needs your OK"
    static let brokenWords = "Stopped on a problem"

    /// A turn this app is running, as far as a row says it.
    struct Turn: Equatable {
        /// The status line's words.
        var message: String
        var isStopping = false
    }

    /// What a thread is doing. A turn's state outranks an unsent message,
    /// which outranks an unread reply. `turn` is the turn this app runs in
    /// it now, `needsOK` whether that turn waits to be allowed something,
    /// `ended` how the last turn this app ran in it ended (which is newer
    /// than what `marks`, read from the store, may say). A thread on
    /// screen has no unsent message yet (it is being written) and no
    /// unread reply (it is being read as it arrives).
    static func of(
        turn: Turn?, needsOK: Bool, ended: TurnOutcome?, marks: ThreadMarks?, hasUnsent: Bool, isShown: Bool
    ) -> ConversationActivity? {
        if let turn {
            // A Stop outranks the approval it interrupted.
            return needsOK && !turn.isStopping ? .waiting(needsOKWords) : .moving(turn.message)
        }
        switch ended ?? marks?.latestTurn {
        case .failed, .interrupted:
            return .broken(brokenWords)
        case .running:
            // Recorded as running, and not run here: the app closed on it.
            // An agent's own run went on; any other is lost.
            return marks?.latestTurnHasRun == true ? .paused : .broken(brokenWords)
        case .completed, .cancelled, nil:
            break
        }
        if isShown { return nil }
        if hasUnsent { return .unsent }
        return marks?.isUnread == true ? .unread : nil
    }

    /// Whether the thread is still open: work moving, paused or broken,
    /// something waiting for the person, or an unsent message. An unread
    /// reply alone is not.
    var isStillOpen: Bool {
        self != .unread
    }

    var isWaiting: Bool {
        if case .waiting = self { return true }
        return false
    }

    /// The caption line under the row's title; nil for an unread row,
    /// which, like a finished one, is one line.
    var caption: String? {
        switch self {
        case let .moving(words), let .waiting(words), let .broken(words): words
        case .paused: "Paused"
        case .unsent: "Unsent message"
        case .unread: nil
        }
    }

    /// What VoiceOver reads after the row's title.
    var accessibilityWords: String {
        caption ?? "Unread"
    }
}
