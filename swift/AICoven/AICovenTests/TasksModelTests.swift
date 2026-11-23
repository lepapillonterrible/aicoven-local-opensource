@testable import AICoven
import XCTest

/// A place's Tasks page: what it shows of the tasks it reads, adding one,
/// and marking one done, closed or open again, each as the account that
/// asked.
@MainActor
final class TasksModelTests: XCTestCase {
    private func task(
        _ id: String, _ title: String? = nil, status: TaskStatus = .open, pin: TaskPin? = nil, unreadable: Bool = false
    ) -> TaskItem {
        TaskItem(
            id: id, covenID: nil, title: unreadable ? "" : title ?? id.capitalized, status: status, stage: .backlog, due: nil, pin: pin,
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
        var created: [(title: String, covenID: String?, account: String)] = []
        var createFails: Error?
        var creatingWaits: Gate?
        var changed: [(id: String, change: TaskChange, account: String)] = []
        var changeFails: Error?
        var changingWaits: Gate?
        /// What VoiceOver was told, in order.
        var heard: [String] = []
        var answered: [(ids: [String], keepUntil: Date?, account: String)] = []
        var answerFails: Error?
        var answers: Set<String>?
        var answeringWaits: Gate?
    }

    private func model(_ stand: Stand, covenID: String? = nil) -> TasksModel {
        TasksModel(
            covenID: covenID,
            source: TasksModel.Source(
                tasks: { covenID, account in
                    // What is kept is read, or fails to be, as the reading is asked;
                    // what came of it is given once it is let through.
                    let outcome: Result<TaskListing, Error> = await MainActor.run {
                        stand.readings.append((covenID, account))
                        if let error = stand.readFails { return .failure(error) }
                        let open = stand.kept.filter { !$0.isFinished }
                        let finished = stand.kept.filter(\.isFinished)
                        return .success(TaskListing(tasks: open + finished, finished: stand.finishedInAll ?? finished.count))
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
                            return self.task(kept.id, kept.title, status: change.status ?? kept.status, pin: pin)
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
            signedIn: { stand.account }, announce: { stand.heard.append($0) }, now: { self.now }, calendar: { self.calendar }
        )
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
            covenID: nil,
            source: TasksModel.Source(
                tasks: { _, _ in await MainActor.run { TaskListing(tasks: stand.kept, finished: 0) } },
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
}
