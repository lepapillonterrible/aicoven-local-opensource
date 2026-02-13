import Foundation

struct UsageEntryResponse: Codable, Identifiable {
    let id: String
    /// Local-only client: we don't have multi-user accounts, but we keep this
    /// field for compatibility with the original schema.
    let userId: String
    let covenId: String?
    let threadId: String?
    /// Identifier of the provider that served this request (e.g. "openai").
    let provider: String
    /// Raw model identifier used for the call (e.g. "gpt-4o").
    let model: String
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let costUsd: Double
    /// metadata is optional dict, tricky to decode if mixed types, keeping as [String: String] for now or omitting if complex
    /// let metadata: [String: String]?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, model, provider
        case userId = "user_id"
        case covenId = "coven_id"
        case threadId = "thread_id"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case costUsd = "cost_usd"
        case createdAt = "created_at"
    }
}

struct UsageSummaryResponse: Codable {
    let totalTokens: Int
    let totalCostUsd: Double
    let promptTokens: Int
    let completionTokens: Int
    let messageCount: Int
    let startDate: String
    let endDate: String

    enum CodingKeys: String, CodingKey {
        case totalTokens = "total_tokens"
        case totalCostUsd = "total_cost_usd"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case messageCount = "message_count"
        case startDate = "start_date"
        case endDate = "end_date"
    }
}

struct CovenUsageResponse: Codable {
    let covenId: String
    let covenName: String
    let totalTokens: Int
    let totalCostUsd: Double
    let messageCount: Int

    enum CodingKeys: String, CodingKey {
        case covenId = "coven_id"
        case covenName = "coven_name"
        case totalTokens = "total_tokens"
        case totalCostUsd = "total_cost_usd"
        case messageCount = "message_count"
    }
}

struct BudgetResponse: Codable, Identifiable {
    let id: String
    let ownerId: String
    let provider: String
    let amountUsd: Double
    let hardCap: Bool
    let alerts: [Int]
    let active: Bool
    let createdAt: String
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, provider, alerts, active
        case ownerId = "owner_id"
        case amountUsd = "amount_usd"
        case hardCap = "hard_cap"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct RemainingResponse: Codable {
    let provider: String
    let budgetUsd: Double?
    let usageToDateUsd: Double
    let remainingUsd: Double?
    let hardCap: Bool
    let thresholdHit: Int?

    enum CodingKeys: String, CodingKey {
        case provider
        case budgetUsd = "budget_usd"
        case usageToDateUsd = "usage_to_date_usd"
        case remainingUsd = "remaining_usd"
        case hardCap = "hard_cap"
        case thresholdHit = "threshold_hit"
    }
}
