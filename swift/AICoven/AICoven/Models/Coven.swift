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
    
    // Memberwise initializer for testing/previews
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
    
    // Custom decoder to handle optional fields and defaults
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
    
    enum CodingKeys: String, CodingKey {
        case defaultMemoryPolicy = "default_memory_policy"
        case budgetCaps = "budget_caps"
        case autoRouteEnabled = "auto_route_enabled"
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
    
    enum CodingKeys: String, CodingKey {
        case toolConfig = "tool_config"
        case allowedTools = "allowed_tools"
        case collaboratorRoleIds = "collaborator_role_ids"
        case autonomousMode = "autonomous_mode"
        case autonomousMaxSteps = "autonomous_max_steps"
        case plannerMaxTasks = "planner_max_tasks"
        case plannerMaxSeconds = "planner_max_seconds"
    }
    
    // Custom decoder to handle any additional known fields
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolConfig = try container.decodeIfPresent([String: AnyJSONValue].self, forKey: .toolConfig)
        allowedTools = try container.decodeIfPresent([String].self, forKey: .allowedTools)
        collaboratorRoleIds = try container.decodeIfPresent([String].self, forKey: .collaboratorRoleIds)
        autonomousMode = try container.decodeIfPresent(Bool.self, forKey: .autonomousMode)
        autonomousMaxSteps = try container.decodeIfPresent(Int.self, forKey: .autonomousMaxSteps)
        plannerMaxTasks = try container.decodeIfPresent(Int.self, forKey: .plannerMaxTasks)
        plannerMaxSeconds = try container.decodeIfPresent(Double.self, forKey: .plannerMaxSeconds)
    }
    
    // Explicit initializer for creating instances
    init(
        toolConfig: [String: AnyJSONValue]? = nil,
        allowedTools: [String]? = nil,
        collaboratorRoleIds: [String]? = nil,
        autonomousMode: Bool? = nil,
        autonomousMaxSteps: Int? = nil,
        plannerMaxTasks: Int? = nil,
        plannerMaxSeconds: Double? = nil
    ) {
        self.toolConfig = toolConfig
        self.allowedTools = allowedTools
        self.collaboratorRoleIds = collaboratorRoleIds
        self.autonomousMode = autonomousMode
        self.autonomousMaxSteps = autonomousMaxSteps
        self.plannerMaxTasks = plannerMaxTasks
        self.plannerMaxSeconds = plannerMaxSeconds
    }
}


/// Provider account (BYOK) model
struct ProviderAccount: Codable, Identifiable {
    let id: String
    let userId: String?
    let provider: String  // Can be AIProvider enum or string
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
        provider.lowercased() == "ollama"
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
}
