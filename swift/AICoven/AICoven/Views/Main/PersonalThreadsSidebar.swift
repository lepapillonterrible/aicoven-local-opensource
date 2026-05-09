import SwiftUI

/// Sidebar for personal threads (conversations outside covens)
struct PersonalThreadsSidebar: View {
    @Binding var threads: [Thread]
    let covens: [Coven]
    @Binding var selectedThread: Thread?
    @Binding var isExpanded: Bool

    @State private var showStrixSettings = false

    /// Strix settings for displaying the preferred model in thread rows
    @State private var strixSettings: LocalStrixSettings?

    let onNewThread: () -> Void
    let onCreateCoven: () -> Void
    let onSelectThread: (Thread) -> Void
    let onDeleteThread: (Thread) -> Void
    let onRefresh: () async -> Void
    let onSwitchToCovens: () -> Void
    let onSelectCoven: (Coven) -> Void
    let onOpenWorkspaceTab: (WorkspaceTabType) -> Void
    @State private var showCovenMenu = false

    var body: some View {
        VStack(spacing: 0) {
            #if !os(macOS)
            // Workspace switcher
            WorkspaceSwitcher(
                currentWorkspace: .home,
                onSwitch: onSwitchToCovens,
                isExpanded: isExpanded
            )
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.sm)
            GradientDivider()
            #endif

            // Header with actions
            VStack(spacing: Spacing.sm) {
                // Title with collapse button
                HStack {
                    if isExpanded {
                        Image(systemName: "person.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.aicovenTeal)
                    }
                    Spacer()

                    if isExpanded {
                        // Strix settings button
                        Button(action: { showStrixSettings = true }) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 14))
                                .foregroundColor(.aicovenTextSecondary)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                    }

                    // Collapse button
                    Button(action: { isExpanded.toggle() }) {
                        Image(systemName: isExpanded ? "sidebar.left" : "sidebar.right")
                            .font(.system(size: 14))
                            .foregroundColor(.aicovenTextSecondary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                }

                #if os(macOS)
                if isExpanded {
                    covenScopeDropdown
                        .padding(.top, Spacing.xs)
                }
                #endif

                // Action buttons (only show when expanded)
                if isExpanded {
                    VStack(spacing: Spacing.xs) {
                        // New chat button
                        Button(action: onNewThread) {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: "plus.message")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("New Chat")
                                    .font(.aicovenBodyMedium)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.sm)
                            .background(
                                LinearGradient(
                                    colors: [Color.aicovenTeal, Color.aicovenPurple],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .foregroundColor(.white)
                            .cornerRadius(BorderRadius.md)
                        }
                        .buttonStyle(.plain)

                        // Create coven button
                        Button(action: onCreateCoven) {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: "person.3")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Create Coven")
                                    .font(.aicovenBodyMedium)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.sm)
                            .background(Color.aicovenGlass)
                            .overlay(
                                RoundedRectangle(cornerRadius: BorderRadius.md)
                                    .strokeBorder(Color.aicovenBorder, lineWidth: 1)
                            )
                            .foregroundColor(.aicovenTextPrimary)
                            .cornerRadius(BorderRadius.md)
                        }
                        .buttonStyle(.plain)

                        #if os(macOS)
                        Button {
                            onOpenWorkspaceTab(.memoryList(covenId: nil))
                        } label: {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: "brain")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Memory")
                                    .font(.aicovenBodyMedium)
                                Spacer()
                                Text("Strix")
                                    .font(.aicovenCaption)
                                    .foregroundColor(.aicovenTextTertiary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.sm)
                            .padding(.horizontal, Spacing.sm)
                            .background(Color.aicovenGlass)
                            .overlay(
                                RoundedRectangle(cornerRadius: BorderRadius.md)
                                    .strokeBorder(Color.aicovenBorder, lineWidth: 1)
                            )
                            .cornerRadius(BorderRadius.md)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.aicovenTextPrimary)
                        #endif
                    }
                }
            }
            .padding(Spacing.md)

            GradientDivider()

            // Thread list (only show when expanded)
            if isExpanded {
                ScrollView {
                    VStack(spacing: Spacing.lg) {
                        if threads.isEmpty {
                            // Empty state
                            VStack(spacing: Spacing.md) {
                                IconBadge(icon: "message", size: 48, color: .aicovenTeal)

                                Text("No conversations yet")
                                    .font(.aicovenBodyMedium)
                                    .foregroundColor(.aicovenTextSecondary)

                                Text("Start a new chat with the default assistant")
                                    .font(.aicovenBodySmall)
                                    .foregroundColor(.aicovenTextTertiary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, Spacing.lg)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.xl)
                        } else {
                            LazyVStack(spacing: Spacing.xs) {
                                ForEach(threads) { thread in
                                    PersonalThreadRow(
                                        thread: thread,
                                        isSelected: selectedThread?.id == thread.id,
                                        preferredModel: strixSettings?.model,
                                        onTap: {
                                            onSelectThread(thread)
                                        },
                                        onDelete: {
                                            onDeleteThread(thread)
                                        }
                                    )
                                }
                            }
                            .padding(Spacing.sm)
                        }

                        #if os(macOS)
                        WorkspaceToolsSection(
                            onOpenTab: onOpenWorkspaceTab,
                            isCollapsible: true
                        )
                        .padding(.horizontal, Spacing.sm)
                        .padding(.bottom, Spacing.lg)
                        #endif

                        if !threads.isEmpty {
                            Spacer(minLength: Spacing.md)
                        }
                    }
                }
            }
        }
        .frame(width: isExpanded ? 280 : 60)
        .background(Color.aicovenGlass.opacity(0.5))
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
        .sheet(isPresented: $showStrixSettings) {
            StrixSettingsView(onClose: {
                // Dismiss the sheet once the agent settings have been saved
                showStrixSettings = false
                // Reload settings to reflect any changes in thread rows
                Task {
                    strixSettings = try? await StrixSettingsService.shared.loadPersonalStrix()
                }
            })
        }
        .task {
            // Load Strix settings on appear to display the preferred model
            strixSettings = try? await StrixSettingsService.shared.loadPersonalStrix()
        }
    }

    #if os(macOS)
    private var covenScopeDropdown: some View {
        Button {
            showCovenMenu.toggle()
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13))
                    .foregroundColor(.aicovenTeal)

                if isExpanded {
                    Text("Coven: Strix")
                        .font(.aicovenBodySmall)
                        .foregroundColor(.aicovenTextPrimary)

                    Spacer()

                    Text("\(covens.count)")
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextTertiary)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.aicovenTextTertiary)
                }
            }
            .padding(.horizontal, isExpanded ? Spacing.xs : 4)
            .padding(.vertical, Spacing.xs)
            .background(Color.aicovenGlass)
            .cornerRadius(BorderRadius.sm)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: isExpanded ? .infinity : nil)
        .popover(isPresented: $showCovenMenu) {
            CovenScopePopoverContent(
                covens: covens,
                onSelectStrix: {
                    showCovenMenu = false
                },
                onSelectCoven: { coven in
                    showCovenMenu = false
                    onSelectCoven(coven)
                },
                onCreateCoven: {
                    showCovenMenu = false
                    onCreateCoven()
                }
            )
        }
    }
    #endif
}

