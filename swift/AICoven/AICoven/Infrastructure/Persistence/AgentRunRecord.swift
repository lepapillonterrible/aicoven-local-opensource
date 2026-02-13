import Foundation
import GRDB

/// Low-level GRDB representation of an autonomous agent run.
struct AgentRunRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "agent_runs"

    var id: String
    var threadID: String?
    var agentType: String
    var maxSteps: Int
    var status: String
    var createdAt: Date
    var updatedAt: Date?

    enum Columns: String, ColumnExpression {
        case id
        case threadID = "thread_id"
        case agentType = "agent_type"
        case maxSteps = "max_steps"
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Memberwise initializer used by repositories when inserting new rows.
    init(
        id: String,
        threadID: String?,
        agentType: String,
        maxSteps: Int,
        status: String,
        createdAt: Date,
        updatedAt: Date?
    ) {
        self.id = id
        self.threadID = threadID
        self.agentType = agentType
        self.maxSteps = maxSteps
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Custom Row initializer so GRDB can decode from the snake_case schema.
    init(row: Row) {
        id = row[Columns.id]
        threadID = row[Columns.threadID]
        agentType = row[Columns.agentType]
        maxSteps = row[Columns.maxSteps]
        status = row[Columns.status]
        createdAt = row[Columns.createdAt]
        updatedAt = row[Columns.updatedAt]
    }

    /// Explicitly map Swift property names to snake_case DB columns so
    /// INSERT/UPDATE statements use the correct column names.
    func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.threadID] = threadID
        container[Columns.agentType] = agentType
        container[Columns.maxSteps] = maxSteps
        container[Columns.status] = status
        container[Columns.createdAt] = createdAt
        container[Columns.updatedAt] = updatedAt
    }
}

/// Low-level GRDB representation of a single agent step.
struct AgentStepRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "agent_steps"

    var id: String
    var runID: String
    var stepIndex: Int
    var inputCiphertext: Data
    var outputCiphertext: Data
    var toolCallsCiphertext: Data?
    var createdAt: Date

    enum Columns: String, ColumnExpression {
        case id
        case runID = "run_id"
        case stepIndex = "step_index"
        case inputCiphertext = "input_ciphertext"
        case outputCiphertext = "output_ciphertext"
        case toolCallsCiphertext = "tool_calls_ciphertext"
        case createdAt = "created_at"
    }

    func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.runID] = runID
        container[Columns.stepIndex] = stepIndex
        container[Columns.inputCiphertext] = inputCiphertext
        container[Columns.outputCiphertext] = outputCiphertext
        container[Columns.toolCallsCiphertext] = toolCallsCiphertext
        container[Columns.createdAt] = createdAt
    }
}

/// Domain model for an agent run.
struct LocalAgentRun: Identifiable, Equatable {
    let id: String
    let threadID: String?
    let agentType: String
    let maxSteps: Int
    let status: String
    let createdAt: Date
    let updatedAt: Date?
}

/// Domain model for an agent step.
struct LocalAgentStep: Identifiable, Equatable {
    let id: String
    let runID: String
    let stepIndex: Int
    let input: String
    let output: String
    let toolCalls: String?
    let createdAt: Date
}

actor AgentRunRepository {
    static let shared = AgentRunRepository()

    /// Access the database queue from the MainActor-isolated DatabaseManager.
    /// This must be called from async context.
    private func getDbQueue() async -> DatabaseQueue? {
        await MainActor.run { DatabaseManager.shared.dbQueue }
    }

    private init() {}

    func createRun(threadID: String?, agentType: String, maxSteps: Int) async throws -> LocalAgentRun {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        let id = UUID().uuidString
        let now = Date()
        let status = "running"

        var record = AgentRunRecord(
            id: id,
            threadID: threadID,
            agentType: agentType,
            maxSteps: maxSteps,
            status: status,
            createdAt: now,
            updatedAt: now
        )

        try await dbQueue.write { db in
            try record.insert(db)
        }

        return LocalAgentRun(
            id: id,
            threadID: threadID,
            agentType: agentType,
            maxSteps: maxSteps,
            status: status,
            createdAt: now,
            updatedAt: now
        )
    }

    func updateStatus(runID: String, status: String) async throws {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        try await dbQueue.write { db in
            if var record = try AgentRunRecord.fetchOne(db, key: runID) {
                record.status = status
                record.updatedAt = Date()
                try record.update(db)
            }
        }
    }

    func appendStep(
        runID: String,
        stepIndex: Int,
        input: String,
        output: String,
        toolCallsJSON: String?
    ) async throws -> LocalAgentStep {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }

        let id = UUID().uuidString
        let now = Date()

        let inputData = Data(input.utf8)
        let outputData = Data(output.utf8)
        let toolCallsData = toolCallsJSON.flatMap { Data($0.utf8) }

        let inputCipher = try await DataEncryptionService.shared.encrypt(inputData, purpose: "agent_step")
        let outputCipher = try await DataEncryptionService.shared.encrypt(outputData, purpose: "agent_step")

        let toolCallsCipher: Data? = if let toolCallsData {
            try await DataEncryptionService.shared.encrypt(toolCallsData, purpose: "agent_step")
        } else {
            nil
        }

        var record = AgentStepRecord(
            id: id,
            runID: runID,
            stepIndex: stepIndex,
            inputCiphertext: inputCipher,
            outputCiphertext: outputCipher,
            toolCallsCiphertext: toolCallsCipher,
            createdAt: now
        )

        try await dbQueue.write { db in
            try record.insert(db)
        }

        return LocalAgentStep(
            id: id,
            runID: runID,
            stepIndex: stepIndex,
            input: input,
            output: output,
            toolCalls: toolCallsJSON,
            createdAt: now
        )
    }
}

extension AgentRunRepository: AgentRunStore {}
