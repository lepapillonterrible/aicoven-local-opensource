import SwiftUI

/// Sidebar for personal threads in the local workspace.
struct PersonalThreadsSidebar: View {
    @Binding var threads: [Thread]
    @Binding var selectedThread: Thread?
    @Binding var isExpanded: Bool

    @State private var showStrixSettings = false

    /// Strix settings for displaying the preferred model in thread rows
    @State private var strixSettings: LocalStrixSettings?

    let onNewThread: () -> Void
    let onSelectThread: (Thread) -> Void
    let onDeleteThread: (Thread) -> Void
    var onSwitchToCovens: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // Header with actions
            VStack(spacing: Spacing.sm) {
                // Title with collapse button
                HStack {
                    if isExpanded {
                        Image(systemName: "message")
                            .font(.aicovenH3)
                            .foregroundColor(.aicovenTeal)
                        Text("Conversations")
                            .font(.aicovenH2)
                            .foregroundColor(.aicovenTextPrimary)
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

                        // Switch to covens workspace
                        if let onSwitchToCovens {
                            Button(action: onSwitchToCovens) {
                                HStack(spacing: Spacing.xs) {
                                    Image(systemName: "person.3")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("Covens")
                                        .font(.aicovenBodyMedium)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Spacing.sm)
                                .background(Color.aicovenPurple.opacity(0.3))
                                .foregroundColor(.aicovenTextPrimary)
                                .cornerRadius(BorderRadius.md)
                                .overlay(
                                    RoundedRectangle(cornerRadius: BorderRadius.md)
                                        .strokeBorder(Color.aicovenPurple.opacity(0.5), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(Spacing.md)

            GradientDivider()

            // Thread list (only show when expanded)
            if isExpanded {
                ScrollView {
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
                }
            }
        }
        .frame(width: isExpanded ? 280 : 60)
        .background(Color.aicovenGlass.opacity(0.5))
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
        .sheet(isPresented: $showStrixSettings) {
            StrixSettingsView(onClose: {
                // Dismiss the sheet once the agent settings have been saved.
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
}

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
