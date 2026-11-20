import SwiftUI

/// The shell's content pane: the place open in the scope on screen (a
/// thread, the new-thread page, the memory, the agents, a coven's
/// connections), or else the scope's Overview.
struct ShellContentView: View {
    @ObservedObject var navigator: ShellNavigator
    /// The threads of the scope on screen, for its Overview.
    @ObservedObject var shellThreads: ShellThreads
    /// Rename, archive, delete and copy, for the open thread's menu.
    @ObservedObject var threadActions: ThreadActions
    /// What each scope's new-thread page holds unsent.
    let drafts: DraftThreads
    /// The coven on screen; nil for Strix, or while the covens are not in.
    let coven: Coven?
    /// Starts a thread with one of the coven's agents.
    let onNewThreadWithAgent: (Role) -> Void
    /// Told of a thread the new-thread page, or the Overview, made.
    let onThreadCreated: (Thread) -> Void
    let onOpenProviderKeys: () -> Void

    var body: some View {
        Group {
            switch navigator.place?.type {
            case let .thread(thread):
                // Its name is the window's title, so it shows none of its own.
                // Tied to the thread, so each thread has its own state.
                PersonalChatView(thread: thread, onEditAgent: nil, onBack: nil, showsHeader: false)
                    .id(thread.id)
                    .toolbar { threadActionsMenu(thread) }
            case let .draftThread(covenID):
                // A coven's page only once the coven is in: it is the
                // coven's agents the message can go to.
                if covenID == nil || coven?.id == covenID {
                    DraftThreadView(
                        coven: coven,
                        askedAgentID: navigator.draftAgent(in: navigator.selected),
                        submission: drafts.submission(for: navigator.selected),
                        onThreadCreated: onThreadCreated
                    )
                    .id(navigator.selected)
                } else {
                    overview
                }
            case let .memoryList(covenID):
                ShellMemoryPlace(covenID: covenID)
                    .id(covenID)
                    // Once for each opening of a scope's memory: outside the
                    // list, which is made anew after every save.
                    .onAppear { AnalyticsService.shared.trackMemoryListOpened(covenId: covenID) }
            case let .covenAgents(covenID):
                // Only for the coven on screen; while it is not in, or it is
                // another's, the Overview.
                if let coven, coven.id == covenID {
                    CovenAgentsView(coven: coven, onNewThread: onNewThreadWithAgent)
                        .id(covenID)
                } else {
                    overview
                }
            case .personalStrixSettings:
                // Strix's agent is Strix itself: its own settings. Closing
                // them leaves this place only if it is still the one on
                // screen: a save can end after the person has gone elsewhere.
                StrixSettingsView(onClose: { navigator.close(.personalStrix) })
                    .environmentObject(StoreService.shared)
            case let .covenConnections(covenID):
                if let coven, coven.id == covenID {
                    // In a stack of its own: its title is its own, not the window's.
                    NavigationStack {
                        CovenConnectionsView(coven: coven)
                    }
                    .id(covenID)
                } else {
                    overview
                }
            default:
                overview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NebulaBackground())
    }

    private var overview: some View {
        ScopeOverviewView(
            navigator: navigator,
            shellThreads: shellThreads,
            threadActions: threadActions,
            submission: drafts.submission(for: navigator.selected),
            coven: coven,
            onOpenProviderKeys: onOpenProviderKeys,
            onThreadCreated: onThreadCreated
        )
        .id(navigator.selected)
    }

    /// The open thread's actions, a menu beside the toolbar's other buttons:
    /// the window's title names the thread.
    @ToolbarContentBuilder
    private func threadActionsMenu(_ thread: Thread) -> some ToolbarContent {
        StoneToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    threadActions.copy(thread)
                } label: {
                    Label("Copy Thread as Markdown", systemImage: "doc.on.doc")
                }
                .disabled(!threadActions.canCopy)
                Divider()
                Button("Rename…") { threadActions.renaming = thread }
                Button(thread.isArchived ? "Unarchive" : "Archive") { threadActions.setArchived(thread, !thread.isArchived) }
                Button("Delete…", role: .destructive) { threadActions.deleting = thread }
            } label: {
                Label("Thread Actions", systemImage: "ellipsis.circle")
            }
            .stoneToolbarMenu()
            .help("Thread Actions")
            .accessibilityIdentifier("thread-actions")
        }
    }
}

/// The memory of the scope on screen. The list asks for its forms as tabs
/// (it was made for the window's tabs); here a form opens in a sheet over
/// it, and the list is read again when one has saved.
private struct ShellMemoryPlace: View {
    let covenID: String?
    @State private var form: MemoryForm?
    /// Counts the saves, so the list is made anew, and reads again, after each.
    @State private var saves = 0

    var body: some View {
        MemoryListView(covenId: covenID, openTabs: tabs, activeTabId: .constant(nil))
            .id(saves)
            .sheet(item: $form) { form in
                ShellFormSheet(onCancel: { self.form = nil }) {
                    if let memoryID = form.memoryID {
                        EditMemoryView(memoryId: memoryID, covenId: covenID) { saved(form) }
                    } else {
                        AddMemoryView(covenId: covenID) { saved(form) }
                    }
                }
            }
    }

    /// A form has saved: its sheet closes, if it is still the one on screen
    /// (a save can end after its sheet was cancelled and another opened),
    /// and the list is read again either way.
    private func saved(_ saved: MemoryForm) {
        if form == saved { form = nil }
        saves += 1
    }

    /// What the list takes for the window's tabs: it holds none, and a tab
    /// the list adds for a form opens that form.
    private var tabs: Binding<[WorkspaceTab]> {
        Binding(
            get: { [] },
            set: { tabs in
                if let asked = tabs.last.flatMap(MemoryForm.init(tab:)) { form = asked }
            }
        )
    }
}

/// One showing of a memory's form: a new memory, or one being edited. Each
/// showing is its own, so a form that saves late closes only its own sheet.
enum MemoryForm: Identifiable, Equatable {
    case add(showing: UUID)
    case edit(memoryID: String, showing: UUID)

    /// The form a tab stands for; nil for a tab that is no memory form.
    init?(tab: WorkspaceTab) {
        switch tab.type {
        case .addMemory: self = .add(showing: UUID())
        case let .editMemory(memoryID, _): self = .edit(memoryID: memoryID, showing: UUID())
        default: return nil
        }
    }

    var id: UUID {
        switch self {
        case let .add(showing), let .edit(_, showing): showing
        }
    }

    /// The memory being edited; nil for a new one.
    var memoryID: String? {
        if case let .edit(memoryID, _) = self { return memoryID }
        return nil
    }
}
