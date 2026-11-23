@testable import AICoven
import XCTest

/// The reminders the system holds follow the store: read as the account
/// signed in, one reading at a time, and nothing while its data is locked.
@MainActor
final class TaskRemindersTests: XCTestCase {
    /// Holds whoever waits at it until the test opens it, and tells when someone has come.
    private actor Gate {
        private var isOpen = false
        private var held: [CheckedContinuation<Void, Never>] = []
        private var arrivals = 0
        private var hearing: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func wait() async {
            arrivals += 1
            let due = hearing.filter { $0.count <= arrivals }
            hearing.removeAll { $0.count <= arrivals }
            due.forEach { $0.continuation.resume() }
            if !isOpen { await withCheckedContinuation { held.append($0) } }
        }

        func arrived(_ count: Int = 1) async {
            if arrivals < count { await withCheckedContinuation { hearing.append((count, $0)) } }
        }

        func open() {
            isOpen = true
            held.forEach { $0.resume() }
            held = []
        }
    }

    /// The store and the system, as the test stands in for them. Sendable by hand: used on the main actor only.
    private final class Stand: @unchecked Sendable {
        var account = "ada"
        var kept: [TaskReminderDue] = []
        var readFails: Error?
        var readingWaits: Gate?
        var readings: [String] = []
        var held: [(due: [TaskReminderDue], account: String)] = []
        var permission: LocalNotifications.Permission? = .allowed
        var asked = 0
    }

    private func reminders(_ stand: Stand) -> TaskReminders {
        TaskReminders(
            hands: TaskReminders.Hands(
                reminders: { account in
                    // What is kept is read as the reading is asked; it is given once it is let through.
                    let outcome: Result<[TaskReminderDue], Error> = await MainActor.run {
                        stand.readings.append(account)
                        if let error = stand.readFails { return .failure(error) }
                        return .success(stand.kept)
                    }
                    await MainActor.run { stand.readingWaits }?.wait()
                    return try outcome.get()
                },
                hold: { due, account in stand.held.append((due, account)) },
                permission: { stand.permission },
                ask: {
                    stand.asked += 1
                    stand.permission = .allowed
                }
            ),
            signedIn: { stand.account }
        )
    }

    private let due = TaskReminderDue(taskID: "a", title: "Renew the lease", remindAt: Date(timeIntervalSince1970: 1_800_000_000))

    func testTheSignedInAccountsRemindersAreReadAndHandedToTheSystem() async {
        let stand = Stand()
        stand.kept = [due]
        let reminders = reminders(stand)
        await reminders.refresh().value
        XCTAssertEqual(stand.readings, ["ada"])
        XCTAssertEqual(stand.held.map(\.due), [[due]])
        XCTAssertEqual(stand.held.map(\.account), ["ada"])

        // While the account's data is locked nothing is read, and what waits stays as it is.
        stand.readFails = RepositoryError.dataLocked
        await reminders.refresh().value
        XCTAssertEqual(stand.held.count, 1)
        // With nobody signed in there is nothing to read.
        stand.readFails = nil
        stand.account = ""
        await reminders.refresh().value
        XCTAssertEqual(stand.readings.count, 2)
        XCTAssertEqual(stand.held.count, 1)
    }

    func testOneReadingAtATime_andTheLastAskIsAnsweredByAReadingMadeAfterIt() async {
        let stand = Stand()
        let gate = Gate()
        stand.readingWaits = gate
        let reminders = reminders(stand)

        let first = reminders.refresh()
        await gate.arrived()
        // A task changes while the first reading is under way: asked again, it is read again afterwards, once.
        stand.kept = [due]
        let second = reminders.refresh()
        let third = reminders.refresh()
        await gate.open()
        await first.value
        await second.value
        await third.value
        XCTAssertEqual(stand.readings.count, 2, "The reading under way, and one more for what was asked meanwhile")
        XCTAssertEqual(stand.held.map(\.due), [[], [due]], "The last word is the store's as it is now")
    }

    func testNothingIsHandedOverForAnAccountThatLeftWhileItsRemindersWereRead() async {
        let stand = Stand()
        stand.kept = [due]
        let gate = Gate()
        stand.readingWaits = gate
        let reminders = reminders(stand)
        let reading = reminders.refresh()
        await gate.arrived()
        stand.account = "grace"
        await gate.open()
        await reading.value
        XCTAssertEqual(stand.held.count, 0)
    }

