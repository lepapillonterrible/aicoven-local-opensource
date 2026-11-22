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

    /// A store of the test's own: what waits in each scope, and what was reviewed.
    private final class Store {
        var waiting: [String?: [MemoryProposal]] = [:]
        var reviewed: [(id: String, approve: Bool)] = []
        var failsToList = false
        var reviewFails: Error?

        var source: ActivityProposals.Source {
            ActivityProposals.Source(
                pending: { [self] coven in
                    if failsToList { throw RepositoryError.dataLocked }
                    return waiting[coven] ?? []
                },
                review: { [self] id, approve in
                    if let reviewFails { throw reviewFails }
                    reviewed.append((id, approve))
                    for scope in waiting.keys {
                        waiting[scope]?.removeAll { $0.id == id }
                    }
                }
            )
        }
    }

    func testWhatWaitsInStrixAndInEachCovenIsListed_theLatestFirst_withoutWhatIsBeingAsked() async {
        let store = Store()
        store.waiting = [nil: [proposal("mine", at: 20)], "work": [proposal("work-old", in: "work", at: 10), proposal("work-new", in: "work", at: 30)], "gone": [proposal("elsewhere", in: "gone", at: 40)]]
        let model = ActivityProposals(source: store.source, signedIn: { "ada" })
        XCTAssertEqual(model.shown(without: []).map(\.id), [], "Nothing until they are read")
        XCTAssertFalse(model.hasRead, "Nor is it known yet that none waits")

        await model.load(covens: ["work", "home"])
        XCTAssertTrue(model.hasRead)

        XCTAssertEqual(model.shown(without: []).map(\.id), ["work-new", "mine", "work-old"], "Only of the scopes asked for")
        XCTAssertFalse(model.loadFailed)
        XCTAssertEqual(model.shown(without: ["mine"]).map(\.id), ["work-new", "work-old"], "What a question is asking is left to the question")
    }

    func testNothingOfOneAccountIsShownToAnother() async {
        var signedIn = "ada"
        let store = Store()
        store.waiting = [nil: [proposal("mine")]]
        let model = ActivityProposals(source: store.source, signedIn: { signedIn })
        await model.load(covens: [])
        XCTAssertEqual(model.shown(without: []).map(\.id), ["mine"])

        signedIn = "grace"
        XCTAssertEqual(model.shown(without: []).map(\.id), [], "Before her own are read")
        XCTAssertFalse(model.hasRead, "Hers have not been read")
        store.waiting = [nil: [proposal("hers")]]
        await model.load(covens: [])
        XCTAssertEqual(model.shown(without: []).map(\.id), ["hers"])
    }

    func testNoMoreAreListedAtOnceThanTheMost_theRestComeInAsTheseAreAnswered() async {
        let store = Store()
        store.waiting = [nil: (1 ... ActivityProposals.most + 2).map { proposal(String(format: "p%03d", $0), at: TimeInterval($0)) }]
        let model = ActivityProposals(source: store.source, signedIn: { "ada" })
        await model.load(covens: [])

        var shown = model.shown(without: [])
        XCTAssertEqual(shown.count, ActivityProposals.most)
        XCTAssertEqual(shown.first?.id, "p022", "The latest first")
        XCTAssertTrue(model.hasMore(without: []))

        await model.answer(shown[0], approve: false, covens: [], as: "ada")
        await model.answer(shown[1], approve: false, covens: [], as: "ada")
        shown = model.shown(without: [])
        XCTAssertEqual(shown.count, ActivityProposals.most)
        XCTAssertEqual(shown.last?.id, "p001", "The ones behind have come in")
        XCTAssertFalse(model.hasMore(without: []))
    }

    func testAReadingThatFailsLeavesWhatWasRead_andSaysItFailed() async {
        let store = Store()
        store.waiting = [nil: [proposal("mine")]]
        let model = ActivityProposals(source: store.source, signedIn: { "ada" })
        await model.load(covens: [])

        store.failsToList = true
        await model.load(covens: [])
        XCTAssertTrue(model.loadFailed)
        XCTAssertEqual(model.shown(without: []).map(\.id), ["mine"])

        store.failsToList = false
        await model.load(covens: [])
        XCTAssertFalse(model.loadFailed)
    }

    func testAnAnswerIsKeptOnce_andTheListReadAgain() async {
        let store = Store()
        store.waiting = [nil: [proposal("a"), proposal("b")]]
        let model = ActivityProposals(source: store.source, signedIn: { "ada" })
        await model.load(covens: [])
        let shown = model.shown(without: [])

        await model.answer(shown[0], approve: true, covens: [], as: "ada")
        await model.answer(shown[1], approve: false, covens: [], as: "ada")

        XCTAssertEqual(store.reviewed.map(\.id), ["a", "b"])
        XCTAssertEqual(store.reviewed.map(\.approve), [true, false])
        XCTAssertEqual(model.shown(without: []).count, 0, "Answered, they no longer wait")
        XCTAssertEqual(model.answering, [])
        XCTAssertEqual(model.notKept, [])
    }

    func testAProposalThatCannotBeReadIsNotApprovedAsItIs_andCanBeDenied() async {
        let store = Store()
        store.waiting = [nil: [proposal("sealed", unreadable: true)]]
        let model = ActivityProposals(source: store.source, signedIn: { "ada" })
        await model.load(covens: [])
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

        await model.answer(sealed, approve: true, covens: [], as: "ada")
        XCTAssertEqual(store.reviewed.count, 0, "Nothing unseen is kept")
        await model.answer(sealed, approve: false, covens: [], as: "ada")
        XCTAssertEqual(store.reviewed.map(\.approve), [false])
    }

    func testAnAnswerThatCouldNotBeKeptIsSaidUnderItsProposal_toWhoeverGaveIt() async {
        var signedIn = "ada"
        let store = Store()
        store.waiting = [nil: [proposal("a")]]
        let model = ActivityProposals(source: store.source, signedIn: { signedIn })
        await model.load(covens: [])
        let waiting = model.shown(without: [])[0]

        store.reviewFails = RepositoryError.dataLocked
        await model.answer(waiting, approve: true, covens: [], as: "ada")
        XCTAssertEqual(model.notKept, ["a"])
        XCTAssertEqual(model.shown(without: []).map(\.id), ["a"], "It still waits")

        // Answered again, and kept: nothing is said any more.
        store.reviewFails = nil
        await model.answer(waiting, approve: true, covens: [], as: "ada")
        XCTAssertEqual(model.notKept, [])

        // One that had its answer elsewhere meanwhile is no failure.
        store.waiting = [nil: [proposal("b")]]
        await model.load(covens: [])
        store.reviewFails = ProposalReviewError.alreadyReviewed
        await model.answer(model.shown(without: [])[0], approve: true, covens: [], as: "ada")
        XCTAssertEqual(model.notKept, [])

        // A failure is not said to an account that did not answer.
        store.waiting = [nil: [proposal("c")]]
        await model.load(covens: [])
        let asked = model.shown(without: [])[0]
        store.reviewFails = RepositoryError.dataLocked
        signedIn = "grace"
        await model.answer(asked, approve: true, covens: [], as: "ada")
        XCTAssertEqual(model.notKept, [])
    }
}
