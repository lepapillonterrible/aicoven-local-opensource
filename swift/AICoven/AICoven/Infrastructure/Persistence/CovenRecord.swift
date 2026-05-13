import Foundation
import GRDB

// MARK: - Coven Record

/// Low-level GRDB representation of a coven.
struct CovenRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "covens"

    var id: String
    var name: String
    var description: String?
    var avatar: String?
    var settings: String? // JSON-encoded CovenSettings
    var userId: String?
    var createdAt: Date
    var updatedAt: Date

    enum Columns: String, ColumnExpression {
        case id
        case name
        case description
        case avatar
        case settings
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        id: String,
        name: String,
        description: String?,
        avatar: String?,
        settings: String?,
        userId: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.avatar = avatar
        self.settings = settings
        self.userId = userId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(row: Row) {
        id = row[Columns.id]
        name = row[Columns.name]
        description = row[Columns.description]
        avatar = row[Columns.avatar]
        settings = row[Columns.settings]
        userId = row[Columns.userId]
        createdAt = row[Columns.createdAt]
        updatedAt = row[Columns.updatedAt]
    }

    func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.name] = name
        container[Columns.description] = description
        container[Columns.avatar] = avatar
        container[Columns.settings] = settings
        container[Columns.userId] = userId
        container[Columns.createdAt] = createdAt
        container[Columns.updatedAt] = updatedAt
    }
}

// MARK: - Role Record

/// Low-level GRDB representation of an agent role.
struct RoleRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "roles"

    var id: String
    var covenId: String
    var name: String
    var emoji: String?
    var description: String?
    var systemPrompt: String?
    var model: String?
    var provider: String?
    var providerAccountId: String?
    var temperature: Double?
    var maxTokens: Int?
    var settings: String? // JSON-encoded RoleSettings
    var userId: String?
    var createdAt: Date
    var updatedAt: Date

    enum Columns: String, ColumnExpression {
        case id
        case covenId = "coven_id"
        case name
        case emoji
        case description
        case systemPrompt = "system_prompt"
        case model
        case provider
        case providerAccountId = "provider_account_id"
        case temperature
        case maxTokens = "max_tokens"
        case settings
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        id: String,
        covenId: String,
        name: String,
        emoji: String?,
        description: String?,
        systemPrompt: String?,
        model: String?,
        provider: String?,
        providerAccountId: String?,
        temperature: Double?,
        maxTokens: Int?,
        settings: String?,
        userId: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.covenId = covenId
        self.name = name
        self.emoji = emoji
        self.description = description
        self.systemPrompt = systemPrompt
        self.model = model
        self.provider = provider
        self.providerAccountId = providerAccountId
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.settings = settings
        self.userId = userId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(row: Row) {
        id = row[Columns.id]
        covenId = row[Columns.covenId]
        name = row[Columns.name]
        emoji = row[Columns.emoji]
        description = row[Columns.description]
        systemPrompt = row[Columns.systemPrompt]
        model = row[Columns.model]
        provider = row[Columns.provider]
        providerAccountId = row[Columns.providerAccountId]
        temperature = row[Columns.temperature]
        maxTokens = row[Columns.maxTokens]
        settings = row[Columns.settings]
        userId = row[Columns.userId]
        createdAt = row[Columns.createdAt]
        updatedAt = row[Columns.updatedAt]
    }

    func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.covenId] = covenId
        container[Columns.name] = name
        container[Columns.emoji] = emoji
        container[Columns.description] = description
        container[Columns.systemPrompt] = systemPrompt
        container[Columns.model] = model
        container[Columns.provider] = provider
        container[Columns.providerAccountId] = providerAccountId
        container[Columns.temperature] = temperature
        container[Columns.maxTokens] = maxTokens
        container[Columns.settings] = settings
        container[Columns.userId] = userId
        container[Columns.createdAt] = createdAt
        container[Columns.updatedAt] = updatedAt
    }
}

// MARK: - Coven Repository