    func testSettingAReminderAsksTheSystemOnlyWhereItWasNeverAsked() async {
        let stand = Stand()
        stand.kept = [due]
        let reminders = reminders(stand)
        stand.permission = .notAsked
        await reminders.reminderWasSet()
        XCTAssertEqual(stand.asked, 1, "The person has just asked to be reminded")
        XCTAssertEqual(stand.held.count, 1, "Handed over with the answer")
        // Allowed, or refused: the system is not asked again.
        await reminders.reminderWasSet()
        stand.permission = .denied
        await reminders.reminderWasSet()
        XCTAssertEqual(stand.asked, 1)
        XCTAssertEqual(stand.held.count, 3)
    }

    func testWhatIsSaidUnderAReminderThatWouldNotBeShown() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let toCome = TaskReminder(preset: nil, remindAt: now.addingTimeInterval(60), timeZone: "GMT")
        let passed = TaskReminder(preset: nil, remindAt: now.addingTimeInterval(-60), timeZone: "GMT")
        XCTAssertNil(TaskDetailView.reminderNote(for: toCome, now: now, permission: .allowed, isOn: true))
        XCTAssertNil(TaskDetailView.reminderNote(for: toCome, now: now, permission: .notAsked, isOn: true), "Setting one asks")
        XCTAssertEqual(TaskDetailView.reminderNote(for: toCome, now: now, permission: .denied, isOn: true), TaskDetailView.remindersOffOnDevice)
        XCTAssertEqual(TaskDetailView.reminderNote(for: toCome, now: now, permission: .allowed, isOn: false), TaskDetailView.remindersOffForAccount)
        // Nothing of one that has reminded, or of no reminder.
        XCTAssertNil(TaskDetailView.reminderNote(for: passed, now: now, permission: .denied, isOn: false))
        XCTAssertNil(TaskDetailView.reminderNote(for: nil, now: now, permission: .denied, isOn: false))
    }

    // MARK: - A tapped reminder

    func testATappedReminderOpensItsTasksDetailsWhereTheTaskIsKept() async {
        let navigator = ShellNavigator()
        navigator.openPlace(.memory)

        // A task of a coven's: its coven's Tasks, asked to show it; taken once, by that place only.
        await navigator.openTask(askedFor: "t1", as: "ada", signedIn: { "ada" }) { _ in "work" }
        XCTAssertEqual(navigator.selected, .coven("work"))
        XCTAssertEqual(navigator.place, .tasks(covenId: "work"))
        XCTAssertNil(navigator.takeTaskAsk(in: .strix), "Not Strix's to take")
        XCTAssertEqual(navigator.takeTaskAsk(in: .coven("work")), "t1")
        XCTAssertNil(navigator.takeTaskAsk(in: .coven("work")), "Once")

        // One of Strix's own.
        await navigator.openTask(askedFor: "t2", as: "ada", signedIn: { "ada" }) { _ in nil }
        XCTAssertEqual(navigator.selected, .strix)
        XCTAssertEqual(navigator.place, .tasks(covenId: nil))
        // Once the person has gone anywhere else it is asked of nobody, also when they come back.
        navigator.showOverview()
        navigator.openPlace(.tasks)
        XCTAssertNil(navigator.takeTaskAsk(in: .strix))
    }

    func testATappedReminderOpensNothingThatIsNotTheSignedInAccounts_orOverWhereThePersonWent() async {
        let navigator = ShellNavigator()
        // A task that is not the account's, or is gone.
        await navigator.openTask(askedFor: "hers", as: "ada", signedIn: { "ada" }) { _ in throw TaskError.noSuchTask }
        XCTAssertNil(navigator.place)
        // Another account signed in while it was looked up.
        await navigator.openTask(askedFor: "t1", as: "ada", signedIn: { "grace" }) { _ in "work" }
        XCTAssertNil(navigator.place)
        XCTAssertEqual(navigator.selected, .strix)
        // The person went somewhere while it was looked up.
        await navigator.openTask(askedFor: "t1", as: "ada", signedIn: { "ada" }) { _ in
            navigator.openPlace(.memory)
            return "work"
        }
        XCTAssertEqual(navigator.place, .memoryList(covenId: nil))
        XCTAssertNil(navigator.taskAsked)
    }

    func testATappedRemindersTaskIsHeldForTheShell_once_andNotForAnotherAccount() {
        let state = AppState.shared
        addTeardownBlock { await MainActor.run {
            _ = state.consumeTaskAsk()
            state.accountReported(nil)
        } }
        state.accountReported("ada")
        state.notificationTapped(forTask: "t1")
        XCTAssertEqual(state.pendingTaskID, "t1")
        XCTAssertEqual(state.consumeTaskAsk(), "t1")
        XCTAssertNil(state.consumeTaskAsk(), "Once")
        state.notificationTapped(forTask: "t2")
        state.accountReported("grace")
        XCTAssertNil(state.consumeTaskAsk(), "Dropped when another account takes the first one's place")
    }
}
