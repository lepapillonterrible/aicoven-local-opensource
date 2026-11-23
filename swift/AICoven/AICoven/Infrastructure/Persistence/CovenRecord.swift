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

    /// `icon` is the icon chosen for it; without one it starts with the
    /// first suggested symbol and tint that none of the person's covens
    /// shows (`CovenIcon.startingIcon`).
    ///
    /// `account` is the account that asked, where the caller took note of
    /// it as it was asked (a form does, before it waits for anything);
    /// without it, it is the account signed in when this gets to read it.
    func createCoven(
        name: String, description: String? = nil, avatar: String? = nil, icon: (symbol: String, tint: IconTint)? = nil,
        as account: String? = nil
    ) async throws -> Coven {
        if let icon, !IconRules.isSymbolName(icon.symbol) { throw CovenRepositoryError.notASymbol }
        // Whose it is, read once: the coven is made for the account that
        // asked.
        let uid = if let account { account } else { await MainActor.run { UserScope.currentUserID } }
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        let now = Date()
        let id = UUID().uuidString
        // A new coven starts with none of the person's connections on:
        // its agents use only what is turned on in its Connections. (A
        // coven made before there was a choice has none stored, and keeps
        // using everything until one is made for it.)
        // The icon it starts with is chosen in the same write that makes
        // it, among the covens that are there then: two made at once do
        // not take the same one.
        let settings: CovenSettings = try await dbQueue.write { db in
            let chosen = try icon ?? CovenIcon.startingIcon(
                amongIcons: CovenRecord.filter(CovenRecord.Columns.userId == uid).fetchAll(db).map(Self.storedIcon(of:))
            )
            let settings = CovenSettings(connections: CovenConnections(), iconSymbol: chosen.symbol, iconTint: chosen.tint.rawValue)
            try CovenRecord(
                id: id,
                name: name,
                description: description,
                avatar: avatar,
                settings: String(data: JSONEncoder().encode(settings), encoding: .utf8),
                userId: uid,
                createdAt: now,
                updatedAt: now
            ).insert(db)
            return settings
        }

        return Coven(
            id: id,
            name: name,
            description: description,
            avatar: avatar,
            settings: settings,
            createdAt: now,
            updatedAt: now
        )
    }

    /// The icon a stored coven shows, as far as it is stored: nil for
    /// what is not there or cannot be read.
    private static func storedIcon(of record: CovenRecord) -> (symbol: String?, tint: String?) {
        let settings = record.settings.flatMap { try? JSONDecoder().decode(CovenSettings.self, from: Data($0.utf8)) }
        return (settings?.iconSymbol, settings?.iconTint)
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

    /// Sets which connections the coven's agents may use, keeping
    /// everything else in its settings as it is stored. `nil` takes the
    /// choice away. Only `userID`'s coven is changed, and only while
    /// `userID` is still the account signed in. Settings that cannot be
    /// read are not written over: that throws.
    func setConnections(_ connections: CovenConnections?, forCoven id: String) async throws {
        let uid = await MainActor.run { UserScope.currentUserID }
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        // The account can have changed while the database was waited for.
        guard await MainActor.run(body: { UserScope.currentUserID }) == uid else { throw RepositoryError.accountChanged }
        let chosen = try connections.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        try await dbQueue.write { db in
            guard var record = try CovenRecord
                .filter(CovenRecord.Columns.id == id)
                .filter(CovenRecord.Columns.userId == uid)
                .fetchOne(db) else {
                throw CovenRepositoryError.covenNotFound
            }
            var settings = try Self.storedSettings(of: record)
            settings["connections"] = chosen
            record.settings = try String(data: JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]), encoding: .utf8)
            record.updatedAt = Date()
            try record.update(db)
        }
    }

    /// Changes which connections the coven's agents may use, in one
    /// write: `change` is given the choice as it is stored then (or
    /// `unchosen`, what the coven lives by, where it has made none), and
    /// what it gives back is kept and returned. So a change is made to
    /// the choice as it is, not as whoever asked last read it: two
    /// screens changing different things undo nothing of each other's.
    /// What `change` throws is thrown, and nothing is written. Only the
    /// signed-in account's coven is changed, and settings that cannot be
    /// read are not written over.
    func changeConnections(
        ofCoven id: String, unchosen: CovenConnections, _ change: @escaping @Sendable (CovenConnections) throws -> CovenConnections
    ) async throws -> CovenConnections {
        let uid = await MainActor.run { UserScope.currentUserID }
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        // The account can have changed while the database was waited for.
        guard await MainActor.run(body: { UserScope.currentUserID }) == uid else { throw RepositoryError.accountChanged }
        return try await dbQueue.write { db in
            guard var record = try CovenRecord
                .filter(CovenRecord.Columns.id == id)
                .filter(CovenRecord.Columns.userId == uid)
                .fetchOne(db) else {
                throw CovenRepositoryError.covenNotFound
            }
            var settings = try Self.storedSettings(of: record)
            let after = try change(Self.connections(in: settings) ?? unchosen)
            settings["connections"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(after))
            record.settings = try String(data: JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]), encoding: .utf8)
            record.updatedAt = Date()
            try record.update(db)
            return after
        }
    }

    /// The choice of connections in a coven's settings: nil if it has
    /// made none. Throws if what is stored there is not a choice.
    private static func connections(in settings: [String: Any]) throws -> CovenConnections? {
        guard let stored = settings["connections"], !(stored is NSNull) else { return nil }
        guard stored is [String: Any] else { throw CovenRepositoryError.settingsUnreadable }
        return try JSONDecoder().decode(CovenConnections.self, from: JSONSerialization.data(withJSONObject: stored))
    }

    /// Sets the coven's icon, keeping everything else in its settings as
    /// it is stored. Whose coven it is is read once, when this is called:
    /// only that account's coven is changed, whoever is signed in by the
    /// time it is written.
    /// Settings that cannot be read are not written over: that throws, as
    /// does a symbol that cannot be one.
    func setIcon(symbol: String, tint: IconTint, forCoven id: String) async throws {
        guard IconRules.isSymbolName(symbol) else { throw CovenRepositoryError.notASymbol }
        let uid = await MainActor.run { UserScope.currentUserID }
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        try await dbQueue.write { db in
            guard var record = try CovenRecord
                .filter(CovenRecord.Columns.id == id)
                .filter(CovenRecord.Columns.userId == uid)
                .fetchOne(db) else {
                throw CovenRepositoryError.covenNotFound
            }
            var settings = try Self.storedSettings(of: record)
            settings["icon_symbol"] = symbol
            settings["icon_tint"] = tint.rawValue
            record.settings = try String(data: JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]), encoding: .utf8)
            record.updatedAt = Date()
            try record.update(db)
        }
    }

    /// Sets an agent's face, keeping everything else in its settings as it
    /// is stored. Only the signed-in person's agent is changed. Settings
    /// that cannot be read are not written over: that throws.
    func setIcon(symbol: String, tint: IconTint, forRole id: String) async throws {
        guard IconRules.isSymbolName(symbol) else { throw CovenRepositoryError.notASymbol }
        let uid = await MainActor.run { UserScope.currentUserID }
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        try await dbQueue.write { db in
            guard var record = try RoleRecord.fetchOne(db, key: id), record.userId == uid else {
                throw CovenRepositoryError.roleNotFound
            }
            guard var settings = Self.storedSettings(ofRole: record) else { throw CovenRepositoryError.roleSettingsUnreadable }
            settings["icon_symbol"] = symbol
            settings["icon_tint"] = tint.rawValue
            record.settings = try String(data: JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]), encoding: .utf8)
            record.updatedAt = Date()
            try record.update(db)
        }
    }

    /// The tint a stored agent shows, read as the agent itself is read
    /// (`mapRecordToRole`): nil for none, an unknown one, or settings that
    /// are not settings.
    private static func shownTint(of record: RoleRecord) -> IconTint? {
        record.settings
            .flatMap { try? JSONDecoder().decode(RoleSettings.self, from: Data($0.utf8)) }?
            .iconTint.flatMap(IconTint.init(rawValue:))
    }

    /// An agent's settings as they are stored: an object, empty if none
    /// are stored; nil if what is stored is not one.
    private static func storedSettings(ofRole record: RoleRecord) -> [String: Any]? {
        guard let text = record.settings else { return [:] }
        return try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    /// Settings as they are written when an agent's are replaced: the new
    /// ones, with the face that was stored (which the form that replaces
    /// them does not carry).
    private static func settingsText(_ new: RoleSettings, keepingTheFaceOf record: RoleRecord?) -> String? {
        guard let data = try? JSONEncoder().encode(new), var merged = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let kept = record.flatMap(storedSettings(ofRole:)) ?? [:]
        for key in ["icon_symbol", "icon_tint"] where merged[key] == nil {
            merged[key] = kept[key]
        }
        guard let text = try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]) else { return nil }
        return String(data: text, encoding: .utf8)
    }

    /// The coven's choice of connections as it is stored: nil if it has
    /// made none. Throws if the coven is not `userID`'s, or its settings
    /// or its choice cannot be read: what is not read is not taken for no
    /// choice.
    func connections(ofCoven id: String, for userID: String) async throws -> CovenConnections? {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        return try await dbQueue.read { db in
            guard let record = try CovenRecord
                .filter(CovenRecord.Columns.id == id)
                .filter(CovenRecord.Columns.userId == userID)
                .fetchOne(db) else {
                throw CovenRepositoryError.covenNotFound
            }
            return try Self.connections(in: Self.storedSettings(of: record))
        }
    }

    /// A coven's settings as they are stored: an object, empty if none
    /// are stored. Throws if what is stored is not one (empty text
    /// included).
    private static func storedSettings(of record: CovenRecord) throws -> [String: Any] {
        guard let text = record.settings else { return [:] }
        guard let settings = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw CovenRepositoryError.settingsUnreadable
        }
        return settings
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

    /// An agent of the signed-in account's, by its id: or of `account`'s,
    /// where the caller has read whose it is already. Another account's
    /// agent is not found, as one that is not there is not.
    func getRole(roleId: String, for account: String? = nil) async throws -> Role {
        // Whose agents are read, asked once before anything is waited for.
        let uid = if let account { account } else { await MainActor.run { UserScope.currentUserID } }
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        let record: RoleRecord? = try await dbQueue.read { db in
            try RoleRecord
                .filter(RoleRecord.Columns.id == roleId)
                .filter(RoleRecord.Columns.userId == uid)
                .fetchOne(db)
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
        plannerMaxSeconds: Double? = nil,
        icon: (symbol: String, tint: IconTint?)? = nil,
        as account: String? = nil
    ) async throws -> Role {
        if let icon, !IconRules.isSymbolName(icon.symbol) { throw CovenRepositoryError.notASymbol }
        // Whose it is, read once: the agent is made for this account, in
        // a coven of this account, whoever is signed in by the time it is
        // written. Where the caller says who asked (`account`), nothing is
        // made if another is signed in by now.
        let current = await MainActor.run { UserScope.currentUserID }
        let uid = account ?? current
        guard uid == current else { throw RepositoryError.accountChanged }
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        // Asked again once the database is in hand, just before the write.
        if account != nil {
            guard await MainActor.run(body: { UserScope.currentUserID }) == uid else { throw RepositoryError.accountChanged }
        }

        let now = Date()
        let id = UUID().uuidString

        // A new agent starts with a face: the one chosen for it, or the
        // symbol its emoji stands for (or none, which shows `cpu`) on the
        // first tint none of the coven's agents wears. The tint is chosen
        // in the same write that makes the agent, among the agents that
        // are there then.
        let record: RoleRecord = try await dbQueue.write { db in
            guard try CovenRecord
                .filter(CovenRecord.Columns.id == covenId)
                .filter(CovenRecord.Columns.userId == uid)
                .fetchCount(db) == 1 else {
                throw CovenRepositoryError.covenNotFound
            }
            /// The tints worn are those the coven's agents show: one whose
            /// settings cannot be read as settings shows sand.
            func unusedTint() throws -> IconTint {
                try IconTint.nextUnused(
                    worn: RoleRecord
                        .filter(RoleRecord.Columns.covenId == covenId)
                        .filter(RoleRecord.Columns.userId == uid)
                        .fetchAll(db)
                        .map { (Self.shownTint(of: $0) ?? .warm).rawValue }
                )
            }
            let face: (symbol: String?, tint: IconTint) = if let icon {
                try (icon.symbol, icon.tint ?? unusedTint())
            } else {
                try (AgentFace.symbol(forEmoji: emoji), unusedTint())
            }
            let roleSettings = RoleSettings(
                toolConfig: nil,
                allowedTools: allowedTools,
                collaboratorRoleIds: collaboratorRoleIds,
                autonomousMode: autonomousMode,
                autonomousMaxSteps: autonomousMaxSteps,
                plannerMaxTasks: plannerMaxTasks,
                plannerMaxSeconds: plannerMaxSeconds,
                iconSymbol: face.symbol,
                iconTint: face.tint.rawValue
            )
            let record = RoleRecord(
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
                settings: Self.settingsText(roleSettings, keepingTheFaceOf: nil),
                userId: uid,
                createdAt: now,
                updatedAt: now
            )
            try record.insert(db)
            return record
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
        // Whose agent it is, read once: only that account's is changed.
        let uid = await MainActor.run { UserScope.currentUserID }
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        try await dbQueue.write { db in
            guard var record = try RoleRecord.fetchOne(db, key: roleId), record.userId == uid else {
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
                // What is stored and cannot be read is not written over
                // (nothing of this agent is changed).
                guard Self.storedSettings(ofRole: record) != nil else { throw CovenRepositoryError.roleSettingsUnreadable }
                let roleSettings = RoleSettings(
                    toolConfig: nil,
                    allowedTools: allowedTools,
                    collaboratorRoleIds: collaboratorRoleIds,
                    autonomousMode: autonomousMode,
                    autonomousMaxSteps: autonomousMaxSteps,
                    plannerMaxTasks: plannerMaxTasks,
                    plannerMaxSeconds: plannerMaxSeconds
                )
                if let text = Self.settingsText(roleSettings, keepingTheFaceOf: record) {
                    record.settings = text
                }
            }

            record.updatedAt = Date()
            try record.update(db)
        }

        return try await getRole(roleId: roleId)
    }

    /// Saves an agent of `account`'s as the agent form shows it, in one
    /// write: its name, face, description, instructions, what it runs on,
    /// and the settings under Advanced that the form showed. Everything
    /// else in its stored settings stays as it is; settings that cannot be
    /// read are not written over (that throws, and nothing is saved).
    /// `account` is whoever pressed Save: nothing is saved if another is
    /// signed in when this is asked, or when it is asked again with the
    /// database in hand, just before the write (a write already waiting
    /// its turn then is still that account's own, of its own agent). An
    /// agent that is not that account's is not found. Gives the agent as
    /// it was written.
    func saveAgent(_ roleId: String, _ agent: AgentSaving, as account: String) async throws -> Role {
        guard let agent = agent.storable else { throw CovenRepositoryError.agentIncomplete }
        guard IconRules.isSymbolName(agent.iconSymbol) else { throw CovenRepositoryError.notASymbol }
        guard await MainActor.run(body: { UserScope.currentUserID }) == account else { throw RepositoryError.accountChanged }
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        // Asked again once the database is in hand, just before the write.
        guard await MainActor.run(body: { UserScope.currentUserID }) == account else { throw RepositoryError.accountChanged }

        let record: RoleRecord = try await dbQueue.write { db in
            guard var record = try RoleRecord.fetchOne(db, key: roleId), record.userId == account else {
                throw CovenRepositoryError.roleNotFound
            }
            guard var settings = Self.storedSettings(ofRole: record) else { throw CovenRepositoryError.roleSettingsUnreadable }
            record.name = agent.name
            record.description = agent.description.isEmpty ? nil : agent.description
            record.systemPrompt = agent.instructions.isEmpty ? nil : agent.instructions
            record.provider = agent.provider
            record.model = agent.model
            record.providerAccountId = agent.providerAccountId
            if let temperature = agent.temperature { record.temperature = temperature }
            if let maxTokens = agent.maxTokens { record.maxTokens = maxTokens }
            if let mostSteps = agent.mostSteps { settings["autonomous_max_steps"] = mostSteps }
            settings["icon_symbol"] = agent.iconSymbol
            if let tint = agent.iconTint { settings["icon_tint"] = tint.rawValue }
            record.settings = try String(data: JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]), encoding: .utf8)
            record.updatedAt = Date()
            try record.update(db)
            return record
        }
        return mapRecordToRole(record)
    }

    /// Makes an agent in a coven of `account`'s as the agent form shows
    /// it. `account` is whoever pressed Save: nothing is made if another
    /// is signed in when this is asked, or just before the write.
    func createAgent(inCoven covenId: String, _ agent: AgentSaving, as account: String) async throws -> Role {
        guard let agent = agent.storable else { throw CovenRepositoryError.agentIncomplete }
        return try await createRole(
            covenId: covenId,
            name: agent.name,
            description: agent.description.isEmpty ? nil : agent.description,
            systemPrompt: agent.instructions.isEmpty ? nil : agent.instructions,
            model: agent.model,
            provider: agent.provider,
            providerAccountId: agent.providerAccountId,
            temperature: agent.temperature,
            maxTokens: agent.maxTokens,
            autonomousMaxSteps: agent.mostSteps,
            icon: (agent.iconSymbol, agent.iconTint),
            as: account
        )
    }

    /// Deletes an agent of `account`'s (the signed-in account's where none
    /// is named). `account` is whoever asked: if another has signed in by
    /// the time this runs, nothing is deleted. An agent that is not that
    /// account's is not found.
    func deleteRole(roleId: String, as account: String? = nil) async throws {
        let current = await MainActor.run { UserScope.currentUserID }
        let uid = account ?? current
        guard uid == current else { throw RepositoryError.accountChanged }
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        // Asked again once the database is in hand, just before the write.
        guard await MainActor.run(body: { UserScope.currentUserID }) == uid else { throw RepositoryError.accountChanged }

        try await dbQueue.write { db in
            guard let record = try RoleRecord.fetchOne(db, key: roleId), record.userId == uid else {
                throw CovenRepositoryError.roleNotFound
            }
            try record.delete(db)
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
    /// What is stored as a coven's settings is not settings.
    case settingsUnreadable
    /// What is stored as an agent's settings is not settings.
    case roleSettingsUnreadable
    /// What was given as an icon's symbol cannot be a symbol's name.
    case notASymbol
    /// What was given to save is not an agent: it has no name, or one
    /// too long, no provider or model, or a setting out of its range.
    case agentIncomplete

    var errorDescription: String? {
        switch self {
        case .covenNotFound: "Coven not found"
        case .roleNotFound: "Role not found"
        case .settingsUnreadable: "This coven's settings could not be read"
        case .roleSettingsUnreadable: "This agent's settings could not be read"
        case .notASymbol: "That is not a symbol's name"
        case .agentIncomplete: "This agent cannot be saved as it is"
        }
    }
}
