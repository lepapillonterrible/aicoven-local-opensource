import SwiftUI

/// Activity feed surfacing pending memory proposals, unread agent replies, and
/// budget alerts. Mirrors the cloud Activity surface; data comes from the
/// local-first `ActivityService`.
struct ActivityView: View {
    @ObservedObject private var activityBadgeStore = ActivityBadgeStore.shared
    let onOpenTab: (WorkspaceTabType) -> Void

    @State private var activityData: ActivityResponse?
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        ZStack {
            NebulaBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if isLoading, activityData == nil {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    } else if let error {
                        VStack {
                            Text("Failed to load activity.")
                                .foregroundColor(.red)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button("Retry") {
                                Task { await loadData() }
                            }
                            .padding(.top)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                    } else if let data = activityData {
                        if data.unreadAgentReplies.isEmpty,
                           data.pendingMemoryProposalsCount == 0,
                           data.recentBudgetAlerts.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "bell.slash")
                                    .font(.system(size: 40))
                                    .foregroundColor(.secondary)
                                Text("No pending activity")
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 300)
                            .background(Color.aicovenGlass)
                            .cornerRadius(16)
                        } else {
                            // Memory Proposals
                            if data.pendingMemoryProposalsCount > 0 {
                                SectionHeader(title: "Memory", icon: "brain")

                                MemoryProposalCard(
                                    count: data.pendingMemoryProposalsCount,
                                    title: "Memory Proposals Pending",
                                    subtitle: "You have {{count}} memor{{suffix}} waiting for approval"
                                ) {
                                    onOpenTab(.memoryProposals(covenId: nil))
                                }
                            }

                            // Unread Agent Replies
                            if !data.unreadAgentReplies.isEmpty {
                                SectionHeader(title: "Agent Replies", icon: "message.fill")

                                VStack(spacing: 12) {
                                    ForEach(data.unreadAgentReplies) { reply in
                                        AgentReplyCard(reply: reply) {
                                            openThread(reply)
                                        }
                                    }
                                }
                            }

                            // Budget Alerts
                            if !data.recentBudgetAlerts.isEmpty {
                                SectionHeader(title: "Budget Alerts", icon: "exclamationmark.triangle.fill")

                                VStack(spacing: 12) {
                                    ForEach(data.recentBudgetAlerts) { alert in
                                        BudgetAlertCard(alert: alert) {
                                            onOpenTab(.budget)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(32)
            }
        }
        .onAppear {
            Task { await loadData() }
        }
    }

    private func loadData() async {
        isLoading = true
        error = nil
        do {
            let data = try await ActivityService.shared.getActivity()
            activityData = data
            await activityBadgeStore.markViewed(activity: data)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func openThread(_ reply: ActivityAgentReply) {
        Task {
            try? await ActivityService.shared.markThreadAsRead(threadId: reply.threadId)

            await MainActor.run {
                let thread = Thread(
                    id: reply.threadId,
                    userId: "",
                    covenId: reply.covenId,
                    title: reply.title,
                    agentId: reply.agentId,
                    agentName: reply.agentName,
                    agentModel: nil,
                    isPinned: false,
                    isArchived: false,
                    messageCount: 0,
                    createdAt: Date(),
                    updatedAt: nil,
                    lastMessageAt: nil
                )
                onOpenTab(.thread(thread))

                if let currentData = activityData {
                    let filtered = currentData.unreadAgentReplies.filter { $0.id != reply.id }
                    activityData = ActivityResponse(
                        unreadAgentReplies: filtered,
                        pendingMemoryProposalsCount: currentData.pendingMemoryProposalsCount,
                        pendingMemoryProposalsFingerprint: currentData.pendingMemoryProposalsFingerprint,
                        pendingFactPromotionsCount: currentData.pendingFactPromotionsCount,
                        pendingFactPromotionsFingerprint: currentData.pendingFactPromotionsFingerprint,
                        recentBudgetAlerts: currentData.recentBudgetAlerts
                    )
                }
            }
        }
    }
}

// MARK: - Components

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
        }
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

struct MemoryProposalCard: View {
    let count: Int
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.2))
                        .frame(width: 40, height: 40)
                    Image(systemName: "brain.head.profile")
                        .foregroundColor(.orange)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(subtitleWithCount)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color.aicovenGlass)
            .cornerRadius(12)
            .shadow(color: Color.black.opacity(0.1), radius: 5, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    private var subtitleWithCount: String {
        var out = subtitle.replacingOccurrences(of: "{{count}}", with: "\(count)")
        out = out.replacingOccurrences(of: "{{suffix}}", with: count == 1 ? "y" : "ies")
        return out
    }
}

struct AgentReplyCard: View {
    let reply: ActivityAgentReply
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.purple.opacity(0.2))
                        .frame(width: 40, height: 40)
                    Image(systemName: "sparkles")
                        .foregroundColor(.purple)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(reply.agentName ?? "Agent")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("Replied in \(reply.title ?? "Untitled Thread")")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 10, height: 10)

                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .padding(.leading, 8)
            }
            .padding()
            .background(Color.aicovenGlass)
            .cornerRadius(12)
            .shadow(color: Color.black.opacity(0.1), radius: 5, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}

struct BudgetAlertCard: View {
    let alert: ActivityBudgetAlert
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.2))
                        .frame(width: 40, height: 40)
                    Image(systemName: "dollarsign.circle.fill")
                        .foregroundColor(.red)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(alert.provider.capitalized) Budget Alert")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("Threshold of \(alert.thresholdPercentage)% reached ($\(String(format: "%.2f", alert.usageAtAlert)) / $\(String(format: "%.2f", alert.budgetAmount)))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color.aicovenGlass)
            .cornerRadius(12)
            .shadow(color: Color.black.opacity(0.1), radius: 5, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}

/// Top-bar bell button that opens the Activity feed, with an unread badge.
/// Replaces the old profile menu in the workspace top bar (cloud parity).
struct ActivityBellButton: View {
    @ObservedObject private var activityBadgeStore = ActivityBadgeStore.shared
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.aicovenTextSecondary)
                    .frame(width: 32, height: 32)

                if activityBadgeStore.unreadCount > 0 {
                    Text(activityBadgeStore.unreadCount > 9 ? "9+" : "\(activityBadgeStore.unreadCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.red)
                        .clipShape(Capsule())
                        .offset(x: 2, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Activity")
    }
}
