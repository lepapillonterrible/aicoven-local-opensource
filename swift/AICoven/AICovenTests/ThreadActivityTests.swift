@testable import AICoven
import XCTest

/// A thread's row says what the thread is doing, as the cloud app's does:
/// working, waiting for an OK, paused, stopped on a problem, holding an
/// unsent message, or holding a reply not yet seen, with the read marks
/// kept on the device.
final class ThreadActivityTests: XCTestCase {
    private func thread(_ id: String, covenID: String? = nil, archived: Bool = false, made: TimeInterval = 0) -> AICoven.Thread {
        Thread(
            id: id, userId: "ada", covenId: covenID, title: id, isArchived: archived,
            createdAt: Date(timeIntervalSince1970: made), updatedAt: Date(timeIntervalSince1970: made), lastMessageAt: nil
        )
    }

    private func marks(
        read: TimeInterval? = 100, reply: TimeInterval? = nil, draft: Bool = false, turn: TurnOutcome? = nil, run: Bool = false
    ) -> ThreadMarks {
        ThreadMarks(
            readAt: read.map(Date.init(timeIntervalSince1970:)),
            lastReplyAt: reply.map(Date.init(timeIntervalSince1970:)),
            hasDraft: draft,
            latestTurn: turn,
            latestTurnHasRun: run
        )
    }

    // MARK: - The rule

    func testAThreadIsUnread_whenAReplyWasStoredSinceItWasLastOnScreen() {
        XCTAssertTrue(marks(read: 100, reply: 101).isUnread)
        XCTAssertFalse(marks(read: 100, reply: 100).isUnread, "Stored at the moment it was on screen: seen")
        XCTAssertFalse(marks(read: 100, reply: 99).isUnread)
        XCTAssertFalse(marks(read: 100, reply: nil).isUnread, "No reply at all")
        XCTAssertFalse(marks(read: nil, reply: 500).isUnread, "From before read marks were kept: read")
    }

    func testWhatAThreadIsDoing_aTurnOutranksAnUnsentMessage_whichOutranksAnUnreadReply() {
        typealias Activity = ConversationActivity
        func doing(
            turn: Activity.Turn? = nil, needsOK: Bool = false, ended: TurnOutcome? = nil,
            _ stored: ThreadMarks? = nil, unsent: Bool = false, shown: Bool = false
        ) -> Activity? {
            Activity.of(turn: turn, needsOK: needsOK, ended: ended, marks: stored, hasUnsent: unsent, isShown: shown)
        }
        let unread = marks(read: 100, reply: 200)

        // A turn this app runs: its status line's words; waiting for an OK; a Stop outranks the wait.
        XCTAssertEqual(doing(turn: .init(message: "Reading 3 files"), unread, unsent: true), .moving("Reading 3 files"))
        XCTAssertEqual(doing(turn: .init(message: "Reading 3 files"), needsOK: true), .waiting("Needs your OK"))
        XCTAssertEqual(doing(turn: .init(message: "Stopping", isStopping: true), needsOK: true), .moving("Stopping"))
        // An approval asked in a thread with no turn running here is not this row's.
        XCTAssertNil(doing(needsOK: true))

        // How the latest turn stands: the one this app ended, over what was read from the store before.
        XCTAssertEqual(doing(marks(turn: .failed), unsent: true), .broken("Stopped on a problem"))
        XCTAssertEqual(doing(marks(turn: .interrupted)), .broken("Stopped on a problem"))
        XCTAssertEqual(doing(ended: .failed, marks(turn: .running)), .broken("Stopped on a problem"))
        XCTAssertNil(doing(ended: .completed, marks(turn: .running)), "The store was read before the turn ended")
        XCTAssertNil(doing(ended: .cancelled, marks(turn: .failed)), "A later turn, stopped by the person")
        XCTAssertNil(doing(marks(turn: .completed)))
        XCTAssertNil(doing(marks(turn: .cancelled)))
        // Recorded as running and not run here: the app closed on it. An agent's own run went on.
        XCTAssertEqual(doing(marks(turn: .running)), .broken("Stopped on a problem"))
        XCTAssertEqual(doing(marks(turn: .running, run: true)), .paused)
        // A broken thread says so on screen too.
        XCTAssertEqual(doing(marks(turn: .failed), shown: true), .broken("Stopped on a problem"))

        // An unsent message, then an unread reply; neither for the thread on screen.
        XCTAssertEqual(doing(unread, unsent: true), .unsent)
        XCTAssertEqual(doing(unread), .unread)
        XCTAssertEqual(doing(ended: .completed, unread), .unread)
        XCTAssertNil(doing(unread, unsent: true, shown: true), "Being written, and read as it arrives")
        XCTAssertNil(doing(marks(read: 100, reply: 50)))
        XCTAssertNil(doing())
    }

