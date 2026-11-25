@testable import AICoven
import XCTest

final class MemoryPageTests: XCTestCase {
    func testPageTagWinsOverEveryOtherRule() {
        XCTAssertEqual(MemoryPage.of(tags: ["coven:policy", "page:purpose"]), .purpose)
        XCTAssertEqual(MemoryPage.of(tags: ["person", "page:facts"]), .facts)
    }

    func testPolicyAndSkillTagsGoOnHowWeWorkHere() {
        XCTAssertEqual(MemoryPage.of(tags: ["coven:policy"]), .howWeWork)
        XCTAssertEqual(MemoryPage.of(tags: ["coven:skill", "person"]), .howWeWork)
    }

    func testPeopleTagsGoOnWhosWhoInAnyCase() {
        XCTAssertEqual(MemoryPage.of(tags: ["People"]), .people)
        XCTAssertEqual(MemoryPage.of(tags: ["project", "person:dana"]), .people)
        XCTAssertEqual(MemoryPage.of(tags: ["TEAM"]), .people)
    }

    func testEverythingElseGoesOnFactsAndFigures() {
        XCTAssertEqual(MemoryPage.of(tags: []), .facts)
        XCTAssertEqual(MemoryPage.of(tags: ["summary", "coven:source", "page:unknown"]), .facts)
    }

    func testAnEntryAddedOnAPageLandsBackOnThatPage() {
        for page in MemoryPage.allCases {
            XCTAssertEqual(MemoryPage.of(tags: page.tagsForNewEntry), page)
        }
    }
}

final class MemoryDraftTests: XCTestCase {
    func testAnOpenFieldHoldsTheCursorOnlyWhileItHoldsUnsavedText() {
        XCTAssertFalse(MemoryDraft.holdsText(editing: nil, editDraft: "", adding: false, addDraft: ""))
        XCTAssertFalse(MemoryDraft.holdsText(editing: nil, editDraft: "left over", adding: false, addDraft: "left over"))
        XCTAssertFalse(MemoryDraft.holdsText(editing: nil, editDraft: "", adding: true, addDraft: "  \n"))
        XCTAssertTrue(MemoryDraft.holdsText(editing: nil, editDraft: "", adding: true, addDraft: "Ask Sam"))
        XCTAssertFalse(MemoryDraft.holdsText(editing: "Ask Sam", editDraft: " Ask Sam ", adding: false, addDraft: ""))
        XCTAssertTrue(MemoryDraft.holdsText(editing: "Ask Sam", editDraft: "Ask Sam first", adding: false, addDraft: ""))
    }

    func testSavingIsUnchangedWhenOnlyTheWhitespaceAtTheEndsDiffers() {
        XCTAssertTrue(MemoryDraft.isUnchanged("Ask Sam", from: "Ask Sam"))
        XCTAssertTrue(MemoryDraft.isUnchanged("Ask Sam", from: "Ask Sam \n"))
        XCTAssertTrue(MemoryDraft.isUnchanged(" Ask Sam\n", from: "\nAsk Sam  "))
        XCTAssertFalse(MemoryDraft.isUnchanged("Ask Sam first", from: "Ask Sam \n"))
        XCTAssertFalse(MemoryDraft.isUnchanged("Ask  Sam", from: "Ask Sam"))
    }

    func testOnlyAnEntryWithLineBreaksIsEditedInAMultilineField() {
        XCTAssertFalse(MemoryDraft.editsInMultilineField("Ask Sam"))
        XCTAssertFalse(MemoryDraft.editsInMultilineField(""))
        XCTAssertTrue(MemoryDraft.editsInMultilineField("Ask Sam\nthen Priya"))
        XCTAssertTrue(MemoryDraft.editsInMultilineField("Ask Sam\r\nthen Priya"))
    }
}

@MainActor
final class MemoryPagesModelTests: XCTestCase {
    private let work = MemoryPlace.coven("work")

    private func entry(_ id: String, _ content: String = "Text", tags: [String]? = nil, at seconds: TimeInterval = 0) -> Memory {
        FakeMemoryStore.entry(id, content, tags: tags, at: seconds)
    }

    func testLoadPagesThroughEveryEntry() async {
        let store = FakeMemoryStore()
        store.stored = (0 ..< (MemoryPagesModel.pageSize * 2 + 5)).map { entry("m\($0)") }
        let model = MemoryPagesModel(manager: store, signedIn: { "ada" })

        XCTAssertNil(model.entries(in: work), "Nothing is said of a place before it is read")
        await model.load(work)

        XCTAssertEqual(model.entries(in: work)?.count, MemoryPagesModel.pageSize * 2 + 5)
        XCTAssertEqual(store.offsets, [0, 100, 200])
        XCTAssertEqual(store.askedAs, ["ada", "ada", "ada"], "Every page as the account the read began for")
    }

