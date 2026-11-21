import SwiftUI

// MARK: - Memory Proposals View

/// View for displaying and managing pending memory proposals
struct MemoryProposalsView: View {
    let covenId: String?
    @Binding var openTabs: [WorkspaceTab]
    @Binding var activeTabId: String?

    @State private var proposals: [MemoryProposal] = []
    @State private var selectedStatus = "pending"
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// Counts the loads, so that only the latest is shown.
    @State private var loads = 0
    /// The proposals being reviewed now: their buttons are off meanwhile.
    @State private var reviewing: Set<String> = []

    let statuses = ["pending", "approved", "rejected", "all"]

    var body: some View {
        ZStack {
            NebulaBackground()
            VStack(spacing: 0) {
                // Header
                VStack(spacing: Spacing.md) {
                    HStack {
                        Text("Memory Proposals")
                            .font(.aicovenH2)
                            .foregroundColor(.aicovenTextPrimary)

                        Spacer()
                    }

                    // Status filter
                    HStack(spacing: Spacing.xs) {
                        ForEach(statuses, id: \.self) { status in
                            Button {
                                selectedStatus = status
                                Task {
                                    await loadProposals()
                                }
                            } label: {
                                Text(status.capitalized)
                                    .font(.aicovenCaption)
                                    .foregroundColor(selectedStatus == status ? .aicovenTeal : .aicovenTextSecondary)
                                    .padding(.horizontal, Spacing.sm)
                                    .padding(.vertical, Spacing.xs)
                                    .background(
                                        RoundedRectangle(cornerRadius: BorderRadius.sm)
                                            .fill(selectedStatus == status ? Color.aicovenGlass : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                            // Which filter is on is not only its colour.
                            .accessibilityAddTraits(selectedStatus == status ? .isSelected : [])
                        }
                    }
                }
                .padding(Spacing.lg)

                GradientDivider()

                // Content area
                if isLoading {
                    LoadingView(message: "Loading proposals...")
                } else if let error = errorMessage {
                    MemoryErrorView(message: error) {
                        Task {
                            await loadProposals()
                        }
                    }
                } else if proposals.isEmpty {
                    EmptyProposalsState()
                } else {
                    ScrollView {
                        LazyVStack(spacing: Spacing.sm) {
                            ForEach(proposals) { proposal in
                                ProposalCard(
                                    proposal: proposal,
                                    onApprove: {
                                        Task {
                                            await reviewProposal(proposal, action: "approve")
                                        }
                                    },
                                    onReject: {
                                        Task {
                                            await reviewProposal(proposal, action: "reject")
                                        }
                                    },
                                    onSaveAsMemory: { editedContent in
                                        Task {
                                            await saveProposalAsMemory(proposal, editedContent: editedContent)
                                        }
                                    },
                                    onDelete: {
                                        Task {
                                            await deleteProposal(proposal)
                                        }
                                    }
                                )
                                // One review of a proposal at a time.
                                .disabled(reviewing.contains(proposal.id))
                            }
                        }
                        .padding(Spacing.lg)
                    }
                }
            }
            .task {
                await loadProposals()
            }
        } // ZStack
    }

    // MARK: - Actions

    /// Reads the scope's proposals of the status chosen. Only the latest
    /// load is shown, and only to the account that asked.
    private func loadProposals() async {
        loads += 1
        let load = loads
        let account = UserScope.currentUserID
        isLoading = true
        errorMessage = nil
        let loaded: Result<[MemoryProposal], Error>
        do {
            loaded = try await .success(MemoryService.shared.listProposals(covenId: covenId, status: selectedStatus))
        } catch {
            loaded = .failure(error)
        }
        guard load == loads, UserScope.currentUserID == account else { return }
        switch loaded {
        case let .success(found): proposals = found
        case let .failure(error): errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Runs one review of a proposal: nothing while another of it is under
    /// way here. What it settled as replaces it in the list, or takes it
    /// out of the pending ones; what could not be done is said, to the
    /// account that asked. A proposal that turned out to be reviewed
    /// already is read again with the rest.
    private func review(_ proposal: MemoryProposal, failing what: String, _ run: () async throws -> MemoryProposal) async {
        guard reviewing.insert(proposal.id).inserted else { return }
        defer { reviewing.remove(proposal.id) }
        let account = UserScope.currentUserID
        do {
            let updated = try await run()
            guard UserScope.currentUserID == account else { return }
            if let index = proposals.firstIndex(where: { $0.id == updated.id }) {
                proposals[index] = updated
            }
            if selectedStatus == "pending", updated.status != "pending" {
                proposals.removeAll { $0.id == updated.id }
            }
        } catch {
            guard UserScope.currentUserID == account else { return }
            // Reviewed already, here or in another window: the card was out
            // of date. The list is read again and shows it as it is; that
            // load says for itself what it finds, and nothing is said over
            // a newer one.
            if error as? ProposalReviewError == .alreadyReviewed {
                return await loadProposals()
            }
            errorMessage = "Failed to \(what): \(error.localizedDescription)"
        }
    }

    /// Approve or reject, from the buttons of those names.
    private func reviewProposal(_ proposal: MemoryProposal, action: String) async {
        await review(proposal, failing: "\(action) proposal") {
            try await MemoryService.shared.reviewProposal(proposalId: proposal.id, action: action)
        }
    }

    /// Saves the proposal's content, as edited, as a memory, and marks the
    /// proposal reviewed so it is no longer pending.
    private func saveProposalAsMemory(_ proposal: MemoryProposal, editedContent: String) async {
        let trimmed = editedContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await review(proposal, failing: "save memory") {
            try await MemoryService.shared.saveProposalAsMemory(proposalId: proposal.id, content: trimmed)
        }
    }

    /// Delete (reject) a proposal and remove it from the current list.
    private func deleteProposal(_ proposal: MemoryProposal) async {
        await review(proposal, failing: "delete proposal") {
            try await MemoryService.shared.reviewProposal(proposalId: proposal.id, action: "reject", feedback: "Deleted by user")
        }
    }
}

// MARK: - Proposal Card Component

/// Card displaying a memory proposal with approve/reject and edit/save/delete actions
struct ProposalCard: View {
    let proposal: MemoryProposal
    let onApprove: () -> Void
    let onReject: () -> Void
    /// Called when user edits the proposal text and taps "Save as Memory".
    let onSaveAsMemory: (String) -> Void
    /// Called when user chooses to delete (reject) the proposal entirely.
    let onDelete: () -> Void

    @State private var isEditing: Bool = false
    @State private var draftContent: String = ""

    /// Trimmed version of the draft used for validation/disabled state. This
    /// lets users see clearly when the current content is considered "empty"
    /// without silently falling back to the original proposal text.
    private var trimmedDraftContent: String {
        draftContent.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Header. Where there is room (a wide window) Approve and Reject
            // are also here; where there is not (a phone) they are only in
            // the row of actions below, and the status line keeps its width.
            ViewThatFits(in: .horizontal) {
                HStack {
                    titleAndStatus
                    Spacer()
                    if proposal.status == "pending" {
                        HStack(spacing: Spacing.xs) {
                            GradientButton("Approve", icon: "checkmark", style: .primary) {
                                onApprove()
                            }
                            .frame(width: 100)
                            GradientButton("Reject", icon: "xmark", style: .secondary) {
                                onReject()
                            }
                            .frame(width: 100)
                        }
                    }
                }
                titleAndStatus
            }

            // Content (editable when in edit mode)
            if isEditing {
                TextEditor(text: $draftContent)
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextSecondary)
                    .frame(minHeight: 140)
                    .padding(Spacing.sm)
                    .background(Color.aicovenGlass)
                    .cornerRadius(BorderRadius.sm)
            } else {
                Text(proposal.proposedContent)
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextSecondary)
                    .lineLimit(5)
            }

            // Reason (if provided)
            if let reason = proposal.reason {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundColor(.aicovenTeal)

                    Text(reason)
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextSecondary)
                        .italic()
                }
                .padding(Spacing.sm)
                .background(Color.aicovenGlass.opacity(0.5))
                .cornerRadius(BorderRadius.sm)
            }

            // Tags
            if let tags = proposal.proposedTags, !tags.isEmpty {
                HStack(spacing: Spacing.xxs) {
                    ForEach(tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTeal)
                            .padding(.horizontal, Spacing.xs)
                            .padding(.vertical, 2)
                            .background(Color.aicovenGlass)
                            .cornerRadius(BorderRadius.sm)
                    }
                }
            }

            // Actions (only for pending proposals): on one line where they
            // fit, on two where they do not.
            if proposal.status == "pending" {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.xs) {
                        mainActions
                        otherActions
                    }
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack(spacing: Spacing.xs) { mainActions }
                        HStack(spacing: Spacing.md) { otherActions }
                    }
                }
            }
        }
        // As wide as the list, whatever it holds.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.md)
        .glassMorphism(cornerRadius: BorderRadius.md)
        .onAppear {
            if draftContent.isEmpty {
                draftContent = proposal.proposedContent
            }
        }
        // Keep the draft content in sync if the underlying proposal content
        // changes while this view is mounted (e.g. list refresh), but avoid
        // clobbering user edits while they are actively editing.
        .onChange(of: proposal.proposedContent) { newValue in
            if !isEditing {
                draftContent = newValue
            }
        }
    }

    /// The title, and under it the status, the scope and when it was
    /// proposed, each at its own width: none is squeezed into a column.
    private var titleAndStatus: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            if let title = proposal.title {
                Text(title)
                    .font(.aicovenH3)
                    .foregroundColor(.aicovenTextPrimary)
            }

            HStack(spacing: Spacing.xs) {
                // Status badge
                StatusBadge(status: proposal.status)
                    .fixedSize()

                // Scope badge
                if let scope = proposal.scope {
                    Text(scope.capitalized)
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTeal)
                        .lineLimit(1)
                        .padding(.horizontal, Spacing.xs)
                        .padding(.vertical, 2)
                        .background(Color.aicovenGlass)
                        .cornerRadius(BorderRadius.sm)
                        .fixedSize()
                }

                // Date
                Text(proposal.createdAt, style: .relative)
                    .font(.aicovenCaption)
                    .foregroundColor(.aicovenTextTertiary)
                    .lineLimit(1)
            }
        }
    }

    /// Approve and Reject; or, while the text is edited, Save and Cancel.
    @ViewBuilder
    private var mainActions: some View {
        if isEditing {
            GradientButton("Save as Memory", icon: "checkmark", style: .primary) {
                onSaveAsMemory(draftContent)
            }
            .frame(width: 150)
            // Disable when the current edited content is effectively
            // empty; this avoids silently reusing the original
            // proposal text when the user has cleared the field.
            .disabled(trimmedDraftContent.isEmpty)

            Button("Cancel") {
                isEditing = false
                draftContent = proposal.proposedContent
            }
            .font(.aicovenBodySmall)
            .foregroundColor(.aicovenTeal)
            .buttonStyle(.plain)
            .fixedSize()
        } else {
            GradientButton("Approve", icon: "checkmark", style: .primary) {
                onApprove()
            }
            .frame(width: 100)

            GradientButton("Reject", icon: "xmark", style: .secondary) {
                onReject()
            }
            .frame(width: 100)
        }
    }

    /// Edit (unless the text is being edited) and Delete: words that stay
    /// whole.
    @ViewBuilder
    private var otherActions: some View {
        if !isEditing {
            Button {
                isEditing = true
                if draftContent.isEmpty {
                    draftContent = proposal.proposedContent
                }
            } label: {
                HStack(spacing: Spacing.xxs) {
                    Image(systemName: "pencil")
                    Text("Edit")
                }
                .font(.aicovenBodySmall)
                .foregroundColor(.aicovenTeal)
            }
            .buttonStyle(.plain)
            .fixedSize()
        }

        Button(role: .destructive) {
            onDelete()
        } label: {
            HStack(spacing: Spacing.xxs) {
                Image(systemName: "trash")
                Text("Delete")
            }
            .font(.aicovenBodySmall)
        }
        .fixedSize()
    }
}

/// Status badge component
struct StatusBadge: View {
    let status: String

    var statusColor: Color {
        switch status {
        case "pending": .orange
        case "approved": .green
        case "rejected": .red
        default: .gray
        }
    }

    var body: some View {
        Text(status.capitalized)
            .font(.aicovenCaption)
            .foregroundColor(statusColor)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.2))
            .cornerRadius(BorderRadius.sm)
    }
}

/// Empty state for proposals
struct EmptyProposalsState: View {
    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            IconBadge(icon: "doc.text.magnifyingglass", size: 60, color: .aicovenTeal)

            Text("No Proposals")
                .font(.aicovenH2)
                .foregroundColor(.aicovenTextPrimary)

            Text("Memory write proposals will appear here for review")
                .font(.aicovenBodySmall)
                .foregroundColor(.aicovenTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.xl)
    }
}
