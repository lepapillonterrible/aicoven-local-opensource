@testable import AICoven
import SwiftUI
import XCTest

/// The threads the Mac's shell shows for the scope on screen, and the small
/// rules of its sidebar and toolbar.
final class ShellThreadsTests: XCTestCase {
    private func thread(_ id: String, covenID: String? = nil, title: String? = "A thread") -> AICoven.Thread {
        Thread(
            id: id, userId: "ada", covenId: covenID, title: title,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), lastMessageAt: nil
        )
    }

    /// What the store answers, by coven id ("" for Strix), and how.
    private actor Store {
        var threads: [String: [AICoven.Thread]] = [:]
        var failure: Error?
        var asked: [String?] = []
        /// Held until the test lets a reading go on, by coven id.
        var held: [String: CheckedContinuation<Void, Never>] = [:]
        var holding: Set<String> = []
        private var reached: [String: AsyncStream<Void>.Continuation] = [:]

        func set(_ threads: [AICoven.Thread], for covenID: String?) {
            self.threads[covenID ?? ""] = threads
        }

        func fail(with error: Error?) {
            failure = error
        }

        /// The next reading of `covenID` waits; the stream says when it has begun.
        func hold(_ covenID: String?) -> AsyncStream<Void> {
            let key = covenID ?? ""
            holding.insert(key)
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            reached[key] = continuation
            return stream
        }

        func release(_ covenID: String?) {
            held.removeValue(forKey: covenID ?? "")?.resume()
        }

        func load(_ covenID: String?) async throws -> [AICoven.Thread] {
            let key = covenID ?? ""
            asked.append(covenID)
            let answer = threads[key] ?? []
            let failure = failure
            if holding.remove(key) != nil {
                await withCheckedContinuation { continuation in
                    held[key] = continuation
                    reached.removeValue(forKey: key)?.yield()
                }
            }
            if let failure { throw failure }
            return answer
        }
    }

    @MainActor
    func testTheShownScopesThreadsAreRead_andAnotherScopesGoAtOnce() async {
        let store = Store()
        await store.set([thread("s1"), thread("s2")], for: nil)
        await store.set([thread("w1", covenID: "work")], for: "work")
        let threads = ShellThreads(load: { try await store.load($0) })
        XCTAssertNil(threads.scope)
        XCTAssertFalse(threads.hasLoaded)
        XCTAssertNil(threads.reload(), "Nothing to read again before a scope is asked for")

        await threads.load(.strix).value
        XCTAssertEqual(threads.threads.map(\.id), ["s1", "s2"])
        XCTAssertEqual(threads.scope, .strix)
        XCTAssertTrue(threads.hasLoaded)
        XCTAssertFalse(threads.failed)

        // Another scope: the first's threads are gone before the new ones are in.
        let reading = threads.load(.coven("work"))
        XCTAssertEqual(threads.threads, [])
        XCTAssertFalse(threads.hasLoaded, "An empty list is not yet no threads")
        XCTAssertEqual(threads.scope, .coven("work"))
        await reading.value
        XCTAssertEqual(threads.threads.map(\.id), ["w1"])
        XCTAssertTrue(threads.hasLoaded)

        // Read again in place: the list stays until the new reading is in.
        await store.set([thread("w1", covenID: "work"), thread("w2", covenID: "work")], for: "work")
        let again = threads.reload()
        XCTAssertEqual(threads.threads.map(\.id), ["w1"])
        XCTAssertTrue(threads.hasLoaded)
        await again?.value
        XCTAssertEqual(threads.threads.map(\.id), ["w1", "w2"])
        let asked = await store.asked
        XCTAssertEqual(asked, [nil, "work", "work"])
    }

    @MainActor
    func testOnlyTheLatestReadingIsShown_andOnlyForTheScopeOnScreen() async {
        let store = Store()
        await store.set([thread("s1")], for: nil)
        await store.set([thread("w1", covenID: "work")], for: "work")
        let threads = ShellThreads(load: { try await store.load($0) })

        // Strix is still being read when the person goes to a coven: Strix's threads do not land there.
        let strixBegun = await store.hold(nil)
        let early = threads.load(.strix)
        for await _ in strixBegun {
            break
        }
        await threads.load(.coven("work")).value
        XCTAssertEqual(threads.threads.map(\.id), ["w1"])
        await store.release(nil)
        await early.value
        XCTAssertEqual(threads.threads.map(\.id), ["w1"], "Another scope's reading is not shown")
        XCTAssertEqual(threads.scope, .coven("work"))

        // Of two readings of one scope, the later asked for is the one shown, whichever lands last.
        let workBegun = await store.hold("work")
        let older = threads.reload()
        for await _ in workBegun {
            break
        }
        await store.set([thread("w1", covenID: "work"), thread("w2", covenID: "work")], for: "work")
        await threads.reload()?.value
        XCTAssertEqual(threads.threads.map(\.id), ["w1", "w2"])
        await store.release("work")
        await older?.value
        XCTAssertEqual(threads.threads.map(\.id), ["w1", "w2"], "The older reading landed last and is not shown")
    }

    @MainActor
    func testAListAlreadyShownStaysWhenReadingItAgainFails_unlessItIsNoLongerThisReadersToSee() async {
        let store = Store()
        await store.set([thread("s1")], for: nil)
        let threads = ShellThreads(load: { try await store.load($0) })

        // The first reading fails: nothing is shown, and that is said.
        await store.fail(with: URLError(.cannotOpenFile))
        await threads.load(.strix).value
        XCTAssertEqual(threads.threads, [])
        XCTAssertTrue(threads.failed)
        XCTAssertTrue(threads.hasLoaded)

        // Tried again, it works.
        await store.fail(with: nil)
        await threads.reload()?.value
        XCTAssertEqual(threads.threads.map(\.id), ["s1"])
        XCTAssertFalse(threads.failed)

        // Read again and failing: the list stays as it is.
        await store.fail(with: URLError(.cannotOpenFile))
        await threads.reload()?.value
        XCTAssertEqual(threads.threads.map(\.id), ["s1"])
        XCTAssertFalse(threads.failed)

        // Locked, or another account's by now: nothing of it stays.
        await store.fail(with: RepositoryError.dataLocked)
        await threads.reload()?.value
        XCTAssertEqual(threads.threads, [])
        XCTAssertTrue(threads.failed)
        await store.fail(with: nil)
        await threads.reload()?.value
        XCTAssertEqual(threads.threads.map(\.id), ["s1"])
        await store.fail(with: RepositoryError.accountChanged)
        await threads.reload()?.value
        XCTAssertEqual(threads.threads, [])
        XCTAssertTrue(threads.failed)

        // Going to another scope starts afresh.
        await store.fail(with: nil)
        await threads.load(.coven("work")).value
        XCTAssertFalse(threads.failed)
        XCTAssertEqual(threads.threads, [])
        XCTAssertTrue(threads.hasLoaded)
    }

    // MARK: - The sidebar's and the toolbar's rules

    func testASearchShowsTheThreadsWhoseTitleHoldsWhatWasTyped() {
        let threads = [
            thread("a", title: "Plans for May"), thread("b", title: "Café notes"), thread("c", title: nil), thread("d", title: "  "),
        ]
        XCTAssertEqual(ThreadListRules.matching(threads, query: "").map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(ThreadListRules.matching(threads, query: "   ").map(\.id), ["a", "b", "c", "d"], "Nothing typed yet")
        XCTAssertEqual(ThreadListRules.matching(threads, query: "plans").map(\.id), ["a"])
        XCTAssertEqual(ThreadListRules.matching(threads, query: " MAY ").map(\.id), ["a"])
        XCTAssertEqual(ThreadListRules.matching(threads, query: "cafe").map(\.id), ["b"], "Whatever its accents")
        XCTAssertEqual(ThreadListRules.matching(threads, query: "untitled").map(\.id), ["c", "d"], "By the title its row shows")
        XCTAssertEqual(ThreadListRules.matching(threads, query: "zebra").map(\.id), [])
    }

    func testThePersonsRowSaysTheirName_elseTheirEmail_elseAccount() {
        XCTAssertEqual(ShellSidebar.personName(name: " Ada Lovelace ", email: "ada@example.com"), "Ada Lovelace")
        XCTAssertEqual(ShellSidebar.personName(name: "  ", email: "ada@example.com"), "ada@example.com")
        XCTAssertEqual(ShellSidebar.personName(name: nil, email: "ada@example.com"), "ada@example.com")
        XCTAssertEqual(ShellSidebar.personName(name: nil, email: ""), "Account")
        XCTAssertEqual(ShellSidebar.personName(name: nil, email: nil), "Account")
    }

    func testTheSwitcherNamesUpToTwoOtherScopesWithSomethingMovingOrWaiting_inItsOwnOrder() {
        func coven(_ id: String) -> Coven {
            Coven(id: id, name: id.capitalized, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        }
        let covens = [coven("work"), coven("hiring"), coven("home")]
        let current: [ShellScope: ConversationActivity] = [
            .strix: .moving("Thinking"), .coven("work"): .moving("2 moving"), .coven("hiring"): .waiting("Needs your OK"),
            .coven("home"): .moving("Reading"),
        ]
        func names(_ selected: ShellScope) -> [String] {
            ShellSidebar.othersCurrent(covens: covens, selected: selected, current: current).map(\.name)
        }
        XCTAssertEqual(names(.strix), ["Work", "Hiring"], "Not the scope on screen; two at most")
        XCTAssertEqual(names(.coven("work")), ["Strix", "Hiring"], "Strix first")
        XCTAssertEqual(names(.coven("home")), ["Strix", "Work"])
        let others = ShellSidebar.othersCurrent(covens: covens, selected: .strix, current: [.coven("home"): .moving("Reading")])
        XCTAssertEqual(others.map(\.name), ["Home"])
        XCTAssertEqual(others.first?.current, .moving("Reading"))
        XCTAssertTrue(ShellSidebar.othersCurrent(covens: covens, selected: .strix, current: [.strix: .moving("Thinking")]).isEmpty)
    }

    func testWhatVoiceOverReadsAfterAScopesNameInTheSwitcher() {
        XCTAssertEqual(CovenSwitcherList.accessibilityValue(current: nil, unread: false), "")
        XCTAssertEqual(CovenSwitcherList.accessibilityValue(current: nil, unread: true), "Unread")
        XCTAssertEqual(CovenSwitcherList.accessibilityValue(current: .moving("Reading"), unread: false), "Reading")
        XCTAssertEqual(CovenSwitcherList.accessibilityValue(current: .waiting("Needs your OK"), unread: true), "Needs your OK, Unread")
    }

    func testTheSidebarShowsUnlessTheSplitViewShowsTheDetailOnly() {
        XCTAssertTrue(StoneSidebarToggle.isShowing(.automatic))
        XCTAssertTrue(StoneSidebarToggle.isShowing(.all))
        XCTAssertTrue(StoneSidebarToggle.isShowing(.doubleColumn))
        XCTAssertFalse(StoneSidebarToggle.isShowing(.detailOnly))
    }
}