    func testLoadStopsWhenAPageBringsNothingNew() async {
        let store = FakeMemoryStore()
        store.stored = (0 ..< MemoryPagesModel.pageSize * 2).map { entry("m\($0)") }
        store.ignoresOffset = true
        let model = MemoryPagesModel(manager: store, signedIn: { "ada" })

        await model.load(.aboutMe)

        XCTAssertEqual(model.entries(in: .aboutMe)?.count, MemoryPagesModel.pageSize)
        XCTAssertEqual(store.offsets, [0, 100])
    }

    func testAPageThatOverlapsTheLastStillReachesTheRest() async {
        let store = FakeMemoryStore()
        store.stored = (0 ..< (MemoryPagesModel.pageSize * 2 + 5)).map { entry("m\($0)") }
        // A row added before the second page pushes the first page's last row onto it.
        store.insertBeforeSecondPage = entry("new")
        let model = MemoryPagesModel(manager: store, signedIn: { "ada" })

        await model.load(work)

        XCTAssertEqual(model.entries(in: work)?.count, MemoryPagesModel.pageSize * 2 + 5)
        XCTAssertEqual(store.offsets, [0, 100, 200])
    }

    func testAPlaceThatCannotBeRead_saysSo_andIsReadAgainOnAsking() async {
        let store = FakeMemoryStore()
        store.stored = [entry("m1")]
        store.failsReads = true
        let model = MemoryPagesModel(manager: store, signedIn: { "ada" })

        await model.load(work)
        XCTAssertTrue(model.didLoadFail(in: work))
        XCTAssertNil(model.entries(in: work))

        store.failsReads = false
        await model.load(work)
        XCTAssertFalse(model.didLoadFail(in: work))
        XCTAssertEqual(model.entries(in: work)?.map(\.id), ["m1"])
    }

    func testAPagesEntriesAreItsOwn_oldestFirst_andAboutMeHoldsThemAll() async {
        let store = FakeMemoryStore()
        store.stored = [
            entry("later", "Ships on Fridays", tags: ["page:how"], at: 20),
            entry("who", "Dana runs design", tags: ["person"], at: 5),
            entry("earlier", "Reviews on Mondays", tags: ["coven:policy"], at: 10),
            entry("fact", "Budget is 100", at: 1),
        ]
        let model = MemoryPagesModel(manager: store, signedIn: { "ada" })
        await model.load(work)

        XCTAssertEqual(model.entries(on: .howWeWork, in: work).map(\.id), ["earlier", "later"])
        XCTAssertEqual(model.entries(on: .people, in: work).map(\.id), ["who"])
        XCTAssertEqual(model.entries(on: .facts, in: work).map(\.id), ["fact"])
        XCTAssertEqual(model.entries(on: .purpose, in: work).map(\.id), [])
        XCTAssertEqual(model.entries(on: nil, in: work).map(\.id), ["fact", "who", "earlier", "later"])
    }

    func testALoadThatStartedBeforeAnEditDoesNotUndoIt() async {
        let store = FakeMemoryStore()
        let old = entry("m1", "Old")
        store.stored = [old]
        let model = MemoryPagesModel(manager: store, signedIn: { "ada" })
        await model.load(work)

        let held = store.holdNext(.read)
        let reload = Task { await model.load(self.work) }
        await held.reached()
        let saved = await model.edit(old, to: "New", in: work)
        XCTAssertTrue(saved)
        held.release()
        await reload.value

        XCTAssertEqual(model.entries(in: work)?.map(\.content), ["New"])
    }

    func testTwoReadsOfAPlaceAtOnceAreOneRead() async {
        let store = FakeMemoryStore()
        store.stored = [entry("m1")]
        let model = MemoryPagesModel(manager: store, signedIn: { "ada" })

        let held = store.holdNext(.read)
        let first = Task { await model.load(self.work) }
        await held.reached()
        // The first is let go only once the second, asked here, is waiting:
        // this is queued on the main actor, which runs nothing else until
        // the second load, called on it below, comes to its wait.
        Task { held.release() }
        await model.load(work)
        await first.value

        XCTAssertEqual(store.offsets, [0], "The second shared the read under way")
        XCTAssertEqual(model.entries(in: work)?.map(\.id), ["m1"])
        // A read asked for once that one has landed is a read of its own.
        await model.load(work)
        XCTAssertEqual(store.offsets, [0, 0])
    }

