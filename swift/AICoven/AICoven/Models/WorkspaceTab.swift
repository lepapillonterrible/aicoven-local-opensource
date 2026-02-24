import Foundation

/// Type of workspace tab
enum WorkspaceTabType: Equatable {
    case thread(Thread)
    case profile
    case settings
    case providerKeys
    case budget
    case connectedApps
    case usage
    case addRole(covenId: String)
    case editRole(roleId: String)
    case memoryList(covenId: String?)
    case memoryProposals(covenId: String?)
    case addMemory(covenId: String?)
    case editMemory(memoryId: String, covenId: String?)
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
        case let (.addRole(c1), .addRole(c2)):
            c1 == c2
        case let (.editRole(r1), .editRole(r2)):
            r1 == r2
        case let (.memoryList(c1), .memoryList(c2)):
            c1 == c2
        case let (.memoryProposals(c1), .memoryProposals(c2)):
            c1 == c2
        case let (.addMemory(c1), .addMemory(c2)):
            c1 == c2
        case let (.editMemory(m1, c1), .editMemory(m2, c2)):
            m1 == m2 && c1 == c2
        case (.profile, .profile),
             (.settings, .settings),
             (.providerKeys, .providerKeys),
             (.budget, .budget),
             (.usage, .usage),
             (.connectedApps, .connectedApps),
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
        case .profile: "profile"
        case .settings: "settings"
        case .providerKeys: "provider_keys"
        case .budget: "budget"
        case .connectedApps: "connected_apps"
        case .usage: "usage"
        case .addRole: "add_role"
        case .editRole: "edit_role"
        case .memoryList: "memory_list"
        case .memoryProposals: "memory_proposals"
        case .addMemory: "add_memory"
        case .editMemory: "edit_memory"
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

    /// Create a tab for profile
    static var profile: WorkspaceTab {
        WorkspaceTab(
            id: "profile",
            type: .profile,
            title: "Profile"
        )
    }

    /// Create a tab for settings
    static var settings: WorkspaceTab {
        WorkspaceTab(
            id: "settings",
            type: .settings,
            title: "Settings"
        )
    }

    /// Create a tab for provider keys
    static var providerKeys: WorkspaceTab {
        WorkspaceTab(
            id: "provider-keys",
            type: .providerKeys,
            title: "Provider Keys"
        )
    }

    /// Create a tab for budgets
    static var budget: WorkspaceTab {
        WorkspaceTab(
            id: "budget",
            type: .budget,
            title: "Budgets"
        )
    }

    /// Create a tab for connected apps
    static var connectedApps: WorkspaceTab {
        WorkspaceTab(
            id: "connected-apps",
            type: .connectedApps,
            title: "Connected Apps"
        )
    }

    /// Create a tab for usage dashboard
    static var usage: WorkspaceTab {
        WorkspaceTab(
            id: "usage",
            type: .usage,
            title: "Budgets & Usage"
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

    /// Create a tab for viewing memory list
    static func memoryList(covenId: String?) -> WorkspaceTab {
        WorkspaceTab(
            id: "memory-list-\(covenId ?? "personal")",
            type: .memoryList(covenId: covenId),
            title: covenId != nil ? "Memory" : "Personal Memory"
        )
    }

    /// Create a tab for viewing memory proposals
    static func memoryProposals(covenId: String?) -> WorkspaceTab {
        WorkspaceTab(
            id: "memory-proposals-\(covenId ?? "personal")",
            type: .memoryProposals(covenId: covenId),
            title: "Memory Proposals"
        )
    }

    /// Create a tab for adding a new memory
    static func addMemory(covenId: String?) -> WorkspaceTab {
        WorkspaceTab(
            id: "add-memory-\(covenId ?? "personal")",
            type: .addMemory(covenId: covenId),
            title: "New Memory"
        )
    }

    /// Create a tab for editing a memory
    static func editMemory(memoryId: String, memoryTitle: String, covenId: String?) -> WorkspaceTab {
        WorkspaceTab(
            id: "edit-memory-\(memoryId)",
            type: .editMemory(memoryId: memoryId, covenId: covenId),
            title: "Edit \(memoryTitle)"
        )
    }

    /// Tab for personal Strix (default assistant) settings in the personal workspace
    static var personalStrix: WorkspaceTab {
        WorkspaceTab(
            id: "personal-strix",
            type: .personalStrixSettings,
            title: "Strix Settings"
        )
    }

    /// Tab for the in-app purchase store
    static var store: WorkspaceTab {
        WorkspaceTab(
            id: "store",
            type: .store,
            title: "Upgrade"
        )
    }

    /// Tab for Terms of Service
    static var terms: WorkspaceTab {
        WorkspaceTab(
            id: "terms",
            type: .terms,
            title: "Terms & Conditions"
        )
    }

    /// Tab for Privacy Policy
    static var privacy: WorkspaceTab {
        WorkspaceTab(
            id: "privacy",
            type: .privacy,
            title: "Privacy Policy"
        )
    }
}
