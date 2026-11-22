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

        // Anything else closes to the Overview; a place the person has moved on from is not closed.
        let memory = WorkspaceTab.memoryList(covenId: "coven_a")
        navigator.open(memory)
        XCTAssertEqual(navigator.sidebarItem, .memory)
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

    @MainActor
    func testSettingsCoversTheScopesPlace_untilThePersonMoves() {
        let navigator = ShellNavigator()
        navigator.select(.coven("work"))
        navigator.open(.thread(thread("t1", covenID: "work")))
        XCTAssertNil(navigator.personPlace)

        let before = navigator.placeGeneration
        navigator.openPersonPlace(.settings(pane: .providerKeys))
        XCTAssertEqual(navigator.personPlace, .settings(pane: .providerKeys))
        XCTAssertEqual(navigator.personPlaceRequest, 1)
        XCTAssertGreaterThan(navigator.placeGeneration, before, "The person has moved")
        // It belongs to no row of the scope's, and names the window; the scope's place waits underneath.
        XCTAssertNil(navigator.sidebarItem)
        XCTAssertEqual(navigator.placeTitle, "Settings")
        XCTAssertEqual(navigator.place?.id, "t1")
        XCTAssertEqual(navigator.selected, .coven("work"))

        // Asked for again, also for the same: shown anew.
        navigator.openPersonPlace(.settings(pane: .providerKeys))
        XCTAssertEqual(navigator.personPlaceRequest, 2)
        navigator.openPersonPlace(.settings(pane: nil))
        XCTAssertEqual(navigator.personPlace, .settings(pane: nil))
        XCTAssertEqual(navigator.personPlaceRequest, 3)

        // What is no move of the person leaves it open: a thread renamed, one deleted, a coven that is gone.
        navigator.updateThread(thread("t1", covenID: "work", title: "Renamed"))
        navigator.removeThread(id: "t1")
        navigator.handleCovenGone(covenID: "work")
        XCTAssertEqual(navigator.personPlace, .settings(pane: nil))
        XCTAssertEqual(navigator.selected, .strix)

        // Each move of the person leaves it.
        let moves: [(String, (ShellNavigator) -> Void)] = [
            ("the scope on screen, chosen again", { $0.select(.strix) }),
            ("another scope", { $0.select(.coven("home")) }),
            ("the Overview", { $0.showOverview() }),
            ("a place", { $0.openPlace(.memory) }),
            ("a thread", { $0.open(self.thread("t2", covenID: nil)) }),
            ("a new thread", { $0.requestNewThread() }),
        ]
        for (name, move) in moves {
            navigator.openPersonPlace(.settings(pane: nil))
            let generation = navigator.placeGeneration
            move(navigator)
            XCTAssertNil(navigator.personPlace, name)
            XCTAssertGreaterThan(navigator.placeGeneration, generation, name)
        }
    }

    @MainActor
    func testAThreadMadeWhileSettingsIsOpen_doesNotTakeItsPlace() {
        // Asked for from an Overview, then Settings: the thread waits in its list.
        let navigator = ShellNavigator()
        let ask = navigator.askFromOverview()
        navigator.openPersonPlace(.settings(pane: nil))
        navigator.openThreadAskedFromOverview(thread("asked", covenID: nil), ask: ask)
        XCTAssertEqual(navigator.personPlace, .settings(pane: nil))
        XCTAssertNil(navigator.place)

        // A new-thread page's thread takes the page's place underneath, and Settings stays on screen.
        navigator.requestNewThread()
        navigator.openPersonPlace(.settings(pane: nil))
        navigator.handleCreatedThread(thread("made", covenID: nil))
        XCTAssertEqual(navigator.personPlace, .settings(pane: nil))
        XCTAssertEqual(navigator.place?.id, "made")
    }

    @MainActor
    func testThePhonesStackIsTheScopesPlace_andOverItThePersonsOwn() {
        let navigator = ShellNavigator()
        XCTAssertEqual(navigator.phonePath, [], "The Overview is the root")

        // A new-thread page, then the thread it becomes: one entry throughout, so nothing is popped and pushed.
        navigator.requestNewThread()
        XCTAssertEqual(navigator.phonePath, [.place])
        navigator.handleCreatedThread(thread("made", covenID: nil))
        XCTAssertEqual(navigator.phonePath, [.place])
        XCTAssertEqual(navigator.place?.id, "made")

        // Settings over the thread; back from it shows the thread again.
        navigator.openPersonPlace(.settings(pane: nil))
        XCTAssertEqual(navigator.phonePath, [.place, .personPlace])
        navigator.leavePhoneRoutes(notIn: [.place])
        XCTAssertNil(navigator.personPlace)
        XCTAssertEqual(navigator.place?.id, "made", "The thread was underneath")
        XCTAssertEqual(navigator.phonePath, [.place])

        // Back from the thread: the Overview.
        navigator.leavePhoneRoutes(notIn: [])
        XCTAssertNil(navigator.place)
        XCTAssertEqual(navigator.phonePath, [])

        // Settings over the Overview, and back.
        navigator.openPersonPlace(.settings(pane: .providerKeys))
        XCTAssertEqual(navigator.phonePath, [.personPlace])
        navigator.leavePhoneRoutes(notIn: [])
        XCTAssertEqual(navigator.phonePath, [])

        // Everything popped at once (the stack's root is asked for).
        navigator.open(thread("t", covenID: nil))
        navigator.openPersonPlace(.settings(pane: nil))
        navigator.leavePhoneRoutes(notIn: [])
        XCTAssertNil(navigator.personPlace)
        XCTAssertNil(navigator.place)

        // Going back opens nothing, and leaves nothing that is still on the stack.
        navigator.open(thread("t", covenID: nil))
        let generation = navigator.placeGeneration
        navigator.leavePhoneRoutes(notIn: [.place, .personPlace])
        XCTAssertEqual(navigator.place?.id, "t")
        XCTAssertNil(navigator.personPlace)
        XCTAssertEqual(navigator.placeGeneration, generation, "Nothing moved")

        // Choosing another scope shows its Overview: nothing pushed.
        navigator.select(.coven("work"))
        XCTAssertEqual(navigator.phonePath, [])
        XCTAssertEqual(navigator.phonePlaceTitle, "")

        // What the bar calls the place pushed: a thread by its title, the new-thread page, a place by its button's name.
        navigator.open(thread("t", covenID: "work", title: "Plans for May"))
        XCTAssertEqual(navigator.phonePlaceTitle, "Plans for May")
        navigator.open(thread("u", covenID: "work", title: nil))
        XCTAssertEqual(navigator.phonePlaceTitle, "Untitled")
        navigator.requestNewThread()
        XCTAssertEqual(navigator.phonePlaceTitle, "New Thread")
        navigator.openPlace(.memory)
        XCTAssertEqual(navigator.phonePlaceTitle, "Memory")
        navigator.openPlace(.agents)
        XCTAssertEqual(navigator.phonePlaceTitle, "Agents")
        navigator.openPlace(.connectedApps)
        XCTAssertEqual(navigator.phonePlaceTitle, "Connections")
        // A place's forms are named as the place is.
        for form in [WorkspaceTab.addRole(covenId: "work"), .editRole(roleId: "r", roleName: "Scout")] {
            navigator.open(form)
            XCTAssertEqual(navigator.phonePlaceTitle, "Agents", form.id)
        }
        navigator.openPlace(.connectedApps)
        // Covered by Settings, the place underneath keeps its name.
        navigator.openPersonPlace(.settings(pane: nil))
        XCTAssertEqual(navigator.phonePlaceTitle, "Connections")
        navigator.select(.strix)
        navigator.openPlace(.agents)
        XCTAssertEqual(navigator.phonePlaceTitle, "Agents", "Strix's agent is Strix itself")
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
        XCTAssertEqual(shellWindowTitle(covenName: "Work", personPlace: .settings(pane: .providerKeys), covenPlaceTitle: "Plans for May"), "Work — Settings")
        XCTAssertEqual(shellWindowTitle(covenName: nil, personPlace: .settings(pane: nil), covenPlaceTitle: nil), "AICoven")
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
