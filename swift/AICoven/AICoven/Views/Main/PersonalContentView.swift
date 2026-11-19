import SwiftUI

/// Content view for personal threads in the local workspace.
struct PersonalContentView: View {
    @Binding var selectedThread: Thread?
    @Binding var openTabs: [WorkspaceTab]
    @Binding var activeTabId: String?

    // Callbacks from parent
    var onNewChat: (() -> Void)?
    var onCreateCoven: (() -> Void)?

    var activeTab: WorkspaceTab? {
        openTabs.first(where: { $0.id == activeTabId })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar + profile menu (or just profile menu if no tabs)
            if openTabs.isEmpty {
                HStack {
                    Spacer()
                    ProfileMenuView(onOpenTab: openTab)
                        .frame(width: 44, height: 44)
                        .padding(.trailing, Spacing.xs)
                }
                .frame(height: 44)
                .background(Color.aicovenGlass)
            } else {
                HStack(spacing: 0) {
                    // Tab bar
                    WorkspaceTabBar(
                        openTabs: $openTabs,
                        activeTabId: $activeTabId
                    )
                    .frame(maxWidth: .infinity)

                    // Profile menu
                    ProfileMenuView(onOpenTab: openTab)
                        .frame(width: 44, height: 44)
                        .padding(.trailing, Spacing.xs)
                }
                .frame(height: 44)
                .background(
                    VStack(spacing: 0) {
                        Color.aicovenGlass
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.aicovenBorder,
                                        Color.clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: 1)
                    }
                )
            }

            // Content area
            if let tab = activeTab {
                renderTabContent(tab)
            } else {
                // Welcome state - no tab open
                WelcomeToPersonalChat(
                    onNewChat: {
                        AnalyticsService.shared.trackNewChatTapped(source: "personal_content_view")
                        onNewChat?()
                    },
                    onCreateCoven: { onCreateCoven?() },
                    onOpenProviderKeys: { openTab(.providerKeys) }
                )
            }
        }
        // Track tab switches using .onChange for reliable analytics
        .onChange(of: activeTabId) { oldTabId, newTabId in
            guard let newTabId,
                  let oldTabId,
                  newTabId != oldTabId else { return }

            // Look up tab types at the point of change, when both are still valid
            let fromTabType = openTabs.first(where: { $0.id == oldTabId })?.type.analyticsName ?? "unknown"
            let toTabType = openTabs.first(where: { $0.id == newTabId })?.type.analyticsName ?? "unknown"

            AnalyticsService.shared.trackTabSwitched(fromTab: fromTabType, toTab: toTabType)
        }
    }

    @ViewBuilder
    private func renderTabContent(_ tab: WorkspaceTab) -> some View {
        switch tab.type {
        case let .thread(thread):
            // Tie the chat view's identity to the thread so switching tabs on
            // macOS correctly refreshes the content and state for each thread.
            PersonalChatView(
                thread: thread,
                onEditAgent: {
                    openTab(.personalStrixSettings)
                },
                onBack: nil
            )
            .id(thread.id)
        case .mcpServers:
            MCPServerManagementView()
                .onAppear { AnalyticsService.shared.trackMCPServersOpened() }
        case .personalStrixSettings:
            StrixSettingsView(
                onClose: {
                    // When the user saves Strix settings from a tab, close that tab
                    // and fall back to the most recently opened remaining tab.
                    if let index = openTabs.firstIndex(where: { $0.id == tab.id }) {
                        openTabs.remove(at: index)
                    }
                    if openTabs.isEmpty {
                        activeTabId = nil
                    } else if activeTabId == tab.id {
                        activeTabId = openTabs.last?.id
                    }
                }
            )
            .environmentObject(StoreService.shared)
        case let .memoryList(covenId):
            // Personal memory list for the local workspace (no coven).
            MemoryListView(
                covenId: covenId,
                openTabs: $openTabs,
                activeTabId: $activeTabId
            )
            .onAppear { AnalyticsService.shared.trackMemoryListOpened(covenId: covenId) }
        case let .memoryProposals(covenId):
            // For the personal workspace, `covenId` will be nil. The same
            // view can also be reused for coven-scoped proposals in the
            // future by passing a non-nil covenId.
            MemoryProposalsView(
                covenId: covenId,
                openTabs: $openTabs,
                activeTabId: $activeTabId
            )
            .onAppear { AnalyticsService.shared.trackMemoryProposalViewed() }
        default:
            EmptyView()
        }
    }

    private func openTab(_ type: WorkspaceTabType) {
        if AppState.shared.openSettings(for: type) { return }

        // Check if tab already open (this is a tab switch, not a new tab)
        if let existingTab = openTabs.first(where: { $0.type == type }) {
            // Note: Tab switch analytics are handled by .onChange(of: activeTabId)
            // in the view body, which fires reliably when activeTabId changes.
            activeTabId = existingTab.id
            return
        }

        // Create new tab
        let tab: WorkspaceTab
        switch type {
        case let .thread(thread):
            tab = .thread(thread)
        case .mcpServers:
            tab = .mcpServers
        case .personalStrixSettings:
            tab = WorkspaceTab.personalStrix
        case let .memoryList(covenId):
            tab = WorkspaceTab.memoryList(covenId: covenId)
        case let .memoryProposals(covenId):
            tab = WorkspaceTab.memoryProposals(covenId: covenId)
        default:
            return
        }

        openTabs.append(tab)
        activeTabId = tab.id
        AnalyticsService.shared.trackTabOpened(tabType: tab.type.analyticsName)
    }
}

