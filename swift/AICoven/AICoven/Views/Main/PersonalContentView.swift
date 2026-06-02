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
        case .profile:
            EnhancedProfileView()
                .onAppear { AnalyticsService.shared.trackProfileOpened() }
        case .settings:
            EnhancedSettingsView()
                .onAppear { AnalyticsService.shared.trackSettingsOpened() }
        case .providerKeys:
            ProviderKeysView()
        case .usage:
            UsageSettingsView()
                .onAppear { AnalyticsService.shared.trackUsageViewed() }
        case .budget:
            BudgetView()
        case .connectedApps:
            ConnectedAppsView()
                .environmentObject(StoreService.shared)
                .onAppear { AnalyticsService.shared.trackConnectedAppsOpened() }
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
        case .store:
            StoreView()
                .environmentObject(StoreService.shared)
        case .terms:
            TermsOfServiceView()
        case .privacy:
            PrivacyPolicyView()
        default:
            EmptyView()
        }
    }

    private func openTab(_ type: WorkspaceTabType) {
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
        case .profile:
            tab = .profile
        case .settings:
            tab = .settings
        case .providerKeys:
            tab = .providerKeys
        case .usage:
            tab = .usage
        case .budget:
            tab = .budget
        case .connectedApps:
            tab = .connectedApps
        case .mcpServers:
            tab = .mcpServers
        case .personalStrixSettings:
            tab = WorkspaceTab.personalStrix
        case let .memoryList(covenId):
            tab = WorkspaceTab.memoryList(covenId: covenId)
        case let .memoryProposals(covenId):
            tab = WorkspaceTab.memoryProposals(covenId: covenId)
        case .store:
            tab = .store
        case .terms:
            tab = .terms
        case .privacy:
            tab = .privacy
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
    @State private var isSending = false
    @State private var errorMessage: String?

    // Streaming/autonomous state (mirrors EnhancedChatView behavior)
    @State private var lastResponse: ChatResponse?
    @State private var lastResponseId: String?
    /// Descriptive reasoning text shown alongside the loader while the agent is working
    @State private var reasoningLoadingMessage: String = "Thinking through your request…"
    /// Live answer buffer used while streaming in the final response
    @State private var streamingAnswerBuffer: String = ""
    /// Streaming thoughts collected from planning-phase deltas
    @State private var streamingThoughts: [String] = []
    /// Whether the current streamed turn used any tools (web, GitHub, etc.).
    @State private var streamingUsedTools: Bool = false
    @State private var canEditAgent: Bool = true

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
                            RichMessageBubble(
                                message: em,
                                isPersonal: thread.covenId == nil,
                                onApproveToolCall: { _ in },
                                onRejectToolCall: { _ in }
                            )
                            .id(em.id)
                        }

                        // Show thinking indicator when AI is responding
                        if isSending {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "sparkles")
                                        // Show "Strix" for the default personal assistant
                                        Text(thread.agentName ?? "Strix")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(Color.aicovenTeal)

                                    CauldronLoadingView(message: reasoningLoadingMessage, size: 40)
                                        .padding(16)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(Color.aicovenSurfaceElevated)
                                                .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
                                        )
                                }
                                .frame(maxWidth: 800, alignment: .leading)

                                Spacer(minLength: 0)
                            }
                            .id("thinking-indicator")
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
                .onChange(of: isSending) { _, newValue in
                    if newValue {
                        withAnimation {
                            proxy.scrollTo("thinking-indicator", anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    if let lastMessage = enhancedMessages.last {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }

            GradientDivider()

            // Message composer
            EnhancedMessageComposer(
                messageText: $messageText,
                onSend: { attachments in
                    Task { @MainActor in
                        await sendMessage(attachments: attachments)
                    }
                },
                onErrorMessage: { errorText in
                    let errorMessage = ChatMessage(
                        id: UUID().uuidString,
                        threadId: thread.id,
                        role: "assistant",
                        content: errorText,
                        metadata: nil,
                        tokenUsage: nil,
                        createdAt: Date(),
                        isEncrypted: false,
                        keyFingerprint: nil
                    )
                    messages.append(errorMessage)
                    Task {
                        await ChatService.shared.addLocalMessage(errorMessage)
                    }
                },
                isDisabled: isSending,
                threadId: thread.id,
                autoFocus: true
            )
            .padding(Spacing.md)
        }
        #if os(iOS)
        .background(NebulaBackground())
        #endif
        // When the bound thread changes (e.g. user switches tabs on macOS),
        // reset and reload the messages/provider keys for the new thread.
        .task(id: thread.id) {
            messages = []
            lastResponse = nil
            lastResponseId = nil
            streamingAnswerBuffer = ""
            streamingThoughts = []
            streamingUsedTools = false
            isInitialLoading = false
            didLoadInitialMessages = false
            isLoadingMore = false
            hasMoreMessages = true
            oldestMessageId = nil
            isPrependingMessages = false
            pendingScrollAnchorId = nil

            await loadInitialMessages()
            await loadProviderKeys()
        }
        .onReceive(NotificationCenter.default.publisher(for: .providerKeysUpdated)) { _ in
            Task {
                await loadProviderKeys()
            }
        }
    }

    private var enhancedMessages: [EnhancedChatMessage] {
        var idCounts = [String: Int]()
        return messages.map { msg in
            let count = idCounts[msg.id, default: 0]
            idCounts[msg.id] = count + 1
            // Generate unique ID for all messages to handle backend duplicates
            let uniqueId = count == 0 ? msg.id : "\(msg.id)-dup\(count)"

            // For the last AI message, use the cached ChatResponse to preserve tool calls and thoughts.
            if msg.id == lastResponseId, let response = lastResponse {
                let base = MessageAdapter.toEnhanced(from: msg, response: response)

                // Resolve agent name for personal threads:
                // 1) Prefer backend role_name (via base.agentRole)
                // 2) Fall back to the thread's agentName
                let resolvedAgentRole = base.agentRole ?? thread.agentName

                // While streaming, override content with live buffer
                if isSending, !streamingAnswerBuffer.isEmpty, msg.role == "assistant" {
                    return EnhancedChatMessage(
                        id: uniqueId,
                        threadId: base.threadId,
                        role: base.role,
                        content: MessageAdapter.sanitizeContentForDisplay(streamingAnswerBuffer),
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

                // Non-streaming path: use uniqueId for consistency
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
        defer { isInitialLoading = false }
        do {
            let page = try await ChatService.shared.loadMessages(
                threadId: thread.id,
                limit: pageSize,
                before: nil
            )
            messages = page
            oldestMessageId = page.first?.id
            hasMoreMessages = page.count == pageSize
        } catch {
            AppErrorReporter.log(error: error, context: "PersonalContentView.loadInitialMessages")
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
        defer { isLoadingMore = false }

        do {
            let older = try await ChatService.shared.loadMessages(
                threadId: thread.id,
                limit: pageSize,
                before: oldestId
            )
            guard !older.isEmpty else {
                hasMoreMessages = false
                return
            }
            // Remember the first currently visible message so we can keep the
            // scroll position stable after we prepend older messages.
            let anchorId = enhancedMessages.first?.id
            await MainActor.run {
                if let anchorId {
                    isPrependingMessages = true
                    pendingScrollAnchorId = anchorId
                }
                messages.insert(contentsOf: older, at: 0)
                oldestMessageId = messages.first?.id
                hasMoreMessages = older.count == pageSize
            }
        } catch {
            AppErrorReporter.log(error: error, context: "PersonalContentView.loadMoreMessagesIfNeeded")
        }
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
    @MainActor
    private func sendMessage(attachments: [FileAttachmentDetail]) async {
        let raw = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        // Split the outgoing content into the visible user question and any
        // tool-generated context blocks (web search results, attachment analysis).
        let parts = splitUserAndToolContext(from: raw)
        let userVisibleText = parts.userText
        let fullTextForLLM = parts.fullText

        messageText = ""
        isSending = true
        streamingAnswerBuffer = ""
        streamingThoughts = []
        streamingUsedTools = false
        reasoningLoadingMessage = "Thinking through your request…"

        // Add user message immediately and persist it in the local history.
        // We store only the human-authored question so the transcript stays
        // clean; tool context is treated as ephemeral system context.
        let userMessage = ChatMessage(
            id: UUID().uuidString,
            threadId: thread.id,
            role: "user",
            content: userVisibleText,
            metadata: nil,
            tokenUsage: nil,
            createdAt: Date(),
            isEncrypted: false,
            keyFingerprint: nil
        )
        messages.append(userMessage)
        await ChatService.shared.addLocalMessage(userMessage)

        do {
            try await ChatService.shared.streamMessage(
                threadId: thread.id,
                message: fullTextForLLM,
                roleId: thread.agentId,
                attachments: attachments.isEmpty ? nil : attachments,
                onStateChange: { state in
                    Task { @MainActor in
                        switch state.phase {
                        case .starting, .planning, .modelAttempt:
                            let trimmed = state.scratchpad.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                if streamingUsedTools {
                                    reasoningLoadingMessage = "Using tools and memory: \(trimmed)"
                                } else {
                                    reasoningLoadingMessage = "Planning: \(trimmed)"
                                }
                                if streamingThoughts.last != trimmed {
                                    streamingThoughts.append(trimmed)
                                }
                            }
                        case .tooling:
                            streamingUsedTools = true
                            if let lastTool = state.toolsInProgress.values.first ?? state.toolsCompleted.last {
                                reasoningLoadingMessage = toolActivityMessage(for: lastTool.name)
                            }
                        case .answering:
                            streamingAnswerBuffer = state.answer
                            streamingAnswerBuffer = Self.stripThinkTags(from: streamingAnswerBuffer)
                            if streamingAnswerBuffer.contains("web.") || streamingAnswerBuffer.contains("github.") {
                                streamingUsedTools = true
                            }
                        case .finalizing:
                            if state.status == .failed {
                                // Handled in catch block naturally if thrown, but if emitted as failed state:
                                isSending = false
                                streamingAnswerBuffer = ""
                                streamingThoughts = []
                                streamingUsedTools = false
                                reasoningLoadingMessage = "Something went wrong while contacting the assistant. Please try again."

                                let errorMessage = ChatMessage(
                                    id: UUID().uuidString,
                                    threadId: thread.id,
                                    role: "assistant",
                                    content: state.answer,
                                    metadata: nil,
                                    tokenUsage: nil,
                                    createdAt: Date(),
                                    isEncrypted: false,
                                    keyFingerprint: nil
                                )
                                messages.append(errorMessage)
                                Task { await ChatService.shared.addLocalMessage(errorMessage) }
                                return
                            }

                            isSending = false
                            let collapsedThoughts: [String]
                            if streamingThoughts.isEmpty {
                                collapsedThoughts = []
                            } else {
                                let joined = streamingThoughts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                                collapsedThoughts = joined.isEmpty ? [] : [joined]
                            }
                            var meta: [String: AnyJSONValue] = [:]
                            if !collapsedThoughts.isEmpty {
                                meta["thoughts"] = AnyJSONValue(collapsedThoughts)
                            }
                            if let agentName = thread.agentName {
                                meta["role_name"] = AnyJSONValue(agentName)
                            }

                            let cleanedContent = MessageAdapter.sanitizeContentForDisplay(state.answer)
                            let aiMessage = ChatMessage(
                                id: UUID().uuidString,
                                threadId: thread.id,
                                role: "assistant",
                                content: cleanedContent,
                                metadata: meta,
                                tokenUsage: nil,
                                createdAt: Date(),
                                isEncrypted: false,
                                keyFingerprint: nil
                            )
                            messages.append(aiMessage)
                            await ChatService.shared.addLocalMessage(aiMessage)
                            Task {
                                await ChatService.shared.updateThreadSummary(threadId: thread.id)
                            }

                            lastResponse = nil
                            lastResponseId = aiMessage.id
                            streamingAnswerBuffer = ""
                            streamingThoughts = []
                        }
                    }
                }
            )
        } catch {
            AppErrorReporter.log(error: error, context: "PersonalContentView.sendMessage")
            isSending = false
            streamingAnswerBuffer = ""
            streamingThoughts = []
            streamingUsedTools = false
            reasoningLoadingMessage = "Something went wrong while contacting the assistant. Please try again."

            let errorText = "I ran into an error while contacting your provider: \(error.localizedDescription)"
            let errorMessage = ChatMessage(
                id: UUID().uuidString,
                threadId: thread.id,
                role: "assistant",
                content: errorText,
                metadata: nil,
                tokenUsage: nil,
                createdAt: Date(),
                isEncrypted: false,
                keyFingerprint: nil
            )
            messages.append(errorMessage)
            Task {
                await ChatService.shared.addLocalMessage(errorMessage)
            }
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

    /// Map tool names to human-readable activity messages for the loader UI.
    private func toolActivityMessage(for toolName: String) -> String {
        if toolName.hasPrefix("web.search") {
            return "Using web.search to look up information on the web…"
        }
        if toolName.hasPrefix("web.browse") {
            return "Using web.browse to read a web page…"
        }
        if toolName.hasPrefix("github.readFile") {
            return "Using github.readFile to inspect a file in your repo…"
        }
        if toolName.hasPrefix("github.listFiles") {
            return "Using github.listFiles to explore the repository structure…"
        }
        if toolName.hasPrefix("github.searchCode") {
            return "Using github.searchCode to search through your codebase…"
        }
        if toolName.hasPrefix("github.writeFile") {
            return "Using github.writeFile to apply code changes…"
        }
        if toolName.hasPrefix("github.createBranch") {
            return "Using github.createBranch to create a new branch…"
        }
        if toolName.hasPrefix("github.createPR") {
            return "Using github.createPR to open a pull request…"
        }
        if toolName.hasPrefix("image.generate") {
            return "Using image.generate to create an image…"
        }
        if toolName.hasPrefix("video.generate") {
            return "Using video.generate to create a video…"
        }
        if toolName.hasPrefix("file.generate") {
            return "Using file.generate to create a file…"
        }
        if toolName.hasPrefix("shell.execute") {
            return "Using shell.execute to run a command on your machine…"
        }
        if toolName.hasPrefix("google_drive.") || toolName.hasPrefix("google_docs.") || toolName.hasPrefix("google_sheets.") || toolName.hasPrefix("google_slides.") {
            return "Using Google Workspace tools to work with your docs and files…"
        }
        return "Using tool \(toolName)…"
    }

    /// Strip <think>...</think> blocks from the streaming buffer so reasoning
    /// model internals (e.g. Qwen3) don't appear in the live chat UI.
    /// Handles both closed tags and unclosed tags (model still thinking).
    private static func stripThinkTags(from text: String) -> String {
        var result = text
        // Remove fully closed <think>...</think> blocks
        if let regex = try? NSRegularExpression(
            pattern: "<\\s*think\\s*>.*?<\\s*/\\s*think\\s*>",
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) {
            result = regex.stringByReplacingMatches(
                in: result, options: [],
                range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: ""
            )
        }
        // Remove unclosed <think> tags (model still generating reasoning)
        if let thinkStart = result.range(of: "<think>", options: .caseInsensitive) {
            result = String(result[..<thinkStart.lowerBound])
        }
        return result
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
