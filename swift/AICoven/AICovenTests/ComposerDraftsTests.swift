@testable import AICoven
import GRDB
import XCTest

/// What is kept of drafts by the tests' stand-in for the store, and how
/// often it was asked. Used from the main actor only, as the drafts are.
@MainActor
private final class KeptDrafts {
    var texts: [String: String] = [:]
    var saves: [(text: String, threadID: String)] = []
    var loads: [String] = []
    var failsToSave = false
    var account = "account-a"
    /// What is due to run, in the order scheduled.
    var scheduled: [@MainActor () -> Void] = []

    /// While true, a read or a save waits to be let go.
    var holdsLoads = false
    var holdsSaves = false
    private var heldLoads: [CheckedContinuation<Void, Never>] = []
    private var heldSaves: [CheckedContinuation<Void, Never>] = []
    /// Met each time a read or a save starts to wait.
    var loadIsWaiting: XCTestExpectation?
    var saveIsWaiting: XCTestExpectation?

    func makeDrafts() -> ComposerDrafts {
        ComposerDrafts(
            load: { [self] threadID in await read(threadID) },
            save: { [self] text, threadID in try await keep(text, threadID) },
            schedule: { [self] _, action in scheduled.append(action) },
            currentAccount: { [self] in account }
        )
    }

    private func read(_ threadID: String) async -> String? {
        loads.append(threadID)
        let kept = texts[threadID]
        if holdsLoads {
            await withCheckedContinuation { continuation in
                heldLoads.append(continuation)
                loadIsWaiting?.fulfill()
            }
        }
        return kept
    }

    private func keep(_ text: String, _ threadID: String) async throws {
        if holdsSaves {
            await withCheckedContinuation { continuation in
                heldSaves.append(continuation)
                saveIsWaiting?.fulfill()
            }
        }
        if failsToSave { throw NSError(domain: "KeptDrafts", code: 1) }
        saves.append((text, threadID))
        texts[threadID] = text.isEmpty ? nil : text
    }

    func letLoadsGo() {
        holdsLoads = false
        let waiting = heldLoads
        heldLoads = []
        waiting.forEach { $0.resume() }
    }

    func letSavesGo() {
        holdsSaves = false
        let waiting = heldSaves
        heldSaves = []
        waiting.forEach { $0.resume() }
    }

    /// Runs what was scheduled, and waits for the saving it started: only
    /// that, so a scheduled save that saved nothing shows.
    func runScheduled(_ drafts: ComposerDrafts) async {
        let due = scheduled
        scheduled = []
        due.forEach { $0() }
        await drafts.lastSave?.value
    }
}

/// A thread's draft: what its composer holds unsent, kept per thread, its
/// text saved with the thread.
@MainActor
final class ComposerDraftsTests: XCTestCase {
    func testAThreadsDraft_isWhatWasKeptWithItUntilSomethingIsTypedThere() async {
        let kept = KeptDrafts()
        kept.texts["a"] = "Left unsent"
        let drafts = kept.makeDrafts()

        let first = await drafts.draft(for: "a")
        XCTAssertEqual(first, ComposerDraft(text: "Left unsent"))
        let empty = await drafts.draft(for: "b")
        XCTAssertEqual(empty, ComposerDraft())

        let file = FileAttachmentDetail(id: "f", name: "notes.txt", mimeType: nil, sizeBytes: nil, width: nil, height: nil, url: nil)
        drafts.set(ComposerDraft(text: "Left unsent, and more", attachments: [file]), for: "a")
        let again = await drafts.draft(for: "a")
        XCTAssertEqual(again, ComposerDraft(text: "Left unsent, and more", attachments: [file]), "With its attachments, while the app runs")
        XCTAssertEqual(kept.loads, ["a", "b"], "Read from the store once for each thread")
    }

    func testTheText_isSavedOnceItHasStoppedChangingNotOnEveryKeystroke() async {
        let kept = KeptDrafts()
        let drafts = kept.makeDrafts()
        _ = await drafts.draft(for: "a")

        for text in ["H", "He", "Hel", "Hello"] {
            drafts.set(ComposerDraft(text: text), for: "a")
        }
        XCTAssertEqual(kept.saves.count, 0)
        XCTAssertEqual(kept.scheduled.count, 1, "One save is due, however much was typed")

        await kept.runScheduled(drafts)
        XCTAssertEqual(kept.saves.map(\.text), ["Hello"])
        XCTAssertEqual(kept.saves.map(\.threadID), ["a"])

        // Attachments alone change nothing that is saved.
        let file = FileAttachmentDetail(id: "f", name: "notes.txt", mimeType: nil, sizeBytes: nil, width: nil, height: nil, url: nil)
        drafts.set(ComposerDraft(text: "Hello", attachments: [file]), for: "a")
        XCTAssertEqual(kept.scheduled.count, 0)

        // Sent: the kept text goes.
        drafts.set(ComposerDraft(), for: "a")
        await drafts.saveNow()
        XCTAssertEqual(kept.saves.last?.text, "")
        XCTAssertNil(kept.texts["a"])
    }

