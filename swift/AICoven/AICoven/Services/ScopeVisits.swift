import Foundation

/// When the person was last in each scope (Strix, a coven), kept on this
/// device for each account: one list of scopes and times in the
/// preferences, under the account's own key. The cloud app keeps it on its
/// server; here it is this device's own.
struct ScopeVisitStore {
    private let defaults: UserDefaults
    static let key = "scopeVisits"
    /// The name Strix goes by in the list (a coven goes by its id).
    static let strix = "strix"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private static func name(of scope: ShellScope) -> String {
        scope.covenID ?? strix
    }

    private func visits(for account: String) -> [String: Date] {
        defaults.dictionary(forKey: UserScope.scopedKey(Self.key, for: account)) as? [String: Date] ?? [:]
    }

    /// When `account` was last in `scope`; nil if never, on this device.
    func lastVisit(in scope: ShellScope, for account: String) -> Date? {
        visits(for: account)[Self.name(of: scope)]
    }

    /// Notes that `account` is in `scope` at `now`, and gives back when
    /// they were last there before.
    @discardableResult
    func arrive(in scope: ShellScope, at now: Date, for account: String) -> Date? {
        var visits = visits(for: account)
        let before = visits[Self.name(of: scope)]
        visits[Self.name(of: scope)] = now
        defaults.set(visits, forKey: UserScope.scopedKey(Self.key, for: account))
        return before
    }

    /// Forgets `account`'s visits: the account is gone.
    func remove(for account: String) {
        defaults.removeObject(forKey: UserScope.scopedKey(Self.key, for: account))
    }
}
