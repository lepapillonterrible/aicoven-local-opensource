@testable import AICoven
import XCTest

/// Notifications made on this device: what one says, when one is made,
/// and whose it is.
@MainActor
final class LocalNotificationsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        try await super.setUp()
        suite = "LocalNotificationsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private func thread(_ id: String = "t1", of account: String = "ada", agent: String? = "Scout", title: String? = "Q4 board pack") -> AICoven.Thread {
        Thread(
            id: id, userId: account, covenId: "work", title: title, agentName: agent,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: nil, lastMessageAt: nil
        )
    }

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

        /// Returns once `count` have come to wait here.
        func arrived(_ count: Int = 1) async {
            if arrivals < count { await withCheckedContinuation { hearing.append((count, $0)) } }
        }

        func open() {
            isOpen = true
            held.forEach { $0.resume() }
            held = []
        }
    }

    /// The system's side, as the test stands in for it. Sendable by hand: read and written on the main actor only.
    private final class System: @unchecked Sendable {
        var permission = LocalNotifications.Permission.allowed
        /// What the person answers when the system asks.
        var allows = true
        var asked = 0
        /// Where reading the permission, and the system's question, wait, if anywhere.
        var readingWaits: Gate?
        var askingWaits: Gate?
        var shown: [(id: String, notification: ComposedNotification)] = []
        /// Whether the system takes a notification it is given.
        var takes = true
        var withdrawn: [String] = []
        var withdrewAll = 0
        /// What the system was handed to show at a time, and where handing one over waits, if anywhere.
        var scheduled: [(id: String, notification: ComposedNotification, at: Date)] = []
        var schedulingWaits: Gate?
        /// The ids the system holds: waiting for their time, or shown and not cleared.
        var held: [String] = []

        var center: LocalNotifications.Center {
            LocalNotifications.Center(
                permission: { [self] in
                    // As it is when it is asked for, however long the answer takes.
                    let answer = permission
                    await readingWaits?.wait()
                    return answer
                },
                ask: { [self] in
                    asked += 1
                    await askingWaits?.wait()
                    permission = allows ? .allowed : .denied
                    return allows
                },
                show: { [self] id, notification in
                    guard takes else { return false }
                    shown.append((id, notification))
                    return true
                },
                schedule: { [self] id, notification, at in
                    await schedulingWaits?.wait()
                    guard takes else { return false }
                    scheduled.append((id, notification, at))
                    if !held.contains(id) { held.append(id) }
                    return true
                },
                listed: { [self] in held },
                withdraw: { [self] ids in
                    withdrawn += ids
                    held.removeAll { ids.contains($0) }
                },
                withdrawAll: { [self] in
                    withdrewAll += 1
                    held = []
                }
            )
        }
    }

    private func notifications(_ system: System, signedIn: @escaping () -> String = { "ada" }, now: @escaping () -> Date = Date.init) -> LocalNotifications {
        let made = LocalNotifications(center: system.center, defaults: defaults, signedIn: signedIn, now: now)
        made.appIsInFront = false
        return made
    }

    // MARK: - What a notification says

    func testWithoutDetailsANotificationSaysOnlyWhichAgentItIsAbout() {
        func composed(_ event: NotificationEvent, agent: String? = "Scout") -> ComposedNotification {
            NotificationComposer.compose(event, agentName: agent, threadTitle: "Q4 board pack", placeName: "Client work", showsDetails: false)
        }
        XCTAssertEqual(
            composed(.finished(reply: "The pack is ready. It has 12 slides.")),
            ComposedNotification(title: "Scout finished", subtitle: "", body: "Open AICoven to read the answer."),
            "Nothing of the thread's name or of what was said"
        )
        XCTAssertEqual(composed(.needsOK(question: "Run this command?")), ComposedNotification(title: "Scout needs your OK", subtitle: "", body: "Open AICoven to review."))
        XCTAssertEqual(
            composed(.problem(reason: "The key was refused.")),
            ComposedNotification(title: "Scout stopped on a problem", subtitle: "", body: "Open AICoven to see what went wrong.")
        )
        // A thread with no agent of its own is answered by Strix.
        XCTAssertEqual(composed(.finished(reply: "Done."), agent: nil).title, "Strix finished")
        XCTAssertEqual(composed(.finished(reply: "Done."), agent: "  ").title, "Strix finished")
    }

    func testWithDetailsItNamesWhereAndSaysTheFirstSentence() {
        func composed(_ event: NotificationEvent) -> ComposedNotification {
            NotificationComposer.compose(event, agentName: "Scout", threadTitle: "Q4 board pack", placeName: "Client work", showsDetails: true)
        }
        XCTAssertEqual(
            composed(.finished(reply: "The pack is in README.md now.\n\nIt has 12 slides.")),
            ComposedNotification(title: "Scout finished", subtitle: "Client work · Q4 board pack", body: "The pack is in README.md now.")
        )
        XCTAssertEqual(composed(.needsOK(question: "Run this\ncommand?")).body, "Run this command?")
        XCTAssertEqual(composed(.problem(reason: "The key was refused. Add another.")).body, "The key was refused.")
        // Nothing to say: the same words as without details.
        XCTAssertEqual(composed(.finished(reply: " \n")).body, NotificationComposer.answerFallback)
        // One long sentence is cut at the longest, with an ellipsis.
        let long = composed(.finished(reply: String(repeating: "word ", count: 100))).body
        XCTAssertEqual(long.count, NotificationComposer.longestBody)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    // MARK: - A tap

    func testATappedNotificationsIdSaysWhichThreadItIsAbout_andNothingElseDoes() {
        XCTAssertEqual(LocalNotifications.threadID(ofNotification: LocalNotifications.id(forThread: "t1")), "t1")
        XCTAssertEqual(LocalNotifications.threadID(ofNotification: "thread-A1B2-C3"), "A1B2-C3")
        for other in ["", "thread-", "t1", "reminder-t1", "Thread-t1"] {
            XCTAssertNil(LocalNotifications.threadID(ofNotification: other), other)
        }
    }

    // MARK: - When one is made

    func testOneIsMadeOnlyWhileTheAppIsNotInFront_allowed_wanted_andForTheAccountSignedIn() async {
        let system = System()
        var signedIn = "ada"
        let notifications = notifications(system) { signedIn }
        let event = NotificationEvent.finished(reply: "The pack is ready.")

        var made = await notifications.notify(event, in: thread(), placeName: "Client work", as: "ada")
        XCTAssertTrue(made)
        XCTAssertEqual(system.shown.map(\.id), ["thread-t1"], "Under its thread's id: the next takes its place")
        XCTAssertEqual(system.shown.first?.notification, ComposedNotification(title: "Scout finished", subtitle: "", body: "Open AICoven to read the answer."), "Without details, until the person asks for them")

        // In front: the person is looking.
        notifications.appIsInFront = true
        made = await notifications.notify(event, in: thread(), placeName: "Client work", as: "ada")
        XCTAssertFalse(made)
        notifications.appIsInFront = false

        // Not this account's thread; not the account signed in.
        made = await notifications.notify(event, in: thread(of: "grace"), placeName: "Client work", as: "ada")
        XCTAssertFalse(made)
        signedIn = "grace"
        made = await notifications.notify(event, in: thread(), placeName: "Client work", as: "ada")
        XCTAssertFalse(made)
        signedIn = "ada"

        // Turned off in Settings: nothing is made, and what was shown is taken back.
        notifications.setOn(false, for: "ada")
        XCTAssertEqual(system.withdrewAll, 1)
        made = await notifications.notify(event, in: thread(), placeName: "Client work", as: "ada")
        XCTAssertFalse(made)
        notifications.setOn(true, for: "ada")

        // This device does not allow them, or was never asked: read each time, as it is then.
        for permission in [LocalNotifications.Permission.denied, .notAsked] {
            system.permission = permission
            made = await notifications.notify(event, in: thread(), placeName: "Client work", as: "ada")
            XCTAssertFalse(made, "\(permission)")
        }
        XCTAssertEqual(system.shown.count, 1)
        XCTAssertEqual(system.asked, 0, "Notifying never asks for the permission")
        // Allowed since, in the system's own settings: the next one is made, with nothing in the app opened between.
        system.permission = .allowed
        made = await notifications.notify(event, in: thread(), placeName: "Client work", as: "ada")
        XCTAssertTrue(made)
        // One the system would not take was not made.
        system.takes = false
        made = await notifications.notify(event, in: thread(), placeName: "Client work", as: "ada")
        XCTAssertFalse(made)
    }

    func testDetailsAreEachAccountsOwnChoice() async {
        let system = System()
        var signedIn = "ada"
        let notifications = notifications(system) { signedIn }
        notifications.setShowsDetails(true, for: "ada")
        XCTAssertTrue(notifications.showsDetails(for: "ada"))
        XCTAssertFalse(notifications.showsDetails(for: "grace"), "Off until she turns it on")

        await notifications.notify(.finished(reply: "The pack is ready. More follows."), in: thread(), placeName: "Client work", as: "ada")
        XCTAssertEqual(system.shown.last?.notification, ComposedNotification(title: "Scout finished", subtitle: "Client work · Q4 board pack", body: "The pack is ready."))

        signedIn = "grace"
        await notifications.notify(.finished(reply: "Hers."), in: thread("t2", of: "grace"), placeName: "Client work", as: "grace")
        XCTAssertEqual(system.shown.last?.notification.subtitle, "")
        // Turning hers off leaves Ada's on.
        notifications.setOn(false, for: "grace")
        XCTAssertTrue(notifications.isOn(for: "ada"))
    }

    func testWhatWasNotifiedLeavesWhenItsThreadIsShown_andAllOfItWhenTheAccountChanges() async {
        let system = System()
        system.permission = .notAsked
        let notifications = notifications(system)
        notifications.threadShown("t1")
        XCTAssertEqual(system.withdrawn, ["thread-t1"])

        // The app is opened again as the same account: what it was notified of stays.
        notifications.accountReported("ada")
        await notifications.offerIfUseful(agentName: "Scout", as: "ada")
        XCTAssertNotNil(notifications.offer)
        XCTAssertTrue(notifications.takeOfferAnnouncement(), "The line is told to VoiceOver")
        XCTAssertFalse(notifications.takeOfferAnnouncement(), "Once, wherever it shows again")
        notifications.accountReported("ada")
        XCTAssertEqual(system.withdrewAll, 0)
        XCTAssertNotNil(notifications.offer)

        // Another account, or none: nothing notified to the first stays on the screen.
        notifications.accountReported("grace")
        XCTAssertEqual(system.withdrewAll, 1)
        XCTAssertNil(notifications.offer)
        notifications.accountReported(nil)
        XCTAssertEqual(system.withdrewAll, 2)
    }

    func testNotificationsTurnedOffWhileOneIsOnItsWay_isNotMade() async {
        let system = System()
        system.readingWaits = Gate()
        let notifications = notifications(system)
        // The permission has not been read yet: making one waits for it.
        let making = Task { await notifications.notify(.finished(reply: "Done."), in: self.thread(), placeName: "Client work", as: "ada") }
        await system.readingWaits?.arrived()
        notifications.setOn(false, for: "ada")
        await system.readingWaits?.open()

        let made = await making.value
        XCTAssertFalse(made)
        XCTAssertEqual(system.shown.count, 0, "Nothing is shown after the person turned them off")
    }

    func testWhatItIsAboutBeingOverWhileOneIsOnItsWay_isNotMade() async {
        let system = System()
        system.readingWaits = Gate()
        let notifications = notifications(system)
        var stillAsked = true
        // An approval is asked; the permission has not been read yet, so making its notification waits.
        let making = Task {
            await notifications.notify(.needsOK(question: "Run this command?"), in: self.thread(), placeName: "Client work", as: "ada") { stillAsked }
        }
        await system.readingWaits?.arrived()
        // Meanwhile it is answered.
        stillAsked = false
        await system.readingWaits?.open()

        let made = await making.value
        XCTAssertFalse(made)
        XCTAssertEqual(system.shown.count, 0, "Nothing says an OK is needed that no longer is")
    }

    func testAnOlderReadingOfThePermissionDoesNotUndoANewerOne() async {
        let system = System()
        system.permission = .notAsked
        let gate = Gate()
        system.readingWaits = gate
        let notifications = notifications(system)

        // Settings reads the permission (never asked for), and its answer is slow.
        let older = Task { await notifications.refreshPermission() }
        await gate.arrived()
        // Meanwhile the person allows notifications, and that is read.
        system.permission = .allowed
        let newer = Task { await notifications.refreshPermission() }
        await gate.arrived(2)
        await gate.open()
        await older.value
        await newer.value

        XCTAssertEqual(notifications.permission, .allowed)
        // So the line is not offered again after the system's question was answered.
        await notifications.offerIfUseful(agentName: "Scout", as: "ada")
        XCTAssertNil(notifications.offer)
    }

    // MARK: - Asking for the permission

    func testWhileTheSystemIsAskingNothingElseAsksOrIsOffered_andTheLineIsGoneOnceItHasAnswered() async {
        let system = System()
        system.permission = .notAsked
        system.askingWaits = Gate()
        let notifications = notifications(system)
        await notifications.refreshPermission()

        let turningOn = Task { await notifications.turnOn() }
        await system.askingWaits?.arrived()
        XCTAssertTrue(notifications.isAsking)
        // A second press, and a reply that finishes meanwhile.
        await notifications.turnOn()
        await notifications.offerIfUseful(agentName: "Scout", as: "ada")
        XCTAssertEqual(system.asked, 1, "The system asks once")
        XCTAssertNil(notifications.offer)

        await system.askingWaits?.open()
        await turningOn.value
        XCTAssertFalse(notifications.isAsking)
        XCTAssertNil(notifications.offer)
        XCTAssertEqual(notifications.permission, .allowed)
        // What Settings says then is true of the account's own switch.
        XCTAssertEqual(NotificationsSettingsView.wordsWhenAllowed(isOn: true), "Notifications are on.")
        XCTAssertEqual(NotificationsSettingsView.wordsWhenAllowed(isOn: false), "This device allows notifications. They are turned off for your account.")
    }

    func testTheLineIsOfferedWhereThePermissionWasNeverAskedFor_andNotForAWeekAfterNotNow() async {
        let system = System()
        system.permission = .notAsked
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let notifications = notifications(system, now: { clock })

        await notifications.offerIfUseful(agentName: "Scout", as: "ada")
        XCTAssertEqual(notifications.offer, .init(agentName: "Scout"))
        XCTAssertEqual(system.asked, 0, "Offering is not asking: the system's question waits for Turn on")

        notifications.declineOffer(as: "ada")
        XCTAssertNil(notifications.offer)
        clock += LocalNotifications.quietAfterDeclining - 60
        await notifications.offerIfUseful(agentName: "Scout", as: "ada")
        XCTAssertNil(notifications.offer, "Not again within the week")
        clock += 120
        await notifications.offerIfUseful(agentName: nil, as: "ada")
        XCTAssertEqual(notifications.offer, .init(agentName: "Strix"), "A thread with no agent of its own is Strix's")

        // Turn on asks the system, and the line goes whatever the answer.
        system.allows = false
        await notifications.turnOn()
        XCTAssertEqual(system.asked, 1)
        XCTAssertNil(notifications.offer)
        XCTAssertEqual(notifications.permission, .denied)
        // Once answered, it is not offered again.
        await notifications.offerIfUseful(agentName: "Scout", as: "ada")
        XCTAssertNil(notifications.offer)
    }

    func testTheLineIsNotOfferedToAnAccountThatTurnedNotificationsOff_orIsNotSignedIn() async {
        let system = System()
        system.permission = .notAsked
        let notifications = notifications(system)
        notifications.setOn(false, for: "ada")
        await notifications.offerIfUseful(agentName: "Scout", as: "ada")
        XCTAssertNil(notifications.offer)
        notifications.setOn(true, for: "ada")
        await notifications.offerIfUseful(agentName: "Scout", as: "grace")
        XCTAssertNil(notifications.offer)
        // Offered, and then turned off in Settings: the line goes.
        await notifications.offerIfUseful(agentName: "Scout", as: "ada")
        XCTAssertNotNil(notifications.offer)
        notifications.setOn(false, for: "ada")
        XCTAssertNil(notifications.offer)
    }

    func testAnAccountsChoicesGoWithTheAccount() {
        let notifications = notifications(System())
        notifications.setOn(false, for: "ada")
        notifications.setShowsDetails(true, for: "ada")
        notifications.declineOffer(as: "ada")
        notifications.setShowsDetails(true, for: "grace")

        notifications.forget("ada")

        XCTAssertTrue(notifications.isOn(for: "ada"), "As for an account that never chose")
        XCTAssertFalse(notifications.showsDetails(for: "ada"))
        XCTAssertNil(defaults.object(forKey: UserScope.scopedKey("notifications_offer_declined_at", for: "ada")))
        XCTAssertTrue(notifications.showsDetails(for: "grace"), "Another account's stay")
    }

    // MARK: - What tells of turns and approvals

    /// What a source told, in order. Sendable by hand: read and written on the main actor only.
    private final class Told: @unchecked Sendable {
        var events: [(event: NotificationEvent, thread: String, place: String, account: String)] = []
        var finished: [String] = []
    }

    private func source(
        _ told: Told, threads: [AICoven.Thread], lookingUpWaits: Gate? = nil, isAway: @escaping @MainActor () -> Bool = { true },
        account: @escaping @MainActor () -> String = { "ada" }
    ) -> NotificationSource {
        NotificationSource(dependencies: .init(
            account: account,
            isAway: isAway,
            thread: { id in
                await lookingUpWaits?.wait()
                return threads.first { $0.id == id }
            },
            placeName: { _ in "Client work" },
            notify: { event, thread, place, account, stands in
                if stands() { told.events.append((event, thread.id, place, account)) }
            },
            replyFinished: { thread, _ in told.finished.append(thread.id) }
        ))
    }

    func testTheAppIsKeptAtItsWorkUntilAnEndingHasBeenTold() async {
        let told = Told()
        let thread = thread("t1")
        var kept: [Task<Void, Never>] = []
        var dependencies = NotificationSource.Dependencies(
            account: { "ada" }, isAway: { true },
            thread: { _ in thread },
            placeName: { _ in "Strix" },
            notify: { event, thread, place, account, _ in told.events.append((event, thread.id, place, account)) },
            replyFinished: { _, _ in }
        )
        dependencies.keepWorking = { kept.append($0) }
        let source = NotificationSource(dependencies: dependencies)

        let telling = source.ended(["t1": ending("turn-1", .completed, saying: "Done.")])
        XCTAssertEqual(kept, telling, "Each telling is what the app is kept at its work for")
        XCTAssertEqual(kept.count, 1)
        for task in telling {
            await task.value
        }
        XCTAssertEqual(told.events.count, 1)
    }

    private func ending(_ turn: String, _ outcome: TurnOutcome, saying text: String) -> TurnEngine.Ending {
        TurnEngine.Ending(
            turnID: turn, outcome: outcome, trace: WorkTrace(startedAt: Date(timeIntervalSince1970: 0)),
            messages: [TurnProgress.message(in: "t1", role: "assistant", content: text)], stored: true
        )
    }

    func testAReplyThatFinishedAndATurnThatFailedAreEachToldOnce_andAStoppedOneNotAtAll() async {
        let told = Told()
        let source = source(told, threads: [thread("t1"), thread("t2"), thread("t3")])

        var telling = source.ended(["t1": ending("turn-1", .completed, saying: "The pack is ready.")])
        for task in telling {
            await task.value
        }
        XCTAssertEqual(told.events.map(\.event), [.finished(reply: "The pack is ready.")])
        XCTAssertEqual(told.events.map(\.thread), ["t1"])
        XCTAssertEqual(told.events.map(\.place), ["Client work"])
        XCTAssertEqual(told.finished, ["t1"], "A reply that finished may be what the line is offered for")

        // The same endings again, with a failure and a stop beside them.
        telling = source.ended([
            "t1": ending("turn-1", .completed, saying: "The pack is ready."),
            "t2": ending("turn-2", .failed, saying: "The key was refused."),
            "t3": ending("turn-3", .cancelled, saying: "Stopped."),
        ])
        for task in telling {
            await task.value
        }
        XCTAssertEqual(told.events.map(\.event), [.finished(reply: "The pack is ready."), .problem(reason: "The key was refused.")])
        XCTAssertEqual(told.finished, ["t1"], "A problem is no reply")

        // The thread's next turn ends: told again.
        telling = source.ended(["t1": ending("turn-4", .completed, saying: "And the notes.")])
        for task in telling {
            await task.value
        }
        XCTAssertEqual(told.events.last?.event, .finished(reply: "And the notes."))
    }

    func testAnApprovalATurnWaitsOnIsToldOnce_andAQuestionThatIsNoTurnsNotAtAll() async {
        let told = Told()
        let source = source(told, threads: [thread("t1")])
        let approval = ToolApproval(threadID: "t1", question: "Run this command?", details: "ls", toolName: "shell.execute")
        let memory = ToolApproval.memory("Dana runs design", forACoven: false, threadID: "t1")

        for _ in 1 ... 2 {
            for task in source.asked([approval, memory]) {
                await task.value
            }
        }
        XCTAssertEqual(told.events.map(\.event), [.needsOK(question: "Run this command?")])
        XCTAssertEqual(told.finished, [])
    }

    func testAnApprovalIsToldOnceHoweverItMovesThroughTheQueue() async {
        let told = Told()
        let source = source(told, threads: [thread("t1")])
        let approval = ToolApproval(threadID: "t1", question: "Run this command?", details: "ls", toolName: "shell.execute")
        // Held while the person composes; let in (for a moment it is in none of the three); waiting; showing.
        for step in [[approval], [], [approval], [], [approval]] {
            for task in source.asked(step) {
                await task.value
            }
        }
        XCTAssertEqual(told.events.count, 1)
    }

    func testWhatNoLongerStandsOnceItsThreadIsLookedUpIsNotTold_andTheRestIsToldInOrder() async {
        let told = Told()
        let gate = Gate()
        let source = source(told, threads: [thread("t1"), thread("t2")], lookingUpWaits: gate)
        let approval = ToolApproval(threadID: "t1", question: "Run this command?", details: "ls", toolName: "shell.execute")

        // An approval is asked; while its thread is looked up it is answered, and the turn goes on to
        // fail; then that thread's next turn ends with a reply, and another thread's turn ends too.
        var telling = source.asked([approval])
        await gate.arrived()
        telling += source.asked([])
        telling += source.ended(["t1": ending("turn-1", .failed, saying: "The key was refused.")])
        telling += source.ended(["t1": ending("turn-2", .completed, saying: "It worked this time."), "t2": ending("turn-3", .completed, saying: "Hers too.")])
        await gate.open()
        for task in telling {
            await task.value
        }

        XCTAssertEqual(
            told.events.map(\.event), [.finished(reply: "It worked this time."), .finished(reply: "Hers too.")],
            "Not the approval that was answered, nor the failure the thread has moved on from; the rest in the order it happened"
        )
        XCTAssertEqual(told.events.map(\.thread), ["t1", "t2"])
    }

    func testWhatHappensWhileThePersonIsLookingIsNotLookedUp_andAnApprovalStillWaitingWhenTheyLeaveIsToldThen() async {
        let told = Told()
        var away = false
        let source = source(told, threads: [thread("t1"), thread("t2")], isAway: { away })
        let approval = ToolApproval(threadID: "t1", question: "Run this command?", details: "ls", toolName: "shell.execute")

        // In front: a reply finishes and an approval is asked. Nothing is told.
        XCTAssertEqual(source.ended(["t2": ending("turn-1", .completed, saying: "Done.")]).count, 0)
        XCTAssertEqual(source.asked([approval]).count, 0)

        // The person leaves with the approval still waiting: it is told of now; the reply they saw is not.
        away = true
        for task in source.wentAway() {
            await task.value
        }
        XCTAssertEqual(told.events.map(\.event), [.needsOK(question: "Run this command?")])
        for task in source.ended(["t2": ending("turn-1", .completed, saying: "Done.")]) + source.wentAway() {
            await task.value
        }
        XCTAssertEqual(told.events.count, 1, "Each once")
    }

    // MARK: - A task's reminder

    private let noon = Date(timeIntervalSince1970: 1_800_000_000)

    private func reminder(_ id: String, _ title: String? = "Renew the lease", in seconds: TimeInterval) -> TaskReminderDue {
        TaskReminderDue(taskID: id, title: title, remindAt: noon.addingTimeInterval(seconds))
    }

    func testAReminderNamesItsTaskOnlyWithDetails() {
        XCTAssertEqual(
            NotificationComposer.reminder(taskTitle: "Renew the lease", showsDetails: false),
            ComposedNotification(title: "Reminder", subtitle: "", body: "Open AICoven to see the task.")
        )
        XCTAssertEqual(
            NotificationComposer.reminder(taskTitle: "Renew  the\nlease", showsDetails: true),
            ComposedNotification(title: "Reminder", subtitle: "", body: "Renew the lease")
        )
        // A title the key cannot open, or that says nothing, is not named.
        XCTAssertEqual(NotificationComposer.reminder(taskTitle: nil, showsDetails: true).body, "Open AICoven to see the task.")
        XCTAssertEqual(NotificationComposer.reminder(taskTitle: "  ", showsDetails: true).body, "Open AICoven to see the task.")
        XCTAssertEqual(NotificationComposer.reminder(taskTitle: String(repeating: "a", count: 300), showsDetails: true).body.count, 200)

        // Its id names the task and nothing else, and is told from a thread's.
        XCTAssertEqual(LocalNotifications.id(forTask: "t1"), "task-t1")
        XCTAssertEqual(LocalNotifications.taskID(ofNotification: "task-t1"), "t1")
        XCTAssertNil(LocalNotifications.taskID(ofNotification: "thread-t1"))
        XCTAssertNil(LocalNotifications.taskID(ofNotification: "task-"))
        XCTAssertNil(LocalNotifications.threadID(ofNotification: "task-t1"))
    }

    func testTheRemindersTheSystemHoldsAreMadeToMatchTheStores() async {
        let system = System()
        // One of a task that has no reminder any more, one already shown, and a thread's own.
        system.held = ["task-gone", "task-shown", "thread-t1"]
        let made = notifications(system, now: { self.noon })

        await made.setReminders([reminder("soon", in: 60), reminder("later", "Call the bank", in: 3600), reminder("shown", in: -60)], as: "ada")
        XCTAssertEqual(system.scheduled.map(\.id), ["task-soon", "task-later"], "Each one still to come waits at its time")
        XCTAssertEqual(system.scheduled.map(\.at), [noon.addingTimeInterval(60), noon.addingTimeInterval(3600)])
        XCTAssertEqual(system.scheduled.map(\.notification.body), ["Open AICoven to see the task.", "Open AICoven to see the task."], "Without details")
        XCTAssertEqual(system.withdrawn, ["task-gone"], "One whose time has come stays as it was shown; a thread's is not touched")
        XCTAssertEqual(system.held.sorted(), ["task-later", "task-shown", "task-soon", "thread-t1"])

        // With details, a reminder names its task; one that is changed takes the earlier one's place.
        made.setShowsDetails(true, for: "ada")
        await made.setReminders([reminder("later", "Call the bank", in: 7200)], as: "ada")
        XCTAssertEqual(system.scheduled.last?.id, "task-later")
        XCTAssertEqual(system.scheduled.last?.notification.body, "Call the bank")
        XCTAssertEqual(system.scheduled.last?.at, noon.addingTimeInterval(7200))
        XCTAssertEqual(system.held.sorted(), ["task-later", "thread-t1"], "Those of tasks with no reminder any more are taken back, shown or waiting")
    }

    func testNoReminderWaitsWhileNotificationsAreOffOrRefused_andNoneForAnotherAccount() async {
        let system = System()
        let made = notifications(system, now: { self.noon })
        await made.setReminders([reminder("a", in: 60)], as: "ada")
        XCTAssertEqual(system.held, ["task-a"])

        // The account turned notifications off: everything is taken back, and nothing is handed over.
        made.setOn(false, for: "ada")
        await made.setReminders([reminder("a", in: 60)], as: "ada")
        XCTAssertEqual(system.scheduled.count, 1)
        XCTAssertEqual(system.held, [])
        // On again, but this device refuses them.
        made.setOn(true, for: "ada")
        system.permission = .denied
        system.held = ["task-a"]
        await made.setReminders([reminder("a", in: 60)], as: "ada")
        XCTAssertEqual(system.scheduled.count, 1)
        XCTAssertEqual(system.held, [], "What waited is taken back")
        // Not for an account that is not the one signed in.
        system.permission = .allowed
        await made.setReminders([reminder("hers", in: 60)], as: "grace")
        XCTAssertEqual(system.scheduled.count, 1)
    }

    func testOnlyTheSoonestRemindersAreHandedOver_andNoneStaysForAnAccountThatLeftMeanwhile() async {
        let system = System()
        var signedIn = "ada"
        let made = notifications(system, signedIn: { signedIn }, now: { self.noon })
        // More than the system keeps waiting for an app: the soonest are handed over.
        let many = (1 ... LocalNotifications.mostReminders + 5).map { reminder("t\($0)", in: TimeInterval(1000 - $0)) }
        await made.setReminders(many, as: "ada")
        XCTAssertEqual(system.scheduled.count, LocalNotifications.mostReminders)
        XCTAssertEqual(system.scheduled.first?.id, "task-t\(LocalNotifications.mostReminders + 5)", "The soonest first")
        XCTAssertFalse(system.held.contains("task-t1"), "The latest wait their turn")

        // Another account signs in while one is being handed over: it does not stay, and no more are handed over.
        system.scheduled = []
        system.held = []
        let gate = Gate()
        system.schedulingWaits = gate
        let handing = Task { await made.setReminders([self.reminder("a", in: 60), self.reminder("b", in: 120)], as: "ada") }
        await gate.arrived()
        signedIn = "grace"
        await gate.open()
        await handing.value
        XCTAssertEqual(system.scheduled.map(\.id), ["task-a"])
        XCTAssertEqual(system.held, [], "Taken back")
    }

    func testAChangeOfTheAccountsChoicesIsToldToWhoeverHoldsTheReminders() async {
        let system = System()
        let made = notifications(system)
        var told = 0
        made.whenChoicesChange = { told += 1 }
        made.setShowsDetails(true, for: "ada")
        made.setOn(false, for: "ada")
        made.setOn(true, for: "ada")
        XCTAssertEqual(told, 3)
        system.permission = .notAsked
        await made.turnOn()
        XCTAssertEqual(told, 4, "The system's question was answered")
    }

    func testNothingIsToldOfAThreadThatIsNotTheSignedInAccounts() async {
        let told = Told()
        var signedIn = "ada"
        let source = source(told, threads: [thread("hers", of: "grace"), thread("t1")], account: { signedIn })

        for task in source.ended(["hers": ending("turn-1", .completed, saying: "Hers."), "gone": ending("turn-2", .completed, saying: "No such thread.")]) {
            await task.value
        }
        XCTAssertEqual(told.events.count, 0)

        // Another account signs in while the thread is looked up.
        let telling = source.ended(["t1": ending("turn-3", .completed, saying: "Mine.")])
        signedIn = "grace"
        for task in telling {
            await task.value
        }
        XCTAssertEqual(told.events.count, 0)
    }
}
