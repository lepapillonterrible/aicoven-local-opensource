import Foundation

/// One reply made by OpenClaw through its native Gateway. OpenClaw does the
/// work, with its own tools; this starts the run in the thread's session,
/// follows what the Gateway says of it, and reports it as the reply loop
/// reports its own turns, so the thread shows the same status line and
/// approvals for it. Stopping the task that runs it stops the run. A run
/// this app was closed on is picked up again with `resume`.
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

    /// The kinds of request a Gateway asks to be allowed: a command, a
    /// plugin's action, an agent's own.
    static let approvalKinds: Set<String> = ["exec", "plugin", "system-agent"]

    static let lostContact = "AICoven lost contact with OpenClaw before the run ended. It may still be running there."
    static let notFinished = "OpenClaw could not finish this run."
    static let runGone = "OpenClaw no longer has this run. It may have been restarted since."
    static let noAnswerToShow = "OpenClaw finished this run, which went on while AICoven was closed, and its answer could not be read here. It is in OpenClaw."
    /// The Gateway the run was started through is no longer the one
    /// connected.
    struct CannotPickUp: LocalizedError, Equatable {
        var errorDescription: String? {
            "The OpenClaw run this reply was waiting on can no longer be picked up."
        }
    }

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
        try await withGateway { gateway in
            var following = try await subscribe(through: gateway)
            // What was already waiting to be allowed was asked by an earlier
            // run, and is not this one's to ask about.
            following.settled = Set(following.waiting.compactMap { $0["id"] as? String })
            // Whatever is still asked when the turn ends is withdrawn.
            defer { following.withdrawAll() }

            // The Gateway names the run by what it was asked with, so a turn
            // stopped before the Gateway answers can still stop the run.
            var runID = UUID().uuidString
            try Task.checkCancellation()
            // Asked without waiting. If it cannot be asked, no run began;
            // once it is, the request has its place and is sent whatever
            // becomes of the turn, so the stop that follows it is of a run
            // the Gateway was asked for.
            let answer = try await gateway.ask("chat.send", ["sessionKey": following.sessionKey, "message": message, "idempotencyKey": runID])
            do {
                let sent: [String: Any]
                do {
                    // No answer and no failure: the turn was stopped as it waited.
                    guard let answered = try await OpenClawGatewayConnection.first(of: answer) else { throw CancellationError() }
                    // An answer that says nothing of the run leaves it named
                    // as it was asked for.
                    sent = (try? Self.object(answered)) ?? [:]
                } catch let error as OpenClawGatewayError where error != .closed {
                    // The Gateway refused the run: none began.
                    throw error
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The connection ended, or failed, with the run asked
                    // for and not answered: it may have begun.
                    try Task.checkCancellation()
                    var state = TurnState(threadId: threadID)
                    return end(&state, as: .failed, saying: Self.lostContact, report)
                }
                if let named = sent["runId"] as? String, !named.isEmpty {
                    runID = named
                }
                await started(runID)
                try await follow(runID, &following, through: gateway, report)
            } catch {
                if Task.isCancelled {
                    following.withdrawAll()
                    await stop(runID, in: following.sessionKey, through: gateway)
                }
                throw error
            }
        }
    }

    /// Picks up a run started earlier, which went on in OpenClaw while this
    /// app was closed: where it stands is read first, since it may have
    /// ended, and it is followed from there. What it had answered before is
    /// not known here; a run that ends with an answer shows it whole. What
    /// it is waiting to be allowed is asked again: the question the app was
    /// closed on went with it. Ends as `run` does.
    func resume(runID: String, report: @escaping @Sendable (TurnState) -> Void) async throws {
        try await withGateway { gateway in
            var following = try await subscribe(through: gateway)
            defer { following.withdrawAll() }
            do {
                let ended: (status: TurnStatus, answer: String)?
                do {
                    ended = try await ending(of: runID, in: following.sessionKey, through: gateway)
                } catch let error as OpenClawGatewayError where error != .closed {
                    // The Gateway's own refusal, or an answer that is not one.
                    throw error
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The connection ended, or failed, as the run was
                    // looked for.
                    try Task.checkCancellation()
                    ended = (.failed, Self.lostContact)
                }
                if let ended {
                    var state = TurnState(threadId: threadID)
                    return end(&state, as: ended.status, saying: ended.answer, report)
                }
                for approval in following.waiting {
                    consider(approval, phase: "pending", &following, through: gateway)
                }
                try await follow(runID, &following, through: gateway, report)
            } catch {
                if Task.isCancelled {
                    following.withdrawAll()
                    await stop(runID, in: following.sessionKey, through: gateway)
                }
                throw error
            }
        }
    }

    /// What a turn holds of the session its run is in.
    private struct Following {
        /// The Gateway's own name for the session: the one its events use.
        let sessionKey: String
        /// What was waiting to be allowed when the session was subscribed to.
        let waiting: [[String: Any]]
        /// The requests asked about or settled, by the Gateway's ids.
        var settled: Set<String> = []
        /// What the person is being asked, by the Gateway's id for it.
        var asking: [String: Task<Void, Never>] = [:]

        mutating func withdrawAll() {
            asking.values.forEach { $0.cancel() }
            asking = [:]
        }
    }

    /// Opens a connection for `work` and closes it after, however it ends.
    private func withGateway(_ work: (OpenClawGatewayConnection) async throws -> Void) async throws {
        let (gateway, hello) = try await open(address, token)
        if let missing = hello.missing {
            await gateway.close()
            throw OpenClawGatewayError.notSupported(missing)
        }
        do {
            try await work(gateway)
        } catch {
            await gateway.close()
            throw Task.isCancelled ? CancellationError() : error
        }
        await gateway.close()
    }

    /// Subscribes to the thread's session: its events from here on, and
    /// what is waiting to be allowed in it.
    private func subscribe(through gateway: OpenClawGatewayConnection) async throws -> Following {
        let subscribed = try await Self.object(gateway.call("sessions.messages.subscribe", [
            "subscriptionId": "aicoven:\(UUID().uuidString)",
            "key": Self.sessionKey(for: threadID),
            "includeApprovals": true,
        ]))
        return Following(
            sessionKey: (subscribed["key"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Self.sessionKey(for: threadID),
            waiting: (subscribed["approvalReplay"] as? [String: Any])?["approvals"] as? [[String: Any]] ?? []
        )
    }

    /// Follows the run's events to its end, asking the person about what it
    /// asks to be allowed. If the events end first, the turn ends failed.
    private func follow(
        _ runID: String,
        _ following: inout Following,
        through gateway: OpenClawGatewayConnection,
        _ report: @Sendable (TurnState) -> Void
    ) async throws {
        var state = TurnState(threadId: threadID)
        do {
            for try await event in gateway.events {
                let payload = try Self.object(event.payload)
                switch event.name {
                case "chat":
                    guard payload["sessionKey"] as? String == following.sessionKey, payload["runId"] as? String == runID else { continue }
                    if take(payload, into: &state, report) { return }
                case "session.approval":
                    let from = [payload["sessionKey"] as? String, payload["sourceSessionKey"] as? String]
                    guard from.contains(following.sessionKey), let approval = payload["approval"] as? [String: Any] else { continue }
                    consider(approval, phase: payload["phase"] as? String, &following, through: gateway)
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

    /// Takes what the Gateway says of a request to be allowed: one waiting
    /// is asked of the person, once; one settled there (answered elsewhere,
    /// or no longer wanted) is no longer asked here.
    private func consider(_ approval: [String: Any], phase: String?, _ following: inout Following, through gateway: OpenClawGatewayConnection) {
        guard let id = approval["id"] as? String else { return }
        switch phase {
        case "pending":
            guard following.settled.insert(id).inserted else { return }
            // An answer names the kind of request it answers. One of no
            // kind this app knows cannot be answered, and is not asked: as
            // in the cloud app, it is left to the Gateway.
            let presentation = approval["presentation"] as? [String: Any] ?? [:]
            guard let kind = presentation["kind"] as? String, Self.approvalKinds.contains(kind) else {
                return AppErrorReporter.log(message: "An approval of a kind this app does not know was not asked.", context: "OpenClawTurn.approval")
            }
            // Asked apart, so the run's events are still followed while
            // the person decides.
            following.asking[id] = answering(presentation, id: id, kind: kind, through: gateway)
        case "terminal":
            following.settled.insert(id)
            following.asking.removeValue(forKey: id)?.cancel()
        default:
            return
        }
    }

    /// How a run ended, or nil while it is still going: what `agent.wait`
    /// says of it, and what the session's history holds of it, which is
    /// where its answer is.
    private func ending(of runID: String, in sessionKey: String, through gateway: OpenClawGatewayConnection) async throws -> (status: TurnStatus, answer: String)? {
        let waited = try await Self.object(gateway.call("agent.wait", ["runId": runID, "timeoutMs": 1000]))
        let status = waited["status"] as? String ?? ""
        // Every finished run has an end time: without one, "ok" and
        // "timeout" are of a run still going.
        let hasEnded = waited["endedAt"] is NSNumber
        if status == "error" || (status == "timeout" && hasEnded) {
            let reason = (waited["stopReason"] as? String ?? "").lowercased()
            return ["rpc", "stop", "aborted"].contains(reason) ? (.cancelled, "") : (.failed, Self.failure(in: waited))
        }
        let history = try await Self.object(gateway.call("chat.history", [
            "sessionKey": sessionKey, "inputRunIds": [runID], "limit": 20, "maxChars": Self.longestMessage,
        ]))
        let held = Self.ending(of: runID, in: history)
        if status == "ok", hasEnded {
            return held ?? (.completed, Self.noAnswerToShow)
        }
        switch Self.isGoing(runID, in: history) {
        case true?: return nil
        // Neither going nor ended as far as its history shows: the Gateway
        // has lost it.
        case false?: return held ?? (.failed, Self.runGone)
        // The history does not say: `agent.wait` did, that it is going.
        case nil: return nil
        }
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
    private func answering(_ presentation: [String: Any], id: String, kind: String, through gateway: OpenClawGatewayConnection) -> Task<Void, Never> {
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

    /// Whether the session's history says the run is going, or nil where
    /// it does not say.
    static func isGoing(_ runID: String, in history: [String: Any]) -> Bool? {
        if (history["inFlightRun"] as? [String: Any])?["runId"] as? String == runID { return true }
        guard let session = history["sessionInfo"] as? [String: Any] else { return nil }
        if let going = session["activeRunIds"] as? [String] { return going.contains(runID) }
        return session["hasActiveRun"] as? Bool
    }

    /// How the run ended, from the newest row of the session's history
    /// that is the run's, or nil if that row does not end it: stopped;
    /// failed; or answered, by an assistant's row that stopped of itself,
    /// calls no tool and has text.
    static func ending(of runID: String, in history: [String: Any]) -> (status: TurnStatus, answer: String)? {
        let rows = (history["messages"] as? [[String: Any]] ?? []).filter {
            ($0["__openclaw"] as? [String: Any])?["runId"] as? String == runID
                && ["assistant", "toolResult"].contains($0["role"] as? String ?? "")
        }
        guard let newest = rows.last, newest["role"] as? String == "assistant" else { return nil }
        let reason = (newest["stopReason"] as? String ?? "").lowercased()
        let text = finalText(in: ["message": newest])
        if (newest["openclawAbort"] as? [String: Any])?["aborted"] as? Bool == true || reason == "aborted" {
            return (.cancelled, text ?? "")
        }
        if reason == "error" {
            return (.failed, failure(in: newest))
        }
        let callsATool = (newest["content"] as? [[String: Any]])?.contains {
            ["toolCall", "toolUse", "functionCall"].contains($0["type"] as? String ?? "")
        } ?? false
        guard ["stop", "length"].contains(reason), !callsATool,
              let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (.completed, text)
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
