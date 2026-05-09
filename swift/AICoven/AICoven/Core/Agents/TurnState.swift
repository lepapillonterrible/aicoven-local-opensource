import Foundation

/// Represents the execution phase of an agent turn.
enum TurnPhase: String, Codable, Equatable {
    case starting
    case modelAttempt = "model_attempt"
    case planning
    case tooling
    case answering
    case finalizing
}

/// Represents the overall status of an agent turn.
enum TurnStatus: String, Codable, Equatable {
    case running
    case cancelling
    case cancelled
    case completed
    case failed
}

/// A structured tool call currently in progress or completed.
struct TurnToolCall: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let arguments: [String: AnyJSONValue]
    var result: String?
    var status: String // "running", "completed", "failed"
}

/// Represents the entire state of an ongoing or completed turn.
/// Used to broadcast state changes to the UI instead of discrete callbacks.
struct TurnState: Codable, Equatable, Identifiable {
    let id: UUID
    var threadId: String?
    var answer: String
    var scratchpad: String
    var toolsInProgress: [String: TurnToolCall]
    var toolsCompleted: [TurnToolCall]
    var tasks: [AgentTask]
    var status: TurnStatus
    var version: Int
    var phase: TurnPhase

    enum CodingKeys: String, CodingKey {
        case id = "turn_id"
        case threadId = "thread_id"
        case answer
        case scratchpad
        case toolsInProgress = "tools_in_progress"
        case toolsCompleted = "tools_completed"
        case tasks
        case status
        case version
        case phase
    }

    init(
        id: UUID = UUID(),
        threadId: String? = nil,
        answer: String = "",
        scratchpad: String = "",
        toolsInProgress: [String: TurnToolCall] = [:],
        toolsCompleted: [TurnToolCall] = [],
        tasks: [AgentTask] = [],
        status: TurnStatus = .running,
        version: Int = 0,
        phase: TurnPhase = .starting
    ) {
        self.id = id
        self.threadId = threadId
        self.answer = answer
        self.scratchpad = scratchpad
        self.toolsInProgress = toolsInProgress
        self.toolsCompleted = toolsCompleted
        self.tasks = tasks
        self.status = status
        self.version = version
        self.phase = phase
    }

    mutating func bumpVersion() {
        version += 1
    }
}
