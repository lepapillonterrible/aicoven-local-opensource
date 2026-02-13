import SwiftUI

/// Memory explorer sheet that allows opening memory views in tabs
struct MemoryExplorerView: View {
    let covenId: String?
    @Binding var openTabs: [WorkspaceTab]
    @Binding var activeTabId: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.lg) {
                // Title
                Text("Memory")
                    .font(.aicovenH1)
                    .foregroundColor(.aicovenTextPrimary)
                    .padding(.top, Spacing.lg)

                // Description
                Text("Search and manage shared knowledge")
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.lg)

                // Action cards
                VStack(spacing: Spacing.md) {
                    // View memories
                    MemoryActionCard(
                        icon: "brain",
                        title: "View Memories",
                        description: "Browse and search saved memories",
                        color: .aicovenTeal
                    ) {
                        openMemoryList()
                    }

                    // View proposals
                    MemoryActionCard(
                        icon: "doc.text.magnifyingglass",
                        title: "Review Proposals",
                        description: "Approve or reject pending memory writes",
                        color: .orange
                    ) {
                        openMemoryProposals()
                    }

                    // Add memory
                    MemoryActionCard(
                        icon: "plus.circle.fill",
                        title: "Add Memory",
                        description: "Create a new memory manually",
                        color: .aicovenPurple
                    ) {
                        openAddMemory()
                    }
                }
                .padding(.horizontal, Spacing.lg)

                Spacer()
            }
            .navigationTitle("Memory")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
    }

    // MARK: - Actions

    /// Open memory list tab
    private func openMemoryList() {
        let tab = WorkspaceTab.memoryList(covenId: covenId)
        if !openTabs.contains(where: { $0.id == tab.id }) {
            openTabs.append(tab)
        }
        activeTabId = tab.id
        dismiss()
    }

    /// Open memory proposals tab
    private func openMemoryProposals() {
        let tab = WorkspaceTab.memoryProposals(covenId: covenId)
        if !openTabs.contains(where: { $0.id == tab.id }) {
            openTabs.append(tab)
        }
        activeTabId = tab.id
        dismiss()
    }

    /// Open add memory tab
    private func openAddMemory() {
        let tab = WorkspaceTab.addMemory(covenId: covenId)
        if !openTabs.contains(where: { $0.id == tab.id }) {
            openTabs.append(tab)
        }
        activeTabId = tab.id
        dismiss()
    }
}

// MARK: - Memory Action Card

/// Card for a memory action
struct MemoryActionCard: View {
    let icon: String
    let title: String
    let description: String
    let color: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.md) {
                IconBadge(icon: icon, size: 44, color: color)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title)
                        .font(.aicovenH3)
                        .foregroundColor(.aicovenTextPrimary)

                    Text(description)
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.aicovenCaption)
                    .foregroundColor(.aicovenTextTertiary)
            }
            .padding(Spacing.md)
            .glassMorphism(cornerRadius: BorderRadius.md)
            .scaleEffect(isHovering ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

#Preview {
    @Previewable @State var openTabs: [WorkspaceTab] = []
    @Previewable @State var activeTabId: String?

    MemoryExplorerView(
        covenId: nil,
        openTabs: $openTabs,
        activeTabId: $activeTabId
    )
}
