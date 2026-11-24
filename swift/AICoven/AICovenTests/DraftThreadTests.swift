@testable import AICoven
import XCTest

/// A thread that is made when its first message is sent, as the cloud app
/// makes one: where the shell is meanwhile, what the thread is called, who
/// it goes to, and the sending itself.
final class DraftThreadTests: XCTestCase {
    private func thread(_ id: String, covenID: String? = nil) -> AICoven.Thread {
        Thread(
            id: id, userId: "ada", covenId: covenID, title: id,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), lastMessageAt: nil
        )
    }

    private func role(_ id: String) -> Role {
        Role(
            id: id, covenId: "work", name: id.capitalized, emoji: nil, description: nil, systemPrompt: nil, model: nil, provider: nil,
            providerAccountId: nil, temperature: nil, maxTokens: nil, settings: nil,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - What it is called, and who it goes to

    func testANewThreadIsCalledByItsFirstMessagesFirstLine() {
        XCTAssertEqual(ThreadTitleGenerator.title(from: "  Plan the   spring\trelease \nand then the rest"), "Plan the spring release")
        XCTAssertEqual(ThreadTitleGenerator.title(from: "\n\n  Second line first  "), "Second line first")
        XCTAssertEqual(ThreadTitleGenerator.title(from: "   \n  "), "New Thread", "A message that says nothing")
        XCTAssertEqual(ThreadTitleGenerator.title(from: ""), "New Thread")

        // Sixty characters at most, cut at a word.
        let long = "What would it take to move the whole archive to the new format before the end of the year"
        let title = ThreadTitleGenerator.title(from: long)
        XCTAssertEqual(title, "What would it take to move the whole archive to the new")
        XCTAssertLessThanOrEqual(title.count, ThreadTitleGenerator.longest)
        let exactly = String(repeating: "a", count: 60)
        XCTAssertEqual(ThreadTitleGenerator.title(from: exactly), exactly)
        // One word longer than that is cut where the room ends.
        XCTAssertEqual(ThreadTitleGenerator.title(from: String(repeating: "b", count: 75)), String(repeating: "b", count: 60))
    }

    func testANewThreadGoesToTheAgentAskedFor_elseTheOneLastUsed_elseTheFirst() {
        let roles = [role("scout"), role("writer"), role("coder")]
        XCTAssertEqual(NewThreadRules.recipient(lastUsed: nil, among: roles)?.id, "scout", "The coven's first")
        XCTAssertEqual(NewThreadRules.recipient(lastUsed: "writer", among: roles)?.id, "writer")
        XCTAssertEqual(NewThreadRules.recipient(lastUsed: "gone", among: roles)?.id, "scout", "No longer one of the coven's")
        XCTAssertEqual(NewThreadRules.recipient(asked: "coder", lastUsed: "writer", among: roles)?.id, "coder", "Asked for by name")
        XCTAssertEqual(NewThreadRules.recipient(asked: "gone", lastUsed: "writer", among: roles)?.id, "writer")
        XCTAssertNil(NewThreadRules.recipient(asked: "scout", lastUsed: "scout", among: []), "A coven with no agents: Strix answers")
    }

    func testTheAgentLastUsedIsKeptOnTheDevice_forEachAccountAndCoven() throws {
        let suite = "LastUsedAgentStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = LastUsedAgentStore(defaults: defaults)

        XCTAssertNil(store.agentID(inCoven: "work", for: "ada"))
        store.set("scout", inCoven: "work", for: "ada")
        store.set("writer", inCoven: "home", for: "ada")
        store.set("coder", inCoven: "work", for: "ada")
        XCTAssertEqual(store.agentID(inCoven: "work", for: "ada"), "coder")
        XCTAssertEqual(store.agentID(inCoven: "home", for: "ada"), "writer")
        XCTAssertNil(store.agentID(inCoven: "work", for: "grace"), "Another account has its own")
        store.set("scout", inCoven: "work", for: "grace")

        // An account that is deleted takes what it last used with it.
        store.remove(for: "ada")
        XCTAssertNil(store.agentID(inCoven: "work", for: "ada"))
        XCTAssertNil(store.agentID(inCoven: "home", for: "ada"))
        XCTAssertEqual(LastUsedAgentStore(defaults: defaults).agentID(inCoven: "work", for: "grace"), "scout")
    }

    func testTheComposerSaysWhoANewThreadGoesTo() {
        XCTAssertEqual(NewThreadComposer.recipientName(inCoven: false, agentsAreIn: false, recipient: nil), "Strix")
        XCTAssertEqual(NewThreadComposer.recipientName(inCoven: true, agentsAreIn: false, recipient: nil), "Loading agents…")
        XCTAssertEqual(NewThreadComposer.recipientName(inCoven: true, agentsAreIn: true, recipient: role("scout")), "Scout")
        XCTAssertEqual(NewThreadComposer.recipientName(inCoven: true, agentsAreIn: true, recipient: nil), "Strix", "A coven with no agents")
    }

    @MainActor
    func testEachScopesNewThreadPageKeepsWhatItHoldsUnsent_whileTheWindowIsOpen() async {
        let drafts = DraftThreads()
        drafts.submission(for: .strix).messageText = "For Strix"
        drafts.submission(for: .coven("work")).messageText = "For work"
        XCTAssertEqual(drafts.submission(for: .strix).messageText, "For Strix", "There again on coming back")
        XCTAssertEqual(drafts.submission(for: .coven("work")).messageText, "For work")
        XCTAssertEqual(drafts.submission(for: .coven("home")).messageText, "")
        // A coven that is gone takes what was being written for it.
        drafts.forget(.coven("work"))
        XCTAssertEqual(drafts.submission(for: .coven("work")).messageText, "")
        XCTAssertEqual(drafts.submission(for: .strix).messageText, "For Strix")
        // Freed inside a task: a main-actor object released outside one
        // aborts on macOS 15 (issue #61).
        await Task.yield()
    }

    func testACovenIsGoneWhenItIsNoLongerAmongTheCovensRead_onScreenOrNot() {
        func coven(_ id: String) -> Coven {
            Coven(id: id, name: id, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        }
        let known = [coven("a"), coven("b"), coven("c")]
        XCTAssertEqual(CovenOrder.gone(known: known, selected: .strix, among: known), [])
        XCTAssertEqual(CovenOrder.gone(known: known, selected: .strix, among: [coven("a")]), ["b", "c"], "Gone while another scope is on screen")
        XCTAssertEqual(CovenOrder.gone(known: known, selected: .coven("b"), among: [coven("a"), coven("c"), coven("new")]), ["b"])
        // The one on screen counts even before any covens were known.
        XCTAssertEqual(CovenOrder.gone(known: [], selected: .coven("z"), among: [coven("a")]), ["z"])
        XCTAssertEqual(CovenOrder.gone(known: [], selected: .coven("a"), among: [coven("a")]), [])
    }

    // MARK: - Where the shell is meanwhile

    @MainActor
    func testNewThreadOpensAPageInTheScopeOnScreen_whichBelongsToNoRow() async {
        let navigator = ShellNavigator()
        navigator.requestNewThread()
        XCTAssertEqual(navigator.place, .draftThread(covenId: nil))
        XCTAssertEqual(navigator.placeTitle, "New Thread")
        XCTAssertNil(navigator.sidebarItem)
        XCTAssertNil(navigator.draftAgent(in: .strix))

        navigator.select(.coven("work"))
        navigator.requestNewThread(agentID: "scout")
        XCTAssertEqual(navigator.place, .draftThread(covenId: "work"))
        XCTAssertEqual(navigator.draftAgent(in: .coven("work")), "scout")
        XCTAssertEqual(navigator.place(in: .strix), .draftThread(covenId: nil), "Strix keeps its own page")
        // Asked again without an agent: the composer chooses as it does.
        navigator.requestNewThread()
        XCTAssertNil(navigator.draftAgent(in: .coven("work")))
        // Each ask is counted, so a page asked for again for the same agent knows it was.
        let asks = navigator.draftRequests
        navigator.requestNewThread(agentID: "scout")
        navigator.requestNewThread(agentID: "scout")
        XCTAssertEqual(navigator.draftRequests, asks + 2)

        // A coven that is gone takes its page and what was asked for it along.
        navigator.requestNewThread(agentID: "scout")
        navigator.handleCovenGone(covenID: "work")
        XCTAssertEqual(navigator.selected, .strix)
        XCTAssertNil(navigator.place(in: .coven("work")))
        XCTAssertNil(navigator.draftAgent(in: .coven("work")))
        // Freed inside a task: a main-actor object released outside one
        // aborts on macOS 15 (issue #61).
        await Task.yield()
    }

    @MainActor
    func testTheThreadThatIsMadeTakesThePagesPlace_inItsOwnScope_whereThePageStillIs() async {
        let navigator = ShellNavigator()
        navigator.select(.coven("coven_a"))
        navigator.requestNewThread(agentID: "scout")
        navigator.select(.coven("coven_b"))
        // Coming back to a scope shows its Overview, so the page is asked for again and left.
        navigator.select(.coven("coven_a"))
        navigator.requestNewThread(agentID: "scout")
        navigator.open(.memoryList(covenId: "coven_b"), in: .coven("coven_b"))

        // Made while another scope is on screen: it takes the page's place there, and the person stays where they are.
        navigator.handleCreatedThread(thread("thread_new", covenID: "coven_a"))
        XCTAssertEqual(navigator.selected, .coven("coven_b"))
        XCTAssertEqual(navigator.place(in: .coven("coven_a"))?.id, "thread_new")
        XCTAssertNil(navigator.draftAgent(in: .coven("coven_a")))

        // The person moved to another place in the scope meanwhile: the thread waits in the list.
        navigator.select(.strix)
        navigator.requestNewThread()
        navigator.openPlace(.memory)
        navigator.handleCreatedThread(thread("strix_new"))
        XCTAssertEqual(navigator.place, .memoryList(covenId: nil))

        // On screen, with the page still there: the thread is shown.
        navigator.requestNewThread()
        navigator.handleCreatedThread(thread("strix_newer"))
        XCTAssertEqual(navigator.place?.id, "strix_newer")
        XCTAssertEqual(navigator.sidebarItem, .thread("strix_newer"))
        // Freed inside a task: a main-actor object released outside one
        // aborts on macOS 15 (issue #61).
        await Task.yield()
    }

    @MainActor
    func testAThreadAskedFromTheOverviewOpensOnlyIfThePersonStayed() async {
        let navigator = ShellNavigator()
        navigator.select(.coven("coven_a"))
        let first = navigator.askFromOverview()
        navigator.openThreadAskedFromOverview(thread("asked", covenID: "coven_a"), ask: first)
        XCTAssertEqual(navigator.place?.id, "asked")

        navigator.showOverview()
        let moved = navigator.askFromOverview()
        navigator.open(.memoryList(covenId: "coven_a"))
        navigator.showOverview()
        navigator.openThreadAskedFromOverview(thread("late", covenID: "coven_a"), ask: moved)
        XCTAssertNil(navigator.place, "Back on the Overview after moving: the late thread waits in the list")

        // Gone to another scope and stayed there: it does not open, there or here.
        let left = navigator.askFromOverview()
        navigator.select(.strix)
        navigator.openThreadAskedFromOverview(thread("left", covenID: "coven_a"), ask: left)
        XCTAssertEqual(navigator.selected, .strix)
        XCTAssertNil(navigator.place)
        XCTAssertNil(navigator.place(in: .coven("coven_a")))

        // An ask is answered once.
        let once = navigator.askFromOverview()
        navigator.openThreadAskedFromOverview(thread("once"), ask: once)
        XCTAssertEqual(navigator.place?.id, "once")
        navigator.showOverview()
        navigator.openThreadAskedFromOverview(thread("twice"), ask: once)
        XCTAssertNil(navigator.place)
        // Freed inside a task: a main-actor object released outside one
        // aborts on macOS 15 (issue #61).
        await Task.yield()
    }

    @MainActor
    func testAnEarlierAsksLateThreadNeitherOpensNorCancelsTheNewerAsk() async {
        let navigator = ShellNavigator()
        navigator.select(.coven("coven_a"))
        let askA = navigator.askFromOverview()
        navigator.open(.memoryList(covenId: "coven_a"))
        navigator.showOverview()
        let askB = navigator.askFromOverview()

        navigator.openThreadAskedFromOverview(thread("thread_a", covenID: "coven_a"), ask: askA)
        XCTAssertNil(navigator.place, "A's thread waits in the list")

        navigator.openThreadAskedFromOverview(thread("thread_b", covenID: "coven_a"), ask: askB)
        XCTAssertEqual(navigator.place?.id, "thread_b")
        // Freed inside a task: a main-actor object released outside one
        // aborts on macOS 15 (issue #61).
        await Task.yield()
    }

    // MARK: - The sending

    /// What a submission is answered, and what it did.
    @MainActor
    private final class World {
        var account = "ada"
        var did: [String] = []
        var createFails = false
        var sendFails = false
        /// The files cannot be taken into the thread that was made.
        var takeFails = false
        /// Held until the test lets the thread be made.
        var beforeCreating: (() async -> Void)?
        /// Held until the test lets the message be sent into the thread.
        var beforeSending: (() async -> Void)?

        func submission() -> DraftThreadSubmission {
            DraftThreadSubmission(currentAccount: { self.account })
        }

        static func names(_ files: [FileAttachmentDetail]) -> String {
            files.map(\.name).joined(separator: "+")
        }

        static func with(_ files: [FileAttachmentDetail]) -> String {
            files.isEmpty ? "" : " with \(names(files))"
        }

        func send(_ submission: DraftThreadSubmission) -> Task<Void, Never>? {
            submission.send(
                createThread: { title, account in
                    await self.beforeCreating?()
                    if self.createFails { throw URLError(.cannotCreateFile) }
                    self.did.append("create '\(title)' as \(account)")
                    return Thread(
                        id: "t\(self.did.count)", userId: account, covenId: nil, title: title,
                        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), lastMessageAt: nil
                    )
                },
                files: DraftThreadSubmission.Files(
                    take: { files, thread, account in
                        if self.takeFails { throw URLError(.cannotMoveFile) }
                        self.did.append("take \(Self.names(files)) into \(thread.id) as \(account)")
                    },
                    discardThread: { thread, account in self.did.append("discard \(thread.id) as \(account)") },
                    drop: { files in self.did.append("drop \(Self.names(files))") }
                ),
                sendFirstMessage: { thread, text, files in
                    await self.beforeSending?()
                    if self.sendFails { throw URLError(.networkConnectionLost) }
                    self.did.append("send '\(text)'\(Self.with(files)) in \(thread.id)")
                },
                keepUnsent: { thread, text, files, _ in self.did.append("keep '\(text)'\(Self.with(files)) for \(thread.id)") },
                onThreadCreated: { self.did.append("created \($0.id)") }
            )
        }
    }

    private nonisolated static func file(_ name: String) -> FileAttachmentDetail {
        FileAttachmentDetail(id: name, name: name, mimeType: nil, sizeBytes: nil, width: nil, height: nil, url: nil)
    }

    @MainActor
    func testFilesAttachedBeforeThereIsAThread_goIntoItWithTheFirstMessage() async {
        let world = World()
        let submission = world.submission()
        submission.messageText = "Read these"
        submission.attachments = [Self.file("a.pdf"), Self.file("b.png")]

        var held: CheckedContinuation<Void, Never>?
        let (reached, reach) = AsyncStream<Void>.makeStream()
        world.beforeCreating = {
            reach.yield()
            await withCheckedContinuation { held = $0 }
        }
        let sending = world.send(submission)
        // Taken at Send: the composer holds neither the text nor the files, and the page shows both as sent.
        XCTAssertEqual(submission.attachments, [])
        XCTAssertEqual(submission.submittedAttachments.map(\.name), ["a.pdf", "b.png"])
        XCTAssertEqual(DraftThreadView.names(of: submission.submittedAttachments), "a.pdf, b.png")
        for await _ in reached {
            break
        }
        // Attached while the thread is being made: for the next message, not this one.
        submission.attachments = [Self.file("later.txt")]
        world.beforeCreating = nil
        held?.resume()
        await sending?.value

        XCTAssertEqual(world.did, [
            "create 'Read these' as ada", "take a.pdf+b.png into t1 as ada", "send 'Read these' with a.pdf+b.png in t1", "created t1"
        ])
        XCTAssertEqual(submission.attachments.map(\.name), ["later.txt"])
        XCTAssertEqual(submission.submittedAttachments, [])

        // A message with no files takes none.
        world.did = []
        submission.attachments = []
        submission.messageText = "No files"
        await world.send(submission)?.value
        XCTAssertEqual(world.did, ["create 'No files' as ada", "send 'No files' in t1", "created t1"])

        // The message could not be sent into the thread that was made: the thread keeps the text and the files.
        world.did = []
        world.sendFails = true
        submission.messageText = "Keep these"
        submission.attachments = [Self.file("c.md")]
        await world.send(submission)?.value
        XCTAssertEqual(world.did, [
            "create 'Keep these' as ada", "take c.md into t1 as ada", "keep 'Keep these' with c.md for t1", "created t1"
        ])
        XCTAssertEqual(submission.attachments, [], "They are the thread's now")
    }

    @MainActor
    func testFilesThatCannotGoIntoTheThread_undoIt_andComeBackWithTheMessage() async {
        let world = World()
        world.takeFails = true
        let submission = world.submission()
        submission.messageText = "Read these"
        submission.attachments = [Self.file("a.pdf")]
        await world.send(submission)?.value
        // Nothing was sent: the thread made for it is not kept, and is not opened.
        XCTAssertEqual(world.did, ["create 'Read these' as ada", "discard t1 as ada"])
        XCTAssertEqual(submission.messageText, "Read these")
        XCTAssertEqual(submission.attachments.map(\.name), ["a.pdf"])
        XCTAssertEqual(submission.errorMessage, DraftThreadSubmission.couldNotStart)
        XCTAssertFalse(submission.isCreatingThread)
    }

    @MainActor
    func testAThreadThatCannotBeMadeGivesTheFilesBackWithTheText_orDropsThemWithIt() async {
        let world = World()
        world.createFails = true
        let submission = world.submission()

        // Back with the text, in front of what was attached since.
        var held: CheckedContinuation<Void, Never>?
        let (reached, reach) = AsyncStream<Void>.makeStream()
        world.beforeCreating = {
            reach.yield()
            await withCheckedContinuation { held = $0 }
        }
        submission.messageText = "Read these"
        submission.attachments = [Self.file("a.pdf")]
        var sending = world.send(submission)
        for await _ in reached {
            break
        }
        submission.attachments = [Self.file("later.txt")]
        held?.resume()
        await sending?.value
        XCTAssertEqual(world.did, [])
        XCTAssertEqual(submission.messageText, "Read these")
        XCTAssertEqual(submission.attachments.map(\.name), ["a.pdf", "later.txt"])
        XCTAssertEqual(submission.errorMessage, DraftThreadSubmission.couldNotStart)

        // Words typed since: the message does not come back, and its files are not sent with other words.
        let (reachedAgain, reachAgain) = AsyncStream<Void>.makeStream()
        world.beforeCreating = {
            reachAgain.yield()
            await withCheckedContinuation { held = $0 }
        }
        submission.attachments = [Self.file("a.pdf")]
        sending = world.send(submission)
        for await _ in reachedAgain {
            break
        }
        submission.messageText = "Something newer"
        submission.attachments = [Self.file("newer.txt")]
        held?.resume()
        await sending?.value
        XCTAssertEqual(world.did, ["drop a.pdf"])
        XCTAssertEqual(submission.messageText, "Something newer")
        XCTAssertEqual(submission.attachments.map(\.name), ["newer.txt"])
        XCTAssertEqual(submission.errorMessage, DraftThreadSubmission.couldNotStartNotGivenBack)

        // Another account by then: nothing comes back, and nothing of the first account's is touched.
        world.did = []
        let (reachedLast, reachLast) = AsyncStream<Void>.makeStream()
        world.beforeCreating = {
            reachLast.yield()
            await withCheckedContinuation { held = $0 }
        }
        submission.messageText = "Ada's files"
        submission.attachments = [Self.file("ada.pdf")]
        sending = world.send(submission)
        for await _ in reachedLast {
            break
        }
        world.account = "grace"
        held?.resume()
        await sending?.value
        XCTAssertEqual(world.did, [])
        XCTAssertEqual(submission.messageText, "")
        XCTAssertEqual(submission.attachments, [])
        XCTAssertNil(submission.errorMessage)
    }

    @MainActor
    func testSendingMakesTheThread_thenSendsTheMessageIntoIt_once() async {
        let world = World()
        let submission = world.submission()

        // Nothing to send: nothing is done.
        submission.messageText = "   \n "
        XCTAssertNil(world.send(submission))
        XCTAssertFalse(submission.isCreatingThread)

        submission.messageText = "  Plan the release\nwith dates "
        var held: CheckedContinuation<Void, Never>?
        let (reached, reach) = AsyncStream<Void>.makeStream()
        world.beforeCreating = {
            reach.yield()
            await withCheckedContinuation { held = $0 }
        }
        let sending = world.send(submission)
        // Reserved at once: the field is empty, the page shows what was sent, and a second Send does nothing.
        XCTAssertTrue(submission.isCreatingThread)
        XCTAssertEqual(submission.messageText, "")
        XCTAssertEqual(submission.submittedText, "Plan the release\nwith dates")
        XCTAssertNil(world.send(submission), "Not twice")
        for await _ in reached {
            break
        }
        // Typed while the thread is being made: not sent with it, and left as it is.
        submission.messageText = "And another thing"
        XCTAssertNil(world.send(submission), "One at a time")
        world.beforeCreating = nil
        held?.resume()
        await sending?.value

        XCTAssertEqual(world.did, ["create 'Plan the release' as ada", "send 'Plan the release\nwith dates' in t1", "created t1"])
        XCTAssertFalse(submission.isCreatingThread)
        XCTAssertNil(submission.submittedText)
        XCTAssertNil(submission.errorMessage)
        XCTAssertEqual(submission.messageText, "And another thing")
    }

    @MainActor
    func testAThreadThatCannotBeMadeGivesTheMessageBack_unlessSomethingNewerWasTyped() async {
        let world = World()
        world.createFails = true
        let submission = world.submission()

        submission.messageText = "Plan the release"
        await world.send(submission)?.value
        XCTAssertEqual(world.did, [])
        XCTAssertEqual(submission.messageText, "Plan the release", "Back in the field")
        XCTAssertEqual(submission.errorMessage, "The thread could not be started. Your message is still available.")
        XCTAssertFalse(submission.isCreatingThread)
        XCTAssertNil(submission.submittedText)

        // Something newer typed while it was tried: that stays, and the failure is said without the promise.
        var held: CheckedContinuation<Void, Never>?
        let (reached, reach) = AsyncStream<Void>.makeStream()
        world.beforeCreating = {
            reach.yield()
            await withCheckedContinuation { held = $0 }
        }
        let sending = world.send(submission)
        XCTAssertNil(submission.errorMessage, "A new send starts clean")
        for await _ in reached {
            break
        }
        submission.messageText = "Something newer"
        world.beforeCreating = nil
        held?.resume()
        await sending?.value
        XCTAssertEqual(submission.messageText, "Something newer")
        XCTAssertEqual(submission.errorMessage, "The thread could not be started.", "Not said to be available: it was not given back")

        // Only blank space typed meanwhile: that is nothing to keep, and the message comes back over it.
        var heldBlank: CheckedContinuation<Void, Never>?
        let (reachedBlank, reachBlank) = AsyncStream<Void>.makeStream()
        world.beforeCreating = {
            reachBlank.yield()
            await withCheckedContinuation { heldBlank = $0 }
        }
        submission.messageText = "The one that matters"
        let blank = world.send(submission)
        for await _ in reachedBlank {
            break
        }
        submission.messageText = "  \n"
        world.beforeCreating = nil
        heldBlank?.resume()
        await blank?.value
        XCTAssertEqual(submission.messageText, "The one that matters")

        // Tried again and made: the message goes.
        world.createFails = false
        submission.messageText = "Plan the release"
        await world.send(submission)?.value
        XCTAssertEqual(world.did, ["create 'Plan the release' as ada", "send 'Plan the release' in t1", "created t1"])
        XCTAssertNil(submission.errorMessage)
    }

    @MainActor
    func testAMessageThatCannotBeSentIntoItsNewThreadIsKeptForIt_andTheThreadIsStillOpened() async {
        let world = World()
        world.sendFails = true
        let submission = world.submission()
        submission.messageText = "Plan the release"
        await world.send(submission)?.value
        XCTAssertEqual(world.did, ["create 'Plan the release' as ada", "keep 'Plan the release' for t1", "created t1"])
        XCTAssertEqual(submission.messageText, "", "The thread has it now")
        XCTAssertNil(submission.errorMessage)
    }

    @MainActor
    func testAnotherAccountSigningInMeanwhileGetsNothingOfIt() async {
        let world = World()
        let submission = world.submission()

        // While the thread is being made: nothing is sent into it, opened, said or given back.
        var held: CheckedContinuation<Void, Never>?
        let (reached, reach) = AsyncStream<Void>.makeStream()
        world.beforeCreating = {
            reach.yield()
            await withCheckedContinuation { held = $0 }
        }
        submission.messageText = "Ada's plan"
        let sending = world.send(submission)
        for await _ in reached {
            break
        }
        world.account = "grace"
        world.beforeCreating = nil
        held?.resume()
        await sending?.value
        XCTAssertEqual(world.did, ["create 'Ada's plan' as ada"], "Made for the account that sent; nothing after")
        XCTAssertEqual(submission.messageText, "")
        XCTAssertNil(submission.errorMessage)
        XCTAssertFalse(submission.isCreatingThread)

        // While it fails to be made: the text is not put in the other account's field.
        world.account = "ada"
        world.did = []
        world.createFails = true
        var heldAgain: CheckedContinuation<Void, Never>?
        let (reachedAgain, reachAgain) = AsyncStream<Void>.makeStream()
        world.beforeCreating = {
            reachAgain.yield()
            await withCheckedContinuation { heldAgain = $0 }
        }
        submission.messageText = "Ada's other plan"
        let failing = world.send(submission)
        for await _ in reachedAgain {
            break
        }
        world.account = "grace"
        world.beforeCreating = nil
        heldAgain?.resume()
        await failing?.value
        XCTAssertEqual(submission.messageText, "")
        XCTAssertNil(submission.errorMessage)

        // While the message is being sent into the thread that was made: the thread is not opened for the other account.
        world.account = "ada"
        world.did = []
        world.createFails = false
        for sendFails in [false, true] {
            world.account = "ada"
            world.did = []
            world.sendFails = sendFails
            var heldSending: CheckedContinuation<Void, Never>?
            let (reachedSending, reachSending) = AsyncStream<Void>.makeStream()
            world.beforeSending = {
                reachSending.yield()
                await withCheckedContinuation { heldSending = $0 }
            }
            submission.messageText = "Ada's third plan"
            let sending = world.send(submission)
            for await _ in reachedSending {
                break
            }
            world.account = "grace"
            world.beforeSending = nil
            heldSending?.resume()
            await sending?.value
            let made = world.did.first { $0.hasPrefix("create") }
            XCTAssertEqual(made, "create 'Ada's third plan' as ada")
            XCTAssertFalse(world.did.contains { $0.hasPrefix("created") }, "Not opened for the other account")
            XCTAssertFalse(world.did.contains { $0.hasPrefix("keep") }, "Nor kept through it")
            XCTAssertEqual(submission.messageText, "")
            XCTAssertNil(submission.errorMessage)
        }
    }
}
