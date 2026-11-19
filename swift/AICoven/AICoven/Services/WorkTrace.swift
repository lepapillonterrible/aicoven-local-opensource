import Foundation

/// The work behind one answer: the tools the turn ran, with their times, and
/// the reasoning it reported. Built while the turn runs and kept with it.
struct WorkTrace: Codable, Equatable {
    /// One tool call.
    struct Step: Codable, Equatable, Identifiable {
        let id: String
        let tool: String
        let startedAt: Date
        /// Nil while the tool runs, and for one that was running when the
        /// turn ended.
        var finishedAt: Date?
        var failed = false
    }

    let startedAt: Date
    /// Nil while the turn runs.
    var finishedAt: Date?
    var steps: [Step] = []
    var reasoning: [String] = []

    var isEmpty: Bool {
        steps.isEmpty && reasoning.isEmpty
    }

    /// Records what a report of the turn's state shows: tools that have
    /// started or finished since the last one, and a new line of reasoning.
    mutating func note(_ state: TurnState, at now: Date) {
        for tool in state.toolsInProgress.values.sorted(by: { $0.id < $1.id }) where !steps.contains(where: { $0.id == tool.id }) {
            steps.append(Step(id: tool.id, tool: tool.name, startedAt: now))
        }
        for tool in state.toolsCompleted {
            if let index = steps.firstIndex(where: { $0.id == tool.id }) {
                guard steps[index].finishedAt == nil else { continue }
                steps[index].finishedAt = now
                steps[index].failed = tool.status == "failed"
            } else {
                // Started and finished between two reports.
                steps.append(Step(id: tool.id, tool: tool.name, startedAt: now, finishedAt: now, failed: tool.status == "failed"))
            }
        }
        let thought = state.scratchpad.trimmingCharacters(in: .whitespacesAndNewlines)
        if [.starting, .planning, .modelAttempt].contains(state.phase), !thought.isEmpty, reasoning.last != thought {
            reasoning.append(thought)
        }
    }

    /// The line a finished turn keeps under its answer, such as "Worked 12
    /// seconds · 2 steps". Nil for a turn that ran no tool and reported no
    /// reasoning: its question and answer stand alone.
    var receipt: String? {
        guard let finishedAt, !isEmpty else { return nil }
        let worked = "Worked \(Self.durationWords(finishedAt.timeIntervalSince(startedAt)))"
        guard !steps.isEmpty else { return worked }
        return "\(worked) · \(steps.count) \(steps.count == 1 ? "step" : "steps")"
    }

    /// "12 seconds", "1 minute", "3 minutes", "1 hour, 5 minutes".
    static func durationWords(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = seconds < 60 ? [.second] : [.hour, .minute]
        let rounded = seconds < 60 ? max(1, seconds.rounded()) : (seconds / 60).rounded() * 60
        return formatter.string(from: rounded) ?? ""
    }

    /// "0:12", "4:05", "1:02:09": a step's offset from the start of the turn.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
