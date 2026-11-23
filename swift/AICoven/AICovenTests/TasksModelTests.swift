@testable import AICoven
import XCTest

/// A place's Tasks page: what it shows of the tasks it reads, adding one,
/// and marking one done, closed or open again, each as the account that
/// asked.
@MainActor
final class TasksModelTests: XCTestCase {
    private func task(_ id: String, _ title: String? = nil, status: TaskStatus = .open, unreadable: Bool = false) -> TaskItem {
        TaskItem(
            id: id, covenID: nil, title: unreadable ? "" : title ?? id.capitalized, status: status, stage: .backlog, due: nil, pin: nil,
            isUnreadable: unreadable, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

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
    }

    private func model(_ stand: Stand, covenID: String? = nil) -> TasksModel {
        TasksModel(
            covenID: covenID,
            source: TasksModel.Source(
                tasks: { covenID, account in
                    // What is kept is read as the reading is asked, and given once it is let through.
                    let listing = try await MainActor.run {
                        stand.readings.append((covenID, account))
                        if let error = stand.readFails { throw error }
                        let open = stand.kept.filter { !$0.isFinished }
                        let finished = stand.kept.filter(\.isFinished)
                        return TaskListing(tasks: open + finished, finished: stand.finishedInAll ?? finished.count)
                    }
                    await MainActor.run { stand.readingWaits }?.wait()
                    return listing
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
                        stand.kept = stand.kept.map { $0.id == id ? self.task($0.id, $0.title, status: change.status ?? $0.status) : $0 }
                    }
                }
            ),
            signedIn: { stand.account }
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
        XCTAssertEqual(tasks.said, TasksModel.Said(number: 1, words: TasksModel.couldNotLoad))

        stand.readFails = nil
        stand.kept = [task("a")]
        await tasks.load()
        XCTAssertNil(tasks.errorMessage, "Read after all")
        XCTAssertEqual(tasks.open.map(\.id), ["a"])

        stand.readFails = RepositoryError.databaseUnavailable
        await tasks.load()
        XCTAssertEqual(tasks.open.map(\.id), ["a"], "The list stays")
        XCTAssertEqual(tasks.errorMessage, TasksModel.couldNotLoad)
        XCTAssertEqual(tasks.said?.number, 2, "Each failed reading is said")

        // A reading that was called off is no failure.
        stand.readFails = CancellationError()
        await tasks.load()
        XCTAssertEqual(tasks.said?.number, 2)
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
        XCTAssertEqual(tasks.said?.words, "Added Book the venue")
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
        XCTAssertEqual(tasks.said?.words, "Added Second")
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
            XCTAssertEqual(tasks.said?.words, words)
        }
        XCTAssertEqual(tasks.said?.number, 4, "Each its own")

        // Asking again clears what was said of the last; nothing is said to another account.
        stand.account = "grace"
        let anothers = await tasks.add(title: "More", as: "ada")
        XCTAssertFalse(anothers)
        XCTAssertNil(tasks.errorMessage)
        XCTAssertEqual(tasks.said?.number, 4)
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
        XCTAssertNil(tasks.said)
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
        XCTAssertEqual(tasks.said?.words, "Marked Call the bank done")
        XCTAssertEqual(tasks.saving, [])

        await tasks.close(tasks.open[0], as: "ada")
        XCTAssertEqual(stand.changed.last?.change, TaskChange(status: .closed))
        XCTAssertEqual(tasks.said?.words, "Closed Renew the lease")
        XCTAssertEqual(tasks.open.count, 0)

        let done = tasks.finished.first { $0.id == "a" }
        try await tasks.setDone(XCTUnwrap(done), false, as: "ada")
        XCTAssertEqual(stand.changed.last?.change, TaskChange(status: .open))
        XCTAssertEqual(tasks.said?.words, "Reopened Call the bank")
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
            XCTAssertEqual(tasks.said?.words, words)
            XCTAssertEqual(tasks.saving, [])
        }
        let said = tasks.said?.number

        stand.changeFails = TaskError.noSuchTask
        stand.kept = []
        await tasks.setDone(listed, false, as: "ada")
        XCTAssertNil(tasks.errorMessage)
        XCTAssertEqual(tasks.said?.number, said, "Nothing more is said")
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
        XCTAssertNil(tasks.said, "Nothing is said to another account")
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

        // An ask the person has left before it was taken is not kept for later.
        navigator.requestNewTask()
        navigator.showOverview()
        XCTAssertFalse(navigator.takeNewTaskRequest())
        navigator.openPlace(.tasks)
        XCTAssertFalse(navigator.takeNewTaskRequest(), "Coming back to Tasks does not take the cursor")
    }
}
