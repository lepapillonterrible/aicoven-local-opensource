@testable import AICoven
import XCTest

/// Where the Mac's shell is: one scope (Strix or a coven) and the place
/// open in it, as the cloud app's shell keeps them; and the person's own
/// order for their covens.
final class ShellNavigatorTests: XCTestCase {
    private func thread(_ id: String, covenID: String? = nil, title: String? = "A thread") -> AICoven.Thread {
        Thread(
            id: id, userId: "ada", covenId: covenID, title: title,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), lastMessageAt: nil
        )
    }

    private func coven(_ id: String, made: TimeInterval = 0) -> Coven {
        Coven(
            id: id, name: id.capitalized,
            createdAt: Date(timeIntervalSince1970: made), updatedAt: Date(timeIntervalSince1970: made)
        )
    }

    // MARK: - The navigator

    @MainActor
    func testItStartsOnStrixsOverview_andAThreadOpensWhereItBelongs() {
        let navigator = ShellNavigator()
        XCTAssertEqual(navigator.selected, .strix)
        XCTAssertNil(navigator.place, "The Overview")
        XCTAssertEqual(navigator.sidebarItem, .overview)
        XCTAssertNil(navigator.placeTitle)

        navigator.open(thread("t1", title: "Plans"))
        XCTAssertEqual(navigator.selected, .strix)
        XCTAssertEqual(navigator.place?.id, "t1")
        XCTAssertEqual(navigator.sidebarItem, .thread("t1"))
        XCTAssertEqual(navigator.placeTitle, "Plans")

        // A coven's thread opens in its coven, whatever is on screen.
        navigator.open(thread("t2", covenID: "work", title: nil))
        XCTAssertEqual(navigator.selected, .coven("work"))
        XCTAssertEqual(navigator.place?.id, "t2")
        XCTAssertEqual(navigator.placeTitle, "Untitled")
        XCTAssertEqual(navigator.place(in: .strix)?.id, "t1", "Strix keeps its own place meanwhile")
    }

    /// Switching to a scope shows its Overview, also where a thread was open
    /// in it earlier in the session.
    @MainActor
    func testSwitchingBackToAScopeShowsItsOverviewNotTheThreadOpenedThere() {
        let navigator = ShellNavigator()
        navigator.open(thread("thread_a", covenID: "coven_a"))

        navigator.select(.coven("coven_b"))
        XCTAssertNil(navigator.place)
        navigator.select(.coven("coven_a"))

        XCTAssertEqual(navigator.selected, .coven("coven_a"))
        XCTAssertNil(navigator.place, "The Overview")

        // Selecting the scope already on screen keeps its place.
        navigator.open(thread("thread_a", covenID: "coven_a"))
        navigator.select(.coven("coven_a"))
        XCTAssertEqual(navigator.place?.id, "thread_a")
        navigator.showOverview()
        XCTAssertNil(navigator.place)
    }

    @MainActor
    func testASidebarRowOpensItsPlaceInTheScopeOnScreen() {
        let navigator = ShellNavigator()

        // Strix: its memory is the personal one, its agent is Strix itself, and it has no Connections place.
        navigator.openPlace(.memory)
        XCTAssertEqual(navigator.place, .memoryList(covenId: nil))
        XCTAssertEqual(navigator.sidebarItem, .memory)
        navigator.openPlace(.agents)
        XCTAssertEqual(navigator.place, .personalStrix)
        XCTAssertEqual(navigator.sidebarItem, .agents)
        navigator.openPlace(.connectedApps)
        XCTAssertEqual(navigator.place, .personalStrix, "Strix uses every connection: nothing to open")
        navigator.openPlace(.thread("t1"))
        XCTAssertEqual(navigator.place, .personalStrix, "A thread opens by itself, not by its row's name")
        navigator.openPlace(.overview)
        XCTAssertNil(navigator.place)

        navigator.select(.coven("work"))
        navigator.openPlace(.memory)
        XCTAssertEqual(navigator.place, .memoryList(covenId: "work"))
        XCTAssertEqual(navigator.placeTitle, "Memory")
        navigator.openPlace(.agents)
        XCTAssertEqual(navigator.place, .covenAgents(covenId: "work"))
        XCTAssertEqual(navigator.placeTitle, "Agents")
        navigator.openPlace(.connectedApps)
        XCTAssertEqual(navigator.place, .covenConnections(covenId: "work"))
        XCTAssertEqual(navigator.sidebarItem, .connectedApps)
        XCTAssertEqual(navigator.placeTitle, "Connections")

        // A place with no row of its own selects none.
        navigator.open(.mcpServers)
        XCTAssertNil(navigator.sidebarItem)
    }

    @MainActor
    func testClosingAFinishedFormReturnsToWhereItWasReached() {
        let navigator = ShellNavigator()
        navigator.select(.coven("coven_a"))
        let add = WorkspaceTab.addRole(covenId: "coven_a")
        navigator.open(add)
        XCTAssertEqual(navigator.sidebarItem, .agents, "A form of the agents is under Agents")
        navigator.close(add)
        XCTAssertEqual(navigator.place, .covenAgents(covenId: "coven_a"))

        let edit = WorkspaceTab.editRole(roleId: "r1", roleName: "Scout")
        navigator.open(edit)
        navigator.close(edit)
        XCTAssertEqual(navigator.place, .covenAgents(covenId: "coven_a"))

        for form in [
            WorkspaceTab.addMemory(covenId: "coven_a"),
            .editMemory(memoryId: "m1", memoryTitle: "A note", covenId: "coven_a"),
            .memoryProposals(covenId: "coven_a"),
        ] {
            navigator.open(form)
            XCTAssertEqual(navigator.sidebarItem, .memory)
            navigator.close(form)
            XCTAssertEqual(navigator.place, .memoryList(covenId: "coven_a"))
        }

        // Anything else closes to the Overview; a place the person has moved on from is not closed.
        let memory = WorkspaceTab.memoryList(covenId: "coven_a")
        navigator.close(add)
        XCTAssertEqual(navigator.place, memory, "Not the place on screen: nothing closes")
        navigator.close(memory)
        XCTAssertNil(navigator.place)
    }

    @MainActor
    func testARenamedThreadKeepsItsPlace_andOneThatIsGoneLeavesIt() {
        let navigator = ShellNavigator()
        navigator.open(thread("s1", title: "Old"))
        navigator.open(thread("w1", covenID: "work", title: "Work"))

        // Renamed while its scope is off screen: the place kept for that scope holds the thread as it is now.
        navigator.updateThread(thread("s1", title: "New"))
        XCTAssertEqual(navigator.place(in: .strix)?.title, "New")
        XCTAssertEqual(navigator.place(in: .strix)?.threadValue?.title, "New")
        // A thread that is not open anywhere changes nothing.
        navigator.updateThread(thread("other", covenID: "work", title: "Other"))
        XCTAssertEqual(navigator.place?.id, "w1")

        // Deleted or archived: its scope falls back to the Overview, on screen or not.
        navigator.removeThread(id: "s1")
        XCTAssertNil(navigator.place(in: .strix))
        XCTAssertEqual(navigator.place?.id, "w1")
        navigator.removeThread(id: "w1")
        XCTAssertNil(navigator.place)
        XCTAssertEqual(navigator.selected, .coven("work"), "The person stays where they are")
    }

    @MainActor
    func testACovenThatIsGoneGivesWayToStrixsOverview() {
        let navigator = ShellNavigator()
        navigator.open(thread("s1"))
        navigator.open(.memoryList(covenId: "coven_a"), in: .coven("coven_a"))

        // Gone while another scope is on screen: only its place is dropped.
        navigator.select(.coven("coven_b"))
        navigator.open(.memoryList(covenId: "coven_a"), in: .coven("coven_a"))
        navigator.select(.strix)
        navigator.open(thread("s1"))
        navigator.select(.coven("coven_b"))
        navigator.handleCovenGone(covenID: "coven_a")
        XCTAssertEqual(navigator.selected, .coven("coven_b"))
        XCTAssertNil(navigator.place(in: .coven("coven_a")))

        // Gone while on screen: Strix, on its Overview, though a thread was open there earlier.
        navigator.select(.strix)
        navigator.open(thread("s1"))
        navigator.open(.memoryList(covenId: "coven_b"), in: .coven("coven_b"))
        navigator.handleCovenGone(covenID: "coven_b")
        XCTAssertEqual(navigator.selected, .strix)
        XCTAssertNil(navigator.place, "The Overview")
    }

    @MainActor
    func testThePlaceGenerationAdvancesWhenTheScopeOnScreenOrItsPlaceChanges() {
        let navigator = ShellNavigator()
        var generation = navigator.placeGeneration
        func moved(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertGreaterThan(navigator.placeGeneration, generation, what, file: file, line: line)
            generation = navigator.placeGeneration
        }

        navigator.open(thread("s1"))
        moved("Opening a thread")
        navigator.select(.coven("work"))
        moved("Switching scope")
        navigator.openPlace(.memory)
        moved("Opening a place")
        navigator.showOverview()
        moved("Going to the Overview")

        // What changes off screen changes nothing on screen.
        navigator.updateThread(thread("s1", title: "Renamed"))
        navigator.removeThread(id: "s1")
        navigator.handleCovenGone(covenID: "elsewhere")
        navigator.select(.coven("work"))
        XCTAssertEqual(navigator.placeGeneration, generation)

        // The open thread deleted, or the coven on screen gone: the place changed, though the person did not move.
        navigator.open(thread("w1", covenID: "work"))
        moved("Opening a thread")
        navigator.removeThread(id: "w1")
        moved("The open thread was deleted")
        navigator.handleCovenGone(covenID: "work")
        moved("The coven on screen is gone")
    }

    func testAScopeIsStrixOrACoven() {
        XCTAssertEqual(ShellScope(covenID: nil), .strix)
        XCTAssertEqual(ShellScope(covenID: "work"), .coven("work"))
        XCTAssertNil(ShellScope.strix.covenID)
        XCTAssertEqual(ShellScope.coven("work").covenID, "work")
    }

    // MARK: - The window's title

    func testTheWindowIsTitledByTheCovenAndThePlace() {
        XCTAssertEqual(shellWindowTitle(covenName: "Strix", covenPlaceTitle: nil), "Strix — Overview")
        XCTAssertEqual(shellWindowTitle(covenName: "Work", covenPlaceTitle: "Plans for May"), "Work — Plans for May")
        XCTAssertEqual(shellWindowTitle(covenName: nil, covenPlaceTitle: "Plans"), "AICoven", "No scope named yet")
    }

    // MARK: - The covens' order

    func testCovensAreInThePersonsOrder_andOnesItDoesNotNameFollowOldestFirst() {
        let covens = [coven("c", made: 30), coven("a", made: 10), coven("d", made: 5), coven("b", made: 20)]
        XCTAssertEqual(CovenOrder.ordered(covens, by: ["b", "a"]).map(\.id), ["b", "a", "d", "c"])
        XCTAssertEqual(CovenOrder.ordered(covens, by: []).map(\.id), ["d", "a", "b", "c"], "No order saved: oldest first")
        // An id of a coven that is gone, or named twice, is passed over.
        XCTAssertEqual(CovenOrder.ordered(covens, by: ["gone", "c", "c", "a"]).map(\.id), ["c", "a", "d", "b"])
        // Made at the same moment: a fixed order.
        XCTAssertEqual(CovenOrder.ordered([coven("y"), coven("x")], by: []).map(\.id), ["x", "y"])
    }

    func testMovingACoven() {
        let covens = [coven("a"), coven("b"), coven("c")]
        XCTAssertEqual(CovenOrder.moving("c", to: 0, in: covens), ["c", "a", "b"])
        XCTAssertEqual(CovenOrder.moving("a", to: 1, in: covens), ["b", "a", "c"])
        XCTAssertEqual(CovenOrder.moving("a", to: 99, in: covens), ["b", "c", "a"], "No further than the end")
        XCTAssertEqual(CovenOrder.moving("b", to: -3, in: covens), ["b", "a", "c"], "No further than the start")
        XCTAssertEqual(CovenOrder.moving("gone", to: 0, in: covens), ["a", "b", "c"])

        XCTAssertFalse(CovenOrder.canMove("a", up: true, in: covens))
        XCTAssertTrue(CovenOrder.canMove("a", up: false, in: covens))
        XCTAssertTrue(CovenOrder.canMove("c", up: true, in: covens))
        XCTAssertFalse(CovenOrder.canMove("c", up: false, in: covens))
        XCTAssertFalse(CovenOrder.canMove("gone", up: true, in: covens))
        XCTAssertFalse(CovenOrder.canMove("a", up: false, in: [coven("a")]))
    }

    func testTheOrderIsKeptOnTheDevice_forEachAccount() throws {
        let suite = "CovenOrderStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = CovenOrderStore(defaults: defaults)

        XCTAssertEqual(store.ids(for: "ada"), [])
        store.save(["b", "a"], for: "ada")
        XCTAssertEqual(store.ids(for: "ada"), ["b", "a"])
        XCTAssertEqual(store.ids(for: "grace"), [], "Another account has its own")
        store.save(["z"], for: "grace")
        XCTAssertEqual(store.ids(for: "ada"), ["b", "a"])
        XCTAssertEqual(CovenOrderStore(defaults: defaults).ids(for: "grace"), ["z"], "Kept across runs")
        // An account that is deleted takes its order with it; the other's stays.
        store.remove(for: "ada")
        XCTAssertEqual(store.ids(for: "ada"), [])
        XCTAssertEqual(store.ids(for: "grace"), ["z"])
    }
}
