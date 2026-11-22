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
        /// under it; false if the system would not take it.
        var show: (_ id: String, _ notification: ComposedNotification) async -> Bool
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
                do {
                    try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
                    return true
                } catch {
                    // The kind of failure only.
                    AppErrorReporter.log(message: "A notification was not taken by the system (\(type(of: error)))", context: "LocalNotifications.show")
                    return false
                }
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
    /// Whether the system is asking the person just now: nothing else
    /// asks, and nothing is offered, until they have answered.
    @Published private(set) var isAsking = false
    /// Whether the app is in front: nothing is notified of while it is.
    var appIsInFront = true

    /// Who the sign-in service last said is signed in (nobody: nil); not
    /// set until it has said.
    private var reported: String??
    private var offerWasAnnounced = false
    /// Counts the readings of the permission, so that only the latest is kept.
    private var permissionReads = 0
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
        defaults.object(forKey: Self.onKey(for: account)) as? Bool ?? true
    }

    func setOn(_ isOn: Bool, for account: String) {
        objectWillChange.send()
        defaults.set(isOn, forKey: Self.onKey(for: account))
        if !isOn {
            // Nothing stays notified, and nothing more is offered.
            center.withdrawAll()
            offer = nil
        }
    }

    private static func onKey(for account: String) -> String {
        UserScope.scopedKey("notifications_on", for: account)
    }

    private static func detailsKey(for account: String) -> String {
        UserScope.scopedKey("notification_details", for: account)
    }

    private static func declinedKey(for account: String) -> String {
        UserScope.scopedKey("notifications_offer_declined_at", for: account)
    }

    /// The account is deleted: its choices go with it.
    func forget(_ account: String) {
        for key in [Self.onKey(for: account), Self.detailsKey(for: account), Self.declinedKey(for: account)] {
            defaults.removeObject(forKey: key)
        }
    }

    /// Whether a notification names the thread and says what was said:
    /// off unless the account turned it on.
    func showsDetails(for account: String) -> Bool {
        defaults.bool(forKey: Self.detailsKey(for: account))
    }

    func setShowsDetails(_ shows: Bool, for account: String) {
        objectWillChange.send()
        defaults.set(shows, forKey: Self.detailsKey(for: account))
    }

    // MARK: - Permission

    /// Reads this device's permission. Only the latest reading is kept:
    /// one that was asked for earlier and answers later says nothing.
    func refreshPermission() async {
        permissionReads += 1
        let read = permissionReads
        let answer = await center.permission()
        guard read == permissionReads else { return }
        permission = answer
    }

    /// Turn on, from the line or from Settings: the system asks the
    /// person, and the line goes whatever they answer.
    func turnOn() async {
        guard !isAsking else { return }
        isAsking = true
        offer = nil
        _ = await center.ask()
        await refreshPermission()
        // Whatever was offered while the system was asking goes too.
        offer = nil
        isAsking = false
    }

    /// Not now: the line goes, and is not offered again for a week.
    func declineOffer(as account: String) {
        offer = nil
        defaults.set(now(), forKey: Self.declinedKey(for: account))
    }

    /// A reply of `agentName`'s finished while the person was away: the
    /// line is offered where the permission was never asked for, unless
    /// they said "Not now" within the last week or turned notifications
    /// off.
    func offerIfUseful(agentName: String?, as account: String) async {
        guard !isAsking, signedIn() == account, isOn(for: account) else { return }
        // Read each time: the person can have answered in the system's
        // own settings since it was last read.
        await refreshPermission()
        guard permission == .notAsked, !isAsking, signedIn() == account, isOn(for: account) else { return }
        let declinedAt = defaults.object(forKey: Self.declinedKey(for: account)) as? Date
        if let declinedAt, now().timeIntervalSince(declinedAt) < Self.quietAfterDeclining { return }
        let named = agentName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let offered = Offer(agentName: named.isEmpty ? "Strix" : named)
        if offer != offered { offerWasAnnounced = false }
        offer = offered
    }

    // MARK: - Notifying

    /// The id of a thread's notification: one for a thread at a time, the
    /// latest in the earlier one's place.
    static func id(forThread threadID: String) -> String {
        "\(idPrefix)\(threadID)"
    }

    private nonisolated static let idPrefix = "thread-"

    /// The thread a notification with this id is about; nil for an id
    /// that is not one of a thread's.
    nonisolated static func threadID(ofNotification id: String) -> String? {
        guard id.hasPrefix(idPrefix), id.count > idPrefix.count else { return nil }
        return String(id.dropFirst(idPrefix.count))
    }

    /// Notifies of something in `thread`, which is `account`'s, in the
    /// scope named `placeName`: only while the app is not in front, the
    /// account is the one signed in and wants notifications, and this
    /// device allows them; and only if what it is about still stands
    /// (`stands`) at the moment it is made. Says whether it did.
    @discardableResult
    func notify(
        _ event: NotificationEvent, in thread: Thread, placeName: String, as account: String, ifStill stands: @MainActor () -> Bool = { true }
    ) async -> Bool {
        guard !appIsInFront, signedIn() == account, thread.userId == account, isOn(for: account) else { return false }
        // Read each time: the person can have allowed or refused
        // notifications in the system's own settings since it was last
        // read.
        await refreshPermission()
        // Asked again: the wait above may have been long enough for the
        // person to come back, to turn notifications off, for another
        // account to sign in, or for what it is about to be over.
        guard permission == .allowed, !appIsInFront, signedIn() == account, isOn(for: account), stands() else { return false }
        let composed = NotificationComposer.compose(
            event, agentName: thread.agentName, threadTitle: ThreadListRules.title(of: thread), placeName: placeName,
            showsDetails: showsDetails(for: account)
        )
        return await center.show(Self.id(forThread: thread.id), composed)
    }

    /// The thread came on screen: what was notified of it is seen.
    func threadShown(_ threadID: String) {
        center.withdraw([Self.id(forThread: threadID)])
    }

    /// The sign-in service says who is signed in: as it starts, and at
    /// every change. When that is another account than before, or none,
    /// nothing notified to the first stays on the device's screen, and
    /// the line is not offered to the next for what the first did. The
    /// same account reported again (the app was opened again) keeps what
    /// it was notified of.
    func accountReported(_ account: String?) {
        if let was = reported, was != account {
            offer = nil
            offerWasAnnounced = false
            center.withdrawAll()
        }
        reported = .some(account)
    }

    /// Whether the line that is offered is yet to be told to VoiceOver:
    /// true once for each offer.
    func takeOfferAnnouncement() -> Bool {
        guard offer != nil, !offerWasAnnounced else { return false }
        offerWasAnnounced = true
        return true
    }
}

/// Hears that a notification was tapped, and hands its thread to the app:
/// the id alone says which thread, and the shell opens it only if it is
/// the signed-in account's. Nothing else is read from a notification.
final class NotificationTaps: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationTaps()

    /// Starts hearing taps. Called once, as the app starts.
    @MainActor
    func start() {
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let threadID = LocalNotifications.threadID(ofNotification: response.notification.request.identifier) else { return }
        await MainActor.run { AppState.shared.notificationTapped(forThread: threadID) }
    }
}
