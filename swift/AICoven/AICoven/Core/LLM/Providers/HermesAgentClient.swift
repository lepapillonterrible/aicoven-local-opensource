import Foundation

/// One thing a Hermes run reports while it works.
nonisolated enum HermesRunEvent: Equatable {
    /// More of the answer.
    case text(String)
    case reasoning(String)
    case toolStarted(String)
    case toolCompleted(String, failed: Bool)
    /// Hermes is waiting to be allowed something.
    case approvalRequested(HermesApprovalRequest)
    case approvalResolved
    /// The run ended with an answer; nil when the event carried none and
    /// the text reported so far is the answer.
    case completed(output: String?)
    case failed(message: String?)
    case cancelled
}

/// What Hermes asks to be allowed to do, as far as it says.
nonisolated struct HermesApprovalRequest: Equatable {
    /// Hermes's own name for this request, where it gives one: the same
    /// request can be sent again while it waits.
    var id: String?
    var command: String?
    var description: String?
    var tool: String?
}

/// Where a Hermes run stands, read back from Hermes when its event stream
/// was lost.
nonisolated struct HermesRunState: Equatable {
    enum Status: Equatable {
        case running
        case waitingForApproval(HermesApprovalRequest)
        case completed(output: String?)
        case failed
        case cancelled
    }

    let status: Status
}

nonisolated enum HermesAgentError: LocalizedError, Equatable {
    case invalidAddress
    case refused(status: Int)
    case noRunID

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "The Hermes address is not a web address."
        case let .refused(status): "Hermes answered with HTTP \(status)."
        case .noRunID: "Hermes started no run."
        }
    }
}

