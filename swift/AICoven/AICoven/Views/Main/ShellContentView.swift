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
    /// Told of a thread the new-thread page made, which takes the page's
    /// place; and of one asked for from the Overview, which opens only if
    /// the person stayed there.
    let onThreadCreated: (Thread) -> Void
    let onThreadAsked: (Thread) -> Void
    let onOpenProviderKeys: () -> Void
    /// Opens the switcher from a thread's bar. Given on a phone, where this
    /// is the scope's place pushed on the stack: a thread and a new-thread
    /// page then have the phone's bar, the person's place is pushed apart
    /// from it, and nothing here is in a stack of its own.
    var onOpenSwitcher: (() -> Void)?

    var body: some View {
        Group {
            if onOpenSwitcher == nil, case let .settings(pane) = navigator.personPlace {
                // The person's own place covers the scope's. Made anew for
                // each ask, so it opens at the pane now asked for.
                SettingsWorkspaceView(initialPane: pane)
                    .id(navigator.personPlaceRequest)
            } else {
                scopePlace
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NebulaBackground())
    }

    /// The place open in the scope on screen, or else its Overview.
    private var scopePlace: some View {
        Group {
            switch navigator.place?.type {
            case let .thread(thread):
                threadPlace(thread)
                    // The same actions, for the menu bar's Thread menu.
                    .focusedSceneValue(\.threadCommands, ThreadCommandActions(
                        isArchived: thread.isArchived,
                        rename: { threadActions.renaming = thread },
                        toggleArchive: { threadActions.setArchived(thread, !thread.isArchived) },
                        delete: { threadActions.deleting = thread },
                        copyMarkdown: threadActions.canCopy ? { threadActions.copy(thread) } : nil
                    ))
            case let .draftThread(covenID):
                // A coven's page only once the coven is in: it is the
                // coven's agents the message can go to.
                if covenID == nil || coven?.id == covenID {
                    DraftThreadView(
                        coven: coven,
                        askedAgentID: navigator.draftAgent(in: navigator.selected),
                        request: navigator.draftRequests,
                        submission: drafts.submission(for: navigator.selected),
                        onThreadCreated: onThreadCreated
                    )
                    .id(navigator.selected)
                    .phoneConversationBar(title: "New Thread", onOpenSwitcher: onOpenSwitcher)
                } else {
                    overview
                }
            case let .memoryList(covenID):
                ShellMemoryPlace(covenID: covenID)
                    .id(covenID)
                    // Once for each opening of a scope's memory: outside the
                    // list, which is made anew after every save.
                    .onAppear {
                        if ShellRootView.reportsUsage { AnalyticsService.shared.trackMemoryListOpened(covenId: covenID) }
                    }
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
                    if onOpenSwitcher == nil {
                        // In a stack of its own: its title is its own, not the window's.
                        NavigationStack {
                            CovenConnectionsView(coven: coven)
                        }
                        .id(covenID)
                    } else {
                        // On a phone it is already in the stack it was pushed on.
                        CovenConnectionsView(coven: coven)
                            .id(covenID)
                    }
                } else {
                    overview
                }
            default:
                overview
            }
        }
    }

    private var overview: some View {
        ScopeOverviewView(
            navigator: navigator,
            shellThreads: shellThreads,
            threadActions: threadActions,
            submission: drafts.submission(for: navigator.selected),
            coven: coven,
            onOpenProviderKeys: onOpenProviderKeys,
            onThreadAsked: onThreadAsked
        )
        .id(navigator.selected)
    }

    /// The open thread. Tied to the thread, so each thread has its own
    /// state. It shows no header of its own: the Mac's window title names
    /// it; the iPad's bar does, with what can be done with it as the
    /// title's menu; the phone's bar does, its title opening the switcher.
    @ViewBuilder
    private func threadPlace(_ thread: Thread) -> some View {
        let chat = PersonalChatView(thread: thread)
            .id(thread.id)
        #if os(iOS)
        if let onOpenSwitcher {
            chat.phoneConversationBar(
                title: ThreadListRules.title(of: thread),
                onOpenSwitcher: onOpenSwitcher,
                onCopy: { threadActions.copy(thread) },
                canCopy: threadActions.canCopy
            )
        } else {
            chat
                // Solid chrome that is always there, so the thread scrolls
                // below the bar, not under its buttons.
                .navigationTitle(ThreadListRules.title(of: thread))
                .navigationBarTitleDisplayMode(.inline)
                .toolbarTitleMenu { threadMenu(thread) }
                .toolbarBackground(Color.aicovenChrome, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar { threadActionsMenu(thread) }
        }
        #else
        chat.toolbar { threadActionsMenu(thread) }
        #endif
    }

    /// What can be done with the open thread itself: the Mac lists these
    /// in its Thread Actions menu, the iPad under the thread's title.
    @ViewBuilder
    private func threadMenu(_ thread: Thread) -> some View {
        Button("Rename…") { threadActions.renaming = thread }
        Button(thread.isArchived ? "Unarchive" : "Archive") { threadActions.setArchived(thread, !thread.isArchived) }
        Button("Delete…", role: .destructive) { threadActions.deleting = thread }
    }

    /// The open thread's actions, a menu beside the toolbar's other buttons.
    /// On the Mac, where the window's title names the thread, it holds all
    /// of them; on the iPad, Copy, the rest being under the title.
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
                #if os(macOS)
                Divider()
                threadMenu(thread)
                #endif
            } label: {
                Label("Thread Actions", systemImage: "ellipsis.circle")
            }
            .stoneToolbarMenu()
            .help("Thread Actions")
            .accessibilityIdentifier("thread-actions")
        }
    }
}

