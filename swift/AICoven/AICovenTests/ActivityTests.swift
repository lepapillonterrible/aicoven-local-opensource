@testable import AICoven
import XCTest

/// Activity: what waits for the person, moves and has finished, across
/// Strix and every coven.
@MainActor
final class ActivityTests: XCTestCase {
    private func thread(
        _ id: String, covenID: String? = nil, usedAt: TimeInterval = 0, isArchived: Bool = false, of account: String = "ada"
    ) -> AICoven.Thread {
        Thread(
            id: id, userId: account, covenId: covenID, title: id.capitalized, isArchived: isArchived,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: nil, lastMessageAt: Date(timeIntervalSince1970: usedAt)
        )
    }

    // MARK: - The groups

    func testEachThreadIsWhereWhatItIsDoingPutsIt_acrossEveryScope() {
        let threads = [
            thread("asks", covenID: "work", usedAt: 10), thread("broke", usedAt: 20), thread("paused", covenID: "home", usedAt: 30),
            thread("works", covenID: "work", usedAt: 40), thread("replied", usedAt: 50), thread("draft", usedAt: 60), thread("quiet", usedAt: 70),
        ]
        let groups = ActivityGroups.make(
            threads: threads,
            activity: [
                "asks": .waiting(ConversationActivity.needsOKWords), "broke": .broken(ConversationActivity.brokenWords), "paused": .paused,
                "works": .moving("Reading 14 portfolios"), "replied": .unread, "draft": .unsent,
            ],
            unreadReplyAt: ["replied": Date(timeIntervalSince1970: 55)]
        )
        XCTAssertEqual(groups.waiting.map(\.id), ["approval:asks", "problem:broke", "paused:paused"], "What needs an OK first, then problems, then what is paused")
        XCTAssertEqual(groups.moving, [.moving(threads[3], words: "Reading 14 portfolios")])
        XCTAssertEqual(groups.finished, [.finished(threads[4], repliedAt: Date(timeIntervalSince1970: 55))])
        XCTAssertFalse(
            (groups.waiting + groups.moving + groups.finished).contains { ["draft", "quiet"].contains($0.thread.id) },
            "An unsent message, or nothing at all, is in no group"
        )
    }

    func testWithinAKindTheThreadLastUsedComesFirst_andTheLatestReplyFirst() {
        let threads = [
            thread("a", usedAt: 10), thread("b", usedAt: 30), thread("c", usedAt: 20),
            thread("r1", usedAt: 90), thread("r2", usedAt: 80), thread("r3", usedAt: 70), thread("r4", usedAt: 60),
        ]
        let waiting = ActivityGroups.make(
            threads: threads, activity: ["a": .waiting("x"), "b": .waiting("x"), "c": .waiting("x")], unreadReplyAt: [:]
        )
        XCTAssertEqual(waiting.waiting.map(\.thread.id), ["b", "c", "a"])
        let moving = ActivityGroups.make(threads: threads, activity: ["a": .moving("x"), "b": .moving("y"), "c": .moving("z")], unreadReplyAt: [:])
        XCTAssertEqual(moving.moving.map(\.thread.id), ["b", "c", "a"])

        let at = { Date(timeIntervalSince1970: $0) }
        let finished = ActivityGroups.make(
            threads: threads,
            activity: ["r1": .unread, "r2": .unread, "r3": .unread, "r4": .unread],
            unreadReplyAt: ["r1": at(100), "r2": at(300), "r4": at(100)]
        )
        XCTAssertEqual(finished.finished.map(\.thread.id), ["r2", "r1", "r4", "r3"], "By when the reply came; the same moment keeps the threads' order; none known comes last")
    }

    func testAnArchivedThreadIsInNoGroup() {
        let groups = ActivityGroups.make(
            threads: [thread("away", isArchived: true), thread("here")],
            activity: ["away": .unread, "here": .unread],
            unreadReplyAt: [:]
        )
        XCTAssertEqual(groups.finished.map(\.thread.id), ["here"])
    }

    func testSomethingWaitsOnlyWhileATurnAsksForAnOK() {
        XCTAssertTrue(ActivityGroups.isAnythingWaiting(in: ["a": .moving("x"), "b": .waiting("Needs your OK")]))
        XCTAssertFalse(ActivityGroups.isAnythingWaiting(in: ["a": .moving("x"), "b": .broken("x"), "c": .unread, "d": .paused]))
        XCTAssertFalse(ActivityGroups.isAnythingWaiting(in: [:]))
        XCTAssertEqual(ActivityRowMark.words(isWaiting: true, hasUnread: true), "Needs your OK", "What waits outranks a reply not yet seen")
        XCTAssertEqual(ActivityRowMark.words(isWaiting: false, hasUnread: true), "New replies")
        XCTAssertEqual(ActivityRowMark.words(isWaiting: false, hasUnread: false), "")
    }

