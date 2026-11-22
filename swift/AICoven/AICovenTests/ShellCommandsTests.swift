@testable import AICoven
import XCTest

/// The menus for the shell: which places and scopes they offer and
/// with which keys, when the coven on screen can move, and how Search
/// Threads reaches the sidebar.
final class ShellCommandsTests: XCTestCase {
    private func coven(_ id: String) -> Coven {
        Coven(id: id, name: id.capitalized, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    func testThePlaces_keepTheCloudAppsNumbers() {
        let places = ShellCommandRules.places
        XCTAssertEqual(places.map(\.title), ["Overview", "Memory", "Agents", "Assets", "Connections"])
        XCTAssertEqual(places.map(\.item), [.overview, .memory, .agents, .assets, .connectedApps])
        // 2 is Tasks in the cloud app: kept for it.
        XCTAssertEqual(String(places.map(\.key)), "13456")
    }

    func testTheScopes_areStrixThenTheCovensInTheirOrder_nineAtMost() {
        XCTAssertEqual(ShellCommandRules.scopes(covens: []).map(\.name), ["Strix"])

        let few = ShellCommandRules.scopes(covens: [coven("work"), coven("home")])
        XCTAssertEqual(few.map(\.name), ["Strix", "Work", "Home"])
        XCTAssertEqual(few.map(\.scope), [.strix, .coven("work"), .coven("home")])
        XCTAssertEqual(String(few.map(\.key)), "123")

        let many = ShellCommandRules.scopes(covens: (1 ... 12).map { coven("c\($0)") })
        XCTAssertEqual(many.count, 9, "The digits there are")
        XCTAssertEqual(String(many.map(\.key)), "123456789")
        XCTAssertEqual(many.last?.scope, .coven("c8"))
    }

    func testTheCovenOnScreenMovesOnePlace_strixNever_andNothingPastTheEnds() {
        let covens = [coven("a"), coven("b"), coven("c")]
        func can(_ scope: ShellScope, up: Bool) -> Bool {
            ShellCommandRules.canMoveSelected(up: up, selected: scope, covens: covens)
        }
        XCTAssertFalse(can(.strix, up: true))
        XCTAssertFalse(can(.strix, up: false))
        XCTAssertFalse(can(.coven("a"), up: true), "Nothing moves above the first")
        XCTAssertTrue(can(.coven("a"), up: false))
        XCTAssertTrue(can(.coven("b"), up: true))
        XCTAssertTrue(can(.coven("b"), up: false))
        XCTAssertTrue(can(.coven("c"), up: true))
        XCTAssertFalse(can(.coven("c"), up: false))
        XCTAssertFalse(can(.coven("gone"), up: true), "A coven that is not in")

        /// Where it goes, and that going there is the move asked for.
        func moved(_ scope: ShellScope, up: Bool) -> [String]? {
            ShellCommandRules.moveTarget(up: up, selected: scope, covens: covens).map { CovenOrder.moving($0.covenID, to: $0.index, in: covens) }
        }
        XCTAssertEqual(moved(.coven("b"), up: true), ["b", "a", "c"])
        XCTAssertEqual(moved(.coven("b"), up: false), ["a", "c", "b"])
        XCTAssertEqual(moved(.coven("a"), up: false), ["b", "a", "c"])
        XCTAssertEqual(moved(.coven("c"), up: true), ["a", "c", "b"])
        XCTAssertNil(moved(.coven("a"), up: true))
        XCTAssertNil(moved(.coven("c"), up: false))
        XCTAssertNil(moved(.strix, up: false))
    }

    @MainActor
    func testSearchThreadsIsAnsweredOnce_alsoWhenAskedBeforeTheSidebarIsThere() async {
        let navigator = ShellNavigator()
        XCTAssertFalse(navigator.takeSearchRequest(), "Nothing was asked")

        // Asked while no sidebar is on screen: it waits, and is answered once.
        navigator.requestSearch()
        XCTAssertEqual(navigator.searchAsked, 1)
        XCTAssertTrue(navigator.takeSearchRequest())
        XCTAssertFalse(navigator.takeSearchRequest())

        // Asked twice before it is answered: one opening of the search.
        navigator.requestSearch()
        navigator.requestSearch()
        XCTAssertTrue(navigator.takeSearchRequest())
        XCTAssertFalse(navigator.takeSearchRequest())
        // Not a wait for anything: a test that makes a main-actor object is async with a real await, so the
        // object is released inside a task (outside one it aborts on the CI's older macOS, issue #61).
        await Task.yield()
    }
}
