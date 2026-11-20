import Foundation

/// The person's own order for their covens, used by the switcher. Strix,
/// which is no stored coven here, is always first and is not among them.
/// The order is kept on this device, for each account (`CovenOrderStore`);
/// a coven the saved order does not name yet follows the others, the
/// oldest first.
nonisolated enum CovenOrder {
    static func ordered(_ covens: [Coven], by ids: [String]) -> [Coven] {
        let position = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let known = covens
            .filter { position[$0.id] != nil }
            .sorted { (position[$0.id] ?? 0) < (position[$1.id] ?? 0) }
        let new = covens
            .filter { position[$0.id] == nil }
            .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
        return known + new
    }

    /// The ids of `covens` (in order) with `covenID` moved to `index`. A
    /// coven that is not among them moves nothing.
    static func moving(_ covenID: String, to index: Int, in covens: [Coven]) -> [String] {
        var ids = covens.map(\.id)
        guard let from = ids.firstIndex(of: covenID) else { return ids }
        ids.remove(at: from)
        ids.insert(covenID, at: min(max(index, 0), ids.count))
        return ids
    }

    /// Whether `covenID` can move one place up, or down, among `covens`.
    static func canMove(_ covenID: String, up: Bool, in covens: [Coven]) -> Bool {
        guard let index = covens.firstIndex(where: { $0.id == covenID }) else { return false }
        return up ? index > 0 : index < covens.count - 1
    }
}

/// Where the order of an account's covens is kept on this device: a list
/// of coven ids in its preferences, under the account's own key.
struct CovenOrderStore {
    private let defaults: UserDefaults
    static let key = "covenOrder"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The saved order of `account`'s covens; empty where none is saved.
    func ids(for account: String) -> [String] {
        defaults.stringArray(forKey: UserScope.scopedKey(Self.key, for: account)) ?? []
    }

    /// Saves `ids` as the order of `account`'s covens.
    func save(_ ids: [String], for account: String) {
        defaults.set(ids, forKey: UserScope.scopedKey(Self.key, for: account))
    }
}
