@testable import AICoven
import XCTest

/// The memory proposals that wait for the person, as Activity lists them.
@MainActor
final class ActivityProposalsTests: XCTestCase {
    private func proposal(_ id: String, in coven: String? = nil, at time: TimeInterval = 0, unreadable: Bool = false) -> MemoryProposal {
        MemoryProposal(
            id: id, eventId: "", covenId: coven, proposedContent: unreadable ? "" : "Remember \(id)", proposedTags: nil,
            scope: coven == nil ? "user" : "coven", reason: nil, sourceMessageId: nil, status: "pending", proposedBy: "agent",
            reviewedBy: nil, createdAt: Date(timeIntervalSince1970: time), reviewedAt: nil, title: nil, isUnreadable: unreadable
        )
    }

    /// A store of the test's own: what waits in each scope (the latest first, as the real one gives
    /// them), which scopes cannot be read, and what was reviewed.
    private final class Store {
        var waiting: [String?: [MemoryProposal]] = [:]
        var reviewed: [(id: String, approve: Bool)] = []
        var unreadable: Set<String?> = []
        var reviewFails: Error?
        var limitsAsked: [Int] = []
        /// Runs while a review is under way.
        var whileReviewing: (() async -> Void)?

        var source: ActivityProposals.Source {
            ActivityProposals.Source(
                pending: { [self] coven, limit in
                    limitsAsked.append(limit)
                    if unreadable.contains(coven) { throw RepositoryError.dataLocked }
                    return Array((waiting[coven] ?? []).sorted { $0.createdAt > $1.createdAt }.prefix(limit))
                },
                review: { [self] id, approve in
                    await whileReviewing?()
                    if let reviewFails { throw reviewFails }
                    reviewed.append((id, approve))
                    for scope in waiting.keys {
                        waiting[scope]?.removeAll { $0.id == id }
                    }
                }
            )
        }
    }

    private func model(_ store: Store, signedIn: @escaping () -> String = { "ada" }) -> ActivityProposals {
        ActivityProposals(source: store.source, signedIn: signedIn)
    }

    // MARK: - What is listed

    func testWhatWaitsInStrixAndInEachCovenIsListed_theLatestFirst_withoutWhatIsBeingAsked() async {
        let store = Store()
        store.waiting = [nil: [proposal("mine", at: 20)], "work": [proposal("work-old", in: "work", at: 10), proposal("work-new", in: "work", at: 30)], "gone": [proposal("elsewhere", in: "gone", at: 40)]]
        let model = model(store)
        XCTAssertEqual(model.shown(without: []).map(\.id), [], "Nothing until they are read")
        XCTAssertFalse(model.hasRead, "Nor is it known yet that none waits")

        await model.show(covens: ["work", "home"], asked: [])

        XCTAssertEqual(model.shown(without: []).map(\.id), ["work-new", "mine", "work-old"], "Only of the scopes looked in")
        XCTAssertTrue(model.hasRead)
        XCTAssertFalse(model.loadFailed)
        XCTAssertNil(model.announcement, "What is there when the page is first read is not said aloud")
        XCTAssertEqual(model.shown(without: ["mine"]).map(\.id), ["work-new", "work-old"], "What a question is asking is left to the question")
    }

    func testUntilTheCovensAreKnown_itIsNotSaidThatNothingWaits() async {
        let store = Store()
        store.waiting = ["work": [proposal("theirs", in: "work")]]
        let model = model(store)

        // The covens are not read yet: only Strix can be looked in.
        await model.show(covens: nil, asked: [])
        XCTAssertEqual(model.shown(without: []).count, 0)
        XCTAssertFalse(model.hasRead, "A coven may hold one")

        await model.show(covens: ["work"], asked: [])
        XCTAssertTrue(model.hasRead)
        XCTAssertEqual(model.shown(without: []).map(\.id), ["theirs"])
        // A person with no coven: Strix read is everything read.
        let alone = self.model(Store())
        await alone.show(covens: [], asked: [])
        XCTAssertTrue(alone.hasRead)
    }

