internal import Combine
import Foundation

/// Whose threads and places the shell shows: Strix, the person's own space
/// (which is no stored coven here: its threads have no coven), or one of
/// their covens.
nonisolated enum ShellScope: Hashable {
    case strix
    case coven(String)

    init(covenID: String?) {
        self = covenID.map(ShellScope.coven) ?? .strix
    }

    /// The coven's id; nil for Strix.
    var covenID: String? {
        if case let .coven(id) = self { return id }
        return nil
    }
}

/// Where a sidebar row leads.
nonisolated enum ShellSidebarItem: Hashable {
    case overview
    case thread(String)
    case memory
    case agents
    case connectedApps
}

/// Navigation state for the Mac's split-view shell, as the cloud app's.
///
/// The shell shows one scope at a time: Strix or a coven. It starts on
/// Strix's Overview. Switching to a scope opens its Overview, even where a
/// thread was open in it earlier; the other places the person opens (a
/// thread, Memory, Agents, …) stay open until they move.
///
/// Owns navigation state only: no rendering, no loading, no analytics.
@MainActor
final class ShellNavigator: ObservableObject {
    /// The scope on screen.
    @Published private(set) var selected: ShellScope = .strix {
        didSet {
            guard selected != oldValue else { return }
            placeGeneration += 1
            previousVisits[selected] = arrive?(selected)
        }
    }

    /// When the person was last in each scope before they came in this
    /// time, where this device knows.
    @Published private var previousVisits: [ShellScope: Date] = [:]
    /// Notes the person arriving in a scope, and gives back when they were
    /// last there before; nil keeps no visits.
    private let arrive: ((ShellScope) -> Date?)?
    /// The app went inactive since it was last active: coming back enters
    /// the scope on screen again.
    private var wasInactive = false

    /// `arrive` notes an arrival in a scope and gives back the visit
    /// before it. The shell starts in Strix: that arrival is noted here.
    init(arrive: ((ShellScope) -> Date?)? = nil) {
        self.arrive = arrive
        previousVisits[.strix] = arrive?(.strix)
    }

    /// When the person was last in `scope` before this visit, if this
    /// device knows.
    func previousVisit(in scope: ShellScope) -> Date? {
        previousVisits[scope]
    }

    /// The app went inactive; coming back enters the scope on screen again.
    func appWentInactive() {
        wasInactive = true
    }

    /// The app is in front again, after it went inactive: the scope on
    /// screen is entered again, so its last visit reads as it was before
    /// the time away. Moves nothing.
    func appBecameActive() {
        guard wasInactive else { return }
        wasInactive = false
        previousVisits[selected] = arrive?(selected)
    }

    /// Each scope's place; none is its Overview. A scope's place changing
    /// off screen is not the person moving.
    @Published private var places: [ShellScope: WorkspaceTab] = [:] {
        didSet { if places[selected] != oldValue[selected] { placeGeneration += 1 } }
    }

    /// Advances whenever the scope on screen or its place changes, so a
    /// result that arrives late can tell whether the person has moved since.
    private(set) var placeGeneration = 0

    /// The agent a scope's new thread was asked for by name ("New Thread
    /// with Scout"), by its id; the composer otherwise chooses.
    @Published private var draftAgents: [ShellScope: String] = [:]
    /// Counts the asks for a new-thread page, so the page knows it was
    /// asked for again, also for the agent it already had.
    @Published private(set) var draftRequests = 0
    /// The latest ask from an Overview: its identity, the scope it was
    /// sent in, and the place generation then.
    private var overviewAsk: (id: UUID, scope: ShellScope, generation: Int)?

    /// The selected scope's current place; `nil` is its Overview.
    var place: WorkspaceTab? {
        places[selected]
    }

    /// The last place in `scope`, whether or not it is on screen.
    func place(in scope: ShellScope) -> WorkspaceTab? {
        places[scope]
    }

    /// The sidebar row the current place belongs to: a thread's own row,
    /// Agents for the agents and their forms, Memory for the memory and its
    /// forms, the Overview for none. Nil for a place that has no row.
    var sidebarItem: ShellSidebarItem? {
        guard let place else { return .overview }
        switch place.type {
        case let .thread(thread): return .thread(thread.id)
        case .memoryList, .memoryProposals, .addMemory, .editMemory: return .memory
        case .covenAgents, .addRole, .editRole, .personalStrixSettings: return .agents
        case .covenConnections: return .connectedApps
        // The new-thread page belongs to no row.
        default: return nil
        }
    }

    /// The current place's name for the window title: a thread's title
    /// ("Untitled" for none), any other place's own; nil on the Overview.
    var placeTitle: String? {
        guard let place else { return nil }
        return place.threadValue.map(ThreadListRules.title(of:)) ?? place.title
    }

    /// Switches to `scope` and shows its Overview, even where a thread was
    /// open in it earlier. Selecting the scope already on screen keeps its
    /// current place.
    func select(_ scope: ShellScope) {
        guard scope != selected else { return }
        selected = scope
        places[scope] = nil
    }

    /// Opens `tab` in the selected scope.
    func open(_ tab: WorkspaceTab) {
        open(tab, in: selected)
    }

