import Foundation

/// Service for managing agent roles.
///
/// Copied from the cloud AICoven app and adapted for local-first:
/// all API calls replaced with local SQLite operations via CovenRepository.
actor RoleService {
    static let shared = RoleService()

    private init() {}

    /// Load roles for a coven
    /// - Parameter covenId: The coven ID to load roles for
    /// - Returns: Array of roles for the coven
    func loadRoles(covenId: String) async throws -> [Role] {
        try await CovenRepository.shared.loadRoles(covenId: covenId)
    }

    /// Create a new role in a coven
    /// - Parameters:
    ///   - covenId: The coven to create the role in
    ///   - name: Role name
    ///   - emoji: Optional emoji
    ///   - description: Optional description
    ///   - systemPrompt: Optional system prompt
    ///   - model: Optional model identifier
    ///   - provider: Optional provider identifier
    ///   - providerAccountId: Optional provider account ID
    ///   - temperature: Optional temperature
    ///   - maxTokens: Optional max tokens
    ///   - allowedTools: Optional list of allowed tool names
    ///   - collaboratorRoleIds: Optional list of collaborator role IDs
    ///   - autonomousMode: Optional autonomous mode flag
    ///   - autonomousMaxSteps: Optional per-role max autonomous steps
    ///   - plannerMaxTasks: Optional per-role max planner tasks for plan_and_execute
    ///   - plannerMaxSeconds: Optional soft wall-clock budget (seconds) for plan_and_execute
    /// - Returns: The created role
    func createRole(
        covenId: String,
        name: String,
        emoji: String? = nil,
        description: String? = nil,
        systemPrompt: String? = nil,
        model: String? = nil,
        provider: String? = nil,
        providerAccountId: String? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        allowedTools: [String]? = nil,
        collaboratorRoleIds: [String]? = nil,
        autonomousMode: Bool? = nil,
        autonomousMaxSteps: Int? = nil,
        plannerMaxTasks: Int? = nil,
        plannerMaxSeconds: Double? = nil
    ) async throws -> Role {
        try await CovenRepository.shared.createRole(
            covenId: covenId,
            name: name,
            emoji: emoji,
            description: description,
            systemPrompt: systemPrompt,
            model: model,
            provider: provider,
            providerAccountId: providerAccountId,
            temperature: temperature,
            maxTokens: maxTokens,
            allowedTools: allowedTools,
            collaboratorRoleIds: collaboratorRoleIds,
            autonomousMode: autonomousMode,
            autonomousMaxSteps: autonomousMaxSteps,
            plannerMaxTasks: plannerMaxTasks,
            plannerMaxSeconds: plannerMaxSeconds
        )
    }

    /// Update an existing role
    /// - Parameters:
    ///   - roleId: The role ID to update
    ///   - name: Optional new name
    ///   - emoji: Optional new emoji
    ///   - description: Optional new description
    ///   - systemPrompt: Optional new system prompt
    ///   - model: Optional new model
    ///   - provider: Optional new provider
    ///   - providerAccountId: Optional new provider account ID
    ///   - temperature: Optional new temperature
    ///   - maxTokens: Optional new max tokens
    ///   - allowedTools: Optional new allowed tools
    ///   - collaboratorRoleIds: Optional new collaborator role IDs
    ///   - autonomousMode: Optional autonomous mode flag
    ///   - autonomousMaxSteps: Optional per-role max autonomous steps
    ///   - plannerMaxTasks: Optional per-role max planner tasks for plan_and_execute
    ///   - plannerMaxSeconds: Optional soft wall-clock budget (seconds) for plan_and_execute
    /// - Returns: The updated role
    func updateRole(
        roleId: String,
        name: String? = nil,
        emoji: String? = nil,
        description: String? = nil,
        systemPrompt: String? = nil,
        model: String? = nil,
        provider: String? = nil,
        providerAccountId: String? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        allowedTools: [String]? = nil,
        collaboratorRoleIds: [String]? = nil,
        autonomousMode: Bool? = nil,
        autonomousMaxSteps: Int? = nil,
        plannerMaxTasks: Int? = nil,
        plannerMaxSeconds: Double? = nil
    ) async throws -> Role {
        try await CovenRepository.shared.updateRole(
            roleId: roleId,
            name: name,
            emoji: emoji,
            description: description,
            systemPrompt: systemPrompt,
            model: model,
            provider: provider,
            providerAccountId: providerAccountId,
            temperature: temperature,
            maxTokens: maxTokens,
            allowedTools: allowedTools,
            collaboratorRoleIds: collaboratorRoleIds,
            autonomousMode: autonomousMode,
            autonomousMaxSteps: autonomousMaxSteps,
            plannerMaxTasks: plannerMaxTasks,
            plannerMaxSeconds: plannerMaxSeconds
        )
    }

    /// Delete a role
    /// - Parameter roleId: The role ID to delete
    func deleteRole(roleId: String) async throws {
        try await CovenRepository.shared.deleteRole(roleId: roleId)
    }

    /// Get a specific role by ID
    /// - Parameter roleId: The role ID
    /// - Returns: The role
    func getRole(roleId: String) async throws -> Role {
        try await CovenRepository.shared.getRole(roleId: roleId)
    }
}
