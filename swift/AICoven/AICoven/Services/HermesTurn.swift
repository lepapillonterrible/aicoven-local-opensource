import Foundation

/// One reply made by a Hermes run. Hermes does the work, with its own tools
/// and memory; this follows the run and reports it as the reply loop reports
/// its own turns, so the thread shows the same status line, work trace and
/// approvals for it. Stopping the task that runs it stops the run.
nonisolated struct HermesTurn {
    let client: HermesAgentClient
    let threadID: String
    /// Asks the person, and waits for the answer.
    var ask: @Sendable (ToolApproval) async -> ApprovalAnswer = ToolExecutionService.askInItsThread
    /// How long to wait before looking again for a run whose events were
    /// lost, and how many looks in a row may fail to reach Hermes.
    var lookAgainAfter: Duration = .seconds(2)
    var looksBeforeGivingUp = 90

    static let lostContact = "AICoven lost contact with Hermes before the run ended. It may still be running there."
    static let runGone = "Hermes no longer has this run."
    static let notFinished = "Hermes could not finish this run."

    /// Starts the run and follows it to its end. The last report is the
    /// outcome: completed with the answer, or failed with what went wrong.
    /// Throws `CancellationError` when the run was stopped, here or in
    /// Hermes, and whatever starting the run threw.
    func run(
        input: String,
        history: [HermesAgentClient.Message],
        model: String?,
        report: @escaping @Sendable (TurnState) -> Void
    ) async throws {
        let runID = try await client.startRun(input: input, history: history, model: model, sessionKey: threadID)
        try await withTaskCancellationHandler {
            var following = Following(state: TurnState(threadId: threadID))
            try await follow(runID, &following, report)
        } onCancel: {
            // The run is Hermes's own: it goes on unless it is told to stop.
            Task { try? await client.stop(runID) }
        }
    }

    /// What has been seen of the run so far.
    private struct Following {
        var state: TurnState
        var toolsStarted = 0
        /// The request being answered or just answered, for one Hermes
        /// gave no name to: it can be sent again while it waits, and is
        /// not asked again until the run has moved on.
        var approvalPending = false
        /// The requests answered, by the names Hermes gave them.
        var approvalsAnswered: Set<String> = []
    }

    private func follow(_ runID: String, _ following: inout Following, _ report: @Sendable (TurnState) -> Void) async throws {
        var failedLooks = 0
        while true {
            try Task.checkCancellation()
            do {
                for try await event in client.events(of: runID) {
                    if try await take(event, of: runID, &following, report) { return }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The stream was lost, not the run: where it stands is read
                // back below.
            }
            try Task.checkCancellation()
            do {
                let standing = try await client.state(of: runID)
                failedLooks = 0
                switch standing.status {
                case let .completed(output):
                    return finish(&following, with: output, report)
                case .failed:
                    return fail(&following, saying: Self.notFinished, report)
                case .cancelled:
                    throw CancellationError()
                case let .waitingForApproval(request):
                    try await answer(request, of: runID, &following)
                case .running:
                    following.approvalPending = false
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch HermesAgentError.refused(status: 404) {
                return fail(&following, saying: Self.runGone, report)
            } catch {
                failedLooks += 1
                guard failedLooks < looksBeforeGivingUp else {
                    return fail(&following, saying: Self.lostContact, report)
                }
            }
            try await Task.sleep(for: lookAgainAfter)
        }
    }

    /// Takes one event into what the thread shows. True when the run ended.
    private func take(
        _ event: HermesRunEvent,
        of runID: String,
        _ following: inout Following,
        _ report: @Sendable (TurnState) -> Void
    ) async throws -> Bool {
        switch event {
        case let .text(delta):
            following.approvalPending = false
            following.state.phase = .answering
            following.state.answer += delta
        case let .reasoning(text):
            following.approvalPending = false
            following.state.phase = .planning
            following.state.scratchpad = text
        case let .toolStarted(name):
            following.approvalPending = false
            following.toolsStarted += 1
            let id = "hermes-\(following.toolsStarted)"
            following.state.phase = .tooling
            following.state.toolsInProgress[id] = TurnToolCall(id: id, name: name, arguments: [:], result: nil, status: "running")
        case let .toolCompleted(name, failed):
            // Hermes names the tool, not the call: the earliest call of
            // that tool still running is the one that ended.
            let running = following.state.toolsInProgress.values.filter { $0.name == name }.min { $0.id.count == $1.id.count ? $0.id < $1.id : $0.id.count < $1.id.count }
            following.toolsStarted += running == nil ? 1 : 0
            var call = running ?? TurnToolCall(id: "hermes-\(following.toolsStarted)", name: name, arguments: [:], result: nil, status: "running")
            following.state.toolsInProgress[call.id] = nil
            call.status = failed ? "failed" : "completed"
            following.state.phase = .tooling
            following.state.toolsCompleted.append(call)
        case let .approvalRequested(request):
            try await answer(request, of: runID, &following)
            return false
        case .approvalResolved:
            following.approvalPending = false
            return false
        case let .completed(output):
            finish(&following, with: output, report)
            return true
        case let .failed(message):
            fail(&following, saying: message.map { "\(Self.notFinished) \($0)" } ?? Self.notFinished, report)
            return true
        case .cancelled:
            throw CancellationError()
        }
        following.state.bumpVersion()
        report(following.state)
        return false
    }

    /// Asks the person about what Hermes is waiting to be allowed, once,
    /// and gives Hermes the answer. Where the person cannot be asked, the
    /// answer is no.
    private func answer(_ request: HermesApprovalRequest, of runID: String, _ following: inout Following) async throws {
        if let id = request.id {
            guard following.approvalsAnswered.insert(id).inserted else { return }
        } else {
            guard !following.approvalPending else { return }
        }
        following.approvalPending = true
        switch await ask(.hermes(request, threadID: threadID)) {
        case .approved:
            try await client.answerApproval(of: runID, approve: true)
        case .denied, .notAsked:
            try await client.answerApproval(of: runID, approve: false)
        case .withdrawn:
            throw CancellationError()
        }
    }

    private func finish(_ following: inout Following, with output: String?, _ report: @Sendable (TurnState) -> Void) {
        // What Hermes gives as the run's output is the answer; the text it
        // reported on the way is, where it gives none.
        following.state.answer = output ?? following.state.answer
        following.state.phase = .finalizing
        following.state.status = .completed
        following.state.bumpVersion()
        report(following.state)
    }

    private func fail(_ following: inout Following, saying message: String, _ report: @Sendable (TurnState) -> Void) {
        following.state.answer = message
        following.state.phase = .finalizing
        following.state.status = .failed
        following.state.bumpVersion()
        report(following.state)
    }
}