/// The Hermes agent's own API (`/v1/runs`): start a run, follow its events,
/// answer what it asks to be allowed, stop it, and read where it stands.
/// Hermes runs the turn itself, with its own tools and memory; this app
/// shows it and answers for the person.
nonisolated struct HermesAgentClient {
    let baseURL: URL
    let apiKey: String?
    var session: URLSession = .shared

    /// Where a Hermes agent's API server listens unless it is told otherwise.
    static let usualAddress = "http://127.0.0.1:8642"

    /// The longest the event stream may stay silent before it is taken for
    /// lost: Hermes sends keep-alives while a tool or the model works.
    static let streamSilenceLimit: TimeInterval = 90

    struct Message: Equatable {
        let role: String
        let content: String
    }

    // MARK: - Requests

    /// Starts a run with the person's message and what was said before, in
    /// the Hermes session `sessionKey` names, and returns the run's id.
    func startRun(input: String, history: [Message], model: String?, sessionKey: String) async throws -> String {
        var body: [String: Any] = [
            "input": input,
            "conversation_history": history.map { ["role": $0.role, "content": $0.content] },
            "session_id": sessionKey,
        ]
        if let model, !model.isEmpty {
            body["model"] = model
        }
        var request = try request(path: ["v1", "runs"], method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sessionKey, forHTTPHeaderField: "X-Hermes-Session-Key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request)
        guard let created = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runID = (created["run_id"] as? String).flatMap(Self.validRunID) else {
            throw HermesAgentError.noRunID
        }
        return runID
    }

    /// The run's events, in order, until it ends or the stream is lost. A
    /// stream that ends without a `completed`, `failed` or `cancelled` was
    /// lost: `state(of:)` says where the run stands.
    func events(of runID: String) -> AsyncThrowingStream<HermesRunEvent, Error> {
        AsyncThrowingStream { continuation in
            let reading = Task {
                do {
                    var request = try request(path: ["v1", "runs", runID, "events"], method: "GET")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = Self.streamSilenceLimit
                    let (bytes, response) = try await session.bytes(for: request)
                    try Self.requireSuccess(response)
                    for try await line in bytes.lines {
                        // Lines that start with ":" are keep-alives.
                        guard line.hasPrefix("data:") else { continue }
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = json.data(using: .utf8),
                              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let event = Self.event(from: raw) else { continue }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reading.cancel() }
        }
    }

    func state(of runID: String) async throws -> HermesRunState {
        let data = try await send(request(path: ["v1", "runs", runID], method: "GET"))
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HermesAgentError.refused(status: 200)
        }
        return Self.state(from: raw)
    }

    /// Answers what the run is waiting to be allowed: this once, or not.
    func answerApproval(of runID: String, approve: Bool) async throws {
        var request = try request(path: ["v1", "runs", runID, "approval"], method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["choice": approve ? "once" : "deny"])
        _ = try await send(request)
    }

    func stop(_ runID: String) async throws {
        _ = try await send(request(path: ["v1", "runs", runID, "stop"], method: "POST"))
    }

    // MARK: - Reading what Hermes sends

    /// One event of the stream, or nil for one this app shows nothing for.
    static func event(from raw: [String: Any]) -> HermesRunEvent? {
        switch raw["event"] as? String {
        case "message.delta":
            (raw["delta"] as? String).flatMap { $0.isEmpty ? nil : .text($0) }
        case "reasoning.available":
            bounded(raw["text"], to: 2000).map(HermesRunEvent.reasoning)
        case "tool.started":
            .toolStarted(bounded(raw["tool"], to: 160) ?? "tool")
        case "tool.completed":
            .toolCompleted(bounded(raw["tool"], to: 160) ?? "tool", failed: raw["error"] as? Bool ?? false)
        case "approval.request":
            .approvalRequested(approvalRequest(from: raw))
        case "approval.resolved", "approval.responded":
            .approvalResolved
        case "run.completed":
            .completed(output: output(of: raw))
        case "run.failed":
            .failed(message: bounded(raw["error"], to: 500) ?? bounded(raw["message"], to: 500))
        case "run.cancelled":
            .cancelled
        default:
            nil
        }
    }

    static func state(from raw: [String: Any]) -> HermesRunState {
        let status = (raw["status"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lastEvent = (raw["last_event"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if status == "waiting_for_approval" || lastEvent == "approval.request" {
            return HermesRunState(status: .waitingForApproval(approvalRequest(from: raw)))
        }
        switch status {
        case "completed": return HermesRunState(status: .completed(output: output(of: raw)))
        case "failed": return HermesRunState(status: .failed)
        case "cancelled": return HermesRunState(status: .cancelled)
        default: return HermesRunState(status: .running)
        }
    }

    /// What an approval request says it is for. Hermes puts the command, a
    /// description and the tool's name under different names and at
    /// different depths from one version to the next, so each is looked for
    /// in the event and in what it nests, and cut to a length.
    static func approvalRequest(from raw: [String: Any]) -> HermesApprovalRequest {
        var places: [[String: Any]] = [raw]
        var next: [[String: Any]] = [raw]
        let nested = ["payload", "request", "approval", "approval_request", "pending_approval", "details", "tool_call", "action", "input", "args", "arguments"]
        while !next.isEmpty, places.count < 16 {
            let current = next.removeFirst()
            for key in nested {
                if let inner = current[key] as? [String: Any] {
                    places.append(inner)
                    next.append(inner)
                }
            }
        }
        func first(_ keys: [String], limit: Int) -> String? {
            for place in places {
                for key in keys {
                    if let found = bounded(place[key], to: limit) { return found }
                }
            }
            return nil
        }
        return HermesApprovalRequest(
            id: first(["approval_id"], limit: 240),
            command: first(["command", "cmd", "shell_command"], limit: 4000),
            description: first(["description", "preview", "message", "title", "summary"], limit: 2000),
            tool: first(["tool_name", "tool", "name", "toolName"], limit: 160)
        )
    }

    /// A run id as it may appear in a path: Hermes's own ids are letters,
    /// digits, dashes and underscores.
    static func validRunID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard !trimmed.isEmpty, trimmed.count <= 240, trimmed != ".", trimmed != "..",
              trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return trimmed
    }

    private static func output(of raw: [String: Any]) -> String? {
        for key in ["output", "final_response"] {
            if let text = raw[key] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    private static func bounded(_ value: Any?, to limit: Int) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text.count > limit ? String(text.prefix(limit)) : text
    }

    // MARK: - Private

    private func request(path: [String], method: String) throws -> URLRequest {
        guard baseURL.host != nil, ["http", "https"].contains(baseURL.scheme?.lowercased() ?? "") else {
            throw HermesAgentError.invalidAddress
        }
        var request = URLRequest(url: path.reduce(baseURL) { $0.appendingPathComponent($1) })
        request.httpMethod = method
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try Self.requireSuccess(response)
        return data
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw HermesAgentError.refused(status: 0) }
        guard (200 ... 299).contains(http.statusCode) else { throw HermesAgentError.refused(status: http.statusCode) }
    }
}
