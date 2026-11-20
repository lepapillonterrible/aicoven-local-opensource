@testable import AICoven
import XCTest

/// A list of threads is ordered, dated and acted on as the cloud app's:
/// newest first, archived apart, renamed, archived, deleted after asking,
/// and copied as Markdown.
final class ThreadListTests: XCTestCase {
    private func thread(
        _ id: String,
        title: String? = "A thread",
        covenID: String? = nil,
        agentName: String? = nil,
        archived: Bool = false,
        made: TimeInterval = 0,
        lastMessage: TimeInterval? = nil
    ) -> AICoven.Thread {
        Thread(
            id: id, userId: "ada", covenId: covenID, title: title, agentName: agentName, isArchived: archived,
            createdAt: Date(timeIntervalSince1970: made), updatedAt: Date(timeIntervalSince1970: 9_999_999),
            lastMessageAt: lastMessage.map(Date.init(timeIntervalSince1970:))
        )
    }

    // MARK: - Order, sections, words

    func testThreadsAreNewestFirstByWhenTheyWereLastUsed_andArchivedOnesApart() {
        let old = thread("old", made: 10, lastMessage: 500)
        let new = thread("new", made: 300)
        let quiet = thread("quiet", made: 100)
        let put = thread("put", archived: true, made: 50, lastMessage: 900)
        let away = thread("away", archived: true, made: 400)

        XCTAssertEqual(ThreadListRules.lastUsed(old), Date(timeIntervalSince1970: 500), "Its last message")
        XCTAssertEqual(ThreadListRules.lastUsed(new), Date(timeIntervalSince1970: 300), "When it was made, with no message")
        XCTAssertEqual(ThreadListRules.ordered([quiet, new, old]).map(\.id), ["old", "new", "quiet"])
        // Renaming or archiving one (which changes when it was updated) does not move it.
        XCTAssertEqual(ThreadListRules.ordered([new, quiet]).map(\.id), ["new", "quiet"])
        // Used at the same moment: a fixed order.
        let twins = [thread("b", made: 5), thread("a", made: 5)]
        XCTAssertEqual(ThreadListRules.ordered(twins).map(\.id), ["a", "b"])
        XCTAssertEqual(ThreadListRules.ordered(twins.reversed()).map(\.id), ["a", "b"])

        let sections = ThreadListRules.sections([away, quiet, put, new, old])
        XCTAssertEqual(sections.open.map(\.id), ["old", "new", "quiet"])
        XCTAssertEqual(sections.archived.map(\.id), ["put", "away"])
        XCTAssertEqual(ThreadListRules.sections([]).open.count, 0)
    }

    func testAThreadsTitle_theNameItIsGiven_andTheQuestionBeforeItIsDeleted() {
        XCTAssertEqual(ThreadListRules.title(of: thread("a", title: "Plans")), "Plans")
        XCTAssertEqual(ThreadListRules.title(of: thread("a", title: nil)), "Untitled")
        XCTAssertEqual(ThreadListRules.title(of: thread("a", title: "  \n")), "Untitled")

        XCTAssertEqual(ThreadListRules.name(from: "  Plans for May \n"), "Plans for May")
        XCTAssertEqual(ThreadListRules.name(from: "Two\nlines"), "Two lines")
        // As the store keeps a title: runs of white space as one space, 120 characters at most.
        XCTAssertEqual(ThreadListRules.name(from: "A  B\t C"), "A B C")
        XCTAssertEqual(ThreadListRules.name(from: String(repeating: "a", count: 200))?.count, 120)
        XCTAssertEqual(ThreadListRules.name(from: "A  B"), ThreadInputValidator.normalizedTitle("A  B", defaultTitle: "x"))
        XCTAssertNil(ThreadListRules.name(from: ""))
        XCTAssertNil(ThreadListRules.name(from: " \n\t"))

        XCTAssertEqual(ThreadListRules.deleteQuestion(for: thread("a", title: "Plans")), "Delete “Plans”?")
        XCTAssertEqual(ThreadListRules.deleteQuestion(for: thread("a", title: nil)), "Delete “Untitled”?")
        XCTAssertEqual(ThreadListRules.deleteConsequence, "The thread and its messages are removed.")
    }

