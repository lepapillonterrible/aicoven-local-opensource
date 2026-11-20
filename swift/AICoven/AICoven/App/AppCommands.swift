import SwiftUI

/// What the front window's shell offers the menu bar: its scopes in the
/// person's order, and the actions behind the New and Go menus' items.
struct ShellCommandActions {
    /// The person's covens in their order (Strix, which is no stored
    /// coven here, comes before them in the menu).
    let covens: [Coven]
    /// The scope on screen.
    let selected: ShellScope
    let newThread: () -> Void
    /// The New Coven sheet, as the switcher opens it.
    let newCoven: () -> Void
    /// Shows the sidebar and opens its thread search.
    let searchThreads: () -> Void
    /// Opens a place of the scope on screen, as its sidebar row does.
    let openPlace: (ShellSidebarItem) -> Void
    let select: (ShellScope) -> Void
    /// Moves the coven on screen one place in the person's order.
    let moveSelectedCoven: (_ up: Bool) -> Void
}

/// The open thread's actions, as its Thread Actions menu runs them.
struct ThreadCommandActions {
    let isArchived: Bool
    let rename: () -> Void
    let toggleArchive: () -> Void
    let delete: () -> Void
    /// Copies the thread as Markdown; nil while a copy cannot be started.
    let copyMarkdown: (() -> Void)?
}

/// What the menus decide, apart from how they are drawn.
nonisolated enum ShellCommandRules {
    /// A place of the scope on screen, and the digit that opens it with ⌥⌘.
    struct Place: Identifiable {
        let title: String
        let item: ShellSidebarItem
        let key: Character

        var id: String {
            title
        }
    }

    /// The cloud app's places and their numbers, of which these are here:
    /// 2 (Tasks) and 5 (Assets) are kept for when they are.
    static let places: [Place] = [
        Place(title: "Overview", item: .overview, key: "1"),
        Place(title: "Memory", item: .memory, key: "3"),
        Place(title: "Agents", item: .agents, key: "4"),
        Place(title: "Connections", item: .connectedApps, key: "6"),
    ]

    /// A scope in the Go menu, and the digit that selects it with ⌘.
    struct Scope: Identifiable {
        let name: String
        let scope: ShellScope
        let key: Character

        var id: ShellScope {
            scope
        }
    }

    /// The first nine scopes: Strix, then the covens in the order given.
    static func scopes(covens: [Coven]) -> [Scope] {
        let all: [(name: String, scope: ShellScope)] = [("Strix", .strix)] + covens.map { ($0.name, .coven($0.id)) }
        return zip(all, "123456789").map { Scope(name: $0.name, scope: $0.scope, key: $1) }
    }

    /// Whether the coven on screen can move one place up, or down. Strix
    /// does not move, and nothing moves above it.
    static func canMoveSelected(up: Bool, selected: ShellScope, covens: [Coven]) -> Bool {
        guard let covenID = selected.covenID else { return false }
        return CovenOrder.canMove(covenID, up: up, in: covens)
    }

    /// The coven on screen and the place it moves to, one up or one down;
    /// nil where it cannot move.
    static func moveTarget(up: Bool, selected: ShellScope, covens: [Coven]) -> (covenID: String, index: Int)? {
        guard canMoveSelected(up: up, selected: selected, covens: covens),
              let covenID = selected.covenID,
              let index = covens.firstIndex(where: { $0.id == covenID }) else { return nil }
        return (covenID, up ? index - 1 : index + 1)
    }
}

private struct ShellCommandActionsKey: FocusedValueKey {
    typealias Value = ShellCommandActions
}

private struct ThreadCommandActionsKey: FocusedValueKey {
    typealias Value = ThreadCommandActions
}

private struct StopTurnKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    /// The front window's shell.
    var shellCommands: ShellCommandActions? {
        get { self[ShellCommandActionsKey.self] }
        set { self[ShellCommandActionsKey.self] = newValue }
    }

    /// The thread open in the front window.
    var threadCommands: ThreadCommandActions? {
        get { self[ThreadCommandActionsKey.self] }
        set { self[ThreadCommandActionsKey.self] = newValue }
    }

    /// Stops the turn running in the front window's thread; nil when
    /// there is none to stop.
    var stopTurn: (() -> Void)? {
        get { self[StopTurnKey.self] }
        set { self[StopTurnKey.self] = newValue }
    }
}

#if os(macOS)
/// The Mac's menus for the shell, as the cloud app's: New Thread and New
/// Coven under File, a Go menu and a Thread menu. An item with nothing to
/// act on in the front window is disabled, not hidden.
struct ShellCommands: Commands {
    @FocusedValue(\.shellCommands) private var shell
    @FocusedValue(\.threadCommands) private var thread
    @FocusedValue(\.stopTurn) private var stopTurn

    var body: some Commands {
        // In place of the system's New Window: ⌘N is a new thread.
        CommandGroup(replacing: .newItem) {
            Button("New Thread") { shell?.newThread() }
                .keyboardShortcut("n")
                .disabled(shell == nil)
            Button("New Coven…") { shell?.newCoven() }
                .disabled(shell == nil)
        }
        CommandMenu("Go") {
            Button("Search Threads") { shell?.searchThreads() }
                .keyboardShortcut("k")
                .disabled(shell == nil)
            Divider()
            ForEach(ShellCommandRules.places) { place in
                Button(place.title) { shell?.openPlace(place.item) }
                    .keyboardShortcut(KeyEquivalent(place.key), modifiers: [.option, .command])
                    .disabled(shell == nil)
            }
            Divider()
            ForEach(ShellCommandRules.scopes(covens: shell?.covens ?? [])) { scope in
                Button(scope.name) { shell?.select(scope.scope) }
                    .keyboardShortcut(KeyEquivalent(scope.key))
                    .disabled(shell == nil)
            }
            Divider()
            Button("Move Coven Up") { shell?.moveSelectedCoven(true) }
                .disabled(!canMove(up: true))
            Button("Move Coven Down") { shell?.moveSelectedCoven(false) }
                .disabled(!canMove(up: false))
        }
        CommandMenu("Thread") {
            Button("Rename…") { thread?.rename() }
                .disabled(thread == nil)
            Button(thread?.isArchived == true ? "Unarchive" : "Archive") { thread?.toggleArchive() }
                .keyboardShortcut("a", modifiers: [.control, .command])
                .disabled(thread == nil)
            Button("Delete…") { thread?.delete() }
                .disabled(thread == nil)
            Divider()
            Button("Copy Thread as Markdown") { thread?.copyMarkdown?() }
                .keyboardShortcut("c", modifiers: [.option, .shift, .command])
                .disabled(thread?.copyMarkdown == nil)
            Divider()
            Button("Stop") { stopTurn?() }
                .keyboardShortcut(".")
                .disabled(stopTurn == nil)
        }
    }

    private func canMove(up: Bool) -> Bool {
        guard let shell else { return false }
        return ShellCommandRules.canMoveSelected(up: up, selected: shell.selected, covens: shell.covens)
    }
}
#endif
