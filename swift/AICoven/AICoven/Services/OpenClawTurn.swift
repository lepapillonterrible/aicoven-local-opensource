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

    /// How long a stopped turn waits for the Gateway to take the stop.
    var longestWaitToStop: TimeInterval = 5

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
        do {
            try await follow(gateway, message: message, started: started, report)
        } catch {
            await gateway.close()
            throw Task.isCancelled ? CancellationError() : error
        }
        await gateway.close()
    }

    private func follow(
        _ gateway: OpenClawGatewayConnection,
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
        // What the person is being asked, by the Gateway's id for it.
        var asking: [String: Task<Void, Never>] = [:]
        // Whatever is still asked when the turn ends is withdrawn.
        defer { asking.values.forEach { $0.cancel() } }

        // The Gateway names the run by what it was asked with, so a turn
        // stopped before the Gateway answers can still stop the run.
        var runID = UUID().uuidString
        try Task.checkCancellation()
        do {
            let sent: [String: Any]
            do {
                let answered = try await send(message, as: runID, in: sessionKey, through: gateway)
                // An answer that says nothing of the run leaves it named
                // as it was asked for.
                sent = (try? Self.object(answered)) ?? [:]
            } catch let error as OpenClawGatewayError where error != .closed {
                // The Gateway refused the run, or it was not sent: no run began.
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The connection ended, or failed, with the run asked for
                // and not answered: it may have begun.
                try Task.checkCancellation()
                var state = TurnState(threadId: threadID)
                return end(&state, as: .failed, saying: Self.lostContact, report)
            }
            if let named = sent["runId"] as? String, !named.isEmpty {
                runID = named
            }
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
                        guard from.contains(sessionKey), let approval = payload["approval"] as? [String: Any],
                              let id = approval["id"] as? String else { continue }
                        switch payload["phase"] as? String {
                        case "pending":
                            guard settled.insert(id).inserted else { continue }
                            // Asked apart, so the run's events are still
                            // followed while the person decides.
                            asking[id] = answering(approval, id: id, through: gateway)
                        case "terminal":
                            // Settled there (answered elsewhere, or no
                            // longer wanted): no longer asked here.
                            settled.insert(id)
                            asking.removeValue(forKey: id)?.cancel()
                        default:
                            continue
                        }
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
        } catch {
            if Task.isCancelled {
                asking.values.forEach { $0.cancel() }
                await stop(runID, in: sessionKey, through: gateway)
            }
            throw error
        }
    }

    /// Asks the Gateway to start the run, and waits for its answer. Asked
    /// from a task of its own, which stopping the turn does not stop: once
    /// asked for, the request is sent, so the stop that follows it is of a
    /// run the Gateway was asked for. A stopped turn no longer waits for
    /// the answer.
    private func send(_ message: String, as runID: String, in sessionKey: String, through gateway: OpenClawGatewayConnection) async throws -> Data {
        let (answers, answer) = AsyncThrowingStream<Data, Error>.makeStream()
        Task {
            do {
                try await answer.yield(gateway.call("chat.send", ["sessionKey": sessionKey, "message": message, "idempotencyKey": runID]))
                answer.finish()
            } catch {
                answer.finish(throwing: error)
            }
        }
        for try await answered in answers {
            return answered
        }
        // Ended with no answer: the turn was stopped while it waited.
        throw CancellationError()
    }

    /// Tells the Gateway to stop a run. The run is OpenClaw's own: it goes
    /// on unless it is told to stop. Asked from a task of its own, as the
    /// turn's task is cancelled and what it asks is dropped.
    private func stop(_ runID: String, in sessionKey: String, through gateway: OpenClawGatewayConnection) async {
        let asking = Task {
            do {
                _ = try await gateway.call("chat.abort", ["sessionKey": sessionKey, "runId": runID])
            } catch {
                // The turn has stopped here; the run may not have there.
                AppErrorReporter.log(message: "The Gateway did not take the stop (\(Self.kind(of: error))).", context: "OpenClawTurn.stop")
            }
        }
        let givingUp = Task { [longestWaitToStop] in
            try await Task.sleep(nanoseconds: UInt64(longestWaitToStop * 1_000_000_000))
            // Ends the wait for an answer.
            await gateway.close()
        }
        await asking.value
        givingUp.cancel()
    }

    /// What kind of failure, for the log: never what the Gateway said,
    /// which can carry what a run was about.
    private static func kind(of error: Error) -> String {
        switch error {
        case OpenClawGatewayError.refused: "refused"
        case OpenClawGatewayError.closed: "closed"
        case is CancellationError: "stopped"
        default: String(describing: type(of: error))
        }
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
    /// cannot be asked, the answer is no. Cancelling the task withdraws
    /// the question, and nothing is answered.
    private func answering(_ approval: [String: Any], id: String, through gateway: OpenClawGatewayConnection) -> Task<Void, Never> {
        let presentation = approval["presentation"] as? [String: Any] ?? [:]
        let kind = presentation["kind"] as? String ?? "exec"
        let question = ToolApproval.openClaw(presentation, threadID: threadID)
        return Task { [ask] in
            let decision: String
            switch await ask(question) {
            case .approved: decision = "allow-once"
            case .denied, .notAsked: decision = "deny"
            case .withdrawn: return
            }
            do {
                _ = try await gateway.call("approval.resolve", ["id": id, "kind": kind, "decision": decision])
            } catch {
                // What becomes of the run is the Gateway's to say, in its
                // events.
                AppErrorReporter.log(message: "The Gateway did not take the answer (\(Self.kind(of: error))).", context: "OpenClawTurn.answer")
            }
        }
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
