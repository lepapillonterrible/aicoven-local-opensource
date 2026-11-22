import Foundation

/// What one turn does with assets: who its agent is, so that an asset it
/// makes says who made it, and how much it has made and changed, so that a
/// turn does only so much. Sendable by hand, under `lock`.
final nonisolated class TurnAssets: @unchecked Sendable {
    /// The agent an asset made in one of Strix's turns says made it:
    /// Strix is no stored agent here.
    static let strix = "strix"
    /// The most assets a turn makes.
    static let mostMade = 5
    /// The most changes a turn makes to assets (a draft changed, a file
    /// added, an asset proposed).
    static let mostChanges = 20

    /// The agent the turn is for: a coven's agent, or Strix.
    let agentID: String
    private let lock = NSLock()
    private var madeIDs: [String] = []
    private var makings = 0
    private var changes = 0

    init(agentID: String?) {
        self.agentID = agentID ?? Self.strix
    }

    /// The assets the turn has made, in the order it made them.
    var made: [String] {
        lock.withLock { madeIDs }
    }

    /// Takes one of the turn's makings; false if it has none left.
    func takeAMaking() -> Bool {
        lock.withLock {
            guard makings < Self.mostMade else { return false }
            makings += 1
            return true
        }
    }

    /// The asset the making came to; or, with none, the making given
    /// back: it made nothing.
    func made(_ assetID: String?) {
        lock.withLock {
            if let assetID {
                madeIDs.append(assetID)
            } else {
                makings -= 1
            }
        }
    }

    /// Takes one of the turn's changes; false if it has none left.
    func takeAChange() -> Bool {
        lock.withLock {
            guard changes < Self.mostChanges else { return false }
            changes += 1
            return true
        }
    }
}