    func testTheWordsOfARow_andWhichThreadsAreStillOpen() {
        typealias Activity = ConversationActivity
        XCTAssertEqual(Activity.moving("Searching the web").caption, "Searching the web")
        XCTAssertEqual(Activity.waiting("Needs your OK").caption, "Needs your OK")
        XCTAssertEqual(Activity.broken("Stopped on a problem").caption, "Stopped on a problem")
        XCTAssertEqual(Activity.paused.caption, "Paused")
        XCTAssertEqual(Activity.unsent.caption, "Unsent message")
        XCTAssertNil(Activity.unread.caption, "An unread row is one line")
        XCTAssertEqual(Activity.unread.accessibilityWords, "Unread")
        XCTAssertEqual(Activity.unsent.accessibilityWords, "Unsent message")
        XCTAssertTrue(Activity.waiting("Needs your OK").isWaiting)
        XCTAssertFalse(Activity.moving("x").isWaiting)

        let open: [Activity] = [.moving("x"), .waiting("y"), .paused, .broken("z"), .unsent]
        XCTAssertTrue(open.allSatisfy(\.isStillOpen))
        XCTAssertFalse(Activity.unread.isStillOpen, "An unread reply alone is not")
    }

    func testThreadsStillOpenComeFirst_eachPartNewestFirst_andArchivedOnesApart() {
        let threads = [
            thread("old-open", made: 10), thread("new", made: 400), thread("new-open", made: 300),
            thread("old", made: 20), thread("put-away", archived: true, made: 500),
        ]
        let sections = ThreadListRules.sections(threads) { $0.id.hasSuffix("open") || $0.id == "put-away" }
        XCTAssertEqual(sections.open.map(\.id), ["new-open", "old-open", "new", "old"])
        XCTAssertEqual(sections.archived.map(\.id), ["put-away"], "An archived thread stays in its section")
        XCTAssertEqual(ThreadListRules.sections(threads).open.map(\.id), ["new", "new-open", "old", "old-open"])
    }

    // MARK: - The store that puts it together

    /// What the activities are answered, and what they asked.
    @MainActor
    private final class World {
        var account = "ada"
        var stored: [String: ThreadMarks] = [:]
        var covens: [String: String] = [:]
        var drafts: [String: Bool] = [:]
        var now = Date(timeIntervalSince1970: 1000)
        var read: [String] = []
        var failing = false
        /// Held until the test lets a reading of the store go on.
        var beforeLoading: (() async -> Void)?
        /// Held after the marks were read, before the reading lands.
        var beforeCovens: (() async -> Void)?
        var covensFailing = false

        func activities() -> ThreadActivities {
            ThreadActivities(dependencies: .init(
                currentAccount: { self.account },
                loadMarks: { account in
                    await self.beforeLoading?()
                    return try await self.marks(for: account)
                },
                markRead: { threadID, date, account in await self.note(threadID, date, account) },
                loadCovens: {
                    await self.beforeCovens?()
                    if await self.covensFailing { throw URLError(.cannotOpenFile) }
                    return await self.covens
                },
                holdsDraft: { self.drafts[$0] },
                now: { self.now }
            ))
        }

