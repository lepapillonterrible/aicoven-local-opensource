internal import Combine
import Foundation
import UserNotifications

/// Notifications made on this device (there is no server to push them):
/// when an agent's reply finishes, a turn needs the person's OK, or a turn
/// stops on a problem, while the app is not in front.
///
/// The permission is asked for in context, never at sign-in: by the line
/// a thread or an Overview offers once a reply has finished while the
/// person was away, or in Settings. What a notification says is the
/// composer's; whether it holds details is the person's choice, off until
/// they turn it on. Everything is one account's: a notification is made
/// only for the account signed in, and every one of them leaves when
/// another signs in.
@MainActor
final class LocalNotifications: ObservableObject {
    static let shared = LocalNotifications()

    /// Whether this device lets the app notify.
    enum Permission: Equatable {
        case notAsked
        case denied
        case allowed
    }

    /// The system's side, which a test replaces.
    struct Center {
        var permission: () async -> Permission
        /// Asks the person, with the system's prompt; true if they allow.
        var ask: () async -> Bool
        /// Shows a notification under `id`, in place of any earlier one
        /// under it.
        var show: (_ id: String, _ notification: ComposedNotification) async -> Void
        /// Takes back the notifications under these ids, delivered or not.
        var withdraw: (_ ids: [String]) -> Void
        var withdrawAll: () -> Void

        static let system = Center(
            permission: {
                switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
                case .notDetermined: .notAsked
                case .denied: .denied
                default: .allowed
                }
            },
            ask: { await (try? UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false },
            show: { id, notification in
                let content = UNMutableNotificationContent()
                content.title = notification.title
                content.subtitle = notification.subtitle
                content.body = notification.body
                content.sound = .default
                // Nothing of the thread or the account goes with it: the
                // id alone ties it to its thread, on this device.
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            },
            withdraw: { ids in
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
            },
            withdrawAll: {
                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            }
        )
    }

    /// The line that offers notifications: "Get a notification when
    /// Scout finishes?"
    struct Offer: Equatable {
        let agentName: String
    }

    /// How long after "Not now" the line is not offered again.
    static let quietAfterDeclining: TimeInterval = 7 * 24 * 60 * 60

    /// This device's permission; nil until it has been read.
    @Published private(set) var permission: Permission?
    @Published private(set) var offer: Offer?
    /// Whether the app is in front: nothing is notified of while it is.
    var appIsInFront = true

    private let center: Center
    private let defaults: UserDefaults
    private let signedIn: () -> String
    private let now: () -> Date

    init(
        center: Center = .system,
        defaults: UserDefaults = .standard,
        signedIn: @escaping () -> String = { UserScope.currentUserID },
        now: @escaping () -> Date = Date.init
    ) {
        self.center = center
        self.defaults = defaults
        self.signedIn = signedIn
        self.now = now
    }

    // MARK: - The person's choices, kept for each account

    /// Whether the account wants notifications at all: on, unless they
    /// turned them off in Settings.
    func isOn(for account: String) -> Bool {
        defaults.object(forKey: UserScope.scopedKey("notifications_on", for: account)) as? Bool ?? true
    }

    func setOn(_ isOn: Bool, for account: String) {
        objectWillChange.send()
        defaults.set(isOn, forKey: UserScope.scopedKey("notifications_on", for: account))
        if !isOn { center.withdrawAll() }
    }

    /// Whether a notification names the thread and says what was said:
    /// off unless the account turned it on.
    func showsDetails(for account: String) -> Bool {
        defaults.bool(forKey: UserScope.scopedKey("notification_details", for: account))
    }

    func setShowsDetails(_ shows: Bool, for account: String) {
        objectWillChange.send()
        defaults.set(shows, forKey: UserScope.scopedKey("notification_details", for: account))
    }

    // MARK: - Permission

    func refreshPermission() async {
        permission = await center.permission()
    }

    /// Turn on, from the line or from Settings: the system asks the
    /// person, and the line goes whatever they answer.
    func turnOn() async {
        offer = nil
        _ = await center.ask()
        await refreshPermission()
    }

    /// Not now: the line goes, and is not offered again for a week.
    func declineOffer(as account: String) {
        offer = nil
        defaults.set(now(), forKey: UserScope.scopedKey("notifications_offer_declined_at", for: account))
    }

    /// A reply of `agentName`'s finished while the person was away: the
    /// line is offered where the permission was never asked for, unless
    /// they said "Not now" within the last week or turned notifications
    /// off.
    func offerIfUseful(agentName: String?, as account: String) async {
        guard signedIn() == account, isOn(for: account) else { return }
        if permission == nil { await refreshPermission() }
        guard permission == .notAsked, signedIn() == account else { return }
        let declinedAt = defaults.object(forKey: UserScope.scopedKey("notifications_offer_declined_at", for: account)) as? Date
        if let declinedAt, now().timeIntervalSince(declinedAt) < Self.quietAfterDeclining { return }
        let named = agentName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        offer = Offer(agentName: named.isEmpty ? "Strix" : named)
    }

    // MARK: - Notifying

    /// The id of a thread's notification: one for a thread at a time, the
    /// latest in the earlier one's place.
    static func id(forThread threadID: String) -> String {
        "thread-\(threadID)"
    }

    /// Notifies of something in `thread`, which is `account`'s, in the
    /// scope named `placeName`: only while the app is not in front, the
    /// account is the one signed in and wants notifications, and this
    /// device allows them. Says whether it did.
    @discardableResult
    func notify(_ event: NotificationEvent, in thread: Thread, placeName: String, as account: String) async -> Bool {
        guard !appIsInFront, signedIn() == account, thread.userId == account, isOn(for: account) else { return false }
        if permission == nil { await refreshPermission() }
        // Asked again: the wait above may have been long enough for the
        // person to come back, or for another account to sign in.
        guard permission == .allowed, !appIsInFront, signedIn() == account else { return false }
        let composed = NotificationComposer.compose(
            event, agentName: thread.agentName, threadTitle: ThreadListRules.title(of: thread), placeName: placeName,
            showsDetails: showsDetails(for: account)
        )
        await center.show(Self.id(forThread: thread.id), composed)
        return true
    }

    /// The thread came on screen: what was notified of it is seen.
    func threadShown(_ threadID: String) {
        center.withdraw([Self.id(forThread: threadID)])
    }

    /// Another account is signed in, or none: nothing notified to the
    /// first stays on the device's screen, and the line is not offered to
    /// the next for what the first did.
    func accountChanged() {
        offer = nil
        center.withdrawAll()
    }
}
