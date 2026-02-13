import Foundation

/// Protocol abstraction for thread storage used by services and views.
///
/// Implemented by `ThreadRepository` in Infrastructure/Persistence.
protocol ThreadStore {
    func createThread(title: String?) async throws -> LocalThread
    func loadThread(id: String) async throws -> LocalThread?
    func fetchAllThreads() async throws -> [LocalThread]
    func updateSummary(forThreadID threadID: String, summary: String?) async throws
    func appendMessage(toThreadID threadID: String, role: String, content: String) async throws -> LocalMessage
    func loadMessages(forThreadID threadID: String, limit: Int?) async throws -> [LocalMessage]
}

/// Protocol abstraction for long-term memory storage.
///
/// Implemented by `MemoryRepository` in Infrastructure/Persistence.
protocol MemoryStore {
    @discardableResult
    func storeMemory(
        scope: String,
        text: String,
        tags: [String],
        pii: Bool,
        createdBy: String?,
        source: String?,
        embedding: [Float]?
    ) async throws -> LocalMemoryChunk
    func loadMemories(scope: String?, limit: Int) async throws -> [LocalMemoryChunk]
    func loadMemory(id: String) async throws -> LocalMemoryChunk?
    func deleteMemory(id: String) async throws
    @discardableResult
    func updateMemory(
        id: String,
        newText: String,
        newTags: [String],
        newEmbedding: [Float]?
    ) async throws -> LocalMemoryChunk?
}

/// Protocol abstraction for autonomous agent run persistence.
///
/// Implemented by `AgentRunRepository` in Infrastructure/Persistence.
protocol AgentRunStore {
    func createRun(threadID: String?, agentType: String, maxSteps: Int) async throws -> LocalAgentRun
    func updateStatus(runID: String, status: String) async throws
    func appendStep(
        runID: String,
        stepIndex: Int,
        input: String,
        output: String,
        toolCallsJSON: String?
    ) async throws -> LocalAgentStep
}