#if os(macOS)
private struct CovenScopePopoverContent: View {
    let covens: [Coven]
    let onSelectStrix: () -> Void
    let onSelectCoven: (Coven) -> Void
    let onCreateCoven: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Covens")
                .font(.aicovenCaption)
                .foregroundColor(.aicovenTextTertiary)
                .padding(.horizontal, Spacing.sm)
                .padding(.top, Spacing.xs)

            scopeRow(
                icon: "sparkles",
                title: "Strix",
                subtitle: "Default coven",
                isSelected: true,
                tint: .aicovenTeal,
                action: onSelectStrix
            )

            if !covens.isEmpty {
                Rectangle()
                    .fill(Color.aicovenBorder)
                    .frame(height: 1)
                    .padding(.vertical, Spacing.xs)

                Text("Covens Pro")
                    .font(.aicovenCaption)
                    .foregroundColor(.aicovenTextTertiary)
                    .padding(.horizontal, Spacing.sm)

                ForEach(covens) { coven in
                    scopeRow(
                        icon: "person.3.fill",
                        title: coven.name,
                        action: { onSelectCoven(coven) }
                    )
                }
            }

            Rectangle()
                .fill(Color.aicovenBorder)
                .frame(height: 1)
                .padding(.vertical, Spacing.xs)

            scopeRow(
                icon: "plus.circle.fill",
                title: "New Coven",
                tint: .aicovenTeal,
                action: onCreateCoven
            )
        }
        .padding(Spacing.xs)
        .frame(width: 260)
        .background(Color.aicovenSurfaceElevated)
    }

    private func scopeRow(
        icon: String,
        title: String,
        subtitle: String? = nil,
        isSelected: Bool = false,
        tint: Color = .aicovenTextSecondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: icon)
                    .font(.aicovenBodySmall)
                    .foregroundColor(tint)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.aicovenBodySmall)
                        .foregroundColor(.aicovenTextPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextTertiary)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.aicovenTeal)
                }
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif

/// Individual thread row in sidebar
struct PersonalThreadRow: View {
    let thread: Thread
    let isSelected: Bool
    /// The preferred model from Strix settings, used as fallback when thread has no model
    let preferredModel: String?
    let onTap: () -> Void
    let onDelete: () -> Void

    /// Determines the model name to display:
    /// 1. Thread's agentModel (if available - represents the last model used)
    /// 2. Strix preferred model (if configured)
    /// 3. nil (don't show any model)
    private var displayModel: String? {
        thread.agentModel ?? preferredModel
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Spacing.sm) {
                // Icon
                Image(systemName: "message.fill")
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? .aicovenTeal : .aicovenTextSecondary)

                // Title
                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.title ?? "Untitled Chat")
                        .font(.aicovenBody)
                        .foregroundColor(isSelected ? .aicovenTextPrimary : .aicovenTextSecondary)
                        .lineLimit(1)

                    // Show agent name and model (if available)
                    let agentName = thread.agentName ?? "Strix"
                    if let model = displayModel {
                        Text("\(agentName) • \(model)")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)
                    } else {
                        Text(agentName)
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)
                    }

                    if let updatedAt = thread.updatedAt {
                        Text(relativeTime(from: updatedAt))
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextTertiary)
                    }
                }

                Spacer()

                // Pin indicator
                if thread.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.aicovenTeal)
                }
            }
            .padding(Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: BorderRadius.sm)
                    .fill(isSelected ? Color.aicovenPurple.opacity(0.2) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BorderRadius.sm)
                    .strokeBorder(
                        isSelected ? Color.aicovenTeal.opacity(0.5) : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            // Rename / pin are server-backed features; expose only when implemented.
            Button("Delete", role: .destructive) {
                onDelete()
            }
        }
    }

    /// Format relative time without seconds
    private func relativeTime(from date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date, to: now)

        if let years = components.year, years > 0 {
            return "\(years)y"
        } else if let months = components.month, months > 0 {
            return "\(months)mo"
        } else if let days = components.day, days > 0 {
            return "\(days)d"
        } else if let hours = components.hour, hours > 0 {
            return "\(hours)h"
        } else if let minutes = components.minute, minutes > 0 {
            return "\(minutes)m"
        } else {
            return "now"
        }
    }
}