/// Welcome screen for personal workspace
struct WelcomeToPersonalChat: View {
    let onNewChat: () -> Void
    let onCreateCoven: () -> Void
    let onOpenProviderKeys: () -> Void

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            // Static icon instead of animated cauldron
            IconBadge(icon: "sparkles", size: 100, color: .aicovenTeal)

            VStack(spacing: Spacing.md) {
                Text("Welcome to AICoven")
                    .font(.aicovenDisplayMedium)
                    .foregroundColor(.aicovenTextPrimary)

                Text("Start a new conversation or create a coven to collaborate with multiple AI roles")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }

            // Quick actions - now clickable
            HStack(spacing: Spacing.md) {
                Button(action: onNewChat) {
                    VStack(spacing: Spacing.sm) {
                        IconBadge(icon: "message", size: 60, color: .aicovenTeal)
                        Text("Personal Chat")
                            .font(.aicovenBodyMedium)
                            .foregroundColor(.aicovenTextPrimary)
                        Text("One-on-one with AI")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextTertiary)
                    }
                    .frame(width: 200, height: 160)
                    .glassMorphism()
                }
                .buttonStyle(.plain)

                Button(action: onCreateCoven) {
                    VStack(spacing: Spacing.sm) {
                        IconBadge(icon: "person.3", size: 60, color: .aicovenPurple)
                        Text("Create Coven")
                            .font(.aicovenBodyMedium)
                            .foregroundColor(.aicovenTextPrimary)
                        Text("Multi-AI collaboration")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextTertiary)
                    }
                    .frame(width: 200, height: 160)
                    .glassMorphism()
                }
                .buttonStyle(.plain)
            }

            // Provider keys call-to-action when no keys are configured
            AddProviderKeysCard(onOpenProviderKeys: onOpenProviderKeys)
                .padding(.top, Spacing.lg)
                .padding(.horizontal, Spacing.xl)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Personal chat view using the same enhanced streaming tooling as coven chats
struct PersonalChatView: View {
    let thread: Thread
    let onEditAgent: (() -> Void)?
    /// Optional back handler used on iOS mobile to navigate back to the
    /// threads list without relying on a NavigationStack.
    let onBack: (() -> Void)?

