@testable import AICoven
import XCTest

/// A scope's Overview, as the cloud app's: when the person was last here
/// (kept on the device), and which threads it lists where.
final class ScopeOverviewTests: XCTestCase {
    private func thread(_ id: String, archived: Bool = false, used: TimeInterval) -> AICoven.Thread {
        Thread(
            id: id, userId: "ada", covenId: nil, title: id, isArchived: archived,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
            lastMessageAt: Date(timeIntervalSince1970: used)
        )
    }

    func testTheOverviewListsTheThreadsStillOpen_thenTheEarlierOnes_andNoneArchived() {
        let threads = [
            thread("old-open", used: 10), thread("new", used: 400), thread("new-open", used: 300),
            thread("old", used: 20), thread("put-away-open", archived: true, used: 500),
        ]
        let lists = ThreadListRules.overview(threads) { $0.id.hasSuffix("open") }
        XCTAssertEqual(lists.stillOpen.map(\.id), ["new-open", "old-open"], "Newest first")
        XCTAssertEqual(lists.earlier.map(\.id), ["new", "old"])
        let none = ThreadListRules.overview([thread("put-away", archived: true, used: 1)]) { _ in true }
        XCTAssertTrue(none.stillOpen.isEmpty && none.earlier.isEmpty, "A thread put away is on neither list")
    }

    func testWhileYouWereAwayListsTheRepliesNotSeenThatCameSinceTheLastVisit_latestFirst() {
        let threads = [
            thread("before", used: 100), thread("after", used: 600), thread("latest", used: 900),
            thread("put-away", archived: true, used: 950), thread("seen", used: 990),
        ]
        let unread: [String: Date] = [
            "before": Date(timeIntervalSince1970: 100), "after": Date(timeIntervalSince1970: 600),
            "latest": Date(timeIntervalSince1970: 900), "put-away": Date(timeIntervalSince1970: 950),
            "elsewhere": Date(timeIntervalSince1970: 999),
        ]
        let lastVisit = Date(timeIntervalSince1970: 500)
        let away = ThreadListRules.away(threads, unreadReplyAt: unread, since: lastVisit)
        XCTAssertEqual(away.map(\.thread.id), ["latest", "after"], "Not the one from before, the one put away, the one seen, or another scope's")
        XCTAssertEqual(away.first?.repliedAt, Date(timeIntervalSince1970: 900))
        // At the very moment of the visit it was seen; a first visit knows no "away".
        XCTAssertTrue(ThreadListRules.away(threads, unreadReplyAt: unread, since: Date(timeIntervalSince1970: 900)).isEmpty)
        XCTAssertTrue(ThreadListRules.away(threads, unreadReplyAt: unread, since: nil).isEmpty)
        XCTAssertTrue(ThreadListRules.away(threads, unreadReplyAt: [:], since: lastVisit).isEmpty)

        XCTAssertEqual(ThreadListRules.replyDetail(agentName: "Scout"), "Scout replied")
        XCTAssertEqual(ThreadListRules.replyDetail(agentName: "  "), "New reply")
        XCTAssertEqual(ThreadListRules.replyDetail(agentName: nil), "New reply")
    }