    func testNoMoreAreListedAtOnceThanTheMost_andWhatIsBeingAskedIsLeftOutBeforeTheyAreCounted() async {
        let store = Store()
        store.waiting = [nil: (1 ... ActivityProposals.most + 2).map { proposal(String(format: "p%03d", $0), at: TimeInterval($0)) }]
        let model = model(store)
        // The latest of them is being asked about beside its thread.
        await model.show(covens: [], asked: ["p022"])
        XCTAssertEqual(store.limitsAsked.last, ActivityProposals.most + 2, "One more than is listed, and one more for the one left out")

        var shown = model.shown(without: ["p022"])
        XCTAssertEqual(shown.count, ActivityProposals.most)
        XCTAssertEqual(shown.first?.id, "p021", "The latest that is not being asked about")
        XCTAssertTrue(model.hasMore(without: ["p022"]), "One more waits behind the twenty")

        // Answered, the ones behind come in.
        await model.answer(shown[0], approve: false, as: "ada")
        shown = model.shown(without: ["p022"])
        XCTAssertEqual(shown.count, ActivityProposals.most)
        XCTAssertEqual(shown.last?.id, "p001")
        XCTAssertFalse(model.hasMore(without: ["p022"]))
    }

    func testNothingOfOneAccountIsShownToAnother() async {
        var signedIn = "ada"
        let store = Store()
        store.waiting = [nil: [proposal("mine")]]
        let model = model(store) { signedIn }
        await model.show(covens: [], asked: [])
        XCTAssertEqual(model.shown(without: []).map(\.id), ["mine"])

        signedIn = "grace"
        XCTAssertEqual(model.shown(without: []).map(\.id), [], "Before her own are read")
        XCTAssertFalse(model.hasRead, "Hers have not been read")
        store.waiting = [nil: [proposal("hers")]]
        await model.load()
        XCTAssertEqual(model.shown(without: []).map(\.id), ["hers"])
    }

    // MARK: - A scope that cannot be read

    func testAScopeThatCannotBeReadKeepsWhatWasRead_andTheOthersAreReadAllTheSame() async {
        let store = Store()
        store.waiting = [nil: [proposal("mine", at: 1)], "work": [proposal("work", in: "work", at: 2)], "home": [proposal("home", in: "home", at: 3)]]
        let model = model(store)
        await model.show(covens: ["work", "home"], asked: [])
        XCTAssertEqual(model.shown(without: []).map(\.id), ["home", "work", "mine"])

        // Work cannot be read; meanwhile Strix and Home have changed.
        store.unreadable = ["work"]
        store.waiting[nil] = []
        store.waiting["home"]?.append(proposal("home-new", in: "home", at: 4))
        await model.load()

        XCTAssertTrue(model.loadFailed)
        XCTAssertEqual(model.announcement, .init(number: 1, words: ActivityProposals.couldNotLoad), "Said aloud")
        XCTAssertEqual(model.shown(without: []).map(\.id), ["home-new", "home", "work"], "Work as it was read before; the others as they are now")
        XCTAssertTrue(model.hasRead, "Each was read at least once")

        // A scope never read, and unreadable from the first: it is not known whether anything waits there.
        let fresh = self.model(store)
        await fresh.show(covens: ["work", "home"], asked: [])
        XCTAssertTrue(fresh.loadFailed)
        XCTAssertFalse(fresh.hasRead)
        XCTAssertEqual(fresh.shown(without: []).map(\.id), ["home-new", "home"])

        store.unreadable = []
        await fresh.load()
        XCTAssertFalse(fresh.loadFailed)
        XCTAssertTrue(fresh.hasRead)
    }

    // MARK: - Answers

    func testAnAnswerIsKeptOnce_saidAloud_andTheListReadAgain() async {
        let store = Store()
        store.waiting = [nil: [proposal("a", at: 2), proposal("b", at: 1)]]
        let model = model(store)
        await model.show(covens: [], asked: [])
        let shown = model.shown(without: [])

        await model.answer(shown[0], approve: true, as: "ada")
        XCTAssertEqual(model.announcement, .init(number: 1, words: "Approved"))
        await model.answer(shown[1], approve: false, as: "ada")
        XCTAssertEqual(model.announcement, .init(number: 2, words: "Denied"))

        XCTAssertEqual(store.reviewed.map(\.id), ["a", "b"])
        XCTAssertEqual(store.reviewed.map(\.approve), [true, false])
        XCTAssertEqual(model.shown(without: []).count, 0, "Answered, they no longer wait")
        XCTAssertEqual(model.answering, [])
        XCTAssertEqual(model.notKept, [])
    }