    func testAnEditWhileAnEarlierOneIsOnItsWayIsIgnored() async {
        let store = FakeMemoryStore()
        let old = entry("m1", "Old")
        store.stored = [old]
        let model = MemoryPagesModel(manager: store, signedIn: { "ada" })
        await model.load(work)

        let held = store.holdNext(.update)
        let first = Task { await model.edit(old, to: "First", in: self.work) }
        await held.reached()
        XCTAssertTrue(model.savingIds.contains("m1"))
        let second = await model.edit(old, to: "Second", in: work)
        XCTAssertFalse(second)
        XCTAssertNil(model.failures["m1"], "Nothing is said of a press that did nothing")
        held.release()
        let saved = await first.value
        XCTAssertTrue(saved)

        XCTAssertEqual(store.updates, ["First"])
        XCTAssertEqual(model.entries(in: work)?.map(\.content), ["First"])
        XCTAssertTrue(model.savingIds.isEmpty)
    }

    func testAnActionThatFails_leavesThePageAsItWas_saysSoWhereItHappened_andCanBeTriedAgain() async {
        let store = FakeMemoryStore()
        let old = entry("m1", "Old")
        store.stored = [old]
        let model = MemoryPagesModel(manager: store, signedIn: { "ada" })
        await model.load(work)
        let addKey = MemoryPagesModel.addKey(.facts, in: work)

        store.failsWrites = true
        let saved = await model.edit(old, to: "New", in: work)
        XCTAssertFalse(saved)
        XCTAssertEqual(model.failures["m1"], "Couldn't save that change. Try again.")
        let forgotten = await model.forget(old, in: work)
        XCTAssertFalse(forgotten)
        XCTAssertEqual(model.failures["m1"], "Couldn't forget that. Try again.")
        let added = await model.add("Another", on: .facts, in: work)
        XCTAssertFalse(added)
        XCTAssertEqual(model.failures[addKey], "Couldn't add that. Try again.")
        XCTAssertEqual(model.entries(in: work)?.map(\.content), ["Old"])
        XCTAssertTrue(model.savingIds.isEmpty)
        XCTAssertTrue(model.forgettingIds.isEmpty)
        // An Add to another section, or the same section of another place, has failed nowhere.
        XCTAssertNil(model.failures[MemoryPagesModel.addKey(.people, in: work)])
        XCTAssertNil(model.failures[MemoryPagesModel.addKey(.facts, in: .strix)])

        // The next action there takes what was said away, and so does closing the row.
        store.failsWrites = false
        let savedThen = await model.edit(old, to: "New", in: work)
        XCTAssertTrue(savedThen)
        XCTAssertNil(model.failures["m1"])
        XCTAssertEqual(model.entries(in: work)?.map(\.content), ["New"])
        model.clearFailure(addKey)
        XCTAssertNil(model.failures[addKey])
    }

    func testAnEntryAReadBroughtBeforeItsAddAnswered_isShownOnce() async {
        let store = FakeMemoryStore()
        store.stored = [entry("m1", "Old")]
        let model = MemoryPagesModel(manager: store, signedIn: { "ada" })
        await model.load(work)

        // The store has kept the entry, and a read lands with it, before the Add is answered.
        let held = store.holdNext(.create)
        let add = Task { await model.add("New", on: .facts, in: self.work) }
        await held.reached()
        await model.load(work)
        XCTAssertEqual(model.entries(in: work)?.map(\.content).sorted(), ["New", "Old"])
        held.release()
        let added = await add.value
        XCTAssertTrue(added)

        XCTAssertEqual(model.entries(in: work)?.map(\.content).sorted(), ["New", "Old"], "Once, not twice")
        XCTAssertEqual(Set(model.entries(in: work)?.map(\.id) ?? []).count, 2)
    }

    func testAnEntryAddedToAPlaceThatWasNotRead_isShown() async {
        let store = FakeMemoryStore()
        store.failsReads = true
        let model = MemoryPagesModel(manager: store, signedIn: { "ada" })
        await model.load(.aboutMe)
        XCTAssertTrue(model.didLoadFail(in: .aboutMe))

        // The page offers Add under a section that could not be read; what is added there is kept.
        store.failsReads = false
        let added = await model.add("Lives in Lisbon", on: nil, in: .aboutMe)
        XCTAssertTrue(added)
        XCTAssertEqual(model.entries(in: .aboutMe)?.map(\.content), ["Lives in Lisbon"], "Shown, not only kept")
        XCTAssertFalse(model.didLoadFail(in: .aboutMe))
    }

