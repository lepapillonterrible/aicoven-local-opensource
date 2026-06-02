import Foundation
import SwiftUI
internal import Combine

/// An unread agent reply surfaced in the Activity feed.
///
/// Local-first note: the open-source client does not track per-message read
/// state on a server, so this list is currently always empty. The type is kept
/// to mirror the cloud Activity surface and allow future on-device wiring.
struct ActivityAgentReply: Identifiable, Equatable {
    let id: String
    let threadId: String
    let covenId: String?
    let title: String?
    let agentId: String?
    let agentName: String?
}

/// A recent budget threshold alert surfaced in the Activity feed.
struct ActivityBudgetAlert: Identifiable, Equatable {
    let id: String
    let provider: String
    let thresholdPercentage: Int
    let usageAtAlert: Double
    let budgetAmount: Double
}

/// Aggregated activity for the current user, mirroring the cloud
/// `/activity` response shape but derived entirely from local sources.
struct ActivityResponse: Equatable {
    var unreadAgentReplies: [ActivityAgentReply]
    var pendingMemoryProposalsCount: Int
    var pendingMemoryProposalsFingerprint: String?
    var pendingFactPromotionsCount: Int
    var pendingFactPromotionsFingerprint: String?
    var recentBudgetAlerts: [ActivityBudgetAlert]

    static let empty = ActivityResponse(
        unreadAgentReplies: [],
        pendingMemoryProposalsCount: 0,
        pendingMemoryProposalsFingerprint: nil,
        pendingFactPromotionsCount: 0,
        pendingFactPromotionsFingerprint: nil,
        recentBudgetAlerts: []
    )
}

/// Local-first activity aggregator.
///
/// Unlike the cloud client (which fetches `GET /activity`), this derives the
/// activity feed from on-device sources: pending memory proposals from
/// `MemoryService`. Unread agent replies and budget alerts are placeholders
/// for future on-device wiring.
actor ActivityService {
    static let shared = ActivityService()

    private init() {}

    /// Build the current activity snapshot from local data sources.
    func getActivity() async throws -> ActivityResponse {
        let pendingProposals = await (try? MemoryService.shared.listProposals(covenId: nil, status: "pending")) ?? []

        return ActivityResponse(
            unreadAgentReplies: [],
            pendingMemoryProposalsCount: pendingProposals.count,
            pendingMemoryProposalsFingerprint: nil,
            pendingFactPromotionsCount: 0,
            pendingFactPromotionsFingerprint: nil,
            recentBudgetAlerts: []
        )
    }

    /// No-op locally: there is no server-side read state to update.
    func markThreadAsRead(threadId _: String) async throws {}
}

/// Drives the Activity tab's unread badge.
@MainActor
final class ActivityBadgeStore: ObservableObject {
    static let shared = ActivityBadgeStore()

    @Published var unreadCount: Int = 0

    private init() {}

    /// Recompute the badge count from the latest activity snapshot.
    func refresh() async {
        guard let data = try? await ActivityService.shared.getActivity() else { return }
        unreadCount = data.pendingMemoryProposalsCount
            + data.pendingFactPromotionsCount
            + data.unreadAgentReplies.count
    }

    /// Clear the badge once the user has viewed the Activity surface.
    func markViewed(activity _: ActivityResponse) async {
        unreadCount = 0
    }
}