        private func marks(for account: String) throws -> [String: ThreadMarks] {
            if failing { throw URLError(.cannotOpenFile) }
            return account == "ada" ? stored : ["grace-thread": ThreadMarks(readAt: Date(timeIntervalSince1970: 1), lastReplyAt: Date(timeIntervalSince1970: 2))]
        }

        private func note(_ threadID: String, _ date: Date, _ account: String) {
            read.append("\(account) \(threadID) \(Int(date.timeIntervalSince1970))")
            guard account == "ada", var mark = stored[threadID], (mark.readAt ?? .distantPast) < date else { return }
            mark.readAt = date
            stored[threadID] = mark
        }
    }

    @MainActor
    func testRowsSayWhatIsStored_andAThreadOnScreenIsReadAsItIsShown() async {
        let world = World()
        world.stored = [
            "seen": marks(read: 100, reply: 50),
            "unread": marks(read: 100, reply: 200),
            "coven-unread": marks(read: 100, reply: 300),
            "drafted": marks(draft: true),
            "failed": marks(turn: .failed),
        ]
        world.covens = ["coven-unread": "c1", "seen": "c2"]
        let activities = world.activities()
        XCTAssertEqual(activities.activity, [:])

        await activities.reload().value
        XCTAssertEqual(activities.activity, [
            "unread": .unread, "coven-unread": .unread, "drafted": .unsent, "failed": .broken("Stopped on a problem"),
        ])
        XCTAssertEqual(activities.covensWithUnread, ["c1"], "A personal thread's reply is no coven's")

        // On screen: read up to now, at once here and in the store; its draft is being written.
        world.now = Date(timeIntervalSince1970: 2000)
        let shown = activities.show("coven-unread")
        XCTAssertNil(activities.activity["coven-unread"])
        XCTAssertEqual(activities.covensWithUnread, [])
        await shown.value
        XCTAssertEqual(world.read, ["ada coven-unread 2000"])
        activities.show("drafted")
        XCTAssertNil(activities.activity["drafted"])

        // A reply stored while it is on screen was seen: it is read up to then before the store is read again.
        world.stored["coven-unread"]?.lastReplyAt = Date(timeIntervalSince1970: 2500)
        world.now = Date(timeIntervalSince1970: 2600)
        await activities.reload().value
        XCTAssertTrue(world.read.contains("ada coven-unread 2600"))
        XCTAssertNil(activities.activity["coven-unread"])

        // Off screen: read up to then; what its composer holds is from now an unsent message.
        world.now = Date(timeIntervalSince1970: 2700)
        await activities.hide("coven-unread").value
        XCTAssertNil(activities.activity["coven-unread"], "Nothing new since it was on screen")
        await activities.hide("drafted").value
        XCTAssertEqual(activities.activity["drafted"], .unsent)
        // A reply stored after it left is unread.
        world.stored["coven-unread"]?.lastReplyAt = Date(timeIntervalSince1970: 2800)
        await activities.reload().value
        XCTAssertEqual(activities.activity["coven-unread"], .unread)
        XCTAssertEqual(activities.covensWithUnread, ["c1"])

        // Shown in two places, it is on screen until it has left both.
        activities.show("unread")
        activities.show("unread")
        activities.hide("unread")
        XCTAssertNil(activities.activity["unread"])
        world.stored["unread"]?.lastReplyAt = Date(timeIntervalSince1970: 5000)
        await activities.reload().value
        XCTAssertNil(activities.activity["unread"], "Still on screen in the other")
    }

