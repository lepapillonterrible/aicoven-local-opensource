import SwiftUI

/// Settings › Notifications, as the cloud app's pane with what this app
/// has: this device's permission, whether the account wants
/// notifications, and whether they hold details. (The cloud app's
/// reminder of an unanswered approval and its Live Activity need a
/// server.)
struct NotificationsSettingsView: View {
    @ObservedObject private var notifications = LocalNotifications.shared
    @Environment(\.scenePhase) private var scenePhase

    static let whatTheyTell = "Notifications tell you when an agent finishes, needs your OK, or stops on a problem, while AICoven is not in front."
    static let whatDetailsAre = "With details off, a notification says only which agent it is about. With details on, it also names the thread "
        + "and shows the start of the reply, which then appear on your Lock Screen and in Notification Center."

    private var account: String {
        UserScope.currentUserID
    }

    private var openSettingsTitle: String {
        #if os(macOS)
        "Open System Settings"
        #else
        "Open Settings"
        #endif
    }

    private var thisDevice: String {
        #if os(macOS)
        "this Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "this iPad" : "this iPhone"
        #endif
    }

    var body: some View {
        SettingsForm {
            // This device's permission: asking waits for Turn on, here or
            // in the line a thread offers.
            switch notifications.permission {
            case .notAsked:
                Section {
                    Button("Turn on notifications") {
                        Task { await notifications.turnOn() }
                    }
                } footer: {
                    Text("You will be asked to allow notifications from AICoven on \(thisDevice).")
                        .font(.aicovenBodySmall)
                }
            case .denied:
                Section {
                    Button(openSettingsTitle, action: openSystemSettings)
                } footer: {
                    Text("Notifications from AICoven are off on \(thisDevice).")
                        .font(.aicovenBodySmall)
                }
            case .allowed, nil:
                EmptyView()
            }
            Section {
                Toggle("Notifications", isOn: Binding(
                    get: { notifications.isOn(for: account) },
                    set: { notifications.setOn($0, for: account) }
                ))
            } footer: {
                Text(Self.whatTheyTell)
                    .font(.aicovenBodySmall)
            }
            Section {
                Toggle("Show details", isOn: Binding(
                    get: { notifications.showsDetails(for: account) },
                    set: { notifications.setShowsDetails($0, for: account) }
                ))
                .disabled(!notifications.isOn(for: account))
            } footer: {
                Text(Self.whatDetailsAre)
                    .font(.aicovenBodySmall)
            }
        }
        .task { await notifications.refreshPermission() }
        // Back from the system's settings: the permission is read again.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await notifications.refreshPermission() } }
        }
        // The first section changes with the system's answer: said once.
        .onChange(of: notifications.permission) { old, new in
            guard old != nil else { return }
            switch new {
            case .denied: AccessibilityNotification.Announcement("Notifications are off. \(openSettingsTitle) is available.").post()
            case .allowed: AccessibilityNotification.Announcement("Notifications are on.").post()
            case .notAsked, nil: break
            }
        }
    }

    /// Opens the system's own settings for this app's notifications.
    private func openSystemSettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        #else
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}
