import SwiftUI

/// Tab bar for managing multiple open tabs (threads and settings)
struct WorkspaceTabBar: View {
    @Binding var openTabs: [WorkspaceTab]
    @Binding var activeTabId: String?

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: Spacing.xxs) {
                ForEach(openTabs) { tab in
                    WorkspaceTabView(
                        tab: tab,
                        isActive: activeTabId == tab.id,
                        maxWidth: maxTabWidth(availableWidth: geometry.size.width),
                        onSelect: {
                            activeTabId = tab.id
                        },
                        onClose: {
                            closeTab(tab)
                        }
                    )
                }
            }
            .padding(.horizontal, Spacing.xs)
        }
    }

    /// Calculate maximum width for each tab based on available space
    private func maxTabWidth(availableWidth: CGFloat) -> CGFloat {
        let padding = Spacing.xs * 2 // horizontal padding
        let spacing = Spacing.xxs * CGFloat(max(0, openTabs.count - 1)) // spacing between tabs
        let usableWidth = availableWidth - padding - spacing
        let tabCount = CGFloat(openTabs.count)

        // Each tab gets equal width, minimum 80pt, maximum 200pt
        let calculatedWidth = usableWidth / tabCount
        return min(max(calculatedWidth, 80), 200)
    }

    /// Close a tab
    private func closeTab(_ tab: WorkspaceTab) {
        // Remove from open tabs
        openTabs.removeAll { $0.id == tab.id }

        // If closing the active tab, switch to another
        if activeTabId == tab.id {
            activeTabId = openTabs.first?.id
        }
    }
}

/// Individual thread tab
struct ThreadTab: View {
    let thread: Thread
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: Spacing.xs) {
            // Thread name
            Text(thread.title ?? "Untitled")
                .font(.aicovenBodySmall)
                .foregroundColor(isActive ? .aicovenTextPrimary : .aicovenTextSecondary)
                .lineLimit(1)

            // Close button
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundColor(isActive ? .aicovenTextSecondary : .aicovenTextTertiary)
            }
            .buttonStyle(.plain)
            .opacity(0) // Hidden by default
            .animation(.easeInOut(duration: 0.2), value: isActive)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(
            Rectangle()
                .fill(isActive ? Color.aicovenGlass : Color.clear)
        )
        .overlay(
            Rectangle()
                .fill(isActive ? Color.aicovenTeal : Color.clear)
                .frame(height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .onHover { _ in
            // Show close button on hover would need UIViewRepresentable
            // For now, close button is always visible
        }
    }
}

// MARK: - Hover Support

/// Workspace tab view with hover support for showing close button
struct WorkspaceTabView: View {
    let tab: WorkspaceTab
    let isActive: Bool
    let maxWidth: CGFloat
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Spacing.xs) {
            // Tab title
            Text(tab.title)
                .font(.aicovenBodySmall)
                .foregroundColor(isActive ? .aicovenTextPrimary : .aicovenTextSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            // Close button (show on hover or when active)
            if isHovering || isActive {
                Button(action: onClose) {
                    ZStack {
                        Circle()
                            .fill(Color.aicovenTextTertiary.opacity(0.2))
                            .frame(width: 16, height: 16)

                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.aicovenTextPrimary)
                    }
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .frame(width: maxWidth)
        .background(
            RoundedRectangle(cornerRadius: BorderRadius.sm)
                .fill(isActive ? Color.aicovenGlass : (isHovering ? Color.aicovenGlass.opacity(0.5) : Color.clear))
        )
        .overlay(
            Rectangle()
                .fill(isActive ? Color.aicovenTeal : Color.clear)
                .frame(height: 3)
                .frame(maxHeight: .infinity, alignment: .bottom)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

#Preview {
    VStack {
        WorkspaceTabBar(
            openTabs: .constant([
                .thread(Thread(
                    id: "1",
                    userId: "user1",
                    covenId: "coven1",
                    title: "Design Discussion",
                    createdAt: Date(),
                    updatedAt: Date(),
                    lastMessageAt: Date()
                )),
                .profile,
                .settings
            ]),
            activeTabId: .constant("1")
        )

        Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.aicovenDark)
}
