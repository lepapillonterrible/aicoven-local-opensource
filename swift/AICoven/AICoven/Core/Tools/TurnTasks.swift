import Foundation

/// What one turn does with tasks: how many it has made and changed, so
/// that a turn does only so much. Only a turn that is offered the task
/// tools has one. Sendable by hand, under `lock`.
final nonisolated class TurnTasks: @unchecked Sendable {
    /// The most tasks a turn makes.
    static let mostMade = 10
    /// The most changes a turn makes to tasks (one marked done, moved, or
    /// given another due day).
    static let mostChanges = 20

    private let lock = NSLock()
    private var makings = 0
    private var changes = 0

    /// Takes one of the turn's makings; false if it has none left.
    func takeAMaking() -> Bool {
        lock.withLock {
            guard makings < Self.mostMade else { return false }
            makings += 1
            return true
        }
    }

    /// A making that made nothing is given back.
    func giveBackAMaking() {
        lock.withLock { makings -= 1 }
    }

    /// Takes one of the turn's changes; false if it has none left.
    func takeAChange() -> Bool {
        lock.withLock {
            guard changes < Self.mostChanges else { return false }
            changes += 1
            return true
        }
    }

    /// A change that changed nothing is given back.
    func giveBackAChange() {
        lock.withLock { changes -= 1 }
    }
}