    func testAfterAnAnswerTheProposalsAreReadAsThingsStandByThen_notAsWhenItWasGiven() async {
        let store = Store()
        store.waiting = [nil: [proposal("mine", at: 1)], "work": [proposal("work", in: "work", at: 2)]]
        let model = model(store)
        // The covens are not known yet when the answer is given.
        await model.show(covens: nil, asked: [])
        let mine = model.shown(without: [])[0]
        // While the answer is kept, the covens come in and their proposals are read.
        store.whileReviewing = { await model.show(covens: ["work"], asked: []) }

        await model.answer(mine, approve: true, as: "ada")

        XCTAssertEqual(model.shown(without: []).map(\.id), ["work"], "The coven read meanwhile is still looked in")
        XCTAssertTrue(model.hasRead)
    }

    func testAProposalThatCannotBeReadIsNotApprovedAsItIs_andCanBeDenied() async {
        let store = Store()
        store.waiting = [nil: [proposal("sealed", unreadable: true)]]
        let model = model(store)
        await model.show(covens: [], asked: [])
        let sealed = model.shown(without: [])[0]

        // Its block says why there is nothing to read, and takes no approval.
        let asked = ActivityProposals.question(about: sealed, in: "Strix")
        XCTAssertEqual(asked.question, ActivityProposals.unreadableQuestion)
        XCTAssertEqual(asked.details, ActivityProposals.unreadableDetails)
        XCTAssertFalse(asked.canApprove)
        XCTAssertFalse(asked.isOfATurn)
        // One that can be read asks whether to remember it, naming where.
        let readable = ActivityProposals.question(about: proposal("fact", in: "work"), in: "Client work")
        XCTAssertEqual([readable.question, readable.details, readable.threadTitle, readable.covenName], ["Remember this for the coven?", "Remember fact", "Memory", "Client work"])
        XCTAssertTrue(readable.canApprove)
        XCTAssertEqual(ActivityProposals.question(about: proposal("me"), in: "Strix").question, "Remember this about you?")

        await model.answer(sealed, approve: true, as: "ada")
        XCTAssertEqual(store.reviewed.count, 0, "Nothing unseen is kept")
        await model.answer(sealed, approve: false, as: "ada")
        XCTAssertEqual(store.reviewed.map(\.approve), [false])
    }

    func testAnAnswerThatCouldNotBeKeptIsSaidUnderItsProposalAndAloud_toWhoeverGaveIt() async {
        var signedIn = "ada"
        let store = Store()
        store.waiting = [nil: [proposal("a")]]
        let model = model(store) { signedIn }
        await model.show(covens: [], asked: [])
        let waiting = model.shown(without: [])[0]

        store.reviewFails = RepositoryError.dataLocked
        await model.answer(waiting, approve: true, as: "ada")
        XCTAssertEqual(model.notKept, ["a"])
        XCTAssertEqual(model.announcement?.words, ActivityProposals.answerNotKept)
        XCTAssertEqual(model.shown(without: []).map(\.id), ["a"], "It still waits")

        // Answered again, and kept: nothing is said under it any more.
        store.reviewFails = nil
        await model.answer(waiting, approve: true, as: "ada")
        XCTAssertEqual(model.notKept, [])
        XCTAssertEqual(model.announcement?.words, "Approved")

        // One that had its answer elsewhere meanwhile is no failure, and nothing is said of it.
        store.waiting = [nil: [proposal("b")]]
        await model.load()
        let said = model.announcement
        store.reviewFails = ProposalReviewError.alreadyReviewed
        await model.answer(model.shown(without: [])[0], approve: true, as: "ada")
        XCTAssertEqual(model.notKept, [])
        XCTAssertEqual(model.announcement, said)

        // A failure is not said to an account that did not answer.
        store.waiting = [nil: [proposal("c")]]
        await model.load()
        let asked = model.shown(without: [])[0]
        store.reviewFails = RepositoryError.dataLocked
        signedIn = "grace"
        await model.answer(asked, approve: true, as: "ada")
        XCTAssertEqual(model.notKept, [])
    }

    func testAProposalThatNewlyWaitsIsSaidAloud_onceThePageHasBeenRead() async {
        let store = Store()
        store.waiting = [nil: [proposal("a", at: 1)]]
        let model = model(store)
        await model.show(covens: [], asked: [])
        XCTAssertNil(model.announcement)

        // Read again with nothing new: nothing is said.
        await model.load()
        XCTAssertNil(model.announcement)

        // A question about another was given up, so it is listed now.
        store.waiting[nil]?.append(proposal("b", at: 2))
        await model.load()
        XCTAssertEqual(model.announcement, .init(number: 1, words: ActivityProposals.newlyWaiting))
        XCTAssertEqual(model.shown(without: []).map(\.id), ["b", "a"])
    }
}
