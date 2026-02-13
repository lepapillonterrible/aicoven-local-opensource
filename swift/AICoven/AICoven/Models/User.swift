import Foundation

/// User profile model
struct User: Codable, Identifiable {
    let id: String
    let email: String
    let name: String?
    let profile: UserProfile?
    let settings: UserSettings?
    let createdAt: Date?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, email, name, profile, settings
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Memberwise initializer
    init(id: String, email: String, name: String?, profile: UserProfile?, settings: UserSettings?, createdAt: Date?, updatedAt: Date?) {
        self.id = id
        self.email = email
        self.name = name
        self.profile = profile
        self.settings = settings
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Custom decoder to handle JSONB fields that come as strings
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        email = try container.decode(String.self, forKey: .email)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)

        // Decode profile - can be object or JSON string
        if let profileObj = try? container.decodeIfPresent(UserProfile.self, forKey: .profile) {
            profile = profileObj
        } else if let profileStr = try? container.decodeIfPresent(String.self, forKey: .profile),
                  let profileData = profileStr.data(using: .utf8),
                  let profileObj = try? JSONDecoder().decode(UserProfile.self, from: profileData) {
            profile = profileObj
        } else {
            profile = nil
        }

        // Decode settings - can be object or JSON string
        if let settingsObj = try? container.decodeIfPresent(UserSettings.self, forKey: .settings) {
            settings = settingsObj
        } else if let settingsStr = try? container.decodeIfPresent(String.self, forKey: .settings),
                  let settingsData = settingsStr.data(using: .utf8),
                  let settingsObj = try? JSONDecoder().decode(UserSettings.self, from: settingsData) {
            settings = settingsObj
        } else {
            settings = nil
        }
    }
}

/// User profile metadata (stored as JSONB in database)
struct UserProfile: Codable {
    let organization: String?
    let role: String?
    let bio: String?
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case organization, role, bio
        case avatarUrl = "avatar_url"
    }
}

/// User application settings
struct UserSettings: Codable {
    let theme: String?
    let language: String?
    let notifications: Bool?
    let emailNotifications: Bool?
    /// Whether this user has completed FTUE onboarding (account-level).
    let hasCompletedOnboarding: Bool?
    let animatedBackgrounds: Bool?

    enum CodingKeys: String, CodingKey {
        case theme, language, notifications
        case emailNotifications = "email_notifications"
        case hasCompletedOnboarding = "has_completed_onboarding"
        case animatedBackgrounds = "animated_backgrounds"
    }
}

/// User statistics from backend
struct UserStats: Codable {
    let sessionsCount: Int
    let messagesCount: Int
    let totalCost: Double
    let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case sessionsCount = "sessions_count"
        case messagesCount = "messages_count"
        case totalCost = "total_cost"
        case totalTokens = "total_tokens"
    }
}
