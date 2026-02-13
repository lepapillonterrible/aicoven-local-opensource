import SwiftUI

// MARK: - Memory Card Component

/// Card displaying a single memory chunk with actions
struct MemoryCard: View {
    let memory: Memory
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onTogglePin: (Bool) -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Header with title and actions
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    if let title = memory.title {
                        Text(title)
                            .font(.aicovenH3)
                            .foregroundColor(.aicovenTextPrimary)
                    }

                    HStack(spacing: Spacing.xs) {
                        // Scope badge
                        ScopeBadge(scope: memory.scope)

                        // Pinned indicator
                        if memory.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.aicovenTeal)
                        }

                        // Date
                        Text(memory.createdAt, style: .relative)
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextTertiary)
                    }
                }

                Spacer()

                // Actions
                HStack(spacing: Spacing.xs) {
                    #if os(iOS)
                    // Mobile: Menu for actions
                    Menu {
                        Button {
                            onTogglePin(!memory.isPinned)
                        } label: {
                            Label(memory.isPinned ? "Unpin" : "Pin", systemImage: memory.isPinned ? "pin.slash" : "pin")
                        }

                        Button {
                            onEdit()
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 20)) // Larger target
                            .foregroundColor(.aicovenTextSecondary)
                            .padding(8) // Touch padding
                            .background(Color.aicovenGlass)
                            .clipShape(Circle())
                    }
                    #else
                    // Desktop: Individual buttons with hover
                    // Pin/Unpin button
                    Button {
                        onTogglePin(!memory.isPinned)
                    } label: {
                        Image(systemName: memory.isPinned ? "pin.slash" : "pin")
                            .font(.system(size: 12))
                            .foregroundColor(.aicovenTextSecondary)
                    }
                    .buttonStyle(.plain)

                    // Edit button
                    Button {
                        onEdit()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                            .foregroundColor(.aicovenTextSecondary)
                    }
                    .buttonStyle(.plain)

                    // Delete button
                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    #endif
                }
                #if os(macOS)
                .opacity(isHovering ? 1 : 0)
                #endif
            }

            // Content preview
            Text(memory.content)
                .font(.aicovenBodySmall)
                .foregroundColor(.aicovenTextSecondary)
                .lineLimit(3)

            // Tags
            if let tags = memory.tags, !tags.isEmpty {
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
        }
        .padding(Spacing.md)
        .glassMorphism(cornerRadius: BorderRadius.md)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

/// Scope badge component
struct ScopeBadge: View {
    let scope: MemoryScope

    var scopeColor: Color {
        switch scope {
        case .user: .blue
        case .coven: .aicovenTeal
        case .agent: .aicovenPurple
        }
    }

    var body: some View {
        Text(scope.rawValue.capitalized)
            .font(.aicovenCaption)
            .foregroundColor(scopeColor)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 2)
            .background(scopeColor.opacity(0.2))
            .cornerRadius(BorderRadius.sm)
    }
}

/// Empty state for memory list
struct EmptyMemoryState: View {
    let covenId: String?
    let onAddMemory: () -> Void

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            IconBadge(icon: "brain", size: 60, color: .aicovenTeal)

            Text("No Memories Yet")
                .font(.aicovenH2)
                .foregroundColor(.aicovenTextPrimary)

            Text(covenId != nil ? "Add shared knowledge for this coven" : "Add personal memories to save important information")
                .font(.aicovenBodySmall)
                .foregroundColor(.aicovenTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)

            GradientButton("Add Memory", icon: "plus", style: .primary) {
                onAddMemory()
            }
            .frame(width: 160)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.xl)
    }
}
