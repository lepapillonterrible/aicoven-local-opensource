import Foundation

/// Coven (collaborative workspace) model — local-first version.
/// Simplified from cloud: no ownerId/tenantId/memberIds (single-user local).
struct Coven: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String?
    let avatar: String?
    let settings: CovenSettings?
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, description, avatar, settings
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Memberwise initializer for testing/previews
    init(
        id: String,
        name: String,
        description: String? = nil,
        avatar: String? = nil,
        settings: CovenSettings? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.avatar = avatar
        self.settings = settings
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Custom decoder to handle optional fields and defaults
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        avatar = try container.decodeIfPresent(String.self, forKey: .avatar)

        // Decode settings - can be object or JSON string
        if let settingsObj = try? container.decodeIfPresent(CovenSettings.self, forKey: .settings) {
            settings = settingsObj
        } else if let settingsStr = try? container.decodeIfPresent(String.self, forKey: .settings),
                  let settingsData = settingsStr.data(using: .utf8),
                  let settingsObj = try? JSONDecoder().decode(CovenSettings.self, from: settingsData) {
            settings = settingsObj
        } else {
            settings = nil
        }

        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

/// Coven settings
struct CovenSettings: Codable, Hashable {
    let defaultMemoryPolicy: [String: String]?
    let budgetCaps: [String: Double]?
    let autoRouteEnabled: Bool?
    /// Which connections the coven's agents may use. Nil until the coven
    /// has made a choice: until then everything connected is used.
    let connections: CovenConnections?
    /// The coven's icon: an SF Symbol's name and the key of one of the
    /// twelve tints (`IconTint`). Nil for a coven made before covens had
    /// icons, which shows a house on sand.
    let iconSymbol: String?
    let iconTint: String?

    enum CodingKeys: String, CodingKey {
        case defaultMemoryPolicy = "default_memory_policy"
        case budgetCaps = "budget_caps"
        case autoRouteEnabled = "auto_route_enabled"
        case connections
        case iconSymbol = "icon_symbol"
        case iconTint = "icon_tint"
    }

    init(
        defaultMemoryPolicy: [String: String]? = nil,
        budgetCaps: [String: Double]? = nil,
        autoRouteEnabled: Bool? = nil,
        connections: CovenConnections? = nil,
        iconSymbol: String? = nil,
        iconTint: String? = nil
    ) {
        self.defaultMemoryPolicy = defaultMemoryPolicy
        self.budgetCaps = budgetCaps
        self.autoRouteEnabled = autoRouteEnabled
        self.connections = connections
        self.iconSymbol = iconSymbol
        self.iconTint = iconTint
    }

    /// As stored. A choice of connections that cannot be read does not
    /// hide the other settings: it reads here as none, and is refused
    /// where it matters (`CovenRepository.connections(ofCoven:for:)`, which
    /// reads what is stored and grants nothing of what it cannot read).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultMemoryPolicy = try container.decodeIfPresent([String: String].self, forKey: .defaultMemoryPolicy)
        budgetCaps = try container.decodeIfPresent([String: Double].self, forKey: .budgetCaps)
        autoRouteEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoRouteEnabled)
        connections = try? container.decodeIfPresent(CovenConnections.self, forKey: .connections)
        // An icon that cannot be read is none: the coven shows the default.
        iconSymbol = (try? container.decodeIfPresent(String.self, forKey: .iconSymbol)) ?? nil
        iconTint = (try? container.decodeIfPresent(String.self, forKey: .iconTint)) ?? nil
    }
}

extension Coven {
    /// The coven's symbol, where it has one that can be an SF Symbol's
    /// name (see `IconRules.isSymbolName`).
    var iconSymbol: String? {
        settings?.iconSymbol.flatMap { IconRules.isSymbolName($0) ? $0 : nil }
    }

    /// The tint the coven wears; nil when none is stored or the key is
    /// one this app does not know.
    var iconTintValue: IconTint? {
        settings?.iconTint.flatMap(IconTint.init(rawValue:))
    }
}

/// What an icon's stored symbol may be.
nonisolated enum IconRules {
    /// Whether text can be an SF Symbol's name: 1 to 64 of the lower-case
    /// letters, digits and dots such names are written in.
    static func isSymbolName(_ name: String) -> Bool {
        guard (1 ... 64).contains(name.utf8.count) else { return false }
        return name.utf8.allSatisfy { byte in
            (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: ".")
        }
    }
}

/// AI role/agent configuration
struct Role: Codable, Identifiable, Hashable {
    let id: String
    let covenId: String
    let name: String
    let emoji: String?
    let description: String?
    let systemPrompt: String?
    let model: String?
    let provider: String?
    let providerAccountId: String?
    let temperature: Double?
    let maxTokens: Int?
    let settings: RoleSettings?
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case covenId = "coven_id"
        case name, emoji, description
        case systemPrompt = "system_prompt"
        case model, provider
        case providerAccountId = "provider_account_id"
        case temperature
        case maxTokens = "max_tokens"
        case settings
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Role settings with flexible nested structure
struct RoleSettings: Codable, Hashable {
    let toolConfig: [String: AnyJSONValue]?
    let allowedTools: [String]?
    let collaboratorRoleIds: [String]?
    let autonomousMode: Bool?
    let autonomousMaxSteps: Int?
    /// Maximum number of tasks the planner will execute per turn in
    /// `plan_and_execute` mode (maps to settings.planner_max_tasks).
    let plannerMaxTasks: Int?
    /// Soft wall-clock budget in seconds for `plan_and_execute` flows
    /// (maps to settings.planner_max_seconds).
    let plannerMaxSeconds: Double?
    /// The agent's face: an SF Symbol's name and the key of one of the
    /// twelve tints (`IconTint`).
    let iconSymbol: String?
    let iconTint: String?