/// The memory of the scope on screen: what is saved, or what the agents
/// have proposed to save, which the person reviews here. The list asks for
/// its forms as tabs (it was made for the window's tabs); here a form opens
/// in a sheet over it, and the list is read again when one has saved.
private struct ShellMemoryPlace: View {
    let covenID: String?
    @State private var form: MemoryForm?
    /// Counts the saves, so the list is made anew, and reads again, after each.
    @State private var saves = 0
    /// The proposals are on screen, not what is saved.
    @State private var showsProposals = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Memory View", selection: $showsProposals) {
                Text("Saved").tag(false)
                Text("Proposals").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.md)
            if showsProposals {
                // It acts on the proposals themselves and opens no form.
                // What is saved from one is in the list when that is shown
                // again: the list is made anew each time.
                MemoryProposalsView(covenId: covenID, openTabs: .constant([]), activeTabId: .constant(nil))
            } else {
                MemoryListView(covenId: covenID, openTabs: tabs, activeTabId: .constant(nil))
                    .id(saves)
            }
        }
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

// MARK: - The phone's bar over a thread

/// The phone's one-line bar over a thread or a new-thread page, as the
/// cloud app's: the title, which opens the switcher, and for a thread its
/// actions. The scope's name is not repeated.
private struct PhoneConversationBar: ViewModifier {
    let title: String
    let onOpenSwitcher: () -> Void
    /// Copies the thread as Markdown; nil where there is nothing to copy
    /// (a new-thread page).
    let onCopy: (() -> Void)?
    let canCopy: Bool

    func body(content: Content) -> some View {
        content
            .toolbarRole(.editor)
            .toolbar {
                StoneToolbarItem(placement: .principal) {
                    Button(action: onOpenSwitcher) {
                        HStack(spacing: Spacing.xxs) {
                            Text(title)
                                .font(.aicovenH2)
                                .foregroundColor(.aicovenTextPrimary)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.aicovenCaption.weight(.semibold))
                                .foregroundColor(.aicovenTextSecondary)
                        }
                        // A short title is still a target a finger finds.
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(title)
                    .accessibilityHint("Switch coven")
                    .accessibilityIdentifier("conversation-title")
                }
                if let onCopy {
                    StoneToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button(action: onCopy) {
                                Label("Copy Thread as Markdown", systemImage: "doc.on.doc")
                            }
                            .disabled(!canCopy)
                        } label: {
                            Label("Thread Actions", systemImage: "ellipsis.circle")
                        }
                        .stoneToolbarMenu()
                        .accessibilityIdentifier("thread-actions")
                    }
                }
            }
    }
}

private extension View {
    /// The phone's bar where a switcher is given to open; elsewhere the
    /// view as it is.
    @ViewBuilder
    func phoneConversationBar(
        title: String, onOpenSwitcher: (() -> Void)?, onCopy: (() -> Void)? = nil, canCopy: Bool = false
    ) -> some View {
        if let onOpenSwitcher {
            modifier(PhoneConversationBar(title: title, onOpenSwitcher: onOpenSwitcher, onCopy: onCopy, canCopy: canCopy))
        } else {
            self
        }
    }
}