/// Actor-isolated repository for local coven and role CRUD.
/// Follows the same pattern as ThreadRepository / MemoryRepository.
actor CovenRepository {
    static let shared = CovenRepository()

    private func getDbQueue() async -> DatabaseQueue? {
        await MainActor.run { DatabaseManager.shared.dbQueue }
    }

    private init() {}

    // MARK: - Coven CRUD

    func createCoven(name: String, description: String? = nil, avatar: String? = nil) async throws -> Coven {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        let now = Date()
        let id = UUID().uuidString
        let uid = await UserScope.currentUserID
        let record = CovenRecord(
            id: id,
            name: name,
            description: description,
            avatar: avatar,
            settings: nil,
            userId: uid,
            createdAt: now,
            updatedAt: now
        )

        try await dbQueue.write { db in
            try record.insert(db)
        }

        return Coven(
            id: id,
            name: name,
            description: description,
            avatar: avatar,
            settings: nil,
            createdAt: now,
            updatedAt: now
        )
    }

    func loadCovens() async throws -> [Coven] {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        // Fetch user ID outside the synchronous database closure
        let uid = await UserScope.currentUserID

        let records: [CovenRecord] = try await dbQueue.read { db in
            try CovenRecord
                .filter(CovenRecord.Columns.userId == uid)
                .order(CovenRecord.Columns.createdAt.desc)
                .fetchAll(db)
        }

        return records.map { rec in
            let settings: CovenSettings? = if let settingsJSON = rec.settings,
                                              let data = settingsJSON.data(using: .utf8) {
                try? JSONDecoder().decode(CovenSettings.self, from: data)
            } else {
                nil
            }
            return Coven(
                id: rec.id,
                name: rec.name,
                description: rec.description,
                avatar: rec.avatar,
                settings: settings,
                createdAt: rec.createdAt,
                updatedAt: rec.updatedAt
            )
        }
    }

    func updateCoven(id: String, name: String? = nil, description: String? = nil, avatar: String? = nil) async throws -> Coven {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        try await dbQueue.write { db in
            guard var record = try CovenRecord.fetchOne(db, key: id) else {
                throw CovenRepositoryError.covenNotFound
            }
            if let name { record.name = name }
            if let description { record.description = description }
            if let avatar { record.avatar = avatar }
            record.updatedAt = Date()
            try record.update(db)
        }

        // Re-fetch and return
        let covens = try await loadCovens()
        guard let coven = covens.first(where: { $0.id == id }) else {
            throw CovenRepositoryError.covenNotFound
        }
        return coven
    }

    func deleteCoven(id: String) async throws {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        try await dbQueue.write { db in
            _ = try CovenRecord.deleteOne(db, key: id)
            // Roles are cascade-deleted by foreign key
        }
    }

    // MARK: - Role CRUD

    func loadRoles(covenId: String) async throws -> [Role] {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        // Fetch user ID outside the synchronous database closure
        let uid = await UserScope.currentUserID

        let records: [RoleRecord] = try await dbQueue.read { db in
            try RoleRecord
                .filter(RoleRecord.Columns.covenId == covenId)
                .filter(RoleRecord.Columns.userId == uid)
                .order(RoleRecord.Columns.createdAt.asc)
                .fetchAll(db)
        }

        return records.map { mapRecordToRole($0) }
    }

    func getRole(roleId: String) async throws -> Role {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        let record: RoleRecord? = try await dbQueue.read { db in
            try RoleRecord.fetchOne(db, key: roleId)
        }

        guard let record else { throw CovenRepositoryError.roleNotFound }
        return mapRecordToRole(record)
    }

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
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        let now = Date()
        let id = UUID().uuidString

        // Build settings JSON if needed
        var settingsJSON: String? = nil
        if allowedTools != nil || collaboratorRoleIds != nil || autonomousMode != nil ||
            autonomousMaxSteps != nil || plannerMaxTasks != nil || plannerMaxSeconds != nil {
            let roleSettings = RoleSettings(
                toolConfig: nil,
                allowedTools: allowedTools,
                collaboratorRoleIds: collaboratorRoleIds,
                autonomousMode: autonomousMode,
                autonomousMaxSteps: autonomousMaxSteps,
                plannerMaxTasks: plannerMaxTasks,
                plannerMaxSeconds: plannerMaxSeconds
            )
            if let data = try? JSONEncoder().encode(roleSettings) {
                settingsJSON = String(data: data, encoding: .utf8)
            }
        }

        let record = await RoleRecord(
            id: id,
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
            settings: settingsJSON,
            userId: UserScope.currentUserID,
            createdAt: now,
            updatedAt: now
        )

        try await dbQueue.write { db in
            try record.insert(db)
        }

        return mapRecordToRole(record)
    }

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
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        try await dbQueue.write { db in
            guard var record = try RoleRecord.fetchOne(db, key: roleId) else {
                throw CovenRepositoryError.roleNotFound
            }
            if let name { record.name = name }
            if let emoji { record.emoji = emoji }
            if let description { record.description = description }
            if let systemPrompt { record.systemPrompt = systemPrompt }
            if let model { record.model = model }
            if let provider { record.provider = provider }
            if let providerAccountId { record.providerAccountId = providerAccountId }
            if let temperature { record.temperature = temperature }
            if let maxTokens { record.maxTokens = maxTokens }

            // Update settings if any settings-related param is provided
            if allowedTools != nil || collaboratorRoleIds != nil || autonomousMode != nil ||
                autonomousMaxSteps != nil || plannerMaxTasks != nil || plannerMaxSeconds != nil {
                let roleSettings = RoleSettings(
                    toolConfig: nil,
                    allowedTools: allowedTools,
                    collaboratorRoleIds: collaboratorRoleIds,
                    autonomousMode: autonomousMode,
                    autonomousMaxSteps: autonomousMaxSteps,
                    plannerMaxTasks: plannerMaxTasks,
                    plannerMaxSeconds: plannerMaxSeconds
                )
                if let data = try? JSONEncoder().encode(roleSettings) {
                    record.settings = String(data: data, encoding: .utf8)
                }
            }

            record.updatedAt = Date()
            try record.update(db)
        }

        return try await getRole(roleId: roleId)
    }

    func deleteRole(roleId: String) async throws {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        try await dbQueue.write { db in
            _ = try RoleRecord.deleteOne(db, key: roleId)
        }
    }

    // MARK: - Helpers

    private func mapRecordToRole(_ rec: RoleRecord) -> Role {
        let settings: RoleSettings? = if let settingsJSON = rec.settings,
                                         let data = settingsJSON.data(using: .utf8) {
            try? JSONDecoder().decode(RoleSettings.self, from: data)
        } else {
            nil
        }

        return Role(
            id: rec.id,
            covenId: rec.covenId,
            name: rec.name,
            emoji: rec.emoji,
            description: rec.description,
            systemPrompt: rec.systemPrompt,
            model: rec.model,
            provider: rec.provider,
            providerAccountId: rec.providerAccountId,
            temperature: rec.temperature,
            maxTokens: rec.maxTokens,
            settings: settings,
            createdAt: rec.createdAt,
            updatedAt: rec.updatedAt
        )
    }
}

// MARK: - Errors

enum CovenRepositoryError: Error, LocalizedError {
    case covenNotFound
    case roleNotFound

    var errorDescription: String? {
        switch self {
        case .covenNotFound: "Coven not found"
        case .roleNotFound: "Role not found"
        }
    }
}
