import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
import UniformTypeIdentifiers
#endif

/// Redesigned workspace with enhanced sidebar and profile menu
struct WorkspaceView: View {
    @EnvironmentObject var authService: AuthService

    let initialCoven: Coven?
    let initialThread: Thread?

    @State private var selectedCoven: Coven?
    @State private var openTabs: [WorkspaceTab] = []
    @State private var activeTabId: String?
    @State private var roles: [Role] = []
    @State private var threadRefreshTrigger = false
    /// Controls the new thread sheet presentation (shared between sidebar and content)
    @State private var showNewThreadSheet = false

    private let analytics = AnalyticsService.shared

    let onSwitchToHome: () -> Void

    init(initialCoven: Coven? = nil, initialThread: Thread? = nil, onSwitchToHome: @escaping () -> Void) {
        self.initialCoven = initialCoven
        self.initialThread = initialThread
        self.onSwitchToHome = onSwitchToHome
        // Initialize State with the passed initial values
        _selectedCoven = State(initialValue: initialCoven)

        if let thread = initialThread {
            let tab = WorkspaceTab.thread(thread)
            _openTabs = State(initialValue: [tab])
            _activeTabId = State(initialValue: tab.id)
        }
    }

    var body: some View {
        ZStack {
            // Nebula background
            NebulaBackground()

            // Main workspace layout
            HStack(spacing: 0) {
                // Enhanced sidebar with coven selector, threads, and roles
                WorkspaceSidebarView(
                    selectedCoven: $selectedCoven,
                    openTabs: $openTabs,
                    activeTabId: $activeTabId,
                    showNewThreadSheet: $showNewThreadSheet,
                    roles: roles,
                    onAddRole: handleAddRole,
                    onEditRole: handleEditRole,
                    onDeleteRole: handleDeleteRole,
                    onTapRole: handleTapRole,
                    onSwitchToHome: onSwitchToHome
                )

                // Vertical divider
                Rectangle()
                    .fill(Color.aicovenBorder)
                    .frame(width: 1)

                // Main content area with tabs and chat
                WorkspaceContentView(
                    selectedCoven: $selectedCoven,
                    openTabs: $openTabs,
                    activeTabId: $activeTabId,
                    roles: $roles,
                    onCreateThread: selectedCoven != nil ? { showNewThreadSheet = true } : nil
                )
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            analytics.trackScreenView(screenName: "WorkspaceView", screenClass: "WorkspaceView")
        }
        .onChange(of: selectedCoven) { _, newValue in
            pruneTabsForSelectedCoven(newValue?.id)
            if let coven = newValue {
                analytics.trackCovenView(covenId: coven.id)
                Task {
                    await loadRoles(covenId: coven.id)
                }
            } else {
                roles = []
            }
        }
    }

    private func pruneTabsForSelectedCoven(_ covenId: String?) {
        openTabs.removeAll { tab in
            switch tab.type {
            case let .thread(thread):
                thread.covenId != covenId
            case let .addRole(tabCovenId):
                tabCovenId != covenId
            case .editRole:
                true
            case let .memoryList(tabCovenId),
                 let .memoryProposals(tabCovenId),
                 let .addMemory(tabCovenId):
                tabCovenId != covenId
            case let .editMemory(_, tabCovenId):
                tabCovenId != covenId
            default:
                false
            }
        }

        if !openTabs.contains(where: { $0.id == activeTabId }) {
            activeTabId = openTabs.last?.id
        }
    }

    /// Load roles for the selected coven
    private func loadRoles(covenId: String) async {
        do {
            roles = try await RoleService.shared.loadRoles(covenId: covenId)
        } catch {
            AppErrorReporter.log(error: error, context: "WorkspaceView.loadRoles")
            roles = []
        }
    }

    /// Handle adding a new role
    private func handleAddRole(covenId: String) {
        let tab = WorkspaceTab.addRole(covenId: covenId)
        if !openTabs.contains(where: { $0.id == tab.id }) {
            openTabs.append(tab)
        }
        activeTabId = tab.id
        analytics.trackFeatureUsage(featureName: "add_role")
    }

    /// Handle editing a role
    private func handleEditRole(role: Role) {
        let tab = WorkspaceTab.editRole(roleId: role.id, roleName: role.name)
        if !openTabs.contains(where: { $0.id == tab.id }) {
            openTabs.append(tab)
        }
        activeTabId = tab.id
        analytics.trackRoleView(roleId: role.id)
    }

    /// Handle deleting a role
    private func handleDeleteRole(role: Role) {
        Task {
            do {
                try await RoleService.shared.deleteRole(roleId: role.id)
                analytics.trackRoleDelete(roleId: role.id)
                // Refresh roles list
                if let coven = selectedCoven {
                    await loadRoles(covenId: coven.id)
                }
                // Close any edit tab for this role
                openTabs.removeAll { tab in
                    if case let .editRole(roleId) = tab.type, roleId == role.id {
                        return true
                    }
                    return false
                }
            } catch {
                AppErrorReporter.log(error: error, context: "WorkspaceView.handleDeleteRole")
                analytics.trackError(errorType: "role_delete", errorMessage: error.localizedDescription, context: "WorkspaceView")
            }
        }
    }

    /// Handle tapping a role to create a new thread
    private func handleTapRole(role: Role) {
        Task {
            do {
                guard let coven = selectedCoven else { return }
                let thread = try await ThreadService.shared.createThread(
                    title: "Chat with \(role.name)",
                    covenId: coven.id,
                    agentId: role.id,
                    agentName: role.name
                )
                analytics.trackThreadCreate(threadId: thread.id, covenId: coven.id, hasTitle: true)
                analytics.trackRoleAssign(roleId: role.id, threadId: thread.id)
                let tab = WorkspaceTab.thread(thread)
                openTabs.append(tab)
                activeTabId = tab.id
                threadRefreshTrigger.toggle()
            } catch {
                AppErrorReporter.log(error: error, context: "WorkspaceView.handleTapRole")
                analytics.trackError(errorType: "thread_create", errorMessage: error.localizedDescription, context: "WorkspaceView")
            }
        }
    }
}

/// Main content area for the coven workspace with tabs and chat
struct WorkspaceContentView: View {
    @Binding var selectedCoven: Coven?
    @Binding var openTabs: [WorkspaceTab]
    @Binding var activeTabId: String?
    @EnvironmentObject var authService: AuthService
    @Binding var roles: [Role]
    /// Optional callback to create a new thread (passed to empty state CTA)
    var onCreateThread: (() -> Void)?