    @MainActor
    func testAThreadReadWhileTheStoreIsBeingRead_staysRead_andANewThreadIsPickedUpWhenShown() async {
        let world = World()
        world.stored = ["t": marks(read: 100, reply: 200)]
        world.covens = ["t": "c1"]
        let activities = world.activities()
        await activities.reload().value
        XCTAssertEqual(activities.activity, ["t": .unread])

        // A reading has the marks and is still on its way; the thread is opened and left meanwhile.
        var held: CheckedContinuation<Void, Never>?
        let (reached, reach) = AsyncStream<Void>.makeStream()
        world.beforeCovens = {
            reach.yield()
            await withCheckedContinuation { held = $0 }
        }
        let reading = activities.reload()
        for await _ in reached {
            break
        }
        world.beforeCovens = nil
        world.now = Date(timeIntervalSince1970: 2000)
        await activities.show("t").value
        await activities.hide("t").value
        XCTAssertNil(activities.activity["t"])
        // The reading lands with the mark as it was before: the thread stays read.
        world.stored["t"]?.readAt = Date(timeIntervalSince1970: 100)
        held?.resume()
        await reading.value
        XCTAssertNil(activities.activity["t"], "Its older mark is not brought back")
        XCTAssertEqual(activities.covensWithUnread, [])
        // A reply stored after that is unread as ever.
        world.stored["t"] = marks(read: 2000, reply: 2500)
        await activities.reload().value
        XCTAssertEqual(activities.activity["t"], .unread)

        // A thread made since the store was read: shown, it is read for; left with a draft, its row says so.
        world.stored["fresh"] = marks(read: 2600)
        world.drafts["fresh"] = true
        await activities.show("fresh").value
        XCTAssertNil(activities.activity["fresh"], "On screen, it is being written")
        await activities.hide("fresh").value
        XCTAssertEqual(activities.activity["fresh"], .unsent)
    }

    @MainActor
    func testRowsSayWhatTheEngineRuns_andWhatTheComposerHolds() async {
        let world = World()
        world.stored = ["t": marks(read: 100, reply: 200, draft: true, turn: .running), "kept": marks()]
        let activities = world.activities()
        await activities.reload().value
        XCTAssertEqual(activities.activity["t"], .broken("Stopped on a problem"), "Recorded as running, and not run here")

        activities.setTurns(["t": .init(message: "Thinking")])
        XCTAssertEqual(activities.activity["t"], .moving("Thinking"))
        activities.setAsking(["t", "elsewhere"])
        XCTAssertEqual(activities.activity["t"], .waiting("Needs your OK"))
        XCTAssertNil(activities.activity["elsewhere"])
        activities.setTurns(["t": .init(message: "Stopping", isStopping: true)])
        XCTAssertEqual(activities.activity["t"], .moving("Stopping"))

        // The turn ends here before the store is read again: its ending is what counts.
        activities.setEnded(["t": .completed])
        activities.setTurns([:])
        activities.setAsking([])
        XCTAssertEqual(activities.activity["t"], .unsent, "Its draft, kept with it")

        // What the composer holds now says more than what was kept with the thread.
        world.drafts["t"] = false
        activities.setAsking([])
        XCTAssertEqual(activities.activity["t"], .unread)
        world.drafts["kept"] = true
        activities.setAsking([])
        XCTAssertEqual(activities.activity["kept"], .unsent)
        // What the engine handed back, or kept for a thread that had left the screen, is unsent too.
        world.drafts = [:]
        world.stored["t"]?.hasDraft = false
        await activities.reload().value
        XCTAssertEqual(activities.activity["t"], .unread)
        activities.setUnsent(handedBack: ["t"])
        XCTAssertEqual(activities.activity["t"], .unsent)
        activities.setUnsent(handedBack: [], kept: ["t", "new"])
        XCTAssertEqual(activities.activity["t"], .unsent)
        // Only of the account's own threads, as read from the store: the engine's are by thread, whoever's.
        XCTAssertNil(activities.activity["new"])
        activities.setTurns(["someone-elses": .init(message: "Thinking")])
        XCTAssertNil(activities.activity["someone-elses"])
        activities.setTurns([:])
        activities.setUnsent(kept: [])
        XCTAssertEqual(activities.activity["t"], .unread)
    }