    func testAForgetWhileTheSameOneIsOnItsWayIsIgnored() async {
        let store = FakeMemoryStore()
        let gone = entry("m1")
        store.stored = [gone]
        let model = MemoryPagesModel(manager: store, signedIn: { "ada" })
        await model.load(work)

        let held = store.holdNext(.delete)
        let first = Task { await model.forget(gone, in: self.work) }
        await held.reached()
        let second = await model.forget(gone, in: work)
        XCTAssertFalse(second)
        held.release()
        let forgotten = await first.value
        XCTAssertTrue(forgotten)

        XCTAssertEqual(store.deletes, ["m1"])
        XCTAssertEqual(model.entries(in: work)?.isEmpty, true)
        XCTAssertTrue(model.forgettingIds.isEmpty)
    }

    func testAddPutsTheEntryOnItsPage_inItsPlace() async {
        let store = FakeMemoryStore()
        let model = MemoryPagesModel(manager: store, signedIn: { "ada" })
        await model.load(work)
        await model.load(.aboutMe)

        await model.add("Send options as PDFs", on: .howWeWork, in: work)
        await model.add("Lives in Lisbon", on: nil, in: .aboutMe)

        XCTAssertEqual(model.entries(on: .howWeWork, in: work).map(\.content), ["Send options as PDFs"])
        XCTAssertEqual(model.entries(on: nil, in: .aboutMe).map(\.content), ["Lives in Lisbon"])
        XCTAssertEqual(store.created.map(\.place), [work, .aboutMe])
        XCTAssertEqual(store.created.map(\.tags), [["page:how", "coven:policy"], nil], "The person's own memory has no pages")
        XCTAssertEqual(store.offsets.count, 2, "What was added is shown as the store gave it back, with no second read")
    }

    func testWhatWasReadForOneAccount_isNotShownToTheNext_andALateAnswerIsDropped() async throws {
        let store = FakeMemoryStore()
        store.stored = [entry("adas", "Ada's")]
        var signedIn = "ada"
        let model = MemoryPagesModel(manager: store, signedIn: { signedIn })
        await model.load(work)
        XCTAssertEqual(model.entries(in: work)?.map(\.content), ["Ada's"])

        // A read for Ada is under way when Grace signs in.
        let held = store.holdNext(.read)
        let adas = Task { await model.load(self.work) }
        await held.reached()
        signedIn = "grace"
        store.stored = [entry("graces", "Grace's")]
        await model.load(work)
        XCTAssertEqual(model.entries(in: work)?.map(\.content), ["Grace's"], "Ada's went when Grace's were asked for")
        held.release()
        await adas.value
        XCTAssertEqual(model.entries(in: work)?.map(\.content), ["Grace's"], "Ada's late read is not shown to Grace")
        XCTAssertEqual(store.askedAs.last, "grace")

        // An edit Ada began lands after Grace signed in: nothing of it is shown.
        signedIn = "ada"
        await model.load(work)
        let old = try XCTUnwrap(model.entries(in: work)?.first)
        let update = store.holdNext(.update)
        let edit = Task { await model.edit(old, to: "Edited", in: self.work) }
        await update.reached()
        signedIn = "grace"
        await model.load(work)
        update.release()
        let saved = await edit.value
        XCTAssertFalse(saved, "Nothing of it is Grace's to be told")
        XCTAssertEqual(model.entries(in: work)?.map(\.content), ["Grace's"])
        XCTAssertTrue(model.savingIds.isEmpty)

        // Nor is a failure of something Ada began said to Grace.
        signedIn = "ada"
        await model.load(work)
        let adasEntry = try XCTUnwrap(model.entries(in: work)?.first)
        let failing = store.holdNext(.delete)
        let forget = Task { await model.forget(adasEntry, in: self.work) }
        await failing.reached()
        signedIn = "grace"
        await model.load(work)
        store.failsNextHeld = true
        failing.release()
        let forgotten = await forget.value
        XCTAssertFalse(forgotten)
        XCTAssertTrue(model.failures.isEmpty)
        XCTAssertTrue(model.forgettingIds.isEmpty)

        // Nor where the account changes with nothing else asked of the model meanwhile.
        signedIn = "ada"
        await model.load(work)
        let adasAgain = try XCTUnwrap(model.entries(in: work)?.first)
        let unasked = store.holdNext(.update)
        let lateEdit = Task { await model.edit(adasAgain, to: "Edited", in: self.work) }
        await unasked.reached()
        signedIn = "grace"
        store.failsNextHeld = true
        unasked.release()
        let lateSaved = await lateEdit.value
        XCTAssertFalse(lateSaved)
        XCTAssertTrue(model.failures.isEmpty, "Ada's failure is not said to Grace")
        XCTAssertNil(model.entries(in: work), "What was held for Ada went with her")
        XCTAssertTrue(model.savingIds.isEmpty)
    }
}