    var activeTab: WorkspaceTab? {
        openTabs.first(where: { $0.id == activeTabId })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar with profile menu (when no tabs open)
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
                // Tab bar for open tabs with profile menu integrated
                HStack(spacing: 0) {
                    WorkspaceTabBar(
                        openTabs: $openTabs,
                        activeTabId: $activeTabId
                    )
                    .frame(maxWidth: .infinity)

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

            // Content area - render based on active tab type
            if let tab = activeTab {
                renderTabContent(tab)
            } else if selectedCoven != nil {
                // Coven selected but no tab open - show CTA to create new thread
                VStack(spacing: Spacing.lg) {
                    Spacer()
                    IconBadge(icon: "message", size: 60, color: .aicovenTeal)
                    VStack(spacing: Spacing.sm) {
                        Text("Start a Conversation")
                            .font(.aicovenH2)
                            .foregroundColor(.aicovenTextPrimary)
                        Text("Create a new thread to chat with your AI agents")
                            .font(.aicovenBody)
                            .foregroundColor(.aicovenTextSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                    }
                    // Create Thread CTA button
                    if let onCreateThread {
                        GradientButton("New Thread", icon: "plus", style: .primary) {
                            onCreateThread()
                        }
                        .padding(.top, Spacing.md)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                // No coven selected
                VStack(spacing: Spacing.lg) {
                    Spacer()
                    IconBadge(icon: "sparkles", size: 60, color: .aicovenTeal)
                    Text("Select a coven to get started")
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Render appropriate view based on tab type
    @ViewBuilder
    private func renderTabContent(_ tab: WorkspaceTab) -> some View {
        switch tab.type {
        case let .thread(thread):
            // Reuse PersonalChatView for coven threads (same local chat flow)
            PersonalChatView(
                thread: thread,
                onEditAgent: nil,
                onBack: nil
            )
            .id(thread.id)
        case .profile:
            EnhancedProfileView()
        case .settings:
            EnhancedSettingsView()
        case .providerKeys:
            ProviderKeysView()
        case .budget:
            BudgetView()
        case .usage:
            UsageSettingsView()
        case .connectedApps:
            ConnectedAppsView()
                .environmentObject(StoreService.shared)
        case .mcpServers:
            MCPServerManagementView()
        case let .addRole(covenId):
            AddRoleView(covenId: covenId, roles: roles) {
                // Refresh roles list and close tab
                Task {
                    if let coven = selectedCoven {
                        do {
                            roles = try await RoleService.shared.loadRoles(covenId: coven.id)
                        } catch {
                            AppErrorReporter.log(error: error, context: "WorkspaceContentView.addRole.refreshRoles")
                        }
                    }
                }
                // Close this tab
                if let tabIndex = openTabs.firstIndex(where: { $0.id == tab.id }) {
                    openTabs.remove(at: tabIndex)
                    if activeTabId == tab.id {
                        activeTabId = openTabs.last?.id
                    }
                }
            }
        case let .editRole(roleId):
            EditRoleView(roleId: roleId, roles: roles) {
                // Refresh roles list and close tab
                Task {
                    if let coven = selectedCoven {
                        do {
                            roles = try await RoleService.shared.loadRoles(covenId: coven.id)
                        } catch {
                            AppErrorReporter.log(error: error, context: "WorkspaceContentView.editRole.refreshRoles")
                        }
                    }
                }
                // Close this tab
                if let tabIndex = openTabs.firstIndex(where: { $0.id == tab.id }) {
                    openTabs.remove(at: tabIndex)
                    if activeTabId == tab.id {
                        activeTabId = openTabs.last?.id
                    }
                }
            }
            .id(roleId)
        case let .memoryList(covenId):
            MemoryListView(
                covenId: covenId,
                openTabs: $openTabs,
                activeTabId: $activeTabId
            )
        case let .memoryProposals(covenId):
            MemoryProposalsView(
                covenId: covenId,
                openTabs: $openTabs,
                activeTabId: $activeTabId
            )
        case .terms:
            TermsOfServiceView()
        default:
            EmptyView()
        }
    }

    /// Open a new tab
    private func openTab(_ type: WorkspaceTabType) {
        // For settings tabs, only allow one instance
        if case .thread = type {
            // Allow multiple thread tabs
        } else {
            if let existingTab = openTabs.first(where: { $0.type == type }) {
                activeTabId = existingTab.id
                return
            }
        }

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
        case .budget:
            tab = .budget
        case .usage:
            tab = .usage
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
        default:
            return
        }

        openTabs.append(tab)
        activeTabId = tab.id
    }
}

/// Enhanced message composer
struct EnhancedMessageComposer: View {
    @Binding var messageText: String
    /// Callback when user sends a message, provides the full attachment details (with URLs for local file access)
    let onSend: ([FileAttachmentDetail]) -> Void
    /// Optional callback to surface chat-scoped errors as messages in the thread.
    var onErrorMessage: ((String) -> Void)?
    var isDisabled: Bool = false
    var threadId: String? // For upload when feature flag enabled
    /// Optional list of roles that can be @mentioned in this thread
    var mentionableRoles: [MentionableRole] = []
    /// When true (iOS), automatically focus the text field when the composer
    /// appears so users can start typing immediately (e.g. after creating a
    /// new thread).
    var autoFocus: Bool = false

    // Phase B & D: attachments with optional upload
    @State private var attachments: [FileAttachmentDetail] = []
    @State private var isUploading: Bool = false

    #if os(iOS)
    @State private var showFileImporter: Bool = false
    @FocusState private var isTextFieldFocused: Bool
    #endif
    #if os(macOS)
    @State private var macInputHeight: CGFloat = 36
    #endif
    // @mention state
    @State private var showMentionSuggestions: Bool = false
    @State private var mentionQuery: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if !attachments.isEmpty {
                AttachmentsListView(
                    attachments: attachments,
                    compact: true,
                    onRemove: { id in attachments.removeAll { $0.id == id } },
                    showRemove: true
                )
                .padding(.horizontal, Spacing.xs)
            }

            HStack(spacing: Spacing.sm) {
                // Attach button (macOS: NSOpenPanel, iOS: fileImporter)
                Button {
                    #if os(macOS)
                    attachFiles()
                    #elseif os(iOS)
                    showFileImporter = true
                    #endif
                } label: {
                    if isUploading {
                        ProgressView()
                            .controlSize(.small)
                            .padding(Spacing.xs)
                    } else {
                        Image(systemName: "paperclip")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.aicovenTextSecondary)
                            .padding(Spacing.xs)
                    }
                }
                .background(Color.aicovenGlass)
                .cornerRadius(BorderRadius.sm)
                .buttonStyle(.plain)
                .disabled(isUploading)
                #if os(macOS)
                    .help("Attach files")
                #endif

                // Text input
                #if os(macOS)
                MacMultilineTextView(
                    text: $messageText,
                    isDisabled: isDisabled,
                    onSend: {
                        send()
                    },
                    height: $macInputHeight
                )
                .frame(height: macInputHeight)
                .background(Color.aicovenGlass)
                .cornerRadius(BorderRadius.lg)
                #else
                TextField(
                    "",
                    text: $messageText,
                    prompt: Text("Message...").foregroundColor(.aicovenTextTertiary),
                    axis: .vertical
                )
                .focused($isTextFieldFocused)
                .font(.aicovenBody)
                .foregroundColor(.aicovenTextPrimary)
                .padding(Spacing.sm)
                .background(Color.aicovenGlass)
                .cornerRadius(BorderRadius.lg)
                .lineLimit(1 ... 6)
                .disabled(isDisabled)
                .onSubmit {
                    send()
                }
                #if os(iOS)
                .task {
                    if autoFocus, !isDisabled {
                        isTextFieldFocused = true
                    }
                }
                #endif
                #endif

                // Send button
                Button(action: send) {
                    ZStack {
                        Circle()
                            .fill(
                                messageText.isEmpty || isDisabled
                                    ? LinearGradient(
                                        colors: [Color.aicovenGlass, Color.aicovenGlass],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                    : LinearGradient(
                                        colors: [Color.aicovenTeal, Color.aicovenPurple],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                            )
                            .frame(width: 40, height: 40)

                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(.plain)
                .disabled(messageText.isEmpty || isDisabled)
                .glowEffect(
                    color: messageText.isEmpty || isDisabled ? .clear : .aicovenTeal,
                    radius: 8,
                    intensity: 0.4
                )
            }

            // @role mention suggestions
            if showMentionSuggestions, !filteredMentionRoles.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    ForEach(filteredMentionRoles, id: \.id) { role in
                        Button {
                            insertMention(for: role)
                        } label: {
                            HStack(spacing: Spacing.xs) {
                                Text(role.emoji ?? "🤖")
                                Text(role.name)
                                    .font(.aicovenBodySmall)
                                Spacer()
                            }
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, Spacing.xs)
                            .background(Color.aicovenGlass)
                            .cornerRadius(BorderRadius.sm)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, Spacing.xs)
            }
        }
        #if os(iOS)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                Task { await handleImportedFiles(urls) }
            case let .failure(error):
                AppErrorReporter.log(error: error, context: "EnhancedMessageComposer.fileImporter")
                Task { @MainActor in
                    onErrorMessage?("File import failed: \(error.localizedDescription)")
                }
            }
        }
        #endif
        .onChange(of: messageText) { _, _ in
            updateMentionSuggestions()
        }
    }
}

// MARK: - EnhancedMessageComposer Helper Methods

extension EnhancedMessageComposer {
    /// Send the message with all attached files to the onSend callback
    private func send() {
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isDisabled, !trimmed.isEmpty else { return }
        // Pass the full attachment details (including URLs) so the chat service can read file contents
        onSend(attachments)
        // Clear attachments after send
        attachments.removeAll()
        // Reset mention state
        showMentionSuggestions = false
        mentionQuery = ""
    }

    /// Update @mention suggestions based on the current message text.
    private func updateMentionSuggestions() {
        guard !mentionableRoles.isEmpty else {
            showMentionSuggestions = false
            mentionQuery = ""
            return
        }

        // For now, only support suggestions when the cursor is at the end of the text.
        let text = messageText
        guard let atIndex = text.lastIndex(of: "@") else {
            showMentionSuggestions = false
            mentionQuery = ""
            return
        }

        let startOfQuery = text.index(after: atIndex)
        let querySuffix = text[startOfQuery...]

        // If we already have a space or another '@' after the marker, hide suggestions.
        if querySuffix.contains(where: { $0.isWhitespace || $0 == "@" }) {
            showMentionSuggestions = false
            mentionQuery = ""
            return
        }

        mentionQuery = String(querySuffix)
        showMentionSuggestions = true
    }

    /// Roles filtered by the current @mention query.
    private var filteredMentionRoles: [MentionableRole] {
        guard showMentionSuggestions else { return [] }
        let trimmedQuery = mentionQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = mentionableRoles
        if trimmedQuery.isEmpty {
            return Array(base.prefix(6))
        }
        return base.filter { role in
            let name = role.name.lowercased()
            let emoji = (role.emoji ?? "").lowercased()
            return name.contains(trimmedQuery) || emoji.contains(trimmedQuery)
        }.prefix(6).map(\.self)
    }

    /// Insert the selected role mention into the message text, replacing the
    /// current '@query' segment with '@RoleName '.
    private func insertMention(for role: MentionableRole) {
        let text = messageText
        guard let atIndex = text.lastIndex(of: "@") else { return }
        let prefix = text[..<atIndex]
        let mentionToken = "@" + role.name + " "
        messageText = String(prefix) + mentionToken
        showMentionSuggestions = false
        mentionQuery = ""
    }

    #if os(iOS)
    @MainActor
    private func handleImportedFiles(_ urls: [URL]) async {
        guard let threadId else { return }
        isUploading = true
        defer { isUploading = false }

        for url in urls {
            do {
                let detail = try await UploadService.shared.upload(url: url, threadId: threadId)
                attachments.append(detail)
            } catch {
                AppErrorReporter.log(error: error, context: "WorkspaceView.handleImportedFiles.upload")
                Task { @MainActor in
                    onErrorMessage?("Attachment upload failed for \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }
    #endif

    #if os(macOS)
    private func attachFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { resp in
            guard resp == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                isUploading = true
                defer { isUploading = false }

                for url in urls {
                    do {
                        // If threadId available, upload via UploadService (feature flagged)
                        let detail: FileAttachmentDetail
                        if let threadId {
                            detail = try await UploadService.shared.upload(url: url, threadId: threadId)
                        } else {
                            // Fallback: local-only attachment
                            let name = url.lastPathComponent
                            let mime = mimeType(for: url.pathExtension)
                            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                            detail = FileAttachmentDetail(
                                id: UUID().uuidString,
                                name: name,
                                mimeType: mime,
                                sizeBytes: size,
                                width: nil,
                                height: nil,
                                url: url
                            )
                        }
                        attachments.append(detail)
                    } catch {
                        AppErrorReporter.log(error: error, context: "WorkspaceView.attachFiles.upload")
                        Task { @MainActor in
                            onErrorMessage?("Attachment upload failed for \(url.lastPathComponent): \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    private func mimeType(for ext: String) -> String? {
        let lower = ext.lowercased()
        switch lower {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "md": return "text/markdown"
        default: return nil
        }
    }
    #endif
}

struct MentionableRole: Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String?
}

#if os(macOS)
// macOS-specific multiline text view that supports:
// - Shift+Enter for newlines
// - Enter to send
// - Keeping focus after send

struct MacMultilineTextView: NSViewRepresentable {
    @Binding var text: String
    var isDisabled: Bool
    var onSend: () -> Void
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> ChatNSTextView {
        let textView = ChatNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        textView.onSend = { [weak textView] in
            // Let SwiftUI decide whether sending is allowed
            onSend()
            // Keep focus in the text view after sending
            if let tv = textView {
                tv.window?.makeFirstResponder(tv)
            }
        }

        // Initial height based on current content
        context.coordinator.updateHeight(textView)
        return textView
    }

    func updateNSView(_ textView: ChatNSTextView, context: Context) {
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = !isDisabled
        textView.isSelectable = !isDisabled
        context.coordinator.updateHeight(textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacMultilineTextView

        init(_ parent: MacMultilineTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            updateHeight(tv)
        }

        func updateHeight(_ tv: NSTextView) {
            // Measure required height for current content
            let minHeight: CGFloat = 36
            let maxHeight: CGFloat = 140

            let fittingSize = tv.intrinsicContentSize.height
            let clamped = max(minHeight, min(maxHeight, fittingSize))

            if abs(parent.height - clamped) > 0.5 {
                parent.height = clamped
            }
        }
    }

    final class ChatNSTextView: NSTextView {
        var onSend: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            let isEnter = event.keyCode == 36 || event.keyCode == 76 // Return or keypad Enter
            let isShift = event.modifierFlags.contains(.shift)

            if isEnter, isShift {
                // Shift+Enter → insert newline
                insertNewline(nil)
            } else if isEnter {
                // Enter → send
                if let onSend {
                    onSend()
                } else {
                    super.keyDown(with: event)
                }
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
#endif

#Preview {
    WorkspaceView(onSwitchToHome: {})
        .environmentObject(AuthService.shared)
        .environmentObject(AppState.shared)
}