    func testLeavingTheForeground_savesAtOnceEveryThreadThatChanged() async {
        let kept = KeptDrafts()
        let drafts = kept.makeDrafts()
        _ = await drafts.draft(for: "a")
        _ = await drafts.draft(for: "b")
        drafts.set(ComposerDraft(text: "In A"), for: "a")
        drafts.set(ComposerDraft(text: "In B"), for: "b")

        await drafts.saveNow()

        XCTAssertEqual(kept.texts, ["a": "In A", "b": "In B"])
        await drafts.saveNow()
        XCTAssertEqual(kept.saves.count, 2, "Nothing is saved twice")
    }

    func testAnEmptyComposer_saysNothingOfAThreadWhoseKeptTextHasNotBeenRead() async {
        let kept = KeptDrafts()
        kept.texts["a"] = "Left unsent"
        let drafts = kept.makeDrafts()

        // As when a thread is being opened and its field is still empty.
        drafts.set(ComposerDraft(), for: "a")
        await drafts.saveNow()

        XCTAssertEqual(kept.saves.count, 0)
        let draft = await drafts.draft(for: "a")
        XCTAssertEqual(draft.text, "Left unsent")
    }

    func testWhatIsTypedWhileTheKeptTextIsRead_isNewerThanIt() async {
        let kept = KeptDrafts()
        kept.texts["a"] = "Left unsent"
        kept.holdsLoads = true
        kept.loadIsWaiting = expectation(description: "The kept text is being read")
        let drafts = kept.makeDrafts()

        let reading = Task { await drafts.draft(for: "a") }
        await fulfillment(of: [kept.loadIsWaiting].compactMap(\.self), timeout: 10)
        drafts.set(ComposerDraft(text: "Typed meanwhile"), for: "a")
        kept.letLoadsGo()
        let draft = await reading.value

        XCTAssertEqual(draft.text, "Typed meanwhile")
    }

    func testAThreadOpenedInTwoPlacesAtOnce_isReadFromTheStoreOnce() async {
        let kept = KeptDrafts()
        kept.texts["a"] = "Left unsent"
        kept.holdsLoads = true
        kept.loadIsWaiting = expectation(description: "The kept text is being read")
        let drafts = kept.makeDrafts()

        let first = Task { await drafts.draft(for: "a") }
        await fulfillment(of: [kept.loadIsWaiting].compactMap(\.self), timeout: 10)
        let second = Task { await drafts.draft(for: "a") }
        // The second asks while the first is still reading.
        await Task.yield()
        kept.letLoadsGo()
        let (one, two) = await (first.value, second.value)

        XCTAssertEqual(one.text, "Left unsent")
        XCTAssertEqual(two.text, "Left unsent")
        XCTAssertEqual(kept.loads, ["a"])
    }

    func testIfTheAccountChangesWhileADraftIsRead_nothingOfItIsHandedOn() async {
        let kept = KeptDrafts()
        kept.texts["a"] = "Left unsent"
        kept.holdsLoads = true
        kept.loadIsWaiting = expectation(description: "The kept text is being read")
        let drafts = kept.makeDrafts()

        let reading = Task { await drafts.draft(for: "a") }
        await fulfillment(of: [kept.loadIsWaiting].compactMap(\.self), timeout: 10)
        // Also when something was set for the thread meanwhile.
        drafts.set(ComposerDraft(text: "Typed meanwhile"), for: "a")
        kept.account = "account-b"
        kept.letLoadsGo()
        let draft = await reading.value

        XCTAssertEqual(draft, ComposerDraft())
    }

