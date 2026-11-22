import SwiftUI

/// The one line that offers notifications, in context, as the cloud
/// app's: "Get a notification when Strix finishes?" with Not now and Turn
/// on. It shows in a thread and on an Overview while an offer waits for
/// an answer, and is nothing otherwise. Turn on is what brings the
/// system's question.
struct NotificationAskLine: View {
    @ObservedObject private var notifications = LocalNotifications.shared

    var body: some View {
        if let offer = notifications.offer {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "bell")
                    .foregroundStyle(Color.aicovenTextSecondary)
                    .accessibilityHidden(true)
                Text("Get a notification when \(offer.agentName) finishes?")
                    .font(.aicovenBodySmall)
                    .foregroundStyle(Color.aicovenTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Not now") { notifications.declineOffer(as: UserScope.currentUserID) }
                    .buttonStyle(.textLink)
                Button("Turn on") {
                    Task { await notifications.turnOn() }
                }
                .buttonStyle(.textLink)
                .fontWeight(.semibold)
                .disabled(notifications.isAsking)
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BorderRadius.md).fill(Color.aicovenSurfaceElevated))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("notification-ask-line")
            // The line comes by itself, at the top: VoiceOver is told,
            // once for each offer, wherever it is first shown.
            .onAppear {
                guard notifications.takeOfferAnnouncement() else { return }
                AccessibilityNotification.Announcement("Get a notification when \(offer.agentName) finishes? Not now and Turn on are at the top.").post()
            }
        }
    }
}
