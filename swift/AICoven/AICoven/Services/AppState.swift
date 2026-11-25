import Foundation
import SwiftUI
internal import Combine

/// Where an `aicoven://` link leads (`DeepLinkParser`): a place in
/// Settings, or Strix's new-thread page.
nonisolated enum DeepLinkTarget: Equatable {
    case connectedApps
    case providerKeys
    case budgets
    case usage
    case settings
    /// Strix's new-thread page, as the person left it: a link gives it
    /// nothing.
    case newThread
}

/// Global app state management
@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var selectedThread: Thread?
    @Published var threads: [Thread] = []
    @Published var pendingDeepLink: DeepLinkTarget?
    /// The thread a notification that was tapped is about: held until
    /// the shell takes it, as a link is, and dropped when the account
    /// that was signed in leaves or another takes its place. (The shell
    /// opens only a thread of the account it finds signed in.)
    @Published private(set) var pendingThreadID: String?
    /// The task a reminder that was tapped is about: held and dropped as
    /// a tapped thread is. (The shell opens only a task of the account it
    /// finds signed in.)
    @Published private(set) var pendingTaskID: String?
    /// The place in Settings a request names. The Settings window shows it
    /// and clears this.
    @Published var requestedSettingsPane: WorkspaceTabType?
    /// Counts requests for the Settings window; the Mac's root view opens
    /// the window for each.
    @Published private(set) var settingsRequests = 0
    /// Whether the current user has completed the FTUE onboarding flow.
    @Published var hasCompletedOnboarding: Bool = false

    private init() {}

    /// Asks for the Settings window when `type` is Settings or a place in
    /// it. Returns false for any other type, and asks for nothing.
    func openSettings(for type: WorkspaceTabType) -> Bool {
        guard type == .settings || SettingsPane(type) != nil else { return false }
        requestedSettingsPane = type == .settings ? nil : type
        settingsRequests += 1
        return true
    }

    /// A link came in from outside the app. One that reads as a link of
    /// this app's (`DeepLinkParser`) is held until the main view takes it:
    /// at once if it is up, else once the person is signed in and their
    /// data unlocked. Any other does nothing.
    func handleDeepLink(_ url: URL) {
        guard let target = DeepLinkParser.target(for: url) else { return }
        pendingDeepLink = target
    }

    /// Who the sign-in service last said is signed in; nil for nobody.
    private var reportedAccount: String?

    /// The sign-in service says who is signed in: when it starts (nobody,
    /// or the account still signed in from before) and at every change.
    /// A link that was waiting while an account was signed in is not kept
    /// for the next: it is dropped when that account leaves or another
    /// takes its place. Nobody being signed in when the app starts is no
    /// account leaving, so a link the app was opened with stays.
    func accountReported(_ account: String?) {
        if let was = reportedAccount, was != account {
            pendingDeepLink = nil
            pendingThreadID = nil
            pendingTaskID = nil
        }
        reportedAccount = account
    }

    /// A notification about a thread was tapped: the shell opens the
    /// thread, if it is the signed-in account's.
    func notificationTapped(forThread threadID: String) {
        pendingThreadID = threadID
    }

    /// Takes the thread a tapped notification is about, once.
    func consumeThreadAsk() -> String? {
        let threadID = pendingThreadID
        pendingThreadID = nil
        return threadID
    }

    /// A task's reminder was tapped: the shell opens the task, if it is
    /// the signed-in account's.
    func notificationTapped(forTask taskID: String) {
        pendingTaskID = taskID
    }

    /// Takes the task a tapped reminder is about, once.
    func consumeTaskAsk() -> String? {
        let taskID = pendingTaskID
        pendingTaskID = nil
        return taskID
    }

    /// Consume and clear pending deep link target.
    func consumeDeepLink() -> DeepLinkTarget? {
        let target = pendingDeepLink
        pendingDeepLink = nil
        return target
    }

    /// Create a new thread (personal-only in the open client)
    func createNewThread(covenId: String? = nil) {
        Task {
            do {
                let thread = try await ThreadService.shared.createThread(title: "New Chat", covenId: nil, agentId: nil)
                await MainActor.run {
                    self.threads.append(thread)
                    self.selectedThread = thread
                }
            } catch {
                AppErrorReporter.log(error: error, context: "AppState.createNewThread")
            }
        }
    }

    /// Select a thread for chat
    func selectThread(_ thread: Thread) {
        selectedThread = thread
    }

    /// Clear all user-specific state. Call on sign-in/sign-out to prevent
    /// data leakage between users. A link that is waiting is not such
    /// state (it names a place, nobody's data, and may be what the app was
    /// opened with): it stays, until the account it waited under leaves
    /// (`accountReported`).
    func clearUserData() {
        selectedThread = nil
        threads = []
        hasCompletedOnboarding = false
        requestedSettingsPane = nil
    }

    /// Fetch user's threads (personal-only, local store)
    func fetchThreads() async throws {
        let threads = try await ThreadService.shared.loadThreads(covenId: nil)
        self.threads = threads
    }

}
