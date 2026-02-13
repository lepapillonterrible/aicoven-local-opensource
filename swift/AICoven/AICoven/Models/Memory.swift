import Foundation

/// Memory entry model (MemoryChunk in API)
struct Memory: Codable, Identifiable {
    let id: String
    let covenId: String?
    let userId: String?
    let roleId: String?
    let scope: MemoryScope
    let title: String?
    let content: String
    let tags: [String]?
    let isPinned: Bool
    let isApproved: Bool
    let createdAt: Date
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case covenId = "coven_id"
        case userId = "user_id"
        case roleId = "agent_role_id"
        case scope, title, content, tags
        case isPinned = "pinned"
        case isApproved = "approved"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Memory scope enum
enum MemoryScope: String, Codable {
    case user
    case coven
    case agent
}
