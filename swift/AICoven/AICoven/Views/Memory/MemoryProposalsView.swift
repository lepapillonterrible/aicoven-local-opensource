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

    let statuses = ["pending", "approved", "rejected", "all"]

    var body: some View {
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
                        }
                    }
                    .padding(Spacing.lg)
                }
            }
        }
        .task {
            await loadProposals()
        }
    }

    // MARK: - Actions

    /// Load proposals from API
    private func loadProposals() async {
        isLoading = true
        errorMessage = nil

        do {
            proposals = try await MemoryService.shared.listProposals(
                covenId: covenId,
                status: selectedStatus
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Review a proposal (approve/reject only – used by the Approve/Reject
    /// buttons. Edit/save/delete flows are handled separately below.)
    private func reviewProposal(_ proposal: MemoryProposal, action: String) async {
        do {
            let updated = try await MemoryService.shared.reviewProposal(
                proposalId: proposal.id,
                action: action
            )
            // Update in local list
            if let index = proposals.firstIndex(where: { $0.id == updated.id }) {
                proposals[index] = updated
            }
            // If we are showing only pending proposals, remove non-pending ones
            if selectedStatus == "pending", updated.status != "pending" {
                proposals.removeAll { $0.id == updated.id }
            }
        } catch {
            errorMessage = "Failed to \(action) proposal: \(error.localizedDescription)"
        }
    }

    /// Save the (possibly edited) proposal content as a real memory chunk and
    /// mark the underlying proposal as rejected so it no longer appears as
    /// pending. This lets users treat proposals as editable drafts without
    /// requiring backend schema changes.
    private func saveProposalAsMemory(_ proposal: MemoryProposal, editedContent: String) async {
        let trimmed = editedContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            // Derive title from first line if not already present
            let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? ""
            let title = firstLine.isEmpty ? proposal.title : firstLine
            let scope = proposal.scope ?? (covenId == nil ? "user" : "coven")
            let tags = proposal.proposedTags
            // For personal proposals, covenId will be nil; otherwise use the
            // coven context for this view.
            _ = try await MemoryService.shared.createMemory(
                covenId: covenId,
                scope: scope,
                title: title,
                content: trimmed,
                tags: tags,
                isPinned: false
            )
            // Also index this memory locally with an embedding so it can be
            // used by the context sandwich, even while the legacy backend
            // APIs are being phased out.
            _ = try await EmbeddingService.shared.indexMemory(
                scope: scope,
                text: trimmed,
                tags: tags ?? [],
                pii: false,
                createdBy: nil,
                source: proposal.sourceMessageId
            )
            // Mark proposal as rejected so it no longer shows in "pending".
            let updated = try await MemoryService.shared.reviewProposal(
                proposalId: proposal.id,
                action: "reject",
                feedback: "Saved as manual memory from Swift client"
            )
            if let index = proposals.firstIndex(where: { $0.id == updated.id }) {
                proposals[index] = updated
            }
            if selectedStatus == "pending" {
                proposals.removeAll { $0.id == updated.id }
            }
        } catch {
            errorMessage = "Failed to save memory: \(error.localizedDescription)"
        }
    }

    /// Delete (reject) a proposal and remove it from the current list.
    private func deleteProposal(_ proposal: MemoryProposal) async {
        do {
            let updated = try await MemoryService.shared.reviewProposal(
                proposalId: proposal.id,
                action: "reject",
                feedback: "Deleted by user"
            )
            if let index = proposals.firstIndex(where: { $0.id == updated.id }) {
                proposals[index] = updated
            }
            if selectedStatus == "pending" {
                proposals.removeAll { $0.id == updated.id }
            }
        } catch {
            errorMessage = "Failed to delete proposal: \(error.localizedDescription)"
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
            // Header
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    if let title = proposal.title {
                        Text(title)
                            .font(.aicovenH3)
                            .foregroundColor(.aicovenTextPrimary)
                    }

                    HStack(spacing: Spacing.xs) {
                        // Status badge
                        StatusBadge(status: proposal.status)

                        // Scope badge
                        if let scope = proposal.scope {
                            Text(scope.capitalized)
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTeal)
                                .padding(.horizontal, Spacing.xs)
                                .padding(.vertical, 2)
                                .background(Color.aicovenGlass)
                                .cornerRadius(BorderRadius.sm)
                        }

                        // Date
                        Text(proposal.createdAt, style: .relative)
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextTertiary)
                    }
                }

                Spacer()

                // Actions (only for pending proposals)
                if proposal.status == "pending" {
                    HStack(spacing: Spacing.xs) {
                        // Approve button
                        GradientButton("Approve", icon: "checkmark", style: .primary) {
                            onApprove()
                        }
                        .frame(width: 100)

                        // Reject button
                        GradientButton("Reject", icon: "xmark", style: .secondary) {
                            onReject()
                        }
                        .frame(width: 100)
                    }
                }
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

            // Actions (only for pending proposals)
            if proposal.status == "pending" {
                HStack(spacing: Spacing.xs) {
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
                    } else {
                        GradientButton("Approve", icon: "checkmark", style: .primary) {
                            onApprove()
                        }
                        .frame(width: 100)

                        GradientButton("Reject", icon: "xmark", style: .secondary) {
                            onReject()
                        }
                        .frame(width: 100)

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
                }
            }
        }
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
