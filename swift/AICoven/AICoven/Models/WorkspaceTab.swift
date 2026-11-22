import Foundation

/// Type of workspace tab
enum WorkspaceTabType: Equatable {
    case thread(Thread)
    /// A thread not made yet: it is made when its first message is sent.
    /// In a coven, or in Strix (no coven).
    case draftThread(covenId: String?)
    case profile
    case settings
    case providerKeys
    case budget
    case connectedApps
    case mcpServers
    case usage
    case addRole(covenId: String)
    case editRole(roleId: String)
    /// A coven's agents.
    case covenAgents(covenId: String)
    /// Which of the person's connections a coven's agents may use.
    case covenConnections(covenId: String)
    case memoryList(covenId: String?)
    /// A scope's assets: a coven's, or Strix's (no coven).
    case assets(covenId: String?)
    /// Personal Strix settings tab (personal default assistant)
    case personalStrixSettings
    /// In-app purchase store tab
    case store
    /// Terms of Service tab
    case terms
    /// Privacy Policy tab
    case privacy

    static func == (lhs: WorkspaceTabType, rhs: WorkspaceTabType) -> Bool {
        switch (lhs, rhs) {
        case let (.thread(t1), .thread(t2)):
            t1.id == t2.id
        case let (.draftThread(c1), .draftThread(c2)):
            c1 == c2
        case let (.addRole(c1), .addRole(c2)):
            c1 == c2
        case let (.editRole(r1), .editRole(r2)):
            r1 == r2
        case let (.covenAgents(c1), .covenAgents(c2)):
            c1 == c2
        case let (.covenConnections(c1), .covenConnections(c2)):
            c1 == c2
        case let (.memoryList(c1), .memoryList(c2)):
            c1 == c2
        case let (.assets(c1), .assets(c2)):
            c1 == c2
        case (.profile, .profile),
             (.settings, .settings),
             (.providerKeys, .providerKeys),
             (.budget, .budget),
             (.usage, .usage),
             (.connectedApps, .connectedApps),
             (.mcpServers, .mcpServers),
             (.personalStrixSettings, .personalStrixSettings),
             (.store, .store),
             (.terms, .terms),
             (.privacy, .privacy):
            true
        default:
            false
        }
    }

    var analyticsName: String {
        switch self {
        case .thread: "thread"
        case .draftThread: "draft_thread"
        case .profile: "profile"
        case .settings: "settings"
        case .providerKeys: "provider_keys"
        case .budget: "budget"
        case .connectedApps: "connected_apps"
        case .mcpServers: "mcp_servers"
        case .usage: "usage"
        case .addRole: "add_role"
        case .editRole: "edit_role"
        case .covenAgents: "coven_agents"
        case .covenConnections: "coven_connections"
        case .memoryList: "memory_list"
        case .assets: "assets"
        case .personalStrixSettings: "personal_strix_settings"
        case .store: "store"
        case .terms: "terms"
        case .privacy: "privacy"
        }
    }
}

/// Workspace tab model
struct WorkspaceTab: Identifiable, Equatable {
    let id: String
    let type: WorkspaceTabType
    var title: String

    static func == (lhs: WorkspaceTab, rhs: WorkspaceTab) -> Bool {
        lhs.id == rhs.id
    }

    /// Create a tab for a thread
    static func thread(_ thread: Thread) -> WorkspaceTab {
        WorkspaceTab(
            id: thread.id,
            type: .thread(thread),
            title: thread.title ?? "Untitled"
        )
    }

    /// Create a tab for MCP Servers
    static var mcpServers: WorkspaceTab {
        WorkspaceTab(
            id: "mcp-servers",
            type: .mcpServers,
            title: "MCP Servers"
        )
    }

    /// Create a tab for adding a new role
    static func addRole(covenId: String) -> WorkspaceTab {
        WorkspaceTab(
            id: "add-role-\(covenId)",
            type: .addRole(covenId: covenId),
            title: "New Agent Role"
        )
    }

    /// Create a tab for editing a role
    static func editRole(roleId: String, roleName: String) -> WorkspaceTab {
        WorkspaceTab(
            id: "edit-role-\(roleId)",
            type: .editRole(roleId: roleId),
            title: "Edit \(roleName)"
        )
    }

    /// A thread not made yet, in a coven or in Strix.
    static func draftThread(covenId: String?) -> WorkspaceTab {
        WorkspaceTab(id: "draft-thread-\(covenId ?? "strix")", type: .draftThread(covenId: covenId), title: "New Thread")
    }

    /// A coven's agents.
    static func covenAgents(covenId: String) -> WorkspaceTab {
        WorkspaceTab(id: "coven-agents-\(covenId)", type: .covenAgents(covenId: covenId), title: "Agents")
    }

    /// Which of the person's connections a coven's agents may use.
    static func covenConnections(covenId: String) -> WorkspaceTab {
        WorkspaceTab(id: "coven-connections-\(covenId)", type: .covenConnections(covenId: covenId), title: "Connections")
    }

    /// The thread this is the place of, if it is a thread's.
    var threadValue: Thread? {
        if case let .thread(thread) = type { return thread }
        return nil
    }

    /// Create a tab for viewing memory list
    static func memoryList(covenId: String?) -> WorkspaceTab {
        WorkspaceTab(
            id: "memory-list-\(covenId ?? "personal")",
            type: .memoryList(covenId: covenId),
            title: covenId != nil ? "Memory" : "Personal Memory"
        )
    }

    /// A scope's Assets place.
    static func assets(covenId: String?) -> WorkspaceTab {
        WorkspaceTab(id: "assets-\(covenId ?? "personal")", type: .assets(covenId: covenId), title: "Assets")
    }

    /// Strix's Agents place: Strix itself, listed as an agent is.
    static var personalStrix: WorkspaceTab {
        WorkspaceTab(
            id: "personal-strix",
            type: .personalStrixSettings,
            title: "Agents"
        )
    }

}