    @State private var messages: [ChatMessage] = []
    @State private var messageText = ""
    /// The files chosen to go with the message being written.
    @State private var attachments: [FileAttachmentDetail] = []
    /// The thread's draft is being read into the composer: what the
    /// composer holds meanwhile is not yet the thread's to keep.
    @State private var isRestoringDraft = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var errorMessage: String?
    /// The engine runs the replies; this view shows the one in its thread.
    @ObservedObject private var turns = TurnEngine.shared
    /// What turns, in this thread or another, are waiting to be allowed.
    @ObservedObject private var approvals = ToolApprovals.shared
    /// The thread this view's state belongs to. The view is reused when the
    /// thread changes, so work that waited checks it before touching state.
    @State private var shownThreadID: String?
    /// The number of the last of the engine's additions to the thread
    /// that this view has taken in: later ones are shown as they come.
    @State private var additionsShown = 0
    /// The work traces of this thread's finished turns, by the id of the
    /// message each ended with: the receipt under a reply opens its trace.
    @State private var traces: [String: WorkTrace] = [:]
    /// The work trace Details is showing.
    @State private var shownTrace: WorkTraceTarget?
    @State private var canEditAgent: Bool = true

    /// The reply on its way in this thread, if there is one.
    private var runningTurn: TurnEngine.Activity? {
        turns.running[thread.id]
    }

    // Pagination state for message history
    @State private var isInitialLoading: Bool = false
    @State private var didLoadInitialMessages: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var hasMoreMessages: Bool = true
    @State private var oldestMessageId: String? = nil
    @State private var isPrependingMessages: Bool = false
    @State private var pendingScrollAnchorId: String? = nil
    private let pageSize: Int = 20

