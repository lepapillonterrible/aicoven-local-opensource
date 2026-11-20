import Foundation

/// A new thread's title, from its first message, as the cloud app names
/// one: the message's first line, its runs of white space as one space, 60
/// characters at most, cut at a word; "New Thread" for a message that says
/// nothing.
nonisolated enum ThreadTitleGenerator {
    static let longest = 60

    static func title(from userMessage: String) -> String {
        let firstLine = userMessage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
        let collapsed = firstLine
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "New Thread" }
        guard collapsed.count > longest else { return collapsed }
        let cut = String(collapsed.prefix(longest))
        if let lastSpace = cut.lastIndex(of: " ") {
            return String(cut[cut.startIndex ..< lastSpace])
        }
        return cut
    }
}

/// Who a new thread in a coven goes to.
nonisolated enum NewThreadRules {
    /// The agent a new thread goes to unless the person chooses another:
    /// the one asked for by name if it is still one of the coven's, else
    /// the one last used in the coven if it still is, else the coven's
    /// first. None for a coven with no agents: Strix answers there.
    static func recipient(asked: String? = nil, lastUsed: String?, among roles: [Role]) -> Role? {
        if let asked, let role = roles.first(where: { $0.id == asked }) { return role }
        if let lastUsed, let role = roles.first(where: { $0.id == lastUsed }) { return role }
        return roles.first
    }
}

/// The agent each coven's last new thread went to, kept on this device for
/// each account: one list of coven ids and agent ids in the preferences,
/// under the account's own key.
struct LastUsedAgentStore {
    private let defaults: UserDefaults
    static let key = "lastUsedAgents"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func agents(for account: String) -> [String: String] {
        defaults.dictionary(forKey: UserScope.scopedKey(Self.key, for: account)) as? [String: String] ?? [:]
    }

    /// The agent `account`'s last new thread in the coven went to.
    func agentID(inCoven covenID: String, for account: String) -> String? {
        agents(for: account)[covenID]
    }

    /// Notes the agent `account`'s new thread in the coven went to.
    func set(_ agentID: String, inCoven covenID: String, for account: String) {
        var agents = agents(for: account)
        agents[covenID] = agentID
        defaults.set(agents, forKey: UserScope.scopedKey(Self.key, for: account))
    }

    /// Forgets what `account` last used: the account is gone.
    func remove(for account: String) {
        defaults.removeObject(forKey: UserScope.scopedKey(Self.key, for: account))
    }
}
