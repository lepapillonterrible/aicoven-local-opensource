@testable import AICoven
internal import Combine
import XCTest

/// A place's Tasks page: what it shows of the tasks it reads, adding one,
/// and marking one done, closed or open again, each as the account that
/// asked.
@MainActor
final class TasksModelTests: XCTestCase {
    private func task(
        _ id: String, _ title: String? = nil, status: TaskStatus = .open, due: TaskDue? = nil, pin: TaskPin? = nil, unreadable: Bool = false,
        coven: String? = nil
    ) -> TaskItem {
        TaskItem(
            id: id, covenID: coven, title: unreadable ? "" : title ?? id.capitalized, status: status, stage: .backlog, due: due, pin: pin,
            isUnreadable: unreadable, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// Wednesday 13 January 2027, 10:00 UTC, in a calendar whose week starts on Monday.
    private let now = Date(timeIntervalSince1970: 1_799_834_400)
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        calendar.firstWeekday = 2
        return calendar
    }()

    /// Holds whoever comes to it until the test lets them through.
    private actor Gate {
        private var held: [CheckedContinuation<Void, Never>] = []
        private var arrivals = 0
        private var hearing: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                held.append(continuation)
                arrivals += 1
                for heard in hearing where heard.count <= arrivals {
                    heard.continuation.resume()
                }
                hearing.removeAll { $0.count <= arrivals }
            }
        }

        /// Returns once `count` have come to wait.
        func arrived(_ count: Int) async {
            if arrivals >= count { return }
            await withCheckedContinuation { hearing.append((count, $0)) }
        }

        /// Lets the one who came first through.
        func letOneThrough() {
            if !held.isEmpty { held.removeFirst().resume() }
        }

