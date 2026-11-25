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
    /// The person's covens, which name the places of Activity's rows, and
    /// whether they have been read yet.
    let covens: [Coven]
    let covensAreKnown: Bool
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
            // The person's own place covers the scope's (on a phone it
            // is pushed apart from this, and this shows the scope's).
            switch onOpenSwitcher == nil ? navigator.personPlace : nil {
            case let .settings(pane):
                // Made anew for each ask, so it opens at the pane now
                // asked for.
                SettingsWorkspaceView(initialPane: pane)
                    .id(navigator.personPlaceRequest)
            case .activity:
                ActivityView(navigator: navigator, covens: covens, covensAreKnown: covensAreKnown)
            case .onMe:
                TasksView(scope: .onMe, navigator: navigator, covens: covens, covensAreKnown: covensAreKnown)
            case nil:
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
                // Strix's, or the coven's on screen; while that coven is
                // not in, or it is another's, the Overview.
                if covenID == nil || coven?.id == covenID {
                    MemoryPagesView(scope: ShellScope(covenID: covenID), covenName: coven?.name ?? "Strix")
                        .id(covenID)
                        .barTitle("Memory")
                        // Once for each opening of a scope's memory.
                        .onAppear {
                            if ShellRootView.reportsUsage { AnalyticsService.shared.trackMemoryListOpened(covenId: covenID) }
                        }
                } else {
                    overview
                }
            case let .assets(covenID):
                // Strix's, or the coven's on screen; while that coven is
                // not in, or it is another's, the Overview.
                if covenID == nil || coven?.id == covenID {
                    AssetLibraryView(covenID: covenID, navigator: navigator)
                        .id(covenID)
                        .barTitle("Assets")
                } else {
                    overview
                }
            case let .tasks(covenID):
                // Strix's, or the coven's on screen; while that coven is
                // not in, or it is another's, the Overview.
                if covenID == nil || coven?.id == covenID {
                    TasksView(scope: .place(covenID: covenID), navigator: navigator)
                        .id(covenID)
                } else {
                    overview
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
                // Strix's agent is Strix itself, listed as a coven's agents
                // are and opened in the agent form.
                StrixAgentsView()
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
        // An asset's card in the thread opens it in the Assets of where it is kept.
        let chat = PersonalChatView(thread: thread, onOpenAsset: { asset in
            navigator.showAsset(asset.id, in: ShellScope(covenID: asset.covenID))
        })
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

private extension View {
    /// The place's name in the bar off the Mac, as the cloud app's page
    /// gives it: the iPad's split layout has no other, and the phone's
    /// stack gives the same. The Mac's window title names the place.
    func barTitle(_ title: String) -> some View {
        #if os(iOS)
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