    @MainActor
    func testWhatIsStoredIsOneAccounts_andOnlyTheLatestReadingIsKept() async {
        let world = World()
        world.stored = ["t": marks(read: 100, reply: 200)]
        world.covens = ["t": "c1"]
        let activities = world.activities()
        await activities.reload().value
        XCTAssertEqual(activities.activity, ["t": .unread])

        XCTAssertEqual(activities.covensWithUnread, ["c1"])

        // Another account signs in: nothing of the first's is said from that moment, before the store is read again.
        world.account = "grace"
        world.covens = [:]
        let changing = activities.accountChanged()
        XCTAssertEqual(activities.activity, [:])
        XCTAssertEqual(activities.covensWithUnread, [])
        await changing.value
        XCTAssertEqual(activities.activity, ["grace-thread": .unread])

        // A reading begun as one account that lands after another signed in is not kept.
        world.account = "ada"
        var held: CheckedContinuation<Void, Never>?
        let (reached, reach) = AsyncStream<Void>.makeStream()
        world.beforeLoading = {
            reach.yield()
            await withCheckedContinuation { held = $0 }
        }
        let early = activities.reload()
        for await _ in reached {
            break
        }
        world.beforeLoading = nil
        world.account = "grace"
        held?.resume()
        await early.value
        XCTAssertEqual(activities.activity, ["grace-thread": .unread], "Ada's threads are not shown to Grace")

        // Of two readings, the later asked for is the one kept, whichever lands last.
        world.account = "ada"
        world.stored = ["t": marks(read: 100, reply: 200)]
        var first: CheckedContinuation<Void, Never>?
        let (firstReached, firstReach) = AsyncStream<Void>.makeStream()
        world.beforeLoading = {
            firstReach.yield()
            await withCheckedContinuation { first = $0 }
        }
        let older = activities.reload()
        for await _ in firstReached {
            break
        }
        world.beforeLoading = nil
        world.stored = ["t": marks(read: 300, reply: 200)]
        await activities.reload().value
        XCTAssertEqual(activities.activity, [:])
        world.stored = ["t": marks(read: 100, reply: 200)]
        first?.resume()
        await older.value
        XCTAssertEqual(activities.activity, [:], "The older reading landed last and is not kept")

        // A store that cannot be read leaves what was read for this account as it was.
        world.stored = ["t": marks(read: 100, reply: 200)]
        world.covens = ["t": "c1"]
        await activities.reload().value
        XCTAssertEqual(activities.activity, ["t": .unread])
        world.failing = true
        await activities.reload().value
        XCTAssertEqual(activities.activity, ["t": .unread])
        XCTAssertEqual(activities.covensWithUnread, ["c1"])

        // The marks are kept when only the threads' covens cannot be read, with the covens as they were held.
        world.failing = false
        world.covensFailing = true
        world.stored["u"] = marks(read: 100, reply: 300)
        await activities.reload().value
        XCTAssertEqual(activities.activity, ["t": .unread, "u": .unread])
        XCTAssertEqual(activities.covensWithUnread, ["c1"])
    }

    // MARK: - From what is stored

