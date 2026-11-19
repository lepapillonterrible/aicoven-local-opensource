import Foundation

/// One reply made by OpenClaw through its native Gateway. OpenClaw does the
/// work, with its own tools; this starts the run in the thread's session,
/// follows what the Gateway says of it, and reports it as the reply loop
/// reports its own turns, so the thread shows the same status line and
/// approvals for it. Stopping the task that runs it stops the run.
nonisolated struct OpenClawTurn {
    let address: URL
    let token: String?
    let threadID: String
    /// Asks the person, and waits for the answer.
    var ask: @Sendable (ToolApproval) async -> ApprovalAnswer = ToolExecutionService.askInItsThread
    /// Opens a connection to the Gateway.
    var open: @Sendable (URL, String?) async throws -> (gateway: OpenClawGatewayConnection, hello: OpenClawGatewayHello) = {
        try await OpenClawGateway.open($0, token: $1)
    }

    static let lostContact = "AICoven lost contact with OpenClaw before the run ended. It may still be running there."
    static let notFinished = "OpenClaw could not finish this run."
    /// The most text a run is started with.
    static let longestMessage = 65536

    /// The OpenClaw session a thread's turns run in.
    static func sessionKey(for threadID: String) -> String {
        "aicoven-local:\(threadID)"
    }

    /// Starts the run and follows it to its end. The last report is the
    /// outcome: completed with the answer, failed with what went wrong, or
    /// cancelled, with what had been answered, when OpenClaw says the run
    /// was stopped there. Throws `CancellationError` when the turn itself
    /// was stopped, and whatever opening the Gateway or starting the run
    /// threw. `started` is told the run's id as soon as there is one.
    func run(
        message: String,
        started: @Sendable (_ runID: String) async -> Void = { _ in },
        report: @escaping @Sendable (TurnState) -> Void
    ) async throws {
        let (gateway, hello) = try await open(address, token)
        if let missing = hello.missing {
            await gateway.close()
            throw OpenClawGatewayError.notSupported(missing)
        }
        let running = Running()
        do {
            try await follow(gateway, running, message: message, started: started, report)
        } catch {
            let stopped = Task.isCancelled
            if stopped, let run = running.run {
                await Self.stop(run, through: gateway)
            }
            await gateway.close()
            throw stopped ? CancellationError() : error
        }
        await gateway.close()
    }

    /// How long a stopped turn waits for the Gateway to take the stop.
    static let longestWaitToStop: TimeInterval = 5

    /// Tells the Gateway to stop a run. The run is OpenClaw's own: it goes
    /// on unless it is told to stop. Asked from a task of its own, as the
    /// turn's task is cancelled and what it asks is dropped.
    private static func stop(_ run: (sessionKey: String, id: String), through gateway: OpenClawGatewayConnection) async {
        let asking = Task {
            do {
                _ = try await gateway.call("chat.abort", ["sessionKey": run.sessionKey, "runId": run.id])
            } catch {
                // The turn has stopped here; the run may not have there.
                AppErrorReporter.log(error: error, context: "OpenClawTurn.stop")
            }
        }
        let givingUp = Task {
            try await Task.sleep(nanoseconds: UInt64(longestWaitToStop * 1_000_000_000))
            // Ends the wait for an answer.
            await gateway.close()
        }
        await asking.value
        givingUp.cancel()
    }

    /// The run a turn has started, for stopping it.
    private final class Running: @unchecked Sendable {
        // Set by the turn's task as the run is started, and read once the
        // turn has ended: under the lock.
        private let lock = NSLock()
        private var started: (sessionKey: String, id: String)?

        var run: (sessionKey: String, id: String)? {
            get { lock.withLock { started } }
            set { lock.withLock { started = newValue } }
        }
    }

    private func follow(
        _ gateway: OpenClawGatewayConnection,
        _ running: Running,
        message: String,
        started: @Sendable (String) async -> Void,
        _ report: @Sendable (TurnState) -> Void
    ) async throws {
        // The session's events first, so none of the run's is missed.
        let subscribed = try await Self.object(gateway.call("sessions.messages.subscribe", [
            "subscriptionId": "aicoven:\(UUID().uuidString)",
            "key": Self.sessionKey(for: threadID),
            "includeApprovals": true,
        ]))
        // The Gateway's own name for the session is the one its events use.
        let sessionKey = (subscribed["key"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Self.sessionKey(for: threadID)
        // What was already waiting to be allowed was asked by an earlier
        // run, and is not this one's to ask about.
        let replayed = (subscribed["approvalReplay"] as? [String: Any])?["approvals"] as? [[String: Any]] ?? []
        var settled = Set(replayed.compactMap { $0["id"] as? String })

        let asked = UUID().uuidString
        try Task.checkCancellation()
        // The Gateway names the run by what it was asked with, so a turn
        // stopped before the Gateway answers can still stop the run.
        running.run = (sessionKey, asked)
        let sent = try await Self.object(gateway.call("chat.send", ["sessionKey": sessionKey, "message": message, "idempotencyKey": asked]))
        let runID = (sent["runId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? asked
        running.run = (sessionKey, runID)
        await started(runID)

        var state = TurnState(threadId: threadID)
        do {
            for try await event in gateway.events {
                let payload = try Self.object(event.payload)
                switch event.name {
                case "chat":
                    guard payload["sessionKey"] as? String == sessionKey, payload["runId"] as? String == runID else { continue }
                    if take(payload, into: &state, report) { return }
                case "session.approval":
                    let from = [payload["sessionKey"] as? String, payload["sourceSessionKey"] as? String]
                    guard from.contains(sessionKey), payload["phase"] as? String == "pending",
                          let approval = payload["approval"] as? [String: Any],
                          let id = approval["id"] as? String, settled.insert(id).inserted else { continue }
                    try await answer(approval, id: id, through: gateway)
                default:
                    continue
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
        }
        // The events ended before the run did.
        try Task.checkCancellation()
        end(&state, as: .failed, saying: Self.lostContact, report)
    }

    /// Takes one of the run's `chat` events into what the thread shows.
    /// True when the run ended.
    private func take(_ payload: [String: Any], into state: inout TurnState, _ report: @Sendable (TurnState) -> Void) -> Bool {
        switch payload["state"] as? String {
        case "delta":
            guard let text = payload["deltaText"] as? String else { return false }
            state.phase = .answering
            state.answer = payload["replace"] as? Bool == true ? text : state.answer + text
            state.bumpVersion()
            report(state)
            return false
        case "final":
            end(&state, as: .completed, saying: Self.finalText(in: payload) ?? state.answer, report)
            return true
        case "error":
            end(&state, as: .failed, saying: Self.failure(in: payload), report)
            return true
        case "aborted":
            // Stopped there, not by this turn: with what had been answered.
            end(&state, as: .cancelled, saying: state.answer, report)
            return true
        default:
            // Its phases of getting ready are not shown.
            return false
        }
    }

    private func end(_ state: inout TurnState, as status: TurnStatus, saying answer: String, _ report: @Sendable (TurnState) -> Void) {
        state.answer = answer
        state.phase = .finalizing
        state.status = status
        state.bumpVersion()
        report(state)
    }

    /// Asks the person about what OpenClaw is waiting to be allowed, and
    /// gives the Gateway the answer: this once, or no. Where the person
    /// cannot be asked, the answer is no.
    private func answer(_ approval: [String: Any], id: String, through gateway: OpenClawGatewayConnection) async throws {
        let presentation = approval["presentation"] as? [String: Any] ?? [:]
        let kind = presentation["kind"] as? String ?? "exec"
        let decision: String
        switch await ask(.openClaw(presentation, threadID: threadID)) {
        case .approved: decision = "allow-once"
        case .denied, .notAsked: decision = "deny"
        case .withdrawn: throw CancellationError()
        }
        _ = try await gateway.call("approval.resolve", ["id": id, "kind": kind, "decision": decision])
    }

    // MARK: - Reading what the Gateway sends

    /// The run's answer as its last event gives it.
    static func finalText(in payload: [String: Any]) -> String? {
        for key in ["finalText", "text"] {
            if let text = payload[key] as? String, !text.isEmpty { return text }
        }
        let content = (payload["message"] as? [String: Any])?["content"]
        if let text = content as? String, !text.isEmpty { return text }
        if let parts = content as? [[String: Any]] {
            let text = parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? nil : text
        }
        return nil
    }

    /// What to say of a run that ended in an error, by its kind.
    static func failure(in payload: [String: Any]) -> String {
        let said = (payload["errorMessage"] as? String).map { String($0.prefix(500)) }
        let why = switch payload["errorKind"] as? String {
        case "context_length": "The conversation is too long for its model."
        case "refusal": "Its model refused."
        case "timeout": "It timed out."
        case "rate_limit": "Its model's provider is limiting requests."
        default: said ?? ""
        }
        return why.isEmpty ? notFinished : "\(notFinished) \(why)"
    }

    /// What a run is started with: the thread so far and the message, each
    /// under who said it, as the Gateway takes no history apart. If that is
    /// longer than a run takes, the oldest of the thread is left out.
    static func message(_ message: String, after earlier: [(role: String, content: String)]) -> String {
        var parts = earlier.filter { !$0.content.isEmpty }.map { "\($0.role):\n\($0.content)" }
        parts.append(earlier.isEmpty ? message : "user:\n\(message)")
        while parts.count > 1, parts.joined(separator: "\n\n").count > longestMessage {
            parts.removeFirst()
        }
        return String(parts.joined(separator: "\n\n").suffix(longestMessage))
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenClawGatewayError.unexpectedReply
        }
        return object
    }
}