    /// Switches to `scope` and opens `tab` there.
    func open(_ tab: WorkspaceTab, in scope: ShellScope) {
        selected = scope
        places[scope] = tab
    }

    /// Opens a thread where it belongs: in its coven, or in Strix.
    func open(_ thread: Thread) {
        open(.thread(thread), in: ShellScope(covenID: thread.covenId))
    }

    func showOverview() {
        places[selected] = nil
    }

    /// Opens the new-thread page in the selected scope: the thread is made
    /// when its first message is sent. `agentID` names the agent it is to
    /// go to where the person chose one; asked again without one, the
    /// composer chooses as it does.
    func requestNewThread(agentID: String? = nil) {
        draftRequests += 1
        draftAgents[selected] = agentID
        open(.draftThread(covenId: selected.covenID))
    }

    /// The agent the new thread in `scope` was asked for by name, if any.
    func draftAgent(in scope: ShellScope) -> String? {
        draftAgents[scope]
    }

    /// The new-thread page's thread was made: it is shown in place of the
    /// page, in whichever scope it was started. Only where the page still
    /// is: the person may have moved on while the thread was being made,
    /// and it then waits in the list.
    func handleCreatedThread(_ thread: Thread) {
        let scope = ShellScope(covenID: thread.covenId)
        draftAgents[scope] = nil
        guard case .draftThread = places[scope]?.type else { return }
        places[scope] = .thread(thread)
    }

    /// The person asked from the selected scope's Overview. Returns the
    /// ask's identity; the thread it starts opens only if they are still
    /// where they asked and have asked nothing since.
    func askFromOverview() -> UUID {
        let id = UUID()
        placeGeneration += 1
        overviewAsk = (id, selected, placeGeneration)
        return id
    }

    /// Opens the thread the ask `askID` started, unless the person has
    /// moved or asked again since: then it waits in its scope's list.
    func openThreadAskedFromOverview(_ thread: Thread, ask askID: UUID) {
        let scope = ShellScope(covenID: thread.covenId)
        guard let ask = overviewAsk, ask.id == askID, ask.scope == scope, ask.generation == placeGeneration else { return }
        overviewAsk = nil
        open(.thread(thread), in: scope)
    }

    /// Opens one of the selected scope's places, for its sidebar row. A
    /// thread opens with `open(_:)`. Strix's agent is Strix itself, so its
    /// Agents place is Strix's settings; Strix uses every connection, so it
    /// has no Connections place (its row leads to Settings instead).
    func openPlace(_ item: ShellSidebarItem) {
        switch (item, selected) {
        case (.overview, _): showOverview()
        case (.memory, _): open(.memoryList(covenId: selected.covenID))
        case let (.agents, .coven(covenID)): open(.covenAgents(covenId: covenID))
        case (.agents, .strix): open(.personalStrix)
        case let (.connectedApps, .coven(covenID)): open(.covenConnections(covenId: covenID))
        case (.connectedApps, .strix), (.thread, _): break
        }
    }

    /// Leaves a finished place (a saved form, a deleted item) for the place
    /// it was reached from. Does nothing if the person has moved on from it.
    func close(_ tab: WorkspaceTab) {
        guard places[selected]?.id == tab.id else { return }
        places[selected] = Self.parent(of: tab.type, in: selected)
    }

    /// Keeps a thread's stored place current after a rename.
    func updateThread(_ thread: Thread) {
        let scope = ShellScope(covenID: thread.covenId)
        if places[scope]?.threadValue?.id == thread.id {
            places[scope] = .thread(thread)
        }
    }

    /// A thread was deleted or archived: its scope falls back to the
    /// Overview.
    func removeThread(id threadID: String) {
        for (scope, tab) in places where tab.threadValue?.id == threadID {
            places[scope] = nil
        }
    }

    /// A coven is gone (deleted, or no longer among the person's covens).
    /// Drops its place and, if it was on screen, shows Strix's Overview
    /// instead.
    func handleCovenGone(covenID: String) {
        let scope = ShellScope.coven(covenID)
        places[scope] = nil
        draftAgents[scope] = nil
        if selected == scope {
            selected = .strix
            places[.strix] = nil
        }
    }

    /// Where a finished form leads back to: an agent's form to the agents,
    /// a memory's form or the proposals to the memory; anything else to the
    /// Overview.
    private static func parent(of type: WorkspaceTabType, in scope: ShellScope) -> WorkspaceTab? {
        switch type {
        case let .addRole(covenID):
            .covenAgents(covenId: covenID)
        case .editRole:
            scope.covenID.map { .covenAgents(covenId: $0) }
        case let .addMemory(covenID), let .editMemory(_, covenID), let .memoryProposals(covenID):
            .memoryList(covenId: covenID)
        default:
            nil
        }
    }
}

/// The Mac window's title for the shell's current place: "<Coven> —
/// <Place>", the place being "Overview" where none is open; "AICoven"
/// while the scope has no name yet.
nonisolated func shellWindowTitle(covenName: String?, covenPlaceTitle: String?) -> String {
    guard let covenName else { return "AICoven" }
    return "\(covenName) — \(covenPlaceTitle ?? "Overview")"
}