    func testWhatNewlyWaitsOrFinishedIsSaidAloud_notATurnsChangingWords() {
        let threads = [thread("asks", usedAt: 40), thread("broke", usedAt: 30), thread("works", usedAt: 20), thread("replied", usedAt: 10)]
        func groups(_ activity: [String: ConversationActivity]) -> ActivityGroups {
            ActivityGroups.make(threads: threads, activity: activity, unreadReplyAt: [:])
        }
        let before = groups(["works": .moving("Reading"), "broke": .broken("x")])
        let after = groups(["works": .moving("Writing"), "broke": .broken("x"), "asks": .waiting("Needs your OK"), "replied": .unread])
        XCTAssertEqual(
            ActivityGroups.announcements(from: before, to: after),
            ["Needs your OK: Asks", "Strix replied: Replied"],
            "What was already there is not said again, nor that a turn's words changed"
        )
        XCTAssertEqual(ActivityGroups.announcements(from: after, to: after), [])
        XCTAssertEqual(ActivityGroups.announcements(from: groups([:]), to: groups(["broke": .broken("x")])), ["Stopped on a problem: Broke"])
        XCTAssertEqual(ActivityGroups.announcements(from: groups([:]), to: groups(["broke": .paused])), ["Paused: Broke"])
        // A turn that needed an OK and then stopped on a problem is another thing that waits.
        XCTAssertEqual(
            ActivityGroups.announcements(from: groups(["asks": .waiting("x")]), to: groups(["asks": .broken("x")])), ["Stopped on a problem: Asks"]
        )
    }

    // MARK: - The model

    func testTheThreadsShownAreTheSignedInAccounts() async {
        var signedIn = "ada"
        let threads = [thread("mine"), thread("theirs", of: "grace")]
        let model = ActivityModel(loadThreads: { threads }, signedIn: { signedIn })
        XCTAssertNil(model.shown, "Nothing until they are read")

        await model.load()
        XCTAssertEqual(model.shown?.map(\.id), ["mine"])
        XCTAssertFalse(model.loadFailed)

        // Another account signs in: nothing of the first is shown, before or after its own are read.
        signedIn = "grace"
        XCTAssertNil(model.shown)
        await model.load()
        XCTAssertEqual(model.shown?.map(\.id), ["theirs"])
    }

    func testAReadingThatFailsLeavesWhatWasReadBefore_andSaysItFailed() async {
        var fails = false
        let threads = [thread("mine")]
        let model = ActivityModel(loadThreads: {
            if fails { throw RepositoryError.dataLocked }
            return threads
        }, signedIn: { "ada" })

        fails = true
        await model.load()
        XCTAssertTrue(model.loadFailed)
        XCTAssertNil(model.shown, "Nothing was ever read")

        fails = false
        await model.load()
        XCTAssertFalse(model.loadFailed)
        fails = true
        await model.load()
        XCTAssertTrue(model.loadFailed)
        XCTAssertEqual(model.shown?.map(\.id), ["mine"], "What was read before is still shown")
    }

    func testOnlyTheLatestReadingIsShown() async {
        let gate = Reading()
        let old = [thread("old")], new = [thread("new")]
        let model = ActivityModel(loadThreads: {
            // The first reading waits until the second is in.
            await gate.isFirst() ? await gate.heldUntilReleased(giving: old) : new
        }, signedIn: { "ada" })

        let first = Task { await model.load() }
        await gate.firstIsWaiting()
        await model.load()
        XCTAssertEqual(model.shown?.map(\.id), ["new"])
        await gate.release()
        await first.value
        XCTAssertEqual(model.shown?.map(\.id), ["new"], "The earlier reading, landing late, changes nothing")
    }
}

/// Holds the first reading until the test lets it go.
private actor Reading {
    private var readings = 0
    private var held: CheckedContinuation<Void, Never>?
    private var waitingToHear: CheckedContinuation<Void, Never>?
    private var firstWaits = false

    func isFirst() -> Bool {
        readings += 1
        return readings == 1
    }

    func heldUntilReleased(giving threads: [AICoven.Thread]) async -> [AICoven.Thread] {
        firstWaits = true
        waitingToHear?.resume()
        waitingToHear = nil
        await withCheckedContinuation { held = $0 }
        return threads
    }

    func firstIsWaiting() async {
        if !firstWaits { await withCheckedContinuation { waitingToHear = $0 } }
    }

    func release() {
        held?.resume()
        held = nil
    }
}
