import Foundation

/// Role template summary — same structure as cloud API but sourced locally
struct RoleTemplate: Codable, Identifiable {
    let id: String
    let name: String
    let emoji: String?
    let domain: String?
    let description: String
}

/// Full role template details
struct RoleTemplateDetails: Codable {
    let role: RoleInfo
    let purpose: [String]
    let systemPrompt: String?
    let toolPolicy: ToolPolicy?

    struct RoleInfo: Codable {
        let name: String
        let emoji: String?
        let domain: String?
    }

    struct ToolPolicy: Codable {
        let read: [String]?
        let generate: [String]?
        let critique: [String]?
        let proposeOnly: [String]?

        enum CodingKeys: String, CodingKey {
            case read
            case generate
            case critique
            case proposeOnly = "propose_only"
        }
    }

    enum CodingKeys: String, CodingKey {
        case role
        case purpose
        case systemPrompt = "system_prompt"
        case toolPolicy = "tool_policy"
    }
}

/// Service for loading agent role templates.
///
/// Copied from the cloud AICoven app and adapted for local-first:
/// API calls replaced with hardcoded starter templates.
actor RoleTemplateService {
    static let shared = RoleTemplateService()

    private init() {}

    /// Hardcoded starter templates for local use
    private static let builtInTemplates: [RoleTemplate] = [
        RoleTemplate(
            id: "code-assistant",
            name: "Code Assistant",
            emoji: "💻",
            domain: "engineering",
            description: "A helpful coding assistant that can write, review, and debug code across multiple programming languages."
        ),
        RoleTemplate(
            id: "writer",
            name: "Writer",
            emoji: "✍️",
            domain: "content",
            description: "A creative writer that can help with blog posts, documentation, marketing copy, and more."
        ),
        RoleTemplate(
            id: "researcher",
            name: "Researcher",
            emoji: "🔍",
            domain: "research",
            description: "An analytical researcher that can gather information, summarize findings, and provide insights."
        ),
        RoleTemplate(
            id: "analyst",
            name: "Data Analyst",
            emoji: "📊",
            domain: "analytics",
            description: "A data-focused analyst that can help interpret data, create visualizations, and provide statistical insights."
        ),
        RoleTemplate(
            id: "tutor",
            name: "Tutor",
            emoji: "🎓",
            domain: "education",
            description: "A patient tutor that can explain concepts, create practice problems, and adapt to your learning style."
        ),
        RoleTemplate(
            id: "brainstorm",
            name: "Brainstorm Partner",
            emoji: "💡",
            domain: "ideation",
            description: "A creative thinking partner that helps generate ideas, explore possibilities, and refine concepts."
        )
    ]

    /// Hardcoded template details
    private static let templateDetails: [String: RoleTemplateDetails] = [
        "code-assistant": RoleTemplateDetails(
            role: .init(name: "Code Assistant", emoji: "💻", domain: "engineering"),
            purpose: ["Write clean, well-documented code", "Debug and fix issues", "Review code for best practices", "Explain complex code concepts"],
            systemPrompt: "You are an expert software engineer. Help the user write clean, efficient, and well-documented code. Always explain your reasoning and suggest best practices.",
            toolPolicy: nil
        ),
        "writer": RoleTemplateDetails(
            role: .init(name: "Writer", emoji: "✍️", domain: "content"),
            purpose: ["Write engaging content", "Edit and proofread text", "Adapt tone and style", "Create structured documents"],
            systemPrompt: "You are a skilled writer and editor. Help the user craft compelling content with clear structure, engaging prose, and appropriate tone for their audience.",
            toolPolicy: nil
        ),
        "researcher": RoleTemplateDetails(
            role: .init(name: "Researcher", emoji: "🔍", domain: "research"),
            purpose: ["Gather and synthesize information", "Identify key patterns and trends", "Provide balanced analysis", "Cite sources accurately"],
            systemPrompt: "You are a thorough researcher. Help the user explore topics in depth, synthesize information from multiple angles, and present findings clearly with proper citations.",
            toolPolicy: nil
        ),
        "analyst": RoleTemplateDetails(
            role: .init(name: "Data Analyst", emoji: "📊", domain: "analytics"),
            purpose: ["Analyze data patterns", "Create clear visualizations", "Provide statistical insights", "Make data-driven recommendations"],
            systemPrompt: "You are a data analyst. Help the user understand their data, identify patterns, and make informed decisions. Present insights clearly with appropriate statistical context.",
            toolPolicy: nil
        ),
        "tutor": RoleTemplateDetails(
            role: .init(name: "Tutor", emoji: "🎓", domain: "education"),
            purpose: ["Explain concepts clearly", "Adapt to learning pace", "Create practice exercises", "Provide encouraging feedback"],
            systemPrompt: "You are a patient and encouraging tutor. Help the user learn by explaining concepts clearly, providing examples, and creating practice exercises. Adapt your teaching style to their needs.",
            toolPolicy: nil
        ),
        "brainstorm": RoleTemplateDetails(
            role: .init(name: "Brainstorm Partner", emoji: "💡", domain: "ideation"),
            purpose: ["Generate creative ideas", "Explore possibilities", "Challenge assumptions", "Refine and develop concepts"],
            systemPrompt: "You are a creative thinking partner. Help the user brainstorm ideas, explore possibilities, and refine concepts. Be enthusiastic, build on ideas, and don't be afraid to suggest unconventional approaches.",
            toolPolicy: nil
        )
    ]

    /// Load list of available role templates
    /// - Returns: Array of role template summaries
    func loadTemplates() async throws -> [RoleTemplate] {
        RoleTemplateService.builtInTemplates
    }

    /// Get full details for a specific template
    /// - Parameter templateId: The template ID
    /// - Returns: Full template details
    func getTemplate(_ templateId: String) async throws -> RoleTemplateDetails {
        guard let details = RoleTemplateService.templateDetails[templateId] else {
            throw RoleTemplateError.templateNotFound
        }
        return details
    }
}

enum RoleTemplateError: Error, LocalizedError {
    case templateNotFound

    var errorDescription: String? {
        switch self {
        case .templateNotFound: "Role template not found"
        }
    }
}