        /// Lets the one who came last through, ahead of those before it.
        func letNewestThrough() {
            held.popLast()?.resume()
        }
    }

    /// What a source keeps and was asked, set by the test. Sendable by hand: used one step at a time.
    private final class Stand: @unchecked Sendable {
        var account = "ada"
        var kept: [TaskItem] = []
        var finishedInAll: Int?
        var readFails: Error?
        var readingWaits: Gate?
        var readings: [(covenID: String?, account: String)] = []
        /// The most finished tasks a reading lists, as the store's listing has a most.
        var mostFinished: Int?
        /// The task each reading was asked to list besides.
        var alsoAsked: [String?] = []
        var created: [(title: String, covenID: String?, account: String)] = []
        var createFails: Error?
        var creatingWaits: Gate?
        var changed: [(id: String, change: TaskChange, account: String)] = []
        var changeFails: Error?
        var changingWaits: Gate?
        /// What VoiceOver was told, in order.
        var heard: [String] = []
        /// The threads' and the agents' side.
        var agents: [TasksModel.Agent]? = []
        /// A coven's own agents, where a test of every place's tasks gives them; nil for a coven whose agents cannot be read.
        var agentsIn: [String: [TasksModel.Agent]?] = [:]
        var agentsAsked: [String] = []
        var agentsWait: Gate?
        var agentReadings = 0
        var strix = TasksModel.Agent.strix
        /// The agent the place's latest hand-off went to, as the store says it.
        var lastHandedTo: String?
        /// The same for each place, where a test of every place's tasks gives it.
        var lastHandedToIn: [String: String] = [:]
        var scopes: [TasksModel.Scope] = []
        var threads: [String: AICoven.Thread] = [:]
        var threadFails: Error?
        var threadWaits: Gate?
        var madeThreads: [(title: String, covenID: String?, agent: TasksModel.Agent?, account: String)] = []
        var started: [(threadID: String, text: String, agent: TasksModel.Agent?)] = []
        var startFails: Error?
        var startingWaits: Gate?
        /// How a turn just started stands by the time the task is read again.
        var startedAs = TurnOutcome.running
        var handedBack: [(text: String, threadID: String)] = []
        var discarded: [String] = []
        var live: [String: TaskLiveTurn] = [:]
        var answered: [(ids: [String], keepUntil: Date?, account: String)] = []
        var answerFails: Error?
        var answers: Set<String>?
        var answeringWaits: Gate?
    }

    private func model(_ stand: Stand, covenID: String? = nil, onMe: Bool = false) -> TasksModel {
        let tasks = TasksModel(
            scope: onMe ? .onMe : .place(covenID: covenID),
            source: TasksModel.Source(
                tasks: { scope, also, account in
                    // What is kept is read, or fails to be, as the reading is asked;
                    // what came of it is given once it is let through.
                    let outcome: Result<TaskListing, Error> = await MainActor.run {
                        var covenID: String?
                        if case let .place(place) = scope { covenID = place }
                        stand.scopes.append(scope)
                        stand.readings.append((covenID, account))
                        stand.alsoAsked.append(also)
                        if let error = stand.readFails { return .failure(error) }
                        let open = stand.kept.filter { !$0.isFinished }
                        let finished = stand.kept.filter(\.isFinished)
                        // As the store: the finished ones it lists, and the one asked for by name besides.
                        var listed = Array(finished.prefix(stand.mostFinished ?? finished.count))
                        if let also, !listed.contains(where: { $0.id == also }), let named = finished.first(where: { $0.id == also }) {
                            listed.append(named)
                        }
                        return .success(TaskListing(
                            tasks: open + listed, finished: stand.finishedInAll ?? finished.count,
                            lastHandedTo: scope == .onMe ? stand.lastHandedToIn : stand.lastHandedTo.map { [covenID ?? "": $0] } ?? [:]
                        ))
                    }
                    await MainActor.run { stand.readingWaits }?.wait()
                    return try outcome.get()
                },
                create: { title, covenID, account in
                    await MainActor.run { stand.creatingWaits }?.wait()
                    return try await MainActor.run {
                        if let error = stand.createFails { throw error }
                        stand.created.append((title, covenID, account))
                        let made = self.task("new-\(stand.created.count)", title)
                        stand.kept.insert(made, at: 0)
                        return made
                    }
                },
                change: { id, change, account in
                    await MainActor.run { stand.changingWaits }?.wait()
                    try await MainActor.run {
                        if let error = stand.changeFails { throw error }
                        stand.changed.append((id, change, account))
                        stand.kept = stand.kept.map { kept in
                            guard kept.id == id else { return kept }
                            var pin = kept.pin
                            switch change.pin {
                            case let .to(new): pin = new
                            case .cleared: pin = nil
                            case nil: break
                            }
                            var due = kept.due
                            switch change.due {
                            case let .to(new): due = new
                            case .cleared: due = nil
                            case nil: break
                            }
                            var changed = self.task(
                                kept.id, change.title ?? kept.title, status: change.status ?? kept.status, due: due, pin: pin, coven: kept.covenID
                            )
                            changed.threadID = change.threadID ?? kept.threadID
                            changed.leadAgentID = kept.leadAgentID
                            switch change.leadAgentID {
                            case let .to(agent): changed.leadAgentID = agent
                            case .cleared: changed.leadAgentID = nil
                            case nil: break
                            }
                            // A turn just started stands as the store would say.
                            changed.handoff = change.handoffTurnID.map {
                                TaskHandoff(turnID: $0, outcome: stand.startedAs, agentID: change.handoffAgentID)
                            } ?? kept.handoff
                            if change.handoffTurnID != nil, let agent = change.handoffAgentID { stand.lastHandedTo = agent }
                            return changed
                        }
                    }
                },
                answerLapsedPins: { ids, keepUntil, account in
                    await MainActor.run { stand.answeringWaits }?.wait()
                    return try await MainActor.run {
                        if let error = stand.answerFails { throw error }
                        stand.answered.append((ids, keepUntil, account))
                        return stand.answers ?? Set(ids)
                    }
                }
            ),
            hands: TasksModel.Hands(
                agents: { covenID in
                    await MainActor.run {
                        stand.agentReadings += 1
                        stand.agentsAsked.append(covenID)
                    }
                    await MainActor.run { stand.agentsWait }?.wait()
                    return await MainActor.run { stand.agentsIn[covenID] ?? stand.agents }
                },
                strix: { _ in stand.strix },
                thread: { id, _ in
                    await stand.threadWaits?.wait()
                    if let error = stand.threadFails { throw error }
                    guard let thread = stand.threads[id] else { throw RepositoryError.databaseUnavailable }
                    return thread
                },
                createThread: { title, covenID, agent, account in
                    if let error = stand.threadFails { throw error }
                    stand.madeThreads.append((title, covenID, agent, account))
                    let thread = AICoven.Thread(
                        id: "thread-\(stand.madeThreads.count)", userId: account, covenId: covenID, title: title, agentId: agent?.id,
                        agentName: agent?.name, createdAt: Date(timeIntervalSince1970: 0), updatedAt: nil, lastMessageAt: nil
                    )
                    stand.threads[thread.id] = thread
                    return thread
                },
                startTurn: { thread, text, agent in
                    await stand.startingWaits?.wait()
                    if let error = stand.startFails { throw error }
                    stand.started.append((thread.id, text, agent))
                    return "turn-\(stand.started.count)"
                },
                discardThread: { thread, _ in
                    stand.discarded.append(thread.id)
                    stand.threads[thread.id] = nil
                },
                handBack: { text, threadID, _ in stand.handedBack.append((text, threadID)) },
                liveTurn: { stand.live[$0] }
            ),
            signedIn: { stand.account }, announce: { stand.heard.append($0) }, now: { self.now }, calendar: { self.calendar }
        )
        // Its page is on screen, as when anything is asked of it.
        tasks.cameOnScreen()
        return tasks
    }

    /// Returns once the model is at work on the task: told by the model itself.
    private func isWorking(_ tasks: TasksModel, on id: String) async {
        for await saving in tasks.$saving.values where saving.contains(id) {
            return
        }
    }

    // MARK: - Reading

    func testThePageShowsTheOpenTasksAndTheFinishedOnes_withHowManyAreFinishedInAll() async {
        let stand = Stand()
        stand.kept = [task("a"), task("b", status: .done), task("c"), task("d", status: .closed)]
        stand.finishedInAll = 240
        let tasks = model(stand, covenID: "work")
        XCTAssertFalse(tasks.hasRead)
        XCTAssertTrue(tasks.isEmpty)

        await tasks.load()
        XCTAssertTrue(tasks.hasRead)
        XCTAssertEqual(tasks.open.map(\.id), ["a", "c"])
        XCTAssertEqual(tasks.finished.map(\.id), ["b", "d"])
        XCTAssertEqual(tasks.finishedCount, 240, "Counted whether listed or not")
        XCTAssertFalse(tasks.isEmpty)
        XCTAssertNil(tasks.errorMessage)
        XCTAssertEqual(stand.readings.first?.covenID, "work")
        XCTAssertEqual(stand.readings.first?.account, "ada")

        // A place with finished tasks only is not empty; one with none is.
        stand.kept = [task("b", status: .done)]
        stand.finishedInAll = nil
        await tasks.load()
        XCTAssertFalse(tasks.isEmpty)
        stand.kept = []
        await tasks.load()
        XCTAssertTrue(tasks.isEmpty)
    }

    func testAReadingThatFailsSaysSo_andLeavesWhatWasShown() async {
        let stand = Stand()
        stand.readFails = RepositoryError.databaseUnavailable
        let tasks = model(stand)
        await tasks.load()
        XCTAssertFalse(tasks.hasRead)
        XCTAssertEqual(tasks.errorMessage, TasksModel.couldNotLoad)
        XCTAssertEqual(stand.heard, [TasksModel.couldNotLoad])

        stand.readFails = nil
        stand.kept = [task("a")]
        await tasks.load()
        XCTAssertNil(tasks.errorMessage, "Read after all")
        XCTAssertEqual(tasks.open.map(\.id), ["a"])

        stand.readFails = RepositoryError.databaseUnavailable
        await tasks.load()
        XCTAssertEqual(tasks.open.map(\.id), ["a"], "The list stays")
        XCTAssertEqual(tasks.errorMessage, TasksModel.couldNotLoad)
        XCTAssertEqual(stand.heard, [TasksModel.couldNotLoad, TasksModel.couldNotLoad], "Each failed reading is said")

        // A reading that was called off is no failure.
        stand.readFails = CancellationError()
        await tasks.load()
        XCTAssertEqual(stand.heard.count, 2)
    }

    func testOnlyTheLatestReadingIsShown_andNoneForAnotherAccount() async {
        let stand = Stand()
        let gate = Gate()
        stand.readingWaits = gate
        let tasks = model(stand)

        stand.kept = [task("old")]
        let earlier = Task { await tasks.load() }
        await gate.arrived(1)
        stand.kept = [task("new")]
        let later = Task { await tasks.load() }
        await gate.arrived(2)
        await gate.letNewestThrough()
        await later.value
        XCTAssertEqual(tasks.open.map(\.id), ["new"])
        await gate.letOneThrough()
        await earlier.value
        XCTAssertEqual(tasks.open.map(\.id), ["new"], "A reading that lands after a later one is not shown over it")

        // Another account signs in while a reading is under way: it is not shown.
        stand.kept = [task("adas")]
        let adas = Task { await tasks.load() }
        await gate.arrived(3)
        stand.account = "grace"
        await gate.letOneThrough()
        await adas.value
        XCTAssertEqual(tasks.open.map(\.id), ["new"])
    }

    // MARK: - Adding

    func testATaskIsAddedForWhoeverAsked_withATidyTitle_andShownFirst() async {
        let stand = Stand()
        stand.kept = [task("a")]
        let tasks = model(stand, covenID: "work")
        await tasks.load()

        let added = await tasks.add(title: "  Book \n the venue ", as: "ada")
        XCTAssertTrue(added)
        XCTAssertEqual(stand.created.map(\.title), ["Book the venue"])
        XCTAssertEqual(stand.created.map(\.covenID), ["work"])
        XCTAssertEqual(stand.created.map(\.account), ["ada"])
        XCTAssertEqual(tasks.open.map(\.title), ["Book the venue", "A"], "Read again")
        XCTAssertEqual(stand.heard.last, "Added Book the venue")
        XCTAssertFalse(tasks.isAdding)

        // Nothing to add: nothing is asked.
        let nothing = await tasks.add(title: " \n ", as: "ada")
        XCTAssertFalse(nothing)
        XCTAssertEqual(stand.created.count, 1)

        // If the list cannot be read again, what was added is shown all the same.
        stand.readFails = RepositoryError.databaseUnavailable
        let unread = await tasks.add(title: "Second", as: "ada")
        XCTAssertTrue(unread)
        XCTAssertEqual(tasks.open.map(\.title), ["Second", "Book the venue", "A"])
        XCTAssertEqual(stand.heard.last, "Added Second")
    }

    func testATaskFinishedBeforeTheListIsReadAgainIsShownWhereItStands_notAsOpenToo() async {
        let stand = Stand()
        let tasks = model(stand)
        await tasks.load()
        // What is added is finished by something else before the list is read again.
        let gate = Gate()
        stand.readingWaits = gate
        let adding = Task { await tasks.add(title: "Short-lived", as: "ada") }
        await gate.arrived(1)
        // That reading read it open; a later one, which lands first, reads it done.
        stand.kept = stand.kept.map { self.task($0.id, $0.title, status: .done) }
        let later = Task { await tasks.load() }
        await gate.arrived(2)
        await gate.letNewestThrough()
        await later.value
        await gate.letOneThrough()
        let added = await adding.value
        XCTAssertTrue(added)
        XCTAssertEqual(tasks.open.map(\.title), [], "The list says where it stands now")
        XCTAssertEqual(tasks.finished.map(\.title), ["Short-lived"])
    }

    func testALaterReadingThatFailedDoesNotHideWhatAnEarlierOneRead() async {
        let stand = Stand()
        stand.kept = [task("a")]
        let tasks = model(stand)
        await tasks.load()
        // A task is added; the reading after it is held, and a later one fails and lands first.
        let gate = Gate()
        stand.readingWaits = gate
        let adding = Task { await tasks.add(title: "Just added", as: "ada") }
        await gate.arrived(1)
        stand.readFails = RepositoryError.databaseUnavailable
        let failing = Task { await tasks.load() }
        await gate.arrived(2)
        stand.readFails = nil
        await gate.letNewestThrough()
        let wasRead = await failing.value
        XCTAssertFalse(wasRead)
        XCTAssertEqual(tasks.errorMessage, TasksModel.couldNotLoad)
        XCTAssertEqual(tasks.open.map(\.title), ["A"], "Not read yet")

        await gate.letOneThrough()
        let added = await adding.value
        XCTAssertTrue(added)
        XCTAssertEqual(tasks.open.map(\.title), ["Just added", "A"], "What the earlier reading read is shown: nothing newer was read")
        XCTAssertEqual(tasks.errorMessage, TasksModel.couldNotLoad, "The later failure is still so")
        XCTAssertEqual(stand.heard, [TasksModel.couldNotLoad, "Added Just added"])
    }

    func testAFailureThatLandsAfterALaterReadingIsNotSaid() async {
        let stand = Stand()
        stand.kept = [task("a")]
        let tasks = model(stand)
        let gate = Gate()
        stand.readingWaits = gate

        stand.readFails = RepositoryError.databaseUnavailable
        let earlier = Task { await tasks.load() }
        await gate.arrived(1)
        stand.readFails = nil
        let later = Task { await tasks.load() }
        await gate.arrived(2)
        await gate.letNewestThrough()
        let wasRead = await later.value
        XCTAssertTrue(wasRead)
        XCTAssertEqual(tasks.open.map(\.id), ["a"])

        await gate.letOneThrough()
        let earlierRead = await earlier.value
        XCTAssertFalse(earlierRead)
        XCTAssertNil(tasks.errorMessage, "What was read since is what is so")
        XCTAssertEqual(stand.heard, [])
    }

    func testATaskThatWasNotAddedSaysWhy_toWhoeverAsked() async {
        let stand = Stand()
        let tasks = model(stand)
        await tasks.load()
        for (error, words) in [
            (TaskError.tooMany as Error, TasksModel.tooManyOpen), (RepositoryError.dataLocked, TasksModel.needsUnlock),
            (RepositoryError.databaseUnavailable, TasksModel.couldNotAdd), (TaskError.noSuchCoven, TasksModel.couldNotAdd),
        ] {
            stand.createFails = error
            let added = await tasks.add(title: "More", as: "ada")
            XCTAssertFalse(added)
            XCTAssertEqual(tasks.errorMessage, words, "\(error)")
            XCTAssertEqual(stand.heard.last, words)
        }
        XCTAssertEqual(stand.heard.count, 4, "Each its own")

        // Asking again clears what was said of the last; nothing is said to another account.
        stand.account = "grace"
        let anothers = await tasks.add(title: "More", as: "ada")
        XCTAssertFalse(anothers)
        XCTAssertNil(tasks.errorMessage)
        XCTAssertEqual(stand.heard.count, 4)
    }

    func testOneTaskIsAddedAtATime_andNothingIsShownOfOneAddedForAnotherAccount() async {
        let stand = Stand()
        let tasks = model(stand)
        await tasks.load()
        let gate = Gate()
        stand.creatingWaits = gate

        let first = Task { await tasks.add(title: "First", as: "ada") }
        await gate.arrived(1)
        XCTAssertTrue(tasks.isAdding)
        let second = await tasks.add(title: "Second", as: "ada")
        XCTAssertFalse(second, "A second ask while one is under way does nothing")

        stand.account = "grace"
        let readings = stand.readings.count
        await gate.letOneThrough()
        let added = await first.value
        XCTAssertFalse(added, "Not said to another account")
        XCTAssertEqual(stand.created.map(\.title), ["First"])
        XCTAssertEqual(tasks.open.count, 0)
        XCTAssertEqual(stand.heard, [])
        XCTAssertEqual(stand.readings.count, readings)
        XCTAssertFalse(tasks.isAdding)
    }

    // MARK: - Done, closed, open again

    func testATaskIsMarkedDoneClosedAndOpenedAgain_andSaidSo() async throws {
        let stand = Stand()
        stand.kept = [task("a", "Call the bank"), task("b", "Renew the lease")]
        let tasks = model(stand)
        await tasks.load()

        await tasks.setDone(tasks.open[0], true, as: "ada")
        XCTAssertEqual(stand.changed.map(\.id), ["a"])
        XCTAssertEqual(stand.changed.last?.change, TaskChange(status: .done), "The status and nothing else")
        XCTAssertEqual(stand.changed.last?.account, "ada")
        XCTAssertEqual(tasks.open.map(\.id), ["b"], "Read again")
        XCTAssertEqual(tasks.finished.map(\.status), [.done])
        XCTAssertEqual(stand.heard.last, "Marked Call the bank done")
        XCTAssertEqual(tasks.saving, [])

        await tasks.close(tasks.open[0], as: "ada")
        XCTAssertEqual(stand.changed.last?.change, TaskChange(status: .closed))
        XCTAssertEqual(stand.heard.last, "Closed Renew the lease")
        XCTAssertEqual(tasks.open.count, 0)

        let done = tasks.finished.first { $0.id == "a" }
        try await tasks.setDone(XCTUnwrap(done), false, as: "ada")
        XCTAssertEqual(stand.changed.last?.change, TaskChange(status: .open))
        XCTAssertEqual(stand.heard.last, "Reopened Call the bank")
        XCTAssertEqual(tasks.open.map(\.id), ["a"])
        XCTAssertNil(tasks.errorMessage)

        // A task whose title cannot be opened is not named by it.
        XCTAssertEqual(TasksModel.name(of: task("x", unreadable: true)), "the task")
        XCTAssertEqual(TasksModel.couldNotSave(task("x", unreadable: true)), "Couldn't save the change to the task. Try again.")
    }

    func testAChangeThatFailedSaysWhy_andOneThatIsGoneIsNotSaidToHaveFailed() async {
        let stand = Stand()
        stand.kept = [task("a", "Call the bank", status: .done)]
        let tasks = model(stand)
        await tasks.load()
        let listed = tasks.finished[0]

        for (error, words) in [
            (TaskError.tooMany as Error, TasksModel.tooManyOpen), (RepositoryError.dataLocked, TasksModel.needsUnlock),
            (RepositoryError.databaseUnavailable, "Couldn't save the change to “Call the bank”. Try again."),
        ] {
            stand.changeFails = error
            await tasks.setDone(listed, false, as: "ada")
            XCTAssertEqual(tasks.errorMessage, words, "\(error)")
            XCTAssertEqual(stand.heard.last, words)
            XCTAssertEqual(tasks.saving, [])
        }
        let said = stand.heard.count

        stand.changeFails = TaskError.noSuchTask
        stand.kept = []
        await tasks.setDone(listed, false, as: "ada")
        XCTAssertNil(tasks.errorMessage)
        XCTAssertEqual(stand.heard.count, said, "Nothing more is said")
        XCTAssertEqual(tasks.finished.count, 0, "The list, read again, shows it is gone")
    }

    func testOneChangeAtATimeForATask_andNothingIsSaidToAnotherAccount() async {
        let stand = Stand()
        stand.kept = [task("a"), task("b")]
        let tasks = model(stand)
        await tasks.load()
        let (first, other) = (tasks.open[0], tasks.open[1])
        let gate = Gate()
        stand.changingWaits = gate

        let changing = Task { await tasks.setDone(first, true, as: "ada") }
        await gate.arrived(1)
        XCTAssertEqual(tasks.saving, ["a"])
        await tasks.close(first, as: "ada")
        XCTAssertEqual(stand.changed.count, 0, "A second ask of the same task while one is under way does nothing")
        // Another task is not held up by it.
        let closing = Task { await tasks.close(other, as: "ada") }
        await gate.arrived(2)
        XCTAssertEqual(tasks.saving, ["a", "b"])

        stand.account = "grace"
        let readings = stand.readings.count
        await gate.letOneThrough()
        await gate.letOneThrough()
        await changing.value
        await closing.value
        XCTAssertEqual(Set(stand.changed.map(\.id)), ["a", "b"])
        XCTAssertEqual(stand.heard, [], "Nothing is said to another account")
        XCTAssertEqual(stand.readings.count, readings, "Nor read for it")
        XCTAssertEqual(tasks.saving, [])
    }

    func testWhatComesOfTwoChangesEndingTogetherIsSaidOfBoth() async {
        let stand = Stand()
        stand.kept = [task("a", "Call the bank"), task("b", "Renew the lease")]
        let tasks = model(stand)
        await tasks.load()
        let (first, other) = (tasks.open[0], tasks.open[1])
        let gate = Gate()
        stand.changingWaits = gate

        let marking = Task { await tasks.setDone(first, true, as: "ada") }
        let closing = Task { await tasks.close(other, as: "ada") }
        await gate.arrived(2)
        // Both are let through before either's outcome is looked at.
        await gate.letOneThrough()
        await gate.letOneThrough()
        await marking.value
        await closing.value
        XCTAssertEqual(Set(stand.heard), ["Marked Call the bank done", "Closed Renew the lease"], "Each is said, not only the last")
    }

    // MARK: - Pins

    func testATaskIsPinnedUntilTheEndOfThePersonsDayOrWeek_andUnpinned() async {
        let stand = Stand()
        stand.kept = [task("a", "Call the bank"), task("b", status: .done)]
        let tasks = model(stand)
        await tasks.load()
        let midnight = Date(timeIntervalSince1970: 1_799_884_800), monday = Date(timeIntervalSince1970: 1_800_230_400)

        await tasks.pin(tasks.open[0], for: .today, as: "ada")
        XCTAssertEqual(stand.changed.last?.change, TaskChange(pin: .to(TaskPin(period: .today, expiresAt: midnight))), "The pin and nothing else")
        XCTAssertEqual(stand.changed.last?.account, "ada")
        XCTAssertEqual(stand.heard.last, "Pinned Call the bank for today")
        XCTAssertEqual(tasks.open[0].pin?.period, .today, "Read again")

        await tasks.pin(tasks.open[0], for: .week, as: "ada")
        XCTAssertEqual(stand.changed.last?.change, TaskChange(pin: .to(TaskPin(period: .week, expiresAt: monday))))
        XCTAssertEqual(stand.heard.last, "Pinned Call the bank for this week")

        await tasks.unpin(tasks.open[0], as: "ada")
        XCTAssertEqual(stand.changed.last?.change, TaskChange(pin: .cleared))
        XCTAssertEqual(stand.heard.last, "Unpinned Call the bank")
        XCTAssertNil(tasks.open[0].pin)

        // Nothing to unpin, and a finished task is not pinned: nothing is asked.
        let asked = stand.changed.count
        await tasks.unpin(tasks.open[0], as: "ada")
        await tasks.pin(tasks.finished[0], for: .today, as: "ada")
        XCTAssertEqual(stand.changed.count, asked)

        // Why not, in words.
        stand.changeFails = RepositoryError.databaseUnavailable
        await tasks.pin(tasks.open[0], for: .today, as: "ada")
        XCTAssertEqual(tasks.errorMessage, "Couldn't pin “Call the bank”. Try again.")
        stand.kept = [task("a", "Call the bank", pin: TaskPin(period: .today, expiresAt: midnight))]
        stand.changeFails = nil
        await tasks.load()
        stand.changeFails = RepositoryError.databaseUnavailable
        await tasks.unpin(tasks.open[0], as: "ada")
        XCTAssertEqual(tasks.errorMessage, "Couldn't unpin “Call the bank”. Try again.")
        XCTAssertEqual(stand.heard.last, "Couldn't unpin “Call the bank”. Try again.")
    }

    func testPinsThatHaveRunOutAreAnsweredFor_keptOrCleared_andSaidHowMany() async {
        let stand = Stand()
        let over = TaskPin(period: .today, expiresAt: now.addingTimeInterval(-60))
        stand.kept = [
            task("a", pin: over), task("b", pin: over), task("c", pin: TaskPin(period: .today, expiresAt: now.addingTimeInterval(60))),
            task("d", pin: TaskPin(period: .week, expiresAt: now.addingTimeInterval(-60))), task("e"),
        ]
        let tasks = model(stand)
        await tasks.load()
        let midnight = Date(timeIntervalSince1970: 1_799_884_800)

        await tasks.answerLapsedPins(of: tasks.open, keep: true, as: "ada")
        XCTAssertEqual(stand.answered.last?.ids, ["a", "b"], "Only those whose day is over")
        XCTAssertEqual(stand.answered.last?.keepUntil, midnight, "Until the end of today")
        XCTAssertEqual(stand.answered.last?.account, "ada")
        XCTAssertEqual(stand.heard.last, "Kept for today 2 tasks")
        XCTAssertEqual(tasks.saving, [])

        stand.answers = ["a"]
        await tasks.answerLapsedPins(of: [tasks.open[0]], keep: false, as: "ada")
        XCTAssertNil(stand.answered.last?.keepUntil ?? nil)
        XCTAssertEqual(stand.heard.last, "Cleared 1 task")

        // None answered (answered elsewhere meanwhile): nothing is said. None to answer for: nothing is asked.
        let said = stand.heard.count
        stand.answers = []
        await tasks.answerLapsedPins(of: tasks.open, keep: true, as: "ada")
        XCTAssertEqual(stand.heard.count, said)
        let asked = stand.answered.count
        await tasks.answerLapsedPins(of: tasks.open.filter { $0.id == "e" }, keep: true, as: "ada")
        XCTAssertEqual(stand.answered.count, asked)

        // Why not, in words; and nothing to another account.
        stand.answerFails = RepositoryError.databaseUnavailable
        await tasks.answerLapsedPins(of: tasks.open, keep: true, as: "ada")
        XCTAssertEqual(tasks.errorMessage, "Couldn't update 2 tasks.")
        stand.answerFails = RepositoryError.dataLocked
        await tasks.answerLapsedPins(of: [tasks.open[0]], keep: true, as: "ada")
        XCTAssertEqual(tasks.errorMessage, TasksModel.needsUnlock)
        stand.account = "grace"
        stand.answerFails = RepositoryError.databaseUnavailable
        await tasks.answerLapsedPins(of: tasks.open, keep: true, as: "ada")
        XCTAssertNil(tasks.errorMessage)
    }

    func testKeptJustBeforeMidnight_thePinsAreKeptForTheDayThatHasBegun() async {
        let stand = Stand()
        let over = TaskPin(period: .today, expiresAt: now.addingTimeInterval(-60))
        stand.kept = [task("a", pin: over)]
        // The clock moves from a second before midnight to a second after it between the two askings.
        let midnight = Date(timeIntervalSince1970: 1_799_884_800)
        var clock = [midnight.addingTimeInterval(-1), midnight.addingTimeInterval(-1), midnight.addingTimeInterval(1)]
        var asked: [Date?] = []
        let tasks = TasksModel(
            scope: .place(covenID: nil),
            source: TasksModel.Source(
                tasks: { _, _, _ in await MainActor.run { TaskListing(tasks: stand.kept, finished: 0) } },
                create: { _, _, _ in throw TaskError.tooMany },
                change: { _, _, _ in },
                answerLapsedPins: { ids, keepUntil, _ in
                    try await MainActor.run {
                        asked.append(keepUntil)
                        // The first end asked for has passed by the time it is written.
                        if asked.count == 1 { throw TaskError.pinEnded }
                        return Set(ids)
                    }
                }
            ),
            signedIn: { "ada" }, announce: { stand.heard.append($0) }, now: { clock.count > 1 ? clock.removeFirst() : clock[0] },
            calendar: { self.calendar }
        )
        await tasks.load()

        await tasks.answerLapsedPins(of: tasks.open, keep: true, as: "ada")
        XCTAssertEqual(asked, [midnight, midnight.addingTimeInterval(86400)], "Asked once more, until the end of the day that has begun")
        XCTAssertEqual(stand.heard.last, "Kept for today 1 task")
        XCTAssertNil(tasks.errorMessage)
    }

    func testWhileAnAnswerForPinsIsOnItsWay_itsTasksAreNotChanged_andNothingIsSaidToAnotherAccount() async {
        let stand = Stand()
        let over = TaskPin(period: .today, expiresAt: now.addingTimeInterval(-60))
        stand.kept = [task("a", pin: over), task("b", pin: over), task("c")]
        let tasks = model(stand)
        await tasks.load()
        let listed = tasks.open
        let gate = Gate()
        stand.answeringWaits = gate

        let answering = Task { await tasks.answerLapsedPins(of: listed, keep: true, as: "ada") }
        await gate.arrived(1)
        XCTAssertEqual(tasks.saving, ["a", "b"])
        // One of them is not changed, or answered for again, meanwhile; another task is.
        await tasks.unpin(listed[0], as: "ada")
        await tasks.answerLapsedPins(of: [listed[1]], keep: false, as: "ada")
        XCTAssertEqual(stand.changed.count, 0)
        await tasks.close(listed[2], as: "ada")
        XCTAssertEqual(stand.changed.map(\.id), ["c"])

        // Another account signs in before the answer lands.
        stand.account = "grace"
        let heard = stand.heard.count, readings = stand.readings.count
        await gate.letOneThrough()
        await answering.value
        XCTAssertEqual(stand.answered.count, 1)
        XCTAssertEqual(stand.heard.count, heard, "Nothing is said to another account")
        XCTAssertEqual(stand.readings.count, readings, "Nor read for it")
        XCTAssertEqual(tasks.saving, [])
    }

    // MARK: - Details

    func testATaskIsRenamedWithATidyTitle_andOnlyWhereItSaysSomethingNew() async {
        let stand = Stand()
        stand.kept = [task("a", "Call the bank"), task("x", unreadable: true)]
        let tasks = model(stand)
        await tasks.load()

        await tasks.rename(tasks.open[0], to: "  Call \n the  branch ", as: "ada")
        XCTAssertEqual(stand.changed.last?.change, TaskChange(title: "Call the branch"), "The title and nothing else")
        XCTAssertEqual(stand.changed.last?.account, "ada")
        XCTAssertEqual(stand.heard.last, "Renamed to Call the branch")
        XCTAssertEqual(tasks.task("a")?.title, "Call the branch", "Read again, the list shows it")

        // Nothing to say, or what it is called already: nothing is asked.
        let asked = stand.changed.count
        await tasks.rename(task("a", "Call the branch"), to: " \n ", as: "ada")
        await tasks.rename(task("a", "Call the branch"), to: " Call the  branch", as: "ada")
        XCTAssertEqual(stand.changed.count, asked)
        // A task whose title could not be opened is named anew, whatever it was.
        await tasks.rename(tasks.open[1], to: "Named anew", as: "ada")
        XCTAssertEqual(stand.changed.last?.id, "x")
        XCTAssertEqual(stand.changed.last?.change, TaskChange(title: "Named anew"))

        stand.changeFails = RepositoryError.databaseUnavailable
        await tasks.rename(task("a", "Call the branch"), to: "Other", as: "ada")
        XCTAssertEqual(tasks.errorMessage, "Couldn't save the change to “Call the branch”. Try again.")
        XCTAssertEqual(tasks.task("a")?.title, "Call the branch", "As it was")
    }

    func testATasksDueDayIsSetWithOrWithoutATime_andTakenAway() async throws {
        let stand = Stand()
        stand.kept = [task("a", "Call the bank")]
        let tasks = model(stand)
        await tasks.load()
        let listed = tasks.open[0]
        let date = try XCTUnwrap(TaskDueDate(rawValue: "2027-01-20"))
        let withTime = try XCTUnwrap(TaskDue(date: date, time: "09:30")), dayOnly = try XCTUnwrap(TaskDue(date: date))

        await tasks.setDue(listed, to: withTime, as: "ada")
        XCTAssertEqual(stand.changed.last?.change, TaskChange(due: .to(withTime)), "The due day and nothing else")
        XCTAssertEqual(stand.heard.last, "Due date set")
        XCTAssertEqual(tasks.task("a")?.due, withTime, "Read again, the list shows it")
        await tasks.setDue(listed, to: dayOnly, as: "ada")
        XCTAssertEqual(stand.changed.last?.change, TaskChange(due: .to(dayOnly)))
        XCTAssertEqual(tasks.task("a")?.due, dayOnly)
        await tasks.setDue(listed, to: nil, as: "ada")
        XCTAssertEqual(stand.changed.last?.change, TaskChange(due: .cleared))
        XCTAssertEqual(stand.heard.last, "Due date removed")
        XCTAssertNil(tasks.task("a")?.due)

        stand.changeFails = RepositoryError.databaseUnavailable
        await tasks.setDue(listed, to: dayOnly, as: "ada")
        XCTAssertEqual(tasks.errorMessage, "Couldn't change the due date of “Call the bank”. Try again.")
        XCTAssertEqual(stand.heard.last, "Couldn't change the due date of “Call the bank”. Try again.")

        // The task as it was last read, by its id; none for one that is gone.
        XCTAssertEqual(tasks.task("a")?.title, "Call the bank")
        XCTAssertNil(tasks.task("gone"))
    }

    func testTheTaskWhoseDetailsAreOpenStaysListed_andItsDetailsCloseOnlyWhenItIsGone() async {
        let stand = Stand()
        stand.kept = [task("open"), task("newer", status: .done), task("oldest", status: .closed)]
        stand.mostFinished = 2
        let tasks = model(stand)
        await tasks.load()
        XCTAssertEqual(stand.alsoAsked, [nil], "No details open: nothing more is asked for")

        // The details of the oldest finished task listed are opened; another task is then finished,
        // which leaves it out of the ones last changed.
        tasks.detailsOf = "oldest"
        stand.kept = [task("newest", status: .done), task("newer", status: .done), task("oldest", status: .closed)]
        await tasks.load()
        XCTAssertEqual(stand.alsoAsked.last, "oldest", "Every reading asks for it by name")
        XCTAssertEqual(tasks.finished.map(\.id), ["newest", "newer", "oldest"], "Listed all the same, after the others")
        XCTAssertEqual(tasks.detailsOf, "oldest", "Its details stay open")
        XCTAssertEqual(tasks.task("oldest")?.status, .closed)

        // Details opened while a reading that did not ask for the task is under way: when that
        // reading lands without it, the tasks are read again, asking for it.
        tasks.detailsOf = nil
        stand.kept = [task("newest", status: .done), task("newer", status: .done), task("oldest", status: .closed)]
        stand.mostFinished = 3
        await tasks.load()
        stand.mostFinished = 2
        let gate = Gate()
        stand.readingWaits = gate
        let reading = Task { await tasks.load() }
        await gate.arrived(1)
        XCTAssertEqual(stand.alsoAsked.last ?? "none", nil, "It asked for none")
        tasks.detailsOf = "oldest"
        await gate.letOneThrough()
        await gate.arrived(2)
        XCTAssertEqual(stand.alsoAsked.last, "oldest", "Read again, asking for it")
        await gate.letOneThrough()
        let wasRead = await reading.value
        XCTAssertTrue(wasRead)
        XCTAssertEqual(tasks.detailsOf, "oldest", "Its details stay open")
        XCTAssertEqual(tasks.task("oldest")?.status, .closed, "And have their task")
        stand.readingWaits = nil

        // Gone (with its coven, say): its details close.
        stand.kept = [task("newest", status: .done), task("newer", status: .done)]
        await tasks.load()
        XCTAssertNil(tasks.detailsOf)
        // A reading that fails closes nothing.
        tasks.detailsOf = "newer"
        stand.readFails = RepositoryError.databaseUnavailable
        await tasks.load()
        XCTAssertEqual(tasks.detailsOf, "newer")
    }

    func testWhatTheDetailsSayOfATask() throws {
        XCTAssertNil(TaskDetailView.stateWords(for: task("a")))
        XCTAssertEqual(TaskDetailView.stateWords(for: task("a", status: .done)), "Done")
        XCTAssertEqual(TaskDetailView.stateWords(for: task("a", status: .closed)), "Closed")

        XCTAssertEqual(TaskDetailView.pinWords(.none, isCompact: false), "Not pinned")
        XCTAssertEqual(TaskDetailView.pinWords(.none, isCompact: true), "Pin")
        XCTAssertEqual(TaskDetailView.pinWords(.today, isCompact: false), "Pinned: Today")
        XCTAssertEqual(TaskDetailView.pinWords(.week, isCompact: true), "This week")
        XCTAssertEqual(TaskDetailView.pinWords(.review, isCompact: true), "Still on today?")

        let british = Locale(identifier: "en_GB")
        func due(_ task: TaskItem, compact: Bool) -> String {
            TaskDetailView.dueWords(for: task, now: now, isCompact: compact, calendar: calendar, locale: british)
        }
        XCTAssertEqual(due(task("a"), compact: false), "Add due date")
        XCTAssertEqual(due(task("a"), compact: true), "Add due date")
        let date = try XCTUnwrap(TaskDueDate(rawValue: "2027-01-14"))
        let dueTomorrow = TaskItem(
            id: "a", covenID: nil, title: "A", status: .open, stage: .backlog, due: TaskDue(date: date, time: "09:30"), pin: nil,
            createdAt: now, updatedAt: now
        )
        XCTAssertEqual(due(dueTomorrow, compact: false), "Due tomorrow, 09:30")
        XCTAssertEqual(due(dueTomorrow, compact: true), "tomorrow, 09:30", "Without the word where there is little room")

        // The day chosen in the sheet is the person's own; the time of day is theirs too.
        let chosen = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 3, day: 5, hour: 23, minute: 59)))
        let at = try XCTUnwrap(calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: 7, minute: 5)))
        XCTAssertEqual(TaskDueSheet.due(day: chosen, time: nil, calendar: calendar), try TaskDue(date: XCTUnwrap(TaskDueDate(rawValue: "2027-03-05"))))
        XCTAssertEqual(TaskDueSheet.due(day: chosen, time: at, calendar: calendar)?.time, "07:05")

        // The time picker starts at the task's time of day, on a day of its own: a time the clock
        // skips on the due day comes back from the sheet as it was set, not an hour on.
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let skipped = TaskDueSheet.pickerTime("02:30", calendar: berlin)
        XCTAssertEqual(berlin.dateComponents([.hour, .minute], from: skipped), DateComponents(hour: 2, minute: 30))
        let dueDay = try XCTUnwrap(berlin.date(from: DateComponents(year: 2027, month: 3, day: 28, hour: 12)))
        XCTAssertEqual(TaskDueSheet.due(day: dueDay, time: skipped, calendar: berlin), try TaskDue(date: XCTUnwrap(TaskDueDate(rawValue: "2027-03-28")), time: "02:30"))
        XCTAssertEqual(berlin.dateComponents([.hour, .minute], from: TaskDueSheet.pickerTime(nil, calendar: berlin)), DateComponents(hour: 9, minute: 0))
        XCTAssertEqual(berlin.dateComponents([.hour, .minute], from: TaskDueSheet.pickerTime("soon", calendar: berlin)), DateComponents(hour: 9, minute: 0))
    }

    // MARK: - Handing a task to an agent

    private let scout = TasksModel.Agent(id: "scout", name: "Scout", runsOn: "Anthropic")
    private let quill = TasksModel.Agent(id: "quill", name: "Quill", runsOn: "OpenAI")

    func testTheAgentsOfAPlace_orStrixAloneWhereItHasNone() async {
        let stand = Stand()
        stand.agents = [scout, quill]
        let tasks = model(stand, covenID: "work")
        XCTAssertNil(tasks.agentsByPlace["work"], "Not read yet")
        XCTAssertNil(tasks.leadChoices(for: task("a")))
        await tasks.loadAgents()
        XCTAssertEqual(tasks.agentsByPlace["work"], [scout, quill])
        XCTAssertFalse(tasks.placesWhoseAgentsFailed.contains("work"))

        // They could not be read again: those read last stay, and it says so.
        stand.agents = nil
        await tasks.loadAgents()
        XCTAssertEqual(tasks.agentsByPlace["work"], [scout, quill])
        XCTAssertTrue(tasks.placesWhoseAgentsFailed.contains("work"))
        // A coven with none, and Strix's own place: Strix answers.
        stand.agents = []
        await tasks.loadAgents()
        XCTAssertEqual(tasks.agentsByPlace["work"], [.strix])
        XCTAssertFalse(tasks.placesWhoseAgentsFailed.contains("work"))
        // Strix says where it runs, like any agent.
        stand.strix.runsOn = "Anthropic"
        let strixs = model(stand)
        await strixs.loadAgents()
        XCTAssertEqual(strixs.agentsByPlace[""]?.map(\.runsOn), ["Anthropic"])
        XCTAssertEqual(strixs.agentsByPlace[""]?.first?.isStrix, true)
        XCTAssertFalse(scout.isStrix)
    }

    func testTheAgentsAreReadOnceAtATime_andWhoeverAsksMeanwhileWaitsForThatReading() async {
        let stand = Stand()
        stand.agents = nil
        let tasks = model(stand, covenID: "work")
        await tasks.loadAgents()
        XCTAssertTrue(tasks.placesWhoseAgentsFailed.contains("work"))

        // Asked for again while they are read (Try Again pressed twice, or Talk it through, which
        // needs them): nothing more is read, and whoever asked waits for the reading under way.
        // The thread made for the task goes to an agent of the place, not to Strix for want of knowing.
        let gate = Gate()
        stand.agentsWait = gate
        stand.agents = [scout]
        let first = Task { await tasks.loadAgents() }
        await gate.arrived(1)
        stand.kept = [task("a", "Call the bank")]
        let talking = Task { await tasks.talkItThrough(self.task("a", "Call the bank"), as: "ada") }
        await isWorking(tasks, on: "a")
        XCTAssertEqual(stand.agentReadings, 2, "The failed reading, and one more")
        XCTAssertEqual(stand.madeThreads.count, 0, "It waits for the agents")
        await gate.letOneThrough()
        await first.value
        let thread = await talking.value
        XCTAssertEqual(stand.agentReadings, 2)
        XCTAssertEqual(tasks.agentsByPlace["work"], [scout])
        XCTAssertFalse(tasks.placesWhoseAgentsFailed.contains("work"))
        XCTAssertEqual(thread?.id, "thread-1")
        XCTAssertEqual(stand.madeThreads.map(\.agent), [scout])

        // Nothing read for an account that is no longer signed in is kept.
        stand.agents = [scout, quill]
        let anothers = Task { await tasks.loadAgents() }
        await gate.arrived(2)
        stand.account = "grace"
        await gate.letOneThrough()
        await anothers.value
        XCTAssertEqual(tasks.agentsByPlace["work"], [scout])
    }

    func testWhoAnswersATurnStartedFromATask() {
        let thread = AICoven.Thread(
            id: "t", userId: "ada", covenId: "work", title: "Call the bank", agentId: "gone", agentName: "Gone",
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: nil, lastMessageAt: nil
        )
        // Nobody chosen (Talk it through): the thread's own agent.
        XCTAssertEqual(TasksModel.Hands.answering(nil, in: thread).roleID, "gone")
        XCTAssertEqual(TasksModel.Hands.answering(nil, in: thread).name, "Gone")
        XCTAssertEqual(TasksModel.Hands.answering(quill, in: thread).roleID, "quill")
        // Strix chosen is Strix, whoever the thread's own agent was.
        XCTAssertNil(TasksModel.Hands.answering(.strix, in: thread).roleID)
        XCTAssertEqual(TasksModel.Hands.answering(.strix, in: thread).name, "Strix")
    }

    func testTalkItThroughOpensTheTasksThread_madeForItOnce_andStartsWithTheTask() async {
        let stand = Stand()
        stand.kept = [task("a", "Call the bank")]
        let tasks = model(stand, covenID: "work")
        await tasks.load()

        let thread = await tasks.talkItThrough(tasks.open[0], as: "ada")
        XCTAssertEqual(thread?.id, "thread-1")
        XCTAssertEqual(stand.madeThreads.map(\.title), ["Call the bank"], "Named after the task")
        XCTAssertEqual(stand.madeThreads.map(\.covenID), ["work"], "In the task's place")
        XCTAssertNil(stand.madeThreads[0].agent, "A place with no agents of its own: Strix answers there")
        XCTAssertEqual(stand.changed.map(\.change), [TaskChange(threadID: "thread-1")], "Given to the task")
        XCTAssertEqual(stand.started.map(\.text), ["I'd like to talk this task through: Call the bank"])
        XCTAssertEqual(stand.started.map(\.threadID), ["thread-1"])
        XCTAssertNil(tasks.task("a")?.handoff, "Talking it through is no hand-off")
        XCTAssertEqual(tasks.task("a")?.threadID, "thread-1", "Read again")
        XCTAssertEqual(tasks.saving, [])

        // The thread it has is opened as it is: none is made, nothing is sent.
        let again = await tasks.talkItThrough(tasks.open[0], as: "ada")
        XCTAssertEqual(again?.id, "thread-1")
        XCTAssertEqual(stand.madeThreads.count, 1)
        XCTAssertEqual(stand.started.count, 1)
    }

    func testAThreadThatCouldNotBeOpenedOrStartedSaysSo() async {
        let stand = Stand()
        stand.kept = [task("a", "Call the bank")]
        let tasks = model(stand)
        await tasks.load()

        stand.threadFails = RepositoryError.databaseUnavailable
        let none = await tasks.talkItThrough(tasks.open[0], as: "ada")
        XCTAssertNil(none)
        XCTAssertEqual(tasks.errorMessage, TasksModel.couldNotOpenThread)
        XCTAssertEqual(stand.changed.count, 0)

        // The thread is made and given, but the task could not be sent into it: it opens all the same.
        stand.threadFails = nil
        stand.startFails = RepositoryError.databaseUnavailable
        let opened = await tasks.talkItThrough(tasks.open[0], as: "ada")
        XCTAssertEqual(opened?.id, "thread-1")
        XCTAssertEqual(stand.handedBack.map(\.text), ["I'd like to talk this task through: Call the bank"], "To the thread's composer, which says why")
        XCTAssertEqual(stand.handedBack.map(\.threadID), ["thread-1"])
        XCTAssertNil(tasks.errorMessage, "Said in the thread, where the person is taken")
        XCTAssertEqual(tasks.task("a")?.threadID, "thread-1")

        // The task's change refused: no thread is opened for it.
        stand.kept = [task("b", "Renew the lease")]
        await tasks.load()
        stand.startFails = nil
        stand.changeFails = TaskError.noSuchThread
        let refused = await tasks.talkItThrough(tasks.open[0], as: "ada")
        XCTAssertNil(refused)
        XCTAssertEqual(tasks.errorMessage, TasksModel.couldNotOpenThread)
        XCTAssertEqual(stand.discarded, ["thread-2"], "The thread made for it is not left behind, empty")
    }

    func testAThreadMadeForATaskGoesToAnAgentOfThePlace_asANewThreadThereDoes() async {
        let stand = Stand()
        stand.agents = [scout, quill]
        var led = task("a", "Call the bank")
        led.leadAgentID = "quill"
        stand.kept = [led, task("b", "Renew the lease"), task("c", "File the return")]
        // Asked before the agents were read: they are read for it.
        let tasks = model(stand, covenID: "work")
        await tasks.load()

        _ = await tasks.talkItThrough(tasks.open[0], as: "ada")
        XCTAssertEqual(stand.madeThreads.last?.agent, quill, "The agent that leads the task")
        XCTAssertNil(stand.started.last?.agent, "Answered by the thread's own agent")
        _ = await tasks.talkItThrough(tasks.open[1], as: "ada")
        XCTAssertEqual(stand.madeThreads.last?.agent, scout, "Else the place's first")
        stand.lastHandedTo = "quill"
        await tasks.load()
        _ = await tasks.talkItThrough(tasks.open[2], as: "ada")
        XCTAssertEqual(stand.madeThreads.last?.agent, quill, "Or the one a task was last handed to there")
    }

    func testATaskWhoseTitleCannotBeReadIsNotHandedOver_andTalkedThroughOnlyInAThreadItHas() async {
        let stand = Stand()
        stand.agents = [scout]
        var has = task("b", unreadable: true)
        has.threadID = "its-own"
        stand.kept = [task("a", unreadable: true), has]
        stand.threads["its-own"] = AICoven.Thread(
            id: "its-own", userId: "ada", covenId: "work", title: "Call the bank", agentId: nil, agentName: nil,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: nil, lastMessageAt: nil
        )
        let tasks = model(stand, covenID: "work")
        await tasks.load()
        await tasks.loadAgents()
        XCTAssertFalse(TaskRules.canBeHandedOver(tasks.open[0]))
        XCTAssertFalse(TaskRules.canBeTalkedThrough(tasks.open[0]))
        XCTAssertTrue(TaskRules.canBeTalkedThrough(tasks.open[1]), "It has a thread to open")
        XCTAssertFalse(TaskRules.canBeHandedOver(tasks.open[1]))
        XCTAssertFalse(TaskRules.canBeHandedOver(task("done", status: .done)))
        XCTAssertTrue(TaskRules.canBeHandedOver(task("plain")))

        // Its title is what an agent is told: nothing is made, sent or kept for it.
        let outcome = await tasks.doItForMe(tasks.open[0], agent: scout, as: "ada")
        XCTAssertEqual(outcome, .none)
        let none = await tasks.talkItThrough(tasks.open[0], as: "ada")
        XCTAssertNil(none)
        let handed = await tasks.doItForMe(tasks.open[1], agent: scout, as: "ada")
        XCTAssertEqual(handed, .none)
        XCTAssertEqual(stand.madeThreads.count, 0)
        XCTAssertEqual(stand.started.count, 0)
        XCTAssertEqual(stand.changed.count, 0)
        // The thread it has is opened as it is.
        let own = await tasks.talkItThrough(tasks.open[1], as: "ada")
        XCTAssertEqual(own?.id, "its-own")
        XCTAssertEqual(stand.started.count, 0)
    }

    func testNoThreadIsOpenedForAnAccountThatIsNoLongerSignedIn() async {
        let stand = Stand()
        var has = task("a", "Call the bank")
        has.threadID = "its-own"
        stand.kept = [has, task("b", "Renew the lease")]
        stand.threads["its-own"] = AICoven.Thread(
            id: "its-own", userId: "ada", covenId: nil, title: "Call the bank", agentId: nil, agentName: nil,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: nil, lastMessageAt: nil
        )
        let tasks = model(stand)
        await tasks.load()

        // The thread it has, read while another account signs in.
        let gate = Gate()
        stand.threadWaits = gate
        let own = Task { await tasks.talkItThrough(has, as: "ada") }
        await gate.arrived(1)
        stand.account = "grace"
        await gate.letOneThrough()
        let none = await own.value
        XCTAssertNil(none)
        XCTAssertEqual(tasks.saving, [])

        // A thread made for it, whose first message is sent while another account signs in.
        stand.account = "ada"
        stand.threadWaits = nil
        stand.startingWaits = gate
        let made = Task { await tasks.talkItThrough(tasks.open[1], as: "ada") }
        await gate.arrived(2)
        stand.account = "grace"
        await gate.letOneThrough()
        let alsoNone = await made.value
        XCTAssertNil(alsoNone)
        XCTAssertEqual(stand.heard, [])
    }

    func testDoItForMeHandsTheTaskToTheAgentChosen_andTheTaskFollowsTheTurn() async {
        let stand = Stand()
        stand.agents = [scout, quill]
        stand.kept = [task("a", "Call the bank")]
        let tasks = model(stand, covenID: "work")
        await tasks.load()
        await tasks.loadAgents()

        let outcome = await tasks.doItForMe(tasks.open[0], agent: quill, as: "ada")
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(
            stand.changed.map(\.change),
            [
                TaskChange(leadAgentID: .to("quill")), TaskChange(threadID: "thread-1"),
                TaskChange(handoffTurnID: "turn-1", handoffAgentID: "quill"),
            ],
            "Its lead agent, its thread, then the turn it was handed over in and who to"
        )
        XCTAssertEqual(stand.madeThreads.first?.agent, quill, "A thread made for it starts with that agent")
        XCTAssertEqual(stand.started.first?.text, "Please do this for me: Call the bank")
        XCTAssertEqual(stand.started.first?.agent, quill)
        XCTAssertEqual(stand.heard.last, "Quill is on Call the bank")
        let handed = tasks.open[0]
        XCTAssertEqual(handed.leadAgentID, "quill")
        XCTAssertEqual(tasks.agentName(for: handed), "Quill")
        XCTAssertEqual(tasks.leadChoices(for: handed)?.marked, quill, "Its lead agent is listed first")
        XCTAssertEqual(tasks.leadChoices(for: task("other"))?.reason, .lastUsed, "And for another task, as the one last handed to")

        // While the app runs that turn the task follows it; when it ends, the tasks are read again.
        XCTAssertNil(tasks.handoff(of: handed), "Stored as running, and not run here")
        stand.live = ["thread-1": TaskLiveTurn(turnID: "turn-1")]
        tasks.turnsChanged()
        XCTAssertEqual(tasks.handoff(of: handed), .working)
        stand.live = ["thread-1": TaskLiveTurn(turnID: "turn-1", needsOK: true)]
        tasks.turnsChanged()
        XCTAssertEqual(tasks.handoff(of: handed), .needsOK)
        XCTAssertEqual(stand.heard.last, "Quill needs your OK on Call the bank", "Said on Tasks, where the person is")
        let heard = stand.heard.count
        tasks.turnsChanged()
        XCTAssertEqual(stand.heard.count, heard, "Once")
        var ended = handed
        ended.handoff?.outcome = .completed
        stand.kept = [ended]
        stand.live = [:]
        let readAgain = tasks.turnsChanged()
        XCTAssertNotNil(readAgain, "Its turn ended: the tasks are read again")
        await readAgain?.value
        XCTAssertEqual(tasks.handoff(of: tasks.open[0]), .finished, "As the turn stands in the store")
        XCTAssertEqual(stand.heard.last, "Quill finished Call the bank")
        XCTAssertNil(tasks.turnsChanged(), "Nothing changed since")

        // A turn of another task's thread, or another turn in this one, is not followed.
        stand.live = ["thread-1": TaskLiveTurn(turnID: "later"), "elsewhere": TaskLiveTurn(turnID: "x")]
        tasks.turnsChanged()
        XCTAssertEqual(tasks.liveTurns, [:])
        // The thread keeps its agent when the task is handed to another: the turn runs as the one chosen.
        _ = await tasks.doItForMe(tasks.open[0], agent: scout, as: "ada")
        XCTAssertEqual(stand.madeThreads.count, 1, "The thread it has")
        XCTAssertEqual(stand.started.last?.agent, scout)
        XCTAssertEqual(stand.started.last?.threadID, "thread-1")
    }

    func testAHandOffIsNamedByTheAgentItWentTo_whoeverLeadsTheTaskByNow() async {
        let stand = Stand()
        stand.agents = [scout, quill]
        stand.kept = [task("a", "Call the bank")]
        let tasks = model(stand, covenID: "work")
        await tasks.load()
        await tasks.loadAgents()
        _ = await tasks.doItForMe(tasks.open[0], agent: scout, as: "ada")
        stand.live = ["thread-1": TaskLiveTurn(turnID: "turn-1")]
        tasks.turnsChanged()

        // Quill is to lead it next time: Scout is still the one on it.
        await tasks.changeLeadAgent(tasks.open[0], to: quill, as: "ada")
        XCTAssertEqual(tasks.open[0].leadAgentID, "quill")
        XCTAssertEqual(tasks.handoff(of: tasks.open[0]), .working)
        XCTAssertEqual(tasks.agentName(for: tasks.open[0]), "Scout")
        XCTAssertEqual(tasks.leadChoices(for: tasks.open[0])?.marked, quill)
        XCTAssertEqual(tasks.leadChoices(for: task("other"))?.marked, scout, "Last used: the agent the latest hand-off went to")

        // Scout is deleted while it works: the hand-off is nobody's by name, and not Strix's.
        stand.agents = [quill]
        await tasks.loadAgents()
        XCTAssertNil(tasks.agentName(for: tasks.open[0]))
        XCTAssertEqual(tasks.handoff(of: tasks.open[0])?.words(agent: tasks.agentName(for: tasks.open[0])), "An agent is on it")
        // Its turn ended in failure: the task is the person's again, and says who leads it.
        var failed = tasks.open[0]
        failed.handoff?.outcome = .failed
        stand.kept = [failed]
        stand.live = [:]
        await tasks.turnsChanged()?.value
        XCTAssertNil(tasks.handoff(of: tasks.open[0]))
        XCTAssertEqual(tasks.agentName(for: tasks.open[0]), "Quill")
        XCTAssertEqual(tasks.errorMessage, "An agent stopped on a problem with “Call the bank”. Its thread shows what happened.")
    }

    func testLastUsedIsTheStoresAnswer_alsoWhereNoListedTaskWasHandedOver() async {
        let stand = Stand()
        stand.agents = [scout, quill]
        stand.kept = [task("a", "Call the bank")]
        // The task last handed over is finished and no longer listed.
        stand.lastHandedTo = "quill"
        let tasks = model(stand, covenID: "work")
        await tasks.load()
        await tasks.loadAgents()
        XCTAssertEqual(tasks.leadChoices(for: tasks.open[0])?.marked, quill)
        XCTAssertEqual(tasks.leadChoices(for: tasks.open[0])?.reason, .lastUsed)
    }

    func testATurnThatEndedWhileTheTasksWereReadIsReadAgainFor_once() async {
        let stand = Stand()
        stand.agents = [scout]
        var handed = task("a", "Call the bank")
        handed.threadID = "thread-1"
        handed.handoff = TaskHandoff(turnID: "turn-1", outcome: .running, agentID: "scout")
        stand.kept = [handed]
        let tasks = model(stand, covenID: "work")
        await tasks.loadAgents()

        // The listing reads the turn as running; it ends before the listing lands,
        // and nothing runs it by then: the page has no turn of it to see end.
        let gate = Gate()
        stand.readingWaits = gate
        let reading = Task { await tasks.load() }
        await gate.arrived(1)
        var ended = handed
        ended.handoff?.outcome = .completed
        stand.kept = [ended]
        await gate.letOneThrough()
        await gate.arrived(2)
        XCTAssertNil(tasks.handoff(of: tasks.open[0]), "As it was listed: running, and not run here")
        await gate.letOneThrough()
        await reading.value
        XCTAssertEqual(tasks.handoff(of: tasks.open[0]), .finished, "Read again for")
        XCTAssertEqual(stand.heard, ["Scout finished Call the bank"])

        // The same for an agent's own run, which would otherwise be left as paused.
        var run = task("c", "File the return")
        run.threadID = "thread-3"
        run.handoff = TaskHandoff(turnID: "turn-3", outcome: .running, hasRun: true, agentID: "scout")
        stand.kept = [run]
        let runs = Task { await tasks.load() }
        await gate.arrived(3)
        run.handoff?.outcome = .completed
        stand.kept = [run]
        await gate.letOneThrough()
        await gate.arrived(4)
        XCTAssertEqual(tasks.handoff(of: tasks.open[0]), .paused, "As it was listed")
        await gate.letOneThrough()
        await runs.value
        XCTAssertEqual(tasks.handoff(of: tasks.open[0]), .finished)
        XCTAssertEqual(stand.heard.last, "Scout finished File the return")

        // A turn that stays recorded as running (its ending could not be stored, or an agent's
        // own run goes on) is read again for once, not over and over.
        stand.readingWaits = nil
        var stuck = task("b", "Renew the lease")
        stuck.threadID = "thread-2"
        stuck.handoff = TaskHandoff(turnID: "turn-2", outcome: .running, agentID: "scout")
        var paused = task("d", "Book the flights")
        paused.threadID = "thread-4"
        paused.handoff = TaskHandoff(turnID: "turn-4", outcome: .running, hasRun: true, agentID: "scout")
        stand.kept = [stuck, paused]
        let before = stand.readings.count, heard = stand.heard.count
        await tasks.load()
        XCTAssertEqual(stand.readings.count, before + 2)
        await tasks.load()
        XCTAssertEqual(stand.readings.count, before + 3)
        XCTAssertNil(tasks.turnsChanged())
        XCTAssertEqual(tasks.handoff(of: tasks.open[1]), .paused)
        XCTAssertEqual(stand.heard.count, heard, "Nothing has ended")
    }

    func testHowAHandOffEndedIsNotSaidOnceThePersonHasLeftTasks() async {
        let stand = Stand()
        stand.agents = [scout]
        stand.kept = [task("a", "Call the bank")]
        let tasks = model(stand, covenID: "work")
        await tasks.load()
        await tasks.loadAgents()

        // Do it for me, and the person leaves while the turn is being started: it fails at once.
        let gate = Gate()
        stand.startingWaits = gate
        stand.startedAs = .failed
        let handing = Task { await tasks.doItForMe(tasks.open[0], agent: scout, as: "ada") }
        await gate.arrived(1)
        tasks.leftScreen()
        await gate.letOneThrough()
        _ = await handing.value
        XCTAssertNil(tasks.errorMessage)
        XCTAssertEqual(stand.heard, [], "Its thread, Activity and notifications tell of it")

        // Nor that a turn followed here needs an OK, or finished.
        var handed = task("b", "Renew the lease")
        handed.threadID = "thread-9"
        handed.handoff = TaskHandoff(turnID: "turn-9", outcome: .running, agentID: "scout")
        stand.kept = [handed]
        stand.startingWaits = nil
        stand.live = ["thread-9": TaskLiveTurn(turnID: "turn-9", needsOK: true)]
        await tasks.load()
        XCTAssertEqual(tasks.handoff(of: tasks.open[0]), .needsOK)
        handed.handoff?.outcome = .completed
        stand.kept = [handed]
        stand.live = [:]
        await tasks.turnsChanged()?.value
        XCTAssertEqual(tasks.handoff(of: tasks.open[0]), .finished)
        XCTAssertEqual(stand.heard, [])
        // Back on screen, what was not said is not said late.
        tasks.cameOnScreen()
        await tasks.load()
        XCTAssertEqual(stand.heard, [])
    }

    func testATurnThatFailedBeforeItWasSeenAtWorkCouldNotStart_andIsSaidSoOnTheTask() async {
        let stand = Stand()
        stand.agents = [scout]
        stand.kept = [task("a", "Call the bank")]
        let tasks = model(stand, covenID: "work")
        await tasks.load()
        await tasks.loadAgents()

        // With no connection to answer, the turn is started and fails at once.
        stand.startedAs = .failed
        let outcome = await tasks.doItForMe(tasks.open[0], agent: scout, as: "ada")
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(tasks.errorMessage, "Scout couldn't start on “Call the bank”. Its thread shows what's happening there.")
        XCTAssertEqual(stand.heard.last, tasks.errorMessage)
        XCTAssertFalse(stand.heard.contains("Scout is on Call the bank"))
        XCTAssertNil(tasks.handoff(of: tasks.open[0]))
        XCTAssertEqual(tasks.agentName(for: tasks.open[0]), "Scout", "Still led by it")
        // Told once.
        let heard = stand.heard.count
        await tasks.load()
        XCTAssertEqual(stand.heard.count, heard)

        // One the person stopped is told of by nothing.
        stand.kept = [task("b", "Renew the lease")]
        await tasks.load()
        stand.startedAs = .cancelled
        _ = await tasks.doItForMe(tasks.open[0], agent: scout, as: "ada")
        XCTAssertNil(tasks.errorMessage)
        XCTAssertEqual(stand.heard.count, heard)
    }

    func testAHandOffThatDidNotStartKeepsTheLeadAgent_andSaysSo() async {
        let stand = Stand()
        stand.agents = [scout]
        stand.kept = [task("a", "Call the bank"), task("done", status: .done)]
        let tasks = model(stand, covenID: "work")
        await tasks.load()
        await tasks.loadAgents()

        stand.startFails = RepositoryError.databaseUnavailable
        let led = await tasks.doItForMe(tasks.open[0], agent: scout, as: "ada")
        XCTAssertEqual(led, .led)
        XCTAssertEqual(tasks.errorMessage, "Scout couldn't start on “Call the bank”. Its thread shows what's happening there.")
        XCTAssertEqual(stand.handedBack.map(\.text), ["Please do this for me: Call the bank"], "Its thread shows it: the words wait in its composer")
        XCTAssertEqual(stand.heard.last, "Scout leads Call the bank")
        XCTAssertEqual(tasks.open[0].leadAgentID, "scout")
        XCTAssertNil(tasks.open[0].handoff)
        XCTAssertEqual(TaskDetailView.stateWords(for: tasks.open[0], handoff: tasks.handoff(of: tasks.open[0]), agent: "Scout"), "Led by Scout")

        // The lead agent could not be kept: nothing more is done.
        stand.startFails = nil
        stand.changeFails = RepositoryError.dataLocked
        let started = stand.started.count
        let none = await tasks.doItForMe(tasks.open[0], agent: scout, as: "ada")
        XCTAssertEqual(none, .none)
        XCTAssertEqual(tasks.errorMessage, TasksModel.needsUnlock)
        XCTAssertEqual(stand.started.count, started)
        // A finished task is handed to nobody.
        stand.changeFails = nil
        let finished = await tasks.doItForMe(tasks.finished[0], agent: scout, as: "ada")
        XCTAssertEqual(finished, .none)
        XCTAssertEqual(stand.started.count, started)

        // Change Lead Agent… names the agent listed first next time, and starts nothing.
        let quill = quill
        stand.agents = [scout, quill]
        await tasks.loadAgents()
        await tasks.changeLeadAgent(tasks.open[0], to: quill, as: "ada")
        XCTAssertEqual(stand.changed.last?.change, TaskChange(leadAgentID: .to("quill")))
        XCTAssertEqual(stand.heard.last, "Quill leads Call the bank")
        XCTAssertEqual(stand.started.count, started)
    }

    func testStrixIsHandedATaskWithNoLeadAgentNamed_andNothingIsDoneForAnotherAccount() async {
        let stand = Stand()
        stand.kept = [task("a", "Call the bank")]
        let tasks = model(stand)
        await tasks.load()
        await tasks.loadAgents()
        XCTAssertEqual(tasks.leadChoices(for: tasks.open[0]), TaskRules.LeadChoices(marked: nil, reason: nil, others: [.strix]))

        let gate = Gate()
        stand.startingWaits = gate
        let handing = Task { await tasks.doItForMe(tasks.open[0], agent: .strix, as: "ada") }
        await gate.arrived(1)
        XCTAssertEqual(stand.changed.map(\.change), [TaskChange(threadID: "thread-1")], "No lead agent: Strix is no stored agent")
        XCTAssertNil(stand.madeThreads.first?.agent)
        XCTAssertEqual(tasks.saving, ["a"])
        // A second hand-off of the same task while one is on its way does nothing.
        let second = await tasks.doItForMe(tasks.open[0], agent: .strix, as: "ada")
        XCTAssertEqual(second, .none)
        await gate.letOneThrough()
        let outcome = await handing.value
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(stand.heard.last, "Strix is on Call the bank")
        XCTAssertEqual(stand.started.last?.agent, .strix, "As Strix itself, not as whoever the thread's own agent is")
        XCTAssertEqual(stand.changed.last?.change, TaskChange(handoffTurnID: "turn-1"), "Handed to no stored agent")
        XCTAssertNil(tasks.agentName(for: tasks.open[0]), "Recorded as running, and not run here: no hand-off to name")
        stand.live = ["thread-1": TaskLiveTurn(turnID: "turn-1")]
        tasks.turnsChanged()
        XCTAssertEqual(tasks.agentName(for: tasks.open[0]), "Strix")
        await tasks.changeLeadAgent(tasks.open[0], to: .strix, as: "ada")
        XCTAssertEqual(stand.changed.count, 2, "Strix is not named as a lead agent")

        // Another account signs in while the turn is being started: its id is not kept, nothing is said.
        stand.kept = [task("b", "Renew the lease")]
        await tasks.load()
        let changes = stand.changed.count, heard = stand.heard.count
        let anothers = Task { await tasks.doItForMe(tasks.open[0], agent: .strix, as: "ada") }
        await gate.arrived(2)
        stand.account = "grace"
        await gate.letOneThrough()
        _ = await anothers.value
        XCTAssertEqual(stand.changed.count, changes + 1, "Its thread was given before; the turn is not kept after")
        XCTAssertEqual(stand.heard.count, heard)
        XCTAssertEqual(tasks.saving, [])
    }

    // MARK: - On me

    func testOnMeShowsEveryPlacesTasks_andEachIsHandedToAnAgentOfItsOwnPlace() async {
        let stand = Stand()
        stand.kept = [
            task("a", "Call the bank", coven: "work"), task("b", "Book the flights", coven: "home"), task("c", "Renew the lease"),
            task("d", "File the return", coven: "work"), task("done", status: .done, coven: "home"),
        ]
        stand.agentsIn = ["work": [scout], "home": [quill]]
        stand.lastHandedToIn = ["home": "quill"]
        let tasks = model(stand, onMe: true)
        XCTAssertNil(tasks.leadChoices(for: stand.kept[0]), "Not read yet")
        await tasks.load()
        XCTAssertEqual(stand.scopes, [.onMe])
        XCTAssertEqual(tasks.open.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(tasks.finished.map(\.id), ["done"])

        // The places are known once the tasks are read: each coven's agents are read once, and Strix is Strix's.
        XCTAssertEqual(stand.agentsAsked, ["work", "home"])
        XCTAssertEqual(tasks.leadChoices(for: tasks.open[0]), TaskRules.LeadChoices(marked: nil, reason: nil, others: [scout]))
        XCTAssertEqual(tasks.leadChoices(for: tasks.open[1]), TaskRules.LeadChoices(marked: quill, reason: .lastUsed, others: []), "Last used, of its own place")
        XCTAssertEqual(tasks.leadChoices(for: tasks.open[2]), TaskRules.LeadChoices(marked: nil, reason: nil, others: [.strix]))
        await tasks.load()
        XCTAssertEqual(stand.agentsAsked, ["work", "home"], "Not read again with each listing")

        // A task is made in a place: On me adds none.
        let added = await tasks.add(title: "Something new", as: "ada")
        XCTAssertFalse(added)
        XCTAssertEqual(stand.created.count, 0)

        // A thread made for a task is made in the task's own place, for an agent of that place.
        let thread = await tasks.talkItThrough(tasks.open[1], as: "ada")
        XCTAssertEqual(thread?.covenId, "home")
        XCTAssertEqual(stand.madeThreads.last?.agent, quill)
        let handed = await tasks.doItForMe(tasks.open[0], agent: scout, as: "ada")
        XCTAssertEqual(handed, .started)
        XCTAssertEqual(stand.madeThreads.last?.covenID, "work")
        stand.live = ["thread-2": TaskLiveTurn(turnID: "turn-2")]
        tasks.turnsChanged()
        XCTAssertEqual(tasks.agentName(for: tasks.open[0]), "Scout")
        let strixs = await tasks.talkItThrough(tasks.open[2], as: "ada")
        XCTAssertNil(strixs?.covenId, "Strix's task, in no coven")
        XCTAssertNil(stand.madeThreads.last?.agent)
    }

    func testInOnMeACovenWhoseAgentsCouldNotBeReadSaysSoForItsOwnTasksOnly() async {
        let stand = Stand()
        stand.kept = [task("a", "Call the bank", coven: "work"), task("b", "Book the flights", coven: "home")]
        stand.agentsIn = ["work": nil, "home": [quill]]
        let tasks = model(stand, onMe: true)
        await tasks.load()
        XCTAssertTrue(tasks.agentsFailed(for: tasks.open[0]))
        XCTAssertNil(tasks.leadChoices(for: tasks.open[0]))
        XCTAssertFalse(tasks.agentsFailed(for: tasks.open[1]))
        XCTAssertEqual(tasks.leadChoices(for: tasks.open[1])?.others, [quill])

        // A reading that failed waits to be asked for again: not with each listing.
        await tasks.load()
        XCTAssertEqual(stand.agentsAsked, ["work", "home"])
        // Try Again reads the places shown again.
        stand.agentsIn["work"] = [scout]
        await tasks.loadAgents()
        XCTAssertEqual(stand.agentsAsked, ["work", "home", "work", "home"])
        XCTAssertFalse(tasks.agentsFailed(for: tasks.open[0]))
        XCTAssertEqual(tasks.leadChoices(for: tasks.open[0])?.others, [scout])

        // A reading that fails after one that worked keeps the agents read before, and says so
        // over them, with Try Again, for that place's tasks only.
        stand.agentsIn["home"] = .some(nil)
        await tasks.loadAgents()
        XCTAssertTrue(tasks.agentsFailed(for: tasks.open[1]))
        XCTAssertEqual(tasks.leadChoices(for: tasks.open[1])?.others, [quill], "Those read before stay")
        XCTAssertFalse(tasks.agentsFailed(for: tasks.open[0]))
        XCTAssertEqual(LeadAgentChoices.note(hasChoices: true, failedToLoad: true), .failed, "Said over the agents read before")
        XCTAssertEqual(LeadAgentChoices.note(hasChoices: false, failedToLoad: true), .failed)
        XCTAssertEqual(LeadAgentChoices.note(hasChoices: false, failedToLoad: false), .loading)
        XCTAssertNil(LeadAgentChoices.note(hasChoices: true, failedToLoad: false))
        stand.agentsIn["home"] = [quill]
        await tasks.loadAgents()
        XCTAssertFalse(tasks.agentsFailed(for: tasks.open[1]))

        // A place that comes to have a task is read when it does.
        stand.kept.append(task("c", "Renew the lease", coven: "club"))
        stand.agentsIn["club"] = []
        await tasks.load()
        XCTAssertEqual(stand.agentsAsked.last, "club")
        XCTAssertEqual(tasks.leadChoices(for: tasks.open[2])?.others.map(\.isStrix), [true], "A coven with no agents: Strix answers there")
    }

    func testWhatIsSaidOfAHandOffAsTheTasksAreFirstReadNamesItsAgent() async {
        // The agents are read with the tasks, before anything is said: on a place's own page
        // and in On me, where the places are known only once the tasks are read.
        for onMe in [false, true] {
            let stand = Stand()
            var waits = task("a", "Call the bank", coven: "work")
            waits.threadID = "thread-1"
            waits.handoff = TaskHandoff(turnID: "turn-1", outcome: .running, agentID: "scout")
            var ended = task("b", "Book the flights", coven: "work")
            ended.threadID = "thread-2"
            ended.handoff = TaskHandoff(turnID: "turn-2", outcome: .running, agentID: "scout")
            stand.kept = [waits, ended]
            stand.agentsIn = ["work": [scout]]
            stand.live = ["thread-1": TaskLiveTurn(turnID: "turn-1", needsOK: true)]
            let tasks = model(stand, covenID: "work", onMe: onMe)

            // The second task's turn ends while the tasks are read.
            let gate = Gate()
            stand.readingWaits = gate
            let reading = Task { await tasks.load() }
            await gate.arrived(1)
            ended.handoff?.outcome = .completed
            stand.kept = [waits, ended]
            await gate.letOneThrough()
            await gate.arrived(2)
            await gate.letOneThrough()
            await reading.value
            XCTAssertEqual(stand.heard, ["Scout needs your OK on Call the bank", "Scout finished Book the flights"], onMe ? "On me" : "A place's own page")
            XCTAssertEqual(stand.agentsAsked, ["work"], "Read once")
        }
    }

    func testAnApprovalAskedWhileTheAgentsAreReadIsSaidOnceTheyAre_byItsAgentsName() async {
        let stand = Stand()
        var handed = task("a", "Call the bank", coven: "work")
        handed.threadID = "thread-1"
        handed.handoff = TaskHandoff(turnID: "turn-1", outcome: .running, agentID: "scout")
        stand.kept = [handed]
        stand.agentsIn = ["work": [scout]]
        stand.live = ["thread-1": TaskLiveTurn(turnID: "turn-1")]
        let tasks = model(stand, covenID: "work")

        // The tasks are listed, and their place's agents are still being read, when the turn asks to be allowed something.
        let gate = Gate()
        stand.agentsWait = gate
        let reading = Task { await tasks.load() }
        await gate.arrived(1)
        XCTAssertEqual(tasks.open.map(\.id), ["a"], "Listed already")
        stand.live = ["thread-1": TaskLiveTurn(turnID: "turn-1", needsOK: true)]
        tasks.turnsChanged()
        XCTAssertEqual(tasks.handoff(of: tasks.open[0]), .needsOK, "The row says so at once")
        XCTAssertEqual(stand.heard, [], "Not said without its agent's name")
        await gate.letOneThrough()
        await reading.value
        XCTAssertEqual(stand.heard, ["Scout needs your OK on Call the bank"])
        tasks.turnsChanged()
        XCTAssertEqual(stand.heard.count, 1, "Once")

        // Answered, and asked again later: said again. Where the agents could not be read, it is said all the same.
        stand.live = ["thread-1": TaskLiveTurn(turnID: "turn-1")]
        tasks.turnsChanged()
        stand.live = ["thread-1": TaskLiveTurn(turnID: "turn-1", needsOK: true)]
        tasks.turnsChanged()
        XCTAssertEqual(stand.heard.count, 2)
        let failing = Stand()
        failing.kept = [handed]
        failing.agentsIn = ["work": nil]
        failing.live = ["thread-1": TaskLiveTurn(turnID: "turn-1", needsOK: true)]
        let others = model(failing, covenID: "work")
        await others.load()
        XCTAssertEqual(failing.heard, ["An agent needs your OK on Call the bank"])
    }

    func testOnMeNamesEachTasksPlace() {
        let covens = [Coven(id: "work", name: "Work", createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))]
        XCTAssertEqual(TasksView.placeName(ofCoven: nil, among: covens), "Strix")
        XCTAssertEqual(TasksView.placeName(ofCoven: "work", among: covens), "Work")
        XCTAssertEqual(TasksView.placeName(ofCoven: "gone", among: covens), "Another coven")

        // First on the row's line, and in the details.
        var led = task("a", "Call the bank", pin: TaskPin(period: .today, expiresAt: now.addingTimeInterval(3600)), coven: "work")
        led.leadAgentID = "scout"
        XCTAssertEqual(
            TaskRules.context(of: led, now: now, agent: "Scout", place: "Work", calendar: calendar),
            [.plain("Work"), .pin("Today"), .plain("Led by Scout")]
        )
        XCTAssertEqual(TaskRules.context(of: task("b"), now: now, place: "Strix", calendar: calendar), [.plain("Strix")])
        XCTAssertEqual(TaskRules.context(of: task("b"), now: now, calendar: calendar), [], "A place's own page names no place")
        XCTAssertEqual(TaskDetailView.stateWords(for: led, agent: "Scout", place: "Work"), "Work · Led by Scout")
        XCTAssertEqual(TaskDetailView.stateWords(for: task("b"), place: "Strix"), "Strix")
        XCTAssertEqual(TaskDetailView.stateWords(for: task("c", status: .done), place: "Work"), "Work · Done")
        XCTAssertNil(TaskDetailView.stateWords(for: task("b")))
        // And under the title of a task asked about under "Still on today?", for VoiceOver too.
        XCTAssertEqual(TaskReviewRow.label(for: led, place: "Work"), "Still on today: Call the bank, Work")
        XCTAssertEqual(TaskReviewRow.label(for: led, place: nil), "Still on today: Call the bank")
    }

    func testOnMeIsAPlaceOfThePersonsOwn_overWhateverScopeIsOnScreen() {
        let navigator = ShellNavigator()
        navigator.select(.coven("work"))
        navigator.openPlace(.tasks)
        let generation = navigator.placeGeneration

        navigator.openPlace(.onMe)
        XCTAssertEqual(navigator.personPlace, .onMe)
        XCTAssertEqual(navigator.sidebarItem, .onMe, "Its own row")
        XCTAssertEqual(navigator.placeTitle, "On me")
        XCTAssertEqual(navigator.place, .tasks(covenId: "work"), "The scope's place waits underneath")
        XCTAssertGreaterThan(navigator.placeGeneration, generation)
        XCTAssertEqual(
            shellWindowTitle(covenName: "Work", personPlace: navigator.personPlace, covenPlaceTitle: "Tasks"), "On me", "Of every scope: titled by itself"
        )
        XCTAssertEqual(shellWindowTitle(covenName: nil, personPlace: .onMe, covenPlaceTitle: nil), "On me")
        XCTAssertEqual(navigator.phonePath, [.place, .personPlace])

        // New Task is the scope's: it leaves On me for the scope's Tasks, whose line takes the cursor.
        navigator.requestNewTask()
        XCTAssertNil(navigator.personPlace)
        XCTAssertEqual(navigator.sidebarItem, .tasks)
        XCTAssertTrue(navigator.takeNewTaskRequest())
        // While On me is open, an ask for New Task is not its to take.
        navigator.requestNewTask()
        navigator.openPlace(.onMe)
        XCTAssertFalse(navigator.takeNewTaskRequest())

        // Any move of the person leaves it.
        navigator.select(.strix)
        XCTAssertNil(navigator.personPlace)
        navigator.openPlace(.onMe)
        navigator.showOverview()
        XCTAssertNil(navigator.personPlace)
        navigator.openPlace(.onMe)
        navigator.openPlace(.activity)
        XCTAssertEqual(navigator.personPlace, .activity)
        XCTAssertEqual(navigator.sidebarItem, .activity)
    }

    // MARK: - New Task

    func testNewTaskOpensTheTasksOfTheScopeOnScreen_andItsLineIsAskedForOnce() {
        let navigator = ShellNavigator()
        navigator.select(.coven("work"))
        XCTAssertFalse(navigator.takeNewTaskRequest(), "Nothing asked yet")

        navigator.requestNewTask()
        XCTAssertEqual(navigator.place, .tasks(covenId: "work"))
        XCTAssertEqual(navigator.sidebarItem, .tasks)
        XCTAssertTrue(navigator.takeNewTaskRequest())
        XCTAssertFalse(navigator.takeNewTaskRequest(), "Once")

        // On Strix it is Strix's tasks; asked for again while they are open, it is asked again.
        navigator.select(.strix)
        navigator.requestNewTask()
        XCTAssertEqual(navigator.place, .tasks(covenId: nil))
        navigator.requestNewTask()
        XCTAssertTrue(navigator.takeNewTaskRequest())

        // An ask the person has left before anything took it is over: coming
        // back to Tasks, there or in another scope, does not take the cursor.
        navigator.requestNewTask()
        navigator.showOverview()
        navigator.openPlace(.tasks)
        XCTAssertFalse(navigator.takeNewTaskRequest(), "Coming back to Tasks does not take the cursor")
        navigator.requestNewTask()
        navigator.select(.coven("work"))
        navigator.openPlace(.tasks)
        XCTAssertFalse(navigator.takeNewTaskRequest(), "Nor does another scope's Tasks")
        // Asked for again, it is taken.
        navigator.requestNewTask()
        XCTAssertTrue(navigator.takeNewTaskRequest())

        // Taken, the cursor may still be owed while the tasks are read: the ask
        // stands until the person's next move, also one that leaves Tasks open.
        XCTAssertTrue(navigator.newTaskAskStands)
        navigator.requestSearch()
        XCTAssertEqual(navigator.place, .tasks(covenId: "work"), "Still on Tasks")
        XCTAssertFalse(navigator.newTaskAskStands, "The search has the cursor now")
    }

    func testAThreadMadeReadyForATaskIsNotOpenedOverWhatThePersonAskedForSince() {
        // What the page decides once the thread is ready: Talk it through notes the
        // person's moves as it is asked. New Task and Search Threads are moves, also
        // where they leave Tasks open.
        let navigator = ShellNavigator()
        navigator.openPlace(.tasks)
        var asked = navigator.personMoves
        XCTAssertTrue(TasksView.stillOpensThread(askedAt: asked, in: navigator, as: "ada", signedIn: "ada"))
        XCTAssertFalse(TasksView.stillOpensThread(askedAt: asked, in: navigator, as: "ada", signedIn: "grace"), "Another account")
        navigator.requestNewTask()
        XCTAssertEqual(navigator.place, .tasks(covenId: nil), "Still on Tasks")
        XCTAssertFalse(TasksView.stillOpensThread(askedAt: asked, in: navigator, as: "ada", signedIn: "ada"), "New Task since")
        asked = navigator.personMoves
        XCTAssertTrue(TasksView.stillOpensThread(askedAt: asked, in: navigator, as: "ada", signedIn: "ada"))
        navigator.requestSearch()
        XCTAssertFalse(TasksView.stillOpensThread(askedAt: asked, in: navigator, as: "ada", signedIn: "ada"), "Search Threads since")
    }
}