    enum CodingKeys: String, CodingKey {
        case iconSymbol = "icon_symbol"
        case iconTint = "icon_tint"
        case toolConfig = "tool_config"
        case allowedTools = "allowed_tools"
        case collaboratorRoleIds = "collaborator_role_ids"
        case autonomousMode = "autonomous_mode"
        case autonomousMaxSteps = "autonomous_max_steps"
        case plannerMaxTasks = "planner_max_tasks"
        case plannerMaxSeconds = "planner_max_seconds"
    }

    /// Custom decoder to handle any additional known fields
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolConfig = try container.decodeIfPresent([String: AnyJSONValue].self, forKey: .toolConfig)
        allowedTools = try container.decodeIfPresent([String].self, forKey: .allowedTools)
        collaboratorRoleIds = try container.decodeIfPresent([String].self, forKey: .collaboratorRoleIds)
        autonomousMode = try container.decodeIfPresent(Bool.self, forKey: .autonomousMode)
        autonomousMaxSteps = try container.decodeIfPresent(Int.self, forKey: .autonomousMaxSteps)
        plannerMaxTasks = try container.decodeIfPresent(Int.self, forKey: .plannerMaxTasks)
        plannerMaxSeconds = try container.decodeIfPresent(Double.self, forKey: .plannerMaxSeconds)
        // A face that cannot be read is none: the agent shows the default.
        iconSymbol = (try? container.decodeIfPresent(String.self, forKey: .iconSymbol)) ?? nil
        iconTint = (try? container.decodeIfPresent(String.self, forKey: .iconTint)) ?? nil
    }

    /// Explicit initializer for creating instances
    init(
        toolConfig: [String: AnyJSONValue]? = nil,
        allowedTools: [String]? = nil,
        collaboratorRoleIds: [String]? = nil,
        autonomousMode: Bool? = nil,
        autonomousMaxSteps: Int? = nil,
        plannerMaxTasks: Int? = nil,
        plannerMaxSeconds: Double? = nil,
        iconSymbol: String? = nil,
        iconTint: String? = nil
    ) {
        self.iconSymbol = iconSymbol
        self.iconTint = iconTint
        self.toolConfig = toolConfig
        self.allowedTools = allowedTools
        self.collaboratorRoleIds = collaboratorRoleIds
        self.autonomousMode = autonomousMode
        self.autonomousMaxSteps = autonomousMaxSteps
        self.plannerMaxTasks = plannerMaxTasks
        self.plannerMaxSeconds = plannerMaxSeconds
    }
}

extension Role {
    /// The agent's symbol: the one stored, or, for an agent made when
    /// agents had an emoji, the symbol that emoji was replaced by; nil
    /// where there is neither (the face then shows `cpu`).
    var iconSymbol: String? {
        if let stored = settings?.iconSymbol, IconRules.isSymbolName(stored) { return stored }
        return AgentFace.symbol(forEmoji: emoji)
    }

    /// The tint this agent wears; nil when none is stored or the key is
    /// one this app does not know.
    var iconTintValue: IconTint? {
        settings?.iconTint.flatMap(IconTint.init(rawValue:))
    }
}

/// Provider account (BYOK) model
struct ProviderAccount: Codable, Identifiable {
    let id: String
    let userId: String?
    let provider: String // Can be AIProvider enum or string
    let accountName: String?
    let displayName: String
    let status: String
    let scopes: [String]
    let defaultModel: String?
    let baseURL: String?
    let isHealthy: Bool?
    let lastHealthCheck: Date?
    let lastHealthCheckAt: Date?
    let quotaHint: String?
    let createdAt: Date?

    /// Whether this account represents a local provider (e.g. Ollama) that
    /// doesn't require an API key and talks to a server on the user's machine.
    var isLocalProvider: Bool {
        let p = provider.lowercased()
        return p == "ollama" || p == "mlx"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case provider
        case accountName = "account_name"
        case displayName = "display_name"
        case status
        case scopes
        case defaultModel = "default_model"
        case baseURL = "base_url"
        case isHealthy = "is_healthy"
        case lastHealthCheck = "last_health_check"
        case lastHealthCheckAt = "last_health_check_at"
        case quotaHint = "quota_hint"
        case createdAt = "created_at"
    }
}

/// Initialization status for a provider account.
///
/// This is a lightweight view of the `/provider-accounts/{id}/initialization`
/// response that focuses only on the fields the Swift client needs for
/// validating model names (model_metadata).
struct ProviderInitializationStatus: Codable {
    struct ModelMetadata: Codable, Identifiable {
        let id: String
        let name: String?
        let provider: String?
        let contextLength: Int?
        /// Whether the provider's own list says the model takes pictures.
        /// Only OpenRouter's is read for it (false where an entry does not
        /// say); nil for every other provider's. Set where a list is
        /// read, not decoded from one.
        var takesImages: Bool?

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case provider
            case contextLength = "context_length"
        }
    }

    let providerAccountId: String
    let status: String
    let modelMetadata: [ModelMetadata]

    enum CodingKeys: String, CodingKey {
        case providerAccountId = "provider_account_id"
        case status
        case modelMetadata = "model_metadata"
    }
}

/// AI provider enum
enum AIProvider: String, Codable {
    case openai
    case anthropic
    case google
    case mistral
    case ollama
    case mlx
}