    func testSaves_areMadeOneAfterAnotherSoTheLatestTextIsTheOneKept() async {
        let kept = KeptDrafts()
        let drafts = kept.makeDrafts()
        _ = await drafts.draft(for: "a")
        drafts.set(ComposerDraft(text: "Earlier"), for: "a")
        kept.holdsSaves = true
        kept.saveIsWaiting = expectation(description: "The earlier text is being saved")
        let earlier = Task { await drafts.saveNow() }
        await fulfillment(of: [kept.saveIsWaiting].compactMap(\.self), timeout: 10)

        // Changed, and saved again, while the earlier save is under way.
        kept.saveIsWaiting = nil
        drafts.set(ComposerDraft(text: "Later"), for: "a")
        let later = Task { await drafts.saveNow() }
        kept.letSavesGo()
        await earlier.value
        await later.value

        XCTAssertEqual(kept.saves.map(\.text), ["Earlier", "Later"])
        XCTAssertEqual(kept.texts["a"], "Later")
    }

    func testSentAttachments_leaveTheThreadsDraftWhereverItsComposerIs() async {
        let kept = KeptDrafts()
        let drafts = kept.makeDrafts()
        _ = await drafts.draft(for: "a")
        let sent = FileAttachmentDetail(id: "sent", name: "sent.txt", mimeType: nil, sizeBytes: nil, width: nil, height: nil, url: nil)
        let added = FileAttachmentDetail(id: "added", name: "added.txt", mimeType: nil, sizeBytes: nil, width: nil, height: nil, url: nil)
        // As the composer leaves it when a message is on its way: the text
        // cleared, the files still there, and another chosen since.
        drafts.set(ComposerDraft(text: "", attachments: [sent, added]), for: "a")

        drafts.removeAttachments([sent], from: "a")
        drafts.removeAttachments([sent], from: "never-opened")

        let draft = await drafts.draft(for: "a")
        XCTAssertEqual(draft.attachments, [added])
    }

    func testATextThatCouldNotBeSaved_isTriedAgainWithTheNextSave() async {
        let kept = KeptDrafts()
        let drafts = kept.makeDrafts()
        _ = await drafts.draft(for: "a")
        drafts.set(ComposerDraft(text: "Keep me"), for: "a")
        kept.failsToSave = true
        await drafts.saveNow()
        XCTAssertNil(kept.texts["a"])

        kept.failsToSave = false
        await drafts.saveNow()
        XCTAssertEqual(kept.texts["a"], "Keep me")
    }

    // MARK: - Kept with the thread

    func testADraft_isKeptEncryptedWithItsThreadAndGoesWithIt() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        await ThreadService.shared.reloadForCurrentUser()
        let threadID = try await ThreadService.shared.createThread(title: "Drafts \(UUID().uuidString)").id
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await ThreadService.shared.deleteThread(threadId: threadID)
            await ThreadService.shared.reloadForCurrentUser()
            await DataEncryptionService.shared.lock()
        }
        let store = ThreadRepository.shared

        let none = try await store.draft(forThread: threadID)
        XCTAssertNil(none)
        try await store.saveDraft("Remember the milk 🥛", forThread: threadID)
        let kept = try await store.draft(forThread: threadID)
        XCTAssertEqual(kept, "Remember the milk 🥛")
        let stored = try await DatabaseManager.shared.dbQueue?.read { db in
            try Data.fetchOne(db, sql: "SELECT draft_ciphertext FROM threads WHERE id = ?", arguments: [threadID])
        }
        XCTAssertNotNil(stored)
        XCTAssertNil(stored?.range(of: Data("Remember".utf8)), "The text is not readable in the database file")

        // Saving the thread itself (a new title) leaves its draft.
        _ = try await ThreadService.shared.updateThread(threadId: threadID, title: "Renamed")
        let afterRename = try await store.draft(forThread: threadID)
        XCTAssertEqual(afterRename, "Remember the milk 🥛")

        // Nothing is kept for a thread that is not there, or of another's.
        try await store.saveDraft("Nowhere", forThread: "no-such-thread")
        let nowhere = try await store.draft(forThread: "no-such-thread")
        XCTAssertNil(nowhere)

        // Locked, nothing is read or kept.
        await DataEncryptionService.shared.lock()
        do {
            _ = try await store.draft(forThread: threadID)
            XCTFail("A draft is not read while the data is locked")
        } catch {}
        do {
            try await store.saveDraft("While locked", forThread: threadID)
            XCTFail("A draft is not kept while the data is locked")
        } catch {}
        await DataEncryptionService.shared.unlockForTestingEphemeral()

        // Empty text keeps nothing.
        try await store.saveDraft("", forThread: threadID)
        let cleared = try await DatabaseManager.shared.dbQueue?.read { db in
            try Row.fetchOne(db, sql: "SELECT draft_ciphertext FROM threads WHERE id = ?", arguments: [threadID])
        }
        XCTAssertNil(cleared?["draft_ciphertext"] as Data?)
        await DataEncryptionService.shared.lock()
    }
}