// MARK: - Fakes

/// A store in memory that can be made to wait or fail.
@MainActor
private final class FakeMemoryStore: MemoryPagesManaging {
    enum Step {
        case read, create, update, delete
    }

    /// A step of the store held until the test lets it go.
    final class Held {
        private let (arrivals, arrive) = AsyncStream<Void>.makeStream()
        private let (releases, letGo) = AsyncStream<Void>.makeStream()

        /// Returns once the store has got to the held step.
        func reached() async {
            for await _ in arrivals {
                break
            }
        }

        func release() {
            letGo.yield()
        }

        fileprivate func hold() async {
            arrive.yield()
            for await _ in releases {
                break
            }
        }
    }

    var stored: [Memory] = []
    var ignoresOffset = false
    var failsReads = false
    var failsWrites = false
    /// The step held now fails once it is let go.
    var failsNextHeld = false
    var insertBeforeSecondPage: Memory?
    private(set) var offsets: [Int] = []
    private(set) var askedAs: [String?] = []
    private(set) var created: [(place: MemoryPlace, tags: [String]?)] = []
    private(set) var updates: [String] = []
    private(set) var deletes: [String] = []
    private var holding: [Step: Held] = [:]

    static func entry(_ id: String, _ content: String, tags: [String]? = nil, at seconds: TimeInterval = 0) -> Memory {
        Memory(
            id: id, covenId: nil, userId: nil, roleId: nil, scope: .coven, title: nil, content: content, tags: tags,
            isPinned: false, isApproved: true, createdAt: Date(timeIntervalSince1970: seconds), updatedAt: nil
        )
    }

    func holdNext(_ step: Step) -> Held {
        let held = Held()
        holding[step] = held
        return held
    }

    private func pass(_ step: Step) async {
        if let held = holding.removeValue(forKey: step) {
            await held.hold()
        }
    }

    func memories(in _: MemoryPlace, limit: Int, offset: Int, as account: String?) async throws -> [Memory] {
        offsets.append(offset)
        askedAs.append(account)
        if offset > 0, let added = insertBeforeSecondPage {
            insertBeforeSecondPage = nil
            stored.insert(added, at: 0)
        }
        let answer = Array(stored.dropFirst(ignoresOffset ? 0 : offset).prefix(limit))
        await pass(.read)
        if failsReads { throw RepositoryError.databaseUnavailable }
        return answer
    }

    func createMemory(in place: MemoryPlace, content: String, tags: [String]?, as _: String?) async throws -> Memory {
        if failsWrites { throw RepositoryError.databaseUnavailable }
        created.append((place, tags))
        let added = Self.entry("new-\(created.count)", content, tags: tags, at: 100)
        stored.insert(added, at: 0)
        // Held, if it is, once the entry is kept and before the answer.
        await pass(.create)
        return added
    }

    func updateMemory(memoryId: String, content: String, tags _: [String]?, as _: String?) async throws -> Memory {
        if failsWrites { throw RepositoryError.databaseUnavailable }
        let text = content
        updates.append(text)
        await pass(.update)
        if failsNextHeld {
            failsNextHeld = false
            throw RepositoryError.databaseUnavailable
        }
        guard let index = stored.firstIndex(where: { $0.id == memoryId }) else { throw MemoryStoreError.noSuchMemory }
        let old = stored[index]
        stored[index] = Self.entry(old.id, text, tags: old.tags, at: old.createdAt.timeIntervalSince1970)
        return stored[index]
    }

    func deleteMemory(memoryId: String, as _: String?) async throws {
        if failsWrites { throw RepositoryError.databaseUnavailable }
        deletes.append(memoryId)
        await pass(.delete)
        if failsNextHeld {
            failsNextHeld = false
            throw RepositoryError.databaseUnavailable
        }
        stored.removeAll { $0.id == memoryId }
    }
}
