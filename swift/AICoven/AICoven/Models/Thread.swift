import Foundation

/// Thread (conversation/session) model
struct Thread: Codable, Identifiable, Hashable {
    let id: String
    let userId: String
    let covenId: String?
    let title: String?
    let agentId: String?
    let agentName: String?
    let agentModel: String?
    let isPinned: Bool
    let isArchived: Bool
    let messageCount: Int
    let createdAt: Date
    let updatedAt: Date?
    let lastMessageAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title
        case userId = "user_id"
        case covenId = "coven_id"
        case agentId = "agent_id"
        case agentName = "agent_name"
        case agentModel = "agent_model"
        case isPinned = "is_pinned"
        case isArchived = "is_archived"
        case messageCount = "message_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastMessageAt = "last_message_at"
    }

    /// Memberwise initializer for testing/previews
    init(
        id: String,
        userId: String,
        covenId: String?,
        title: String?,
        agentId: String? = nil,
        agentName: String? = nil,
        agentModel: String? = nil,
        isPinned: Bool = false,
        isArchived: Bool = false,
        messageCount: Int = 0,
        createdAt: Date,
        updatedAt: Date?,
        lastMessageAt: Date?
    ) {
        self.id = id
        self.userId = userId
        self.covenId = covenId
        self.title = title
        self.agentId = agentId
        self.agentName = agentName
        self.agentModel = agentModel
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.messageCount = messageCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastMessageAt = lastMessageAt
    }

    /// Custom decoder to handle defaults
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        userId = try container.decode(String.self, forKey: .userId)
        covenId = try container.decodeIfPresent(String.self, forKey: .covenId)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        agentId = try container.decodeIfPresent(String.self, forKey: .agentId)
        agentName = try container.decodeIfPresent(String.self, forKey: .agentName)
        agentModel = try container.decodeIfPresent(String.self, forKey: .agentModel)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        messageCount = try container.decodeIfPresent(Int.self, forKey: .messageCount) ?? 0
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        lastMessageAt = try container.decodeIfPresent(Date.self, forKey: .lastMessageAt)
    }
}

/// Message model
struct Message: Codable, Identifiable {
    let id: String
    let threadId: String
    let roleId: String?
    let role: MessageRole
    let content: String
    let metadata: MessageMetadata?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case threadId = "thread_id"
        case roleId = "role_id"
        case role, content, metadata
        case createdAt = "created_at"
    }
}

/// Message role enum
enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

/// Message metadata (attachments, tool calls, etc.)
struct MessageMetadata: Codable {
    let attachments: [Attachment]?
    let toolCalls: [ToolCall]?
    let model: String?
    let tokensUsed: Int?
    let cost: Double?

    enum CodingKeys: String, CodingKey {
        case attachments
        case toolCalls = "tool_calls"
        case model
        case tokensUsed = "tokens_used"
        case cost
    }
}

/// File attachment model
struct Attachment: Codable, Identifiable {
    let id: String
    let fileName: String
    let fileType: String
    let fileSize: Int
    let url: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fileName = "file_name"
        case fileType = "file_type"
        case fileSize = "file_size"
        case url
    }
}

/// Tool call model
struct ToolCall: Codable {
    let name: String
    let arguments: [String: String]
    let result: String?
}