    func testTheOverviewSaysWhenThePersonWasLastHere() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        // Wednesday 18 November 2026, 15:00.
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 15)))
        func last(_ ago: TimeInterval) -> String {
            VisitWords.lastHere(now.addingTimeInterval(-ago), now: now, calendar: calendar)
        }
        let hour: TimeInterval = 3600
        // In the calendar the days are counted in, whatever the device's own.
        var style = Date.FormatStyle.dateTime
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        XCTAssertEqual(last(2 * hour), "You were last here earlier today.")
        XCTAssertEqual(last(14 * hour), "You were last here earlier today.", "01:00 the same day")
        XCTAssertEqual(last(16 * hour), "You were last here yesterday.", "23:00 the day before, whatever the hours between")
        XCTAssertEqual(last(39 * hour), "You were last here yesterday.")

        // Within the week: the day's name; then the day and month; another year, with the year.
        let friday = now.addingTimeInterval(-5 * 24 * hour)
        XCTAssertEqual(last(5 * 24 * hour), "You were last here on \(friday.formatted(style.weekday(.wide))).")
        let weeksAgo = now.addingTimeInterval(-20 * 24 * hour)
        XCTAssertEqual(last(20 * 24 * hour), "You were last here on \(weeksAgo.formatted(style.day().month(.wide))).")
        let lastYear = now.addingTimeInterval(-400 * 24 * hour)
        XCTAssertEqual(last(400 * 24 * hour), "You were last here on \(lastYear.formatted(style.day().month(.wide).year())).")
        // The day is named in the calendar's own time zone, whatever the device's. Two zones 25 hours apart never
        // share a calendar day, so the device's own zone agrees with one of them at most: naming the day in the
        // device's zone would get the other wrong.
        var names: Set<String> = []
        for zone in ["Pacific/Kiritimati", "Pacific/Pago_Pago"] {
            var far = Calendar(identifier: .gregorian)
            far.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            var farStyle = Date.FormatStyle.dateTime
            farStyle.calendar = far
            farStyle.timeZone = far.timeZone
            let visit = now.addingTimeInterval(-4 * 24 * hour)
            let day = visit.formatted(farStyle.weekday(.wide))
            XCTAssertEqual(VisitWords.lastHere(visit, now: now, calendar: far), "You were last here on \(day).", zone)
            names.insert(day)
        }
        XCTAssertEqual(names.count, 2, "The two zones name different days for the same moment")
        // Seven days is no longer "on Wednesday".
        let weekAgo = now.addingTimeInterval(-7 * 24 * hour)
        XCTAssertEqual(last(7 * 24 * hour), "You were last here on \(weekAgo.formatted(style.day().month(.wide))).")
    }

    func testVisitsAreKeptOnTheDevice_forEachAccountAndScope() throws {
        let suite = "ScopeVisitStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = ScopeVisitStore(defaults: defaults)
        let monday = Date(timeIntervalSince1970: 1_790_000_000)
        let tuesday = monday.addingTimeInterval(86400)

        XCTAssertNil(store.lastVisit(in: .strix, for: "ada"))
        XCTAssertNil(store.arrive(in: .strix, at: monday, for: "ada"), "The first visit has none before it")
        XCTAssertEqual(store.arrive(in: .strix, at: tuesday, for: "ada"), monday, "The visit before this one")
        XCTAssertEqual(store.lastVisit(in: .strix, for: "ada"), tuesday)
        XCTAssertNil(store.arrive(in: .coven("work"), at: tuesday, for: "ada"), "Each scope has its own")
        XCTAssertNil(store.lastVisit(in: .strix, for: "grace"), "And each account")
        store.arrive(in: .strix, at: monday, for: "grace")

        // A coven that is gone takes its own visits along, and nobody else's.
        store.arrive(in: .coven("gone"), at: monday, for: "ada")
        store.arrive(in: .coven("gone"), at: monday, for: "grace")
        store.forget(.coven("gone"), for: "ada")
        XCTAssertNil(store.lastVisit(in: .coven("gone"), for: "ada"))
        XCTAssertEqual(store.lastVisit(in: .coven("gone"), for: "grace"), monday)

        // Kept across runs; an account that is deleted takes its visits with it.
        XCTAssertEqual(ScopeVisitStore(defaults: defaults).lastVisit(in: .coven("work"), for: "ada"), tuesday)
        store.remove(for: "ada")
        XCTAssertNil(store.lastVisit(in: .strix, for: "ada"))
        XCTAssertNil(store.lastVisit(in: .coven("work"), for: "ada"))
        XCTAssertEqual(store.lastVisit(in: .strix, for: "grace"), monday)
    }

    @MainActor
    func testWhatAnOverviewWithNoThreadsSays_isTrueOfWhatIsOnScreen() {
        // Asking is offered on Strix and in a coven that is in; not in a coven that is not in yet (or no longer).
        let coven = Coven(id: "work", name: "Work", createdAt: Date(), updatedAt: Date())
        XCTAssertTrue(ScopeOverviewView.canAsk(in: .strix, coven: nil))
        XCTAssertTrue(ScopeOverviewView.canAsk(in: .coven("work"), coven: coven))
        XCTAssertFalse(ScopeOverviewView.canAsk(in: .coven("work"), coven: nil))

        // "Ask below" is said only where there is a composer below; "yet" only where there are no threads at all.
        XCTAssertEqual(ScopeOverviewView.emptyLine(hasArchived: false, canAsk: true), "No threads yet. Ask below to start one.")
        XCTAssertEqual(ScopeOverviewView.emptyLine(hasArchived: false, canAsk: false), "No threads yet.")
        XCTAssertEqual(ScopeOverviewView.emptyLine(hasArchived: true, canAsk: true), "No open threads. Ask below to start one.")
        XCTAssertEqual(ScopeOverviewView.emptyLine(hasArchived: true, canAsk: false), "No open threads.")
    }

    @MainActor
    func testTheNavigatorNotesEachArrival_andKnowsTheVisitBefore() {
        // A device that was in each scope at the times given.
        var visits: [ShellScope: Date] = [.strix: Date(timeIntervalSince1970: 100), .coven("work"): Date(timeIntervalSince1970: 200)]
        var clock = Date(timeIntervalSince1970: 1000)
        var arrivals: [ShellScope] = []
        let navigator = ShellNavigator(arrive: { scope in
            arrivals.append(scope)
            let before = visits[scope]
            visits[scope] = clock
            return before
        })

        // The shell starts in Strix: that is an arrival.
        XCTAssertEqual(arrivals, [.strix])
        XCTAssertEqual(navigator.previousVisit(in: .strix), Date(timeIntervalSince1970: 100))
        XCTAssertNil(navigator.previousVisit(in: .coven("work")), "Not entered yet")

        clock = Date(timeIntervalSince1970: 2000)
        navigator.select(.coven("work"))
        XCTAssertEqual(navigator.previousVisit(in: .coven("work")), Date(timeIntervalSince1970: 200))
        navigator.select(.coven("home"))
        XCTAssertNil(navigator.previousVisit(in: .coven("home")), "Never here before")
        XCTAssertEqual(arrivals, [.strix, .coven("work"), .coven("home")])

        // Moving within a scope, or selecting it again, is no new arrival.
        navigator.openPlace(.memory)
        navigator.select(.coven("home"))
        navigator.showOverview()
        XCTAssertEqual(arrivals.count, 3)

        // Back to Strix: the visit before is the one this run began with.
        clock = Date(timeIntervalSince1970: 3000)
        navigator.select(.strix)
        XCTAssertEqual(navigator.previousVisit(in: .strix), Date(timeIntervalSince1970: 1000))

        // Coming back to the app after it went inactive enters the scope on screen again; without that, nothing.
        clock = Date(timeIntervalSince1970: 4000)
        navigator.appBecameActive()
        XCTAssertEqual(arrivals.count, 4, "It was never away")
        navigator.appWentInactive()
        navigator.appBecameActive()
        XCTAssertEqual(arrivals.last, .strix)
        XCTAssertEqual(navigator.previousVisit(in: .strix), Date(timeIntervalSince1970: 3000))
        navigator.appBecameActive()
        XCTAssertEqual(arrivals.count, 5, "Once for each time away")

        // A navigator that keeps no visits knows none.
        XCTAssertNil(ShellNavigator().previousVisit(in: .strix))
    }
}