    var body: some View {
        VStack(spacing: 0) {
            // Chat header
            PersonalChatHeader(
                thread: thread,
                canEditAgent: canEditAgent,
                onEditAgent: onEditAgent,
                onBack: onBack
            )
            #if os(iOS)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            #else
            .padding(Spacing.md)
            #endif

            GradientDivider()

            // Messages area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Spacing.md) {
                        // Load-more sentinel at the top. This appears above the
                        // oldest loaded message and triggers when the user
                        // scrolls to the top of the currently loaded history.
                        if hasMoreMessages {
                            Button {
                                guard !isLoadingMore else { return }
                                Task {
                                    await loadMoreMessagesIfNeeded()
                                }
                            } label: {
                                HStack {
                                    Spacer()
                                    if isLoadingMore {
                                        // Show a spinner only while we are actually
                                        // fetching the next page of history.
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Text("Tap to load more messages")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, Spacing.sm)
                            }
                            .buttonStyle(.plain)
                            .id("load-more-sentinel-\(oldestMessageId ?? "none")")
                        }

                        // stable element UUID to allow SwiftUI caching of older history.
                        ForEach(Array(enhancedMessages.enumerated()), id: \.element.id) { _, em in
                            // What the turn asked on the way to this reply,
                            // and the answer it was given.
                            approvalLines(traces[em.id]?.approvals ?? [])
                            RichMessageBubble(
                                message: em,
                                onApproveToolCall: { _ in },
                                onRejectToolCall: { _ in }
                            )
                            .id(em.id)
                            // What it took: opens the steps behind the reply.
                            if let trace = traces[em.id], let receipt = trace.receipt {
                                Button(receipt) {
                                    shownTrace = .finished(messageID: em.id, trace: trace)
                                }
                                .buttonStyle(.textLink)
                                .font(.aicovenBodySmall)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityHint("Shows the steps behind this answer")
                            }
                        }

                        // The reply on its way: one line saying what it
                        // is doing, with Details and Stop.
                        if let runningTurn {
                            approvalLines(approvals.answered[thread.id] ?? [])
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                HStack(spacing: 6) {
                                    Image(systemName: "sparkles")
                                    // Show "Strix" for the default personal assistant
                                    Text(thread.agentName ?? "Strix")
                                }
                                .font(.caption)
                                .foregroundStyle(Color.aicovenTeal)

                                TurnStatusLineView(
                                    turn: runningTurn,
                                    needsOK: approvals.askingThreadIDs.contains(thread.id),
                                    onDetails: { shownTrace = .running(threadID: thread.id, turnID: runningTurn.turnID) },
                                    onStop: { turns.stop(threadID: thread.id) }
                                )
                            }
                            .frame(maxWidth: 800, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("thinking-indicator")
                        }

                        // What was sent while that reply runs, waiting
                        // for it, in the order it will go.
                        ForEach(waitingMessages) { waiting in
                            WaitingMessageBubble(
                                message: waiting,
                                isNext: waiting.id == waitingMessages.first?.id,
                                isBeingSent: turns.starting[thread.id] == waiting.id,
                                agentName: thread.agentName ?? "Strix",
                                onEdit: { turns.editWaiting(waiting.id, threadID: thread.id) },
                                onRemove: { turns.removeWaiting(waiting.id, threadID: thread.id) }
                            )
                            .id(waiting.id)
                        }
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.top, Spacing.lg)
                    .padding(.bottom, Spacing.xxl)
                }
                #if os(iOS)
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                }
                #endif
                .onChange(of: messages.count) { _, _ in
                    // When we're prepending older messages, keep the previously
                    // visible first message pinned in place instead of jumping
                    // to the newest message.
                    if isPrependingMessages, let anchorId = pendingScrollAnchorId {
                        withAnimation {
                            proxy.scrollTo(anchorId, anchor: .top)
                        }
                        isPrependingMessages = false
                        pendingScrollAnchorId = nil
                        return
                    }

                    // Otherwise, scroll to the last message when new messages arrive.
                    if let lastMessage = enhancedMessages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: runningTurn?.turnID) { _, started in
                    if started != nil {
                        withAnimation {
                            proxy.scrollTo("thinking-indicator", anchor: .bottom)
                        }
                    }
                }
                // A turn ended here, or a waiting message was sent: each
                // goes at the end of the thread at once, in the order the
                // engine added them, however many there were since this
                // view last looked.
                .onChange(of: turns.additions[thread.id]?.last?.sequence) { _, _ in
                    showAdditions()
                }
                // Only when one starts waiting, not when one is removed.
                .onChange(of: waitingMessages.count) { before, now in
                    guard now > before, let added = waitingMessages.last?.id else { return }
                    withAnimation {
                        proxy.scrollTo(added, anchor: .bottom)
                    }
                }
                .onAppear {
                    if let lastMessage = enhancedMessages.last {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
            // Approvals come here, from this thread or any other: laid over
            // the thread so it never moves, at the right just above the
            // composer, across the width on the iPhone.
            .overlay(alignment: .bottomTrailing) {
                ApprovalSpot(approvals: approvals)
                    .frame(maxWidth: ApprovalBlock.spansTheWidth ? .infinity : 262)
                    .padding(.horizontal, ApprovalBlock.spansTheWidth ? Spacing.md : 18)
                    .padding(.bottom, Spacing.xs)
            }

            GradientDivider()

            // The field stays open while a turn runs; what is sent then
            // waits for the turn, and comes back here if it is not sent.
            MessageComposer(
                messageText: $messageText,
                attachments: $attachments,
                onSend: { attachments in await sendMessage(attachments: attachments) },
                onStop: { turns.stop(threadID: thread.id) },
                isAgentRunning: runningTurn != nil,
                isStopping: runningTurn?.isStopping == true,
                threadId: thread.id,
                autoFocus: true,
                recipientName: thread.agentName ?? "Strix",
                notice: turns.notSent[thread.id],
                // Once this thread's own draft is in the field: what was
                // handed back before then comes with it.
                hasReturnedDraft: turns.returned[thread.id] != nil && !isRestoringDraft && shownThreadID == thread.id,
                takeReturnedDraft: { turns.takeReturned(threadID: thread.id) }
            )
            .padding(Spacing.md)
        }
        #if os(iOS)
        .background(NebulaBackground())
        #endif
        .sheet(item: $shownTrace) { target in
            WorkTraceSheet(target: target)
        }
        // When the bound thread changes (e.g. user switches tabs on macOS),
        // reset and reload the messages/provider keys for the new thread.
        .task(id: thread.id) {
            shownThreadID = thread.id
            // The composer shows this thread's own draft; the one it held
            // was kept as it was typed, and is saved now.
            isRestoringDraft = true
            messageText = ""
            attachments = []
            Task { await ComposerDrafts.shared.saveNow() }
            // Counted for this thread from here, before anything waits:
            // what the engine added before is among the messages read
            // below, and what it adds from now on is shown as it comes.
            additionsShown = turns.additions[thread.id]?.last?.sequence ?? 0
            messages = []
            traces = [:]
            shownTrace = nil
            isInitialLoading = false
            didLoadInitialMessages = false
            isLoadingMore = false
            hasMoreMessages = true
            oldestMessageId = nil
            isPrependingMessages = false
            pendingScrollAnchorId = nil

            await restoreDraft()
            await TurnEngine.shared.settleInterruptedTurns(threadID: thread.id)
            await loadStoredThread()
            // The view can have moved to another thread while this one was
            // read: its unsent text stays kept for when it is opened again.
            guard shownThreadID == thread.id else { return }
            if let unsent = TurnEngine.shared.takeUnsent(for: thread.id) {
                giveBack(unsent.text, because: unsent.reason)
            }
            await loadProviderKeys()
        }
        // What the composer holds is the thread's draft, kept as it changes.
        .onChange(of: messageText) { _, _ in keepDraft() }
        .onChange(of: attachments) { _, _ in keepDraft() }
        // Leaving the foreground, or the thread: saved now, not a moment
        // later.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                Task { await ComposerDrafts.shared.saveNow() }
            }
        }
        .onDisappear {
            Task { await ComposerDrafts.shared.saveNow() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .providerKeysUpdated)) { _ in
            Task {
                await loadProviderKeys()
            }
        }
    }

    /// Reads the thread's draft into the composer: what its waiting
    /// messages handed back while it was off screen, then what was kept of
    /// what was typed there, then what was typed while that was read.
    private func restoreDraft() async {
        let threadID = thread.id
        let kept = await ComposerDrafts.shared.draft(for: threadID)
        // The view can be showing another thread by now, or this one
        // again after another, with its own draft on the way: the task
        // that asked for this one was then cancelled.
        guard !Task.isCancelled, shownThreadID == threadID else { return }
        let handedBack = turns.takeReturned(threadID: threadID) ?? ComposerDraft()
        let draft = handedBack.followed(by: kept).followed(by: ComposerDraft(text: messageText, attachments: attachments))
        messageText = draft.text
        attachments = draft.attachments
        isRestoringDraft = false
        ComposerDrafts.shared.set(draft, for: threadID)
    }

    /// Keeps what the composer holds as the draft of the thread shown.
    private func keepDraft() {
        guard !isRestoringDraft, shownThreadID == thread.id else { return }
        ComposerDrafts.shared.set(ComposerDraft(text: messageText, attachments: attachments), for: thread.id)
    }

    /// What was sent while this thread's turn runs, in the order it will go.
    private var waitingMessages: [TurnEngine.WaitingMessage] {
        turns.waiting[thread.id] ?? []
    }

    private var enhancedMessages: [EnhancedChatMessage] {
        var idCounts = [String: Int]()
        return messages.map { msg in
            let count = idCounts[msg.id, default: 0]
            idCounts[msg.id] = count + 1
            // Generate unique ID for all messages to handle backend duplicates
            let uniqueId = count == 0 ? msg.id : "\(msg.id)-dup\(count)"

            let base = MessageAdapter.toEnhanced(from: msg, response: nil)
            let resolvedAgentRole = base.agentRole ?? thread.agentName

            // All messages use uniqueId for consistent deduplication
            return EnhancedChatMessage(
                id: uniqueId,
                threadId: base.threadId,
                role: base.role,
                content: base.content,
                agentRole: resolvedAgentRole,
                model: base.model,
                provider: base.provider,
                tokens: base.tokens,
                cost: base.cost,
                thoughts: base.thoughts,
                toolCalls: base.toolCalls,
                attachments: base.attachments,
                images: base.images,
                generatedFiles: base.generatedFiles,
                createdAt: base.createdAt
            )
        }
    }

    /// Load the most recent page of messages for this personal thread.
    private func loadInitialMessages() async {
        guard !isInitialLoading else { return }
        isInitialLoading = true
        let threadID = thread.id
        let account = UserScope.currentUserID
        var page: [ChatMessage]?
        do {
            page = try await ChatService.shared.loadMessages(
                threadId: threadID,
                limit: pageSize,
                before: nil
            )
        } catch {
            AppErrorReporter.log(error: error, context: "PersonalContentView.loadInitialMessages")
        }
        // The view can be showing another thread by now, whose own load is
        // under way: this one, read or failed, touches nothing of it.
        guard shownThreadID == threadID else { return }
        isInitialLoading = false
        // Nor is anything of an earlier account's shown.
        guard UserScope.currentUserID == account else { return }
        if let page {
            messages = page
            oldestMessageId = page.first?.id
            hasMoreMessages = page.count == pageSize
        } else {
            hasMoreMessages = false
        }
        didLoadInitialMessages = true
    }

    /// Load the next (older) page of messages when the user scrolls to the top
    /// of the currently loaded history.
    private func loadMoreMessagesIfNeeded() async {
        AppErrorReporter.log(message: "loadMoreMessagesIfNeeded called. isInitialLoading=\(isInitialLoading) isLoadingMore=\(isLoadingMore) hasMoreMessages=\(hasMoreMessages) oldestMessageId=\(oldestMessageId ?? "nil") messagesCount=\(messages.count)", context: "PersonalContentView.loadMoreMessagesIfNeeded")
        guard !isInitialLoading,
              !isLoadingMore,
              hasMoreMessages,
              let oldestId = oldestMessageId,
              !messages.isEmpty
        else {
            AppErrorReporter.log(message: "loadMoreMessagesIfNeeded guard blocked older page load", context: "PersonalContentView.loadMoreMessagesIfNeeded")
            return
        }

        isLoadingMore = true

        let threadID = thread.id
        let account = UserScope.currentUserID
        var page: [ChatMessage]?
        do {
            page = try await ChatService.shared.loadMessages(
                threadId: threadID,
                limit: pageSize,
                before: oldestId
            )
        } catch {
            AppErrorReporter.log(error: error, context: "PersonalContentView.loadMoreMessagesIfNeeded")
        }
        // As for the first page: a load for a thread the view has left
        // touches nothing, and nothing of an earlier account's is shown.
        guard shownThreadID == threadID else { return }
        isLoadingMore = false
        guard UserScope.currentUserID == account, let older = page else { return }
        guard !older.isEmpty else {
            hasMoreMessages = false
            return
        }
        // Remember the first currently visible message so we can keep the
        // scroll position stable after we prepend older messages.
        if let anchorId = enhancedMessages.first?.id {
            isPrependingMessages = true
            pendingScrollAnchorId = anchorId
        }
        messages.insert(contentsOf: older, at: 0)
        oldestMessageId = messages.first?.id
        hasMoreMessages = older.count == pageSize
    }

    private func loadProviderKeys() async {
        do {
            let accounts = try await ProviderAccountService.shared.loadProviderAccounts()
            await MainActor.run {
                canEditAgent = !accounts.isEmpty
            }
        } catch {
            await MainActor.run {
                canEditAgent = false
            }
        }
    }

    /// Send a message with optional file attachments to the LLM.
    /// Attachments are read from disk and their contents are injected into the context.
    /// True once the turn has started; false if nothing was sent, with the
    /// text back in the composer or kept for its thread.
    @MainActor
    private func sendMessage(attachments: [FileAttachmentDetail]) async -> Bool {
        let raw = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return false }

        // Split the outgoing content into the visible user question and any
        // tool-generated context blocks (web search results, attachment analysis).
        // Only the human-authored question is stored, so the transcript stays
        // clean; tool context is treated as ephemeral system context.
        let parts = splitUserAndToolContext(from: raw)
        // While a turn runs the message waits for it, shown as waiting.
        let waiting = TurnEngine.WaitingMessage(
            // As the field held it, to give back as it was.
            text: messageText,
            userText: parts.userText,
            context: parts.fullText,
            roleID: thread.agentId,
            agentName: thread.agentName,
            attachments: attachments
        )
        if turns.enqueue(waiting, threadID: thread.id) {
            messageText = ""
            ComposerDrafts.shared.removeAttachments(attachments, from: thread.id)
            // The bubble does not take focus: said, so it is known to wait.
            let isNext = turns.waiting[thread.id]?.first?.id == waiting.id
            AccessibilityNotification.Announcement(
                WaitingMessageBubble.note(isNext: isNext, agentName: thread.agentName ?? "Strix")
            ).post()
            return true
        }
        let userMessage = TurnProgress.message(in: thread.id, role: "user", content: parts.userText)
        // Shown at once, before anything waits: this view can be showing
        // another thread by the time the message is stored.
        messageText = ""
        messages.append(userMessage)
        do {
            try await TurnEngine.shared.start(
                with: userMessage,
                context: parts.fullText,
                roleID: thread.agentId,
                agentName: thread.agentName,
                attachments: attachments.isEmpty ? nil : attachments
            )
        } catch {
            AppErrorReporter.log(error: error, context: "PersonalContentView.sendMessage")
            // Nothing was sent or stored. If this thread is still the one
            // shown, the message comes out of it, the text goes back to the
            // composer, and the thread says why, for now only on screen. If
            // it is not, the text is kept for when the thread is opened.
            guard shownThreadID == userMessage.threadId else {
                TurnEngine.shared.keepUnsent(raw, for: userMessage.threadId, because: error.localizedDescription)
                return false
            }
            messages.removeAll { $0.id == userMessage.id }
            giveBack(raw, because: error.localizedDescription)
            return false
        }
        // Sent: its files leave the thread's draft, also if the thread has
        // left the screen and its composer cannot take them out.
        ComposerDrafts.shared.removeAttachments(attachments, from: userMessage.threadId)
        return true
    }

    /// Puts the text of a send that failed back in the composer, after
    /// anything typed since, and says in the thread why it was not sent.
    private func giveBack(_ text: String, because reason: String) {
        messageText = messageText.isEmpty ? text : messageText + "\n" + text
        messages.append(TurnProgress.message(
            in: thread.id,
            role: "assistant",
            content: "I couldn't send your message: \(reason)"
        ))
    }

    /// One line for each approval a turn asked for, in the reading column.
    private func approvalLines(_ approvals: [WorkTrace.Approval]) -> some View {
        ForEach(approvals) { approval in
            ApprovalRecordLine(approval: approval)
                .frame(maxWidth: 800, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Reads the thread from where it is stored, then shows what the engine
    /// added meanwhile. What it had added before the read began is among
    /// the messages read.
    private func loadStoredThread() async {
        let threadID = thread.id
        // The view can be showing another thread by now, or by the time
        // the read ends: what it has taken in is that thread's to count.
        guard shownThreadID == threadID else { return }
        let before = turns.additions[threadID]?.last?.sequence ?? 0
        additionsShown = before
        await loadInitialMessages()
        await loadTraces()
        guard shownThreadID == threadID else { return }
        // From before the read again: what was added during it can have
        // been shown and then replaced by what was read.
        additionsShown = before
        showAdditions()
        showLastEnding()
    }

    /// Shows what the engine has added to this thread and this view has
    /// not taken in yet: replies, and waiting messages it sent, in the
    /// order it added them. If some are no longer kept (more were added
    /// than the engine keeps since this view last looked), the thread is
    /// read again from where it is stored.
    private func showAdditions() {
        // Only while this thread is the one shown: on the way to another
        // thread, that thread's messages are loaded afresh.
        guard shownThreadID == thread.id else { return }
        let pending = (turns.additions[thread.id] ?? []).filter { $0.sequence > additionsShown }
        guard let first = pending.first, let last = pending.last else { return }
        guard first.sequence == additionsShown + 1 else {
            Task { await loadStoredThread() }
            return
        }
        for addition in pending {
            if !messages.contains(where: { $0.id == addition.message.id }) {
                messages.append(addition.message)
            }
            if let trace = addition.trace {
                traces[addition.message.id] = trace
            }
        }
        additionsShown = last.sequence
    }

    /// Shows how the last turn in this thread ended, if it is not shown
    /// yet. A stored ending is also among the loaded messages; one that
    /// could not be stored is only here.
    private func showLastEnding() {
        guard let ending = turns.endings[thread.id] else { return }
        let shown = Set(messages.map(\.id))
        messages.append(contentsOf: ending.messages.filter { !shown.contains($0.id) })
        if let reply = ending.messages.first {
            traces[reply.id] = ending.trace
        }
    }

    /// Loads the work traces of this thread's finished turns.
    private func loadTraces() async {
        let threadID = thread.id
        let account = UserScope.currentUserID
        do {
            let loaded = try await ThreadRepository.shared.loadWorkTraces(threadID: threadID)
            // The view can be showing another thread by now, or another
            // account's.
            guard shownThreadID == threadID, UserScope.currentUserID == account else { return }
            // A turn that ended while these were read has its trace here
            // already, and may not be among them.
            traces.merge(loaded) { shown, _ in shown }
        } catch {
            AppErrorReporter.log(error: error, context: "PersonalContentView.loadTraces")
        }
    }

    /// Split the outgoing composer text into a user-visible question and
    /// optional tool-generated context blocks (web search results, attachment
    /// analysis, etc.). The fullText field preserves the original text for
    /// passing into the LLM/context builder.
    private func splitUserAndToolContext(from text: String) -> (userText: String, fullText: String) {
        // Look for our known tool section markers. If none are present, treat
        // the entire message as user-authored text.
        let markers = ["[Web search results]", "[Attachment analysis]"]
        guard let range = markers
            .compactMap({ text.range(of: $0) })
            .sorted(by: { $0.lowerBound < $1.lowerBound })
            .first
        else {
            return (userText: text, fullText: text)
        }
        let userPart = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        // If the user section is somehow empty, still fall back to the full
        // text so we don't lose their input.
        if userPart.isEmpty {
            return (userText: text, fullText: text)
        }
        return (userText: userPart, fullText: text)
    }
}

/// Simple header for personal chat
struct PersonalChatHeader: View {
    let thread: Thread
    let canEditAgent: Bool
    let onEditAgent: (() -> Void)?
    let onBack: (() -> Void)?

    var body: some View {
        HStack(spacing: Spacing.md) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.aicovenTeal)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(thread.title ?? "Chat")
                    .font(.aicovenH2)
                    .foregroundColor(.aicovenTextPrimary)

                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                    // Show thread's agent name or generic label
                    Text(thread.agentName ?? "Strix")
                        .font(.aicovenCaption)
                }
                .foregroundColor(.aicovenTextSecondary)
            }

            Spacer()

            if let onEditAgent {
                Button(action: { if canEditAgent { onEditAgent() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text("Edit Agent")
                    }
                    .font(.aicovenBodySmall)
                }
                .buttonStyle(.bordered)
                .disabled(!canEditAgent)
            }
        }
    }
}