    func testAThreadsMarksAreStoredWithIt() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        await MainActor.run { DatabaseManager.shared.configureIfNeeded() }
        await ThreadService.shared.reloadForCurrentUser()
        let account = await MainActor.run { UserScope.currentUserID }
        let made = try await ThreadService.shared.createThread(title: "Marks \(UUID().uuidString)")
        let threadID = made.id
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await ThreadService.shared.deleteThread(threadId: threadID)
            await ThreadService.shared.reloadForCurrentUser()
            await DataEncryptionService.shared.lock()
        }
        let store = ThreadRepository.shared
        func stored() async throws -> ThreadMarks {
            let all = try await store.threadMarks(for: account)
            return try XCTUnwrap(all[threadID])
        }
        func message(_ role: String, _ text: String, after seconds: TimeInterval) -> ChatMessage {
            ChatMessage(
                id: UUID().uuidString, threadId: threadID, role: role, content: text, metadata: nil, tokenUsage: nil,
                createdAt: Date().addingTimeInterval(seconds), isEncrypted: false, keyFingerprint: nil
            )
        }

        // A new thread is read up to when it was made, and has nothing else to say.
        let new = try await stored()
        XCTAssertNotNil(new.readAt)
        XCTAssertNil(new.lastReplyAt)
        XCTAssertFalse(new.hasDraft)
        XCTAssertNil(new.latestTurn)
        XCTAssertFalse(new.isUnread)

        // The person's own message is no reply; the turn it began is recorded as running.
        try await store.beginTurn(id: "one-\(threadID)", userMessage: message("user", "Hello", after: 60))
        var marks = try await stored()
        XCTAssertNil(marks.lastReplyAt)
        XCTAssertEqual(marks.latestTurn, .running)
        XCTAssertFalse(marks.latestTurnHasRun)
        try await store.keepRun(AgentRun(provider: AgentRun.hermes, runID: "r1"), forTurn: "one-\(threadID)")
        marks = try await stored()
        XCTAssertTrue(marks.latestTurnHasRun, "An agent's own run")

        // Its reply, stored after the thread was last on screen, is unread until the thread is.
        let reply = message("assistant", "Hi.", after: 120)
        _ = try await store.endTurn(id: "one-\(threadID)", outcome: .completed, message: reply)
        marks = try await stored()
        XCTAssertEqual(marks.latestTurn, .completed)
        XCTAssertTrue(marks.isUnread)
        try await store.markRead(threadID: threadID, at: Date().addingTimeInterval(180), for: account)
        marks = try await stored()
        XCTAssertFalse(marks.isUnread)
        // The mark never moves back, and is only its own account's to move.
        let readAt = marks.readAt
        try await store.markRead(threadID: threadID, at: Date().addingTimeInterval(-3600), for: account)
        try await store.markRead(threadID: threadID, at: Date().addingTimeInterval(9000), for: "someone-else")
        marks = try await stored()
        XCTAssertEqual(marks.readAt, readAt)

        // The latest turn is the one that counts; a draft kept with the thread is told.
        try await store.beginTurn(id: "two-\(threadID)", userMessage: message("user", "Again", after: 240))
        _ = try await store.endTurn(id: "two-\(threadID)", outcome: .failed, message: message("assistant", "Could not.", after: 300))
        try await store.saveDraft("Not sent yet", forThread: threadID)
        marks = try await stored()
        XCTAssertEqual(marks.latestTurn, .failed)
        XCTAssertFalse(marks.latestTurnHasRun)
        XCTAssertTrue(marks.hasDraft)
        XCTAssertTrue(marks.isUnread)
        try await store.saveDraft("", forThread: threadID)
        marks = try await stored()
        XCTAssertFalse(marks.hasDraft)

        // Renaming the thread (its row is written again) keeps its read mark.
        try await store.markRead(threadID: threadID, at: Date().addingTimeInterval(400), for: account)
        let before = try await stored().readAt
        _ = try await ThreadService.shared.updateThread(threadId: threadID, title: "Renamed \(threadID)")
        marks = try await stored()
        XCTAssertEqual(marks.readAt, before)
        XCTAssertNotNil(before)

        // Another account is told nothing of it.
        let others = try await store.threadMarks(for: "someone-else")
        XCTAssertNil(others[threadID])
    }

    func testAThreadsCovenIsTold_untilTheThreadIsArchived() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        await MainActor.run { DatabaseManager.shared.configureIfNeeded() }
        await ThreadService.shared.reloadForCurrentUser()
        let coven = "coven-\(UUID().uuidString)"
        let inCoven = try await ThreadService.shared.createThread(title: "In a coven \(UUID().uuidString)", covenId: coven)
        let personal = try await ThreadService.shared.createThread(title: "Personal \(UUID().uuidString)")
        let made = [inCoven.id, personal.id]
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            for threadID in made {
                try? await ThreadService.shared.deleteThread(threadId: threadID)
            }
            await ThreadService.shared.reloadForCurrentUser()
            await DataEncryptionService.shared.lock()
        }

        var covens = try await ThreadService.shared.covensOfThreads()
        XCTAssertEqual(covens[inCoven.id], coven)
        XCTAssertNil(covens[personal.id], "A personal thread is in none")
        // Put away, its reply marks its row, not its coven.
        _ = try await ThreadService.shared.updateThread(threadId: inCoven.id, isArchived: true)
        covens = try await ThreadService.shared.covensOfThreads()
        XCTAssertNil(covens[inCoven.id])
    }
}