    func testARowsDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 15)))
        func ago(days: Int = 0, hours: Int = 0) throws -> Date {
            try XCTUnwrap(calendar.date(byAdding: DateComponents(day: -days, hour: -hours), to: now))
        }
        let earlier = try ago(hours: 5)
        XCTAssertEqual(VisitWords.rowDate(earlier, now: now, calendar: calendar), earlier.formatted(date: .omitted, time: .shortened), "Today: the time")
        let yesterday = try ago(days: 1)
        XCTAssertEqual(VisitWords.rowDate(yesterday, now: now, calendar: calendar), yesterday.formatted(.dateTime.weekday(.abbreviated)), "Within the week: the weekday")
        let sixDays = try ago(days: 6)
        XCTAssertEqual(VisitWords.rowDate(sixDays, now: now, calendar: calendar), sixDays.formatted(.dateTime.weekday(.abbreviated)))
        let week = try ago(days: 7)
        XCTAssertEqual(VisitWords.rowDate(week, now: now, calendar: calendar), week.formatted(.dateTime.day().month(.abbreviated)), "This year: the day and month")
        let lastYear = try ago(days: 400)
        XCTAssertEqual(VisitWords.rowDate(lastYear, now: now, calendar: calendar), lastYear.formatted(.dateTime.day().month(.abbreviated).year()), "Another year: with the year")
        // The day counts, not the hours: late last night is yesterday's weekday.
        let lateLastNight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 23, minute: 50)))
        XCTAssertEqual(VisitWords.rowDate(lateLastNight, now: now, calendar: calendar), lateLastNight.formatted(.dateTime.weekday(.abbreviated)))
        XCTAssertEqual(VisitWords.daysBetween(lateLastNight, now, calendar), 1)
    }

    // MARK: - As Markdown

    private func message(_ id: String, _ role: String, _ content: String, metadata: [String: AnyJSONValue]? = nil) -> ChatMessage {
        ChatMessage(id: id, threadId: "t", role: role, content: content, metadata: metadata, tokenUsage: nil, createdAt: nil, isEncrypted: nil, keyFingerprint: nil)
    }

    func testAThreadAsMarkdown() throws {
        let document = try ThreadMarkdownExport.document(title: "Plans #1 [draft]", entries: [("You", "What next?"), ("Strix", "  "), ("Strix", "Ship it.\n\n- one\n- two")])
        XCTAssertEqual(document, "# Plans \\#1 \\[draft\\]\n\n## You\n\nWhat next?\n\n## Strix\n\nShip it.\n\n- one\n- two")
        XCTAssertThrowsError(try ThreadMarkdownExport.document(title: "Empty", entries: [("You", " \n")])) {
            XCTAssertEqual($0 as? ThreadMarkdownExportError, .empty)
        }
        XCTAssertEqual(ThreadMarkdownExport.escapedHeading("a\n b <i>&</i> c*d_e"), "a b &lt;i&gt;&amp;&lt;/i&gt; c\\*d\\_e")
        XCTAssertEqual(ThreadMarkdownExport.escapedHeading(" \n "), "Untitled")

        // What the person sent and replies are copied; what ends a turn that did not complete is not.
        let unfinished: Set = ["failed"]
        XCTAssertTrue(ThreadMarkdownExport.isIncluded(message("u", "user", "Hi"), unfinished: unfinished))
        XCTAssertTrue(ThreadMarkdownExport.isIncluded(message("a", "assistant", "Hello"), unfinished: unfinished))
        XCTAssertFalse(ThreadMarkdownExport.isIncluded(message("failed", "assistant", "I ran into an error"), unfinished: unfinished))
        XCTAssertFalse(ThreadMarkdownExport.isIncluded(message("s", "system", "Rules"), unfinished: unfinished))
        XCTAssertFalse(ThreadMarkdownExport.isIncluded(message("t", "tool", "{}"), unfinished: unfinished))

        // Who said it.
        let roles = ["r1": "Coder"]
        XCTAssertEqual(ThreadMarkdownExport.speaker(of: message("u", "user", "Hi"), roles: roles, threadAgent: "Strix"), "You")
        XCTAssertEqual(ThreadMarkdownExport.speaker(of: message("a", "assistant", "x", metadata: ["role_name": AnyJSONValue(" Writer ")]), roles: roles, threadAgent: "Strix"), "Writer")
        XCTAssertEqual(ThreadMarkdownExport.speaker(of: message("a", "assistant", "x", metadata: ["role_id": AnyJSONValue("R1")]), roles: roles, threadAgent: "Strix"), "Coder")
        XCTAssertEqual(ThreadMarkdownExport.speaker(of: message("a", "assistant", "x"), roles: roles, threadAgent: "Strix"), "Strix")
        XCTAssertEqual(ThreadMarkdownExport.speaker(of: message("a", "assistant", "x"), roles: roles, threadAgent: " "), "Agent")
    }

    @MainActor
    func testTheDocumentIsMadeOfWhatTheThreadHolds() async throws {
        let coven = thread("t", title: "Plans", covenID: "c1", agentName: "Strix")
        var askedRolesOf: [String] = []
        let dependencies = ThreadMarkdownExportDependencies(
            loadMessages: { _ in
                [
                    self.message("1", "user", "What next?"),
                    self.message("2", "assistant", "I ran into an error while contacting your provider: offline"),
                    self.message("3", "user", "Again?"),
                    self.message("4", "assistant", "Ship it.", metadata: ["role_id": AnyJSONValue("r1")]),
                ]
            },
            loadUnfinished: { _ in ["2"] },
            loadRoles: { covenID in
                askedRolesOf.append(covenID)
                return [Role(id: "r1", covenId: covenID, name: "Coder", emoji: nil, description: nil, systemPrompt: nil, model: nil, provider: nil, providerAccountId: nil, temperature: nil, maxTokens: nil, settings: nil, createdAt: Date(), updatedAt: Date())]
            },
            isStillThere: { $0 != "gone" },
            writeClipboard: { _ in true }
        )

        let document = try await ThreadMarkdownExport.makeDocument(thread: coven, dependencies: dependencies)

        XCTAssertEqual(document, "# Plans\n\n## You\n\nWhat next?\n\n## You\n\nAgain?\n\n## Coder\n\nShip it.")
        XCTAssertEqual(askedRolesOf, ["c1"])
        // A thread in no coven asks for no roles.
        askedRolesOf = []
        _ = try await ThreadMarkdownExport.makeDocument(thread: thread("p", title: "Mine"), dependencies: dependencies)
        XCTAssertEqual(askedRolesOf, [])
        // A thread deleted while it was read is not copied as if what was read were all of it.
        do {
            _ = try await ThreadMarkdownExport.makeDocument(thread: thread("gone", title: "Gone"), dependencies: dependencies)
            XCTFail("Copied a thread that is gone")
        } catch {
            XCTAssertEqual(error as? ThreadMarkdownExportError, .threadGone)
        }
    }

    func testEveryMessageIsRead_aPageAtATime_fromTheNewestBack() async throws {
        // 1,201 messages, oldest "0": pages of 500 from the newest back.
        let all = (0 ... 1200).map { message(String($0), "user", "m\($0)") }
        var asked: [String?] = []
        let read = try await ThreadMarkdownExport.allMessages { before in
            asked.append(before)
            let end = before.flatMap { id in all.firstIndex { $0.id == id } } ?? all.count
            return Array(all[max(0, end - ThreadMarkdownExport.pageSize) ..< end])
        }
        XCTAssertEqual(read.map(\.id), all.map(\.id), "The whole thread, oldest first")
        XCTAssertEqual(asked, [nil, "701", "201"])

        // A thread of exactly one page asks once more and finds nothing.
        let page = Array(all.prefix(ThreadMarkdownExport.pageSize))
        asked = []
        let one = try await ThreadMarkdownExport.allMessages { before in
            asked.append(before)
            return before == nil ? page : []
        }
        XCTAssertEqual(one.count, ThreadMarkdownExport.pageSize)
        XCTAssertEqual(asked, [nil, "0"])
        // A store that keeps answering with the same page is not asked for ever.
        let stuck = try await ThreadMarkdownExport.allMessages { _ in page }
        XCTAssertEqual(stuck.count, ThreadMarkdownExport.pageSize * 2)
        let empty = try await ThreadMarkdownExport.allMessages { _ in [] }
        XCTAssertEqual(empty.count, 0)
    }

    func testAThreadIsAsLatelyUsedAsItsLastMessage() {
        let made = thread("t", made: 100)
        XCTAssertNil(made.lastMessageAt)
        let used = made.lastUsed(at: Date(timeIntervalSince1970: 500))
        XCTAssertEqual(used.lastMessageAt, Date(timeIntervalSince1970: 500))
        XCTAssertEqual(used.title, made.title)
        XCTAssertEqual(used.createdAt, made.createdAt)
        XCTAssertEqual(used.lastUsed(at: Date(timeIntervalSince1970: 400)).lastMessageAt, Date(timeIntervalSince1970: 500), "Never earlier than it was")
        XCTAssertEqual(used.lastUsed(at: nil).lastMessageAt, Date(timeIntervalSince1970: 500))
        XCTAssertEqual(ThreadListRules.ordered([thread("new", made: 300), used]).map(\.id), ["t", "new"], "An old thread used now comes first")
    }

    func testAShownListStaysWhenReadingItAgainFails_unlessItIsNoLongerThisReadersToSee() {
        XCTAssertTrue(ThreadListRules.keepsShownList(after: URLError(.cannotOpenFile)))
        XCTAssertTrue(ThreadListRules.keepsShownList(after: RepositoryError.databaseUnavailable))
        XCTAssertFalse(ThreadListRules.keepsShownList(after: RepositoryError.dataLocked))
        XCTAssertFalse(ThreadListRules.keepsShownList(after: RepositoryError.accountChanged))
    }

    // MARK: - What a list lets the person do

    /// What the actions did, and what they are answered.
    @MainActor
    private final class Store {
        var did: [String] = []
        var failing = false
        var account = "ada"
        var clipboard: String?
        var clipboardTakes = true
        var messages: [ChatMessage] = []
        var changed = 0
        var left: [String] = []
        /// The thread was deleted while it was read.
        var gone = false
        /// Held until the test lets the messages be read.
        var beforeReading: (() async -> Void)?

        func actions() -> ThreadActions {
            let actions = ThreadActions(dependencies: .init(
                rename: { id, title in
                    if self.failing { throw URLError(.cannotOpenFile) }
                    self.did.append("rename \(id) \(title)")
                },
                setArchived: { id, archived in
                    if self.failing { throw URLError(.cannotOpenFile) }
                    self.did.append("\(archived ? "archive" : "unarchive") \(id)")
                },
                delete: { id in
                    if self.failing { throw URLError(.cannotOpenFile) }
                    self.did.append("delete \(id)")
                },
                stopTurn: { self.did.append("stop \($0)") },
                currentAccount: { self.account },
                export: .init(
                    loadMessages: { _ in
                        await self.beforeReading?()
                        if self.failing { throw URLError(.cannotOpenFile) }
                        return self.messages
                    },
                    loadUnfinished: { _ in [] },
                    loadRoles: { _ in [] },
                    isStillThere: { _ in !self.gone },
                    writeClipboard: { text in
                        guard self.clipboardTakes else { return false }
                        self.clipboard = text
                        return true
                    }
                )
            ))
            actions.onChanged = { self.changed += 1 }
            actions.onLeft = { self.left.append($0.id) }
            return actions
        }
    }

    @MainActor
    func testRenameArchiveAndDelete() async {
        let store = Store()
        let actions = store.actions()
        let plans = thread("t1", title: "Plans")

        await actions.rename(plans, to: "  Plans for May\n")?.value
        XCTAssertEqual(store.changed, 1)
        XCTAssertEqual(store.did, ["rename t1 Plans for May"])
        XCTAssertEqual(store.left, [], "A renamed thread stays open")
        // Nothing to call it, or the name it has: nothing is started.
        XCTAssertNil(actions.rename(plans, to: "  "))
        XCTAssertNil(actions.rename(plans, to: "Plans"))
        XCTAssertEqual(store.did.count, 1)

        // Archiving stops the turn running in it, then puts it away.
        await actions.setArchived(plans, true)?.value
        XCTAssertEqual(store.changed, 2)
        XCTAssertEqual(Array(store.did.suffix(2)), ["stop t1", "archive t1"])
        XCTAssertEqual(store.left, ["t1"], "What showed it closes")
        await actions.setArchived(thread("t1", archived: true), false)?.value
        XCTAssertEqual(store.changed, 3)
        XCTAssertEqual(store.did.last, "unarchive t1")
        XCTAssertEqual(store.left, ["t1"], "Bringing one back opens or closes nothing")

        await actions.delete(plans)?.value
        XCTAssertEqual(store.changed, 4)
        XCTAssertEqual(Array(store.did.suffix(2)), ["stop t1", "delete t1"])
        XCTAssertEqual(store.left, ["t1", "t1"])
        XCTAssertNil(actions.failure)
    }

    @MainActor
    func testWhatCouldNotBeDoneIsSaid_andNothingIsSaidToAnotherAccount() async {
        let store = Store()
        store.failing = true
        let actions = store.actions()
        let plans = thread("t1", title: "Plans")

        for (run, title) in [
            ({ actions.rename(plans, to: "New") }, "Couldn't rename the thread"),
            ({ actions.setArchived(plans, true) }, "Couldn't archive the thread"),
            ({ actions.setArchived(plans, false) }, "Couldn't unarchive the thread"),
            ({ actions.delete(plans) }, "Couldn't delete the thread"),
        ] as [(() -> Task<Void, Never>?, String)] {
            actions.failure = nil
            await run()?.value
            XCTAssertEqual(actions.failure?.title, title)
        }
        XCTAssertEqual(ThreadActions.Failure.message, "Try again.")
        XCTAssertEqual(store.left, [], "A thread that was not archived or deleted stays open")

        // Another account signs in while it is tried: nothing is said or shown to it.
        actions.failure = nil
        let changedBefore = store.changed
        let renaming = actions.rename(plans, to: "Newer")
        store.account = "grace"
        await renaming?.value
        XCTAssertNil(actions.failure)
        XCTAssertEqual(store.changed, changedBefore)
    }

    @MainActor
    func testCopyingAThreadAsMarkdown() async {
        let store = Store()
        let actions = store.actions()
        let plans = thread("t1", title: "Plans", agentName: "Strix")
        store.messages = [message("1", "user", "What next?"), message("2", "assistant", "Ship it.")]

        XCTAssertTrue(actions.canCopy)
        var copying = actions.copy(plans)
        XCTAssertEqual(actions.exportingThreadID, "t1")
        XCTAssertFalse(actions.canCopy, "Not while one is being read")
        XCTAssertNil(actions.copy(plans), "A second is not started")
        await copying?.value
        XCTAssertEqual(store.clipboard, "# Plans\n\n## You\n\nWhat next?\n\n## Strix\n\nShip it.")
        XCTAssertEqual(actions.notice?.title, "Thread Copied")
        XCTAssertEqual(actions.notice?.message, "The full thread was copied as Markdown.")
        XCTAssertNil(actions.exportingThreadID)

        // Nothing to copy: the clipboard is left as it was.
        store.messages = []
        await actions.copy(plans)?.value
        XCTAssertEqual(actions.notice?.kind, .failure)
        XCTAssertEqual(actions.notice?.title, "Couldn’t Copy Thread")
        XCTAssertEqual(actions.notice?.message, ThreadMarkdownExport.nothingToCopy)
        XCTAssertEqual(store.clipboard?.hasPrefix("# Plans"), true)

        // The clipboard would not take it; then the thread could not be read.
        store.messages = [message("1", "user", "Hi")]
        store.clipboardTakes = false
        await actions.copy(plans)?.value
        XCTAssertEqual(actions.notice?.message, ThreadMarkdownExport.clipboardFailed)
        store.failing = true
        await actions.copy(plans)?.value
        XCTAssertEqual(actions.notice?.message, ThreadMarkdownExport.failed)

        // Another account signs in while it is read: nothing is copied or said.
        store.failing = false
        store.clipboardTakes = true
        store.clipboard = nil
        copying = actions.copy(plans)
        store.account = "grace"
        await copying?.value
        XCTAssertNil(actions.exportingThreadID)
        XCTAssertNil(store.clipboard)
        XCTAssertNil(actions.notice)

        // The thread went while it was read: nothing is copied, and that is said.
        store.account = "ada"
        store.gone = true
        await actions.copy(plans)?.value
        XCTAssertEqual(actions.notice?.message, ThreadMarkdownExport.failed)
        XCTAssertNil(store.clipboard)
        store.gone = false

        // Deleting a thread calls off a copy of it under way: nothing is copied or said of it.
        var reading: CheckedContinuation<Void, Never>?
        let (reached, reach) = AsyncStream<Void>.makeStream()
        store.beforeReading = {
            reach.yield()
            await withCheckedContinuation { reading = $0 }
        }
        actions.notice = nil
        copying = actions.copy(plans)
        for await _ in reached {
            break
        }
        let deleting = actions.delete(plans)
        XCTAssertNil(actions.exportingThreadID)
        store.beforeReading = nil
        reading?.resume()
        await copying?.value
        await deleting?.value
        XCTAssertNil(store.clipboard)
        XCTAssertNil(actions.notice)

        // The list went elsewhere: a copy under way says nothing.
        copying = actions.copy(plans)
        actions.invalidate()
        await copying?.value
        XCTAssertNil(store.clipboard)
        XCTAssertNil(actions.notice)
        XCTAssertNil(actions.exportingThreadID)
        XCTAssertTrue(actions.canCopy)
    }

    @MainActor
    func testAStoredMessageIsTold_evenInAThreadNotHeldYet() async {
        // The threads can be on their way from the database when a message
        // is stored: the lists are told all the same, and read again.
        let told = expectation(forNotification: ThreadService.threadUsed, object: nil)
        await ThreadService.shared.noteMessage(in: "not-held-\(UUID().uuidString)", at: Date())
        await fulfillment(of: [told], timeout: 10)
    }

    // MARK: - From what is stored

    func testAStoredThreadIsCopied_withoutWhatEndedATurnThatDidNotComplete() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        await MainActor.run { DatabaseManager.shared.configureIfNeeded() }
        await ThreadService.shared.reloadForCurrentUser()
        let made = try await ThreadService.shared.createThread(title: "Copy \(UUID().uuidString)")
        let threadID = made.id
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await ThreadService.shared.deleteThread(threadId: threadID)
            await ThreadService.shared.reloadForCurrentUser()
            await DataEncryptionService.shared.lock()
        }
        let store = ThreadRepository.shared
        try await store.beginTurn(id: "failed-\(threadID)", userMessage: TurnProgress.message(in: threadID, role: "user", content: "First try"))
        let failure = TurnProgress.message(in: threadID, role: "assistant", content: "I ran into an error while contacting your provider: offline")
        _ = try await store.endTurn(id: "failed-\(threadID)", outcome: .failed, message: failure)
        try await store.beginTurn(id: "done-\(threadID)", userMessage: TurnProgress.message(in: threadID, role: "user", content: "Second try"))
        let reply = TurnProgress.message(in: threadID, role: "assistant", content: "Here it is.", metadata: ["role_name": AnyJSONValue("Strix")])
        _ = try await store.endTurn(id: "done-\(threadID)", outcome: .completed, message: reply)

        // The thread is as lately used as its last message, in what the
        // service holds and in what is read from the store afresh.
        let held = try await ThreadService.shared.loadThreads().first { $0.id == threadID }
        XCTAssertEqual(held?.lastMessageAt.map { Int($0.timeIntervalSince1970) }, reply.createdAt.map { Int($0.timeIntervalSince1970) })
        await ThreadService.shared.reloadForCurrentUser()
        let reread = try await ThreadService.shared.loadThreads().first { $0.id == threadID }
        XCTAssertEqual(reread?.lastMessageAt.map { Int($0.timeIntervalSince1970) }, reply.createdAt.map { Int($0.timeIntervalSince1970) })
        XCTAssertNotNil(reread?.lastMessageAt)

        let unfinished = try await store.messagesOfTurnsNotCompleted(threadID: threadID)
        XCTAssertEqual(unfinished, [failure.id])

        let document = try await ThreadMarkdownExport.makeDocument(thread: made, dependencies: .live)
        XCTAssertEqual(document, "# \(ThreadMarkdownExport.escapedHeading(made.title ?? ""))\n\n## You\n\nFirst try\n\n## You\n\nSecond try\n\n## Strix\n\nHere it is.")
    }
}
