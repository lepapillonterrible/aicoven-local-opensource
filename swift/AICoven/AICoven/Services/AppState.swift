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
    /// Strix's new-thread page, empty: a link gives it no words.
    case newThread
}

/// Global app state management
@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var selectedThread: Thread?
    @Published var threads: [Thread] = []
    @Published var pendingDeepLink: DeepLinkTarget?
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
    /// data leakage between users. A link that is waiting stays through a
    /// sign-in (it may be what the app was opened with, and it names a
    /// place, nobody's data); `signedOut` drops it.
    func clearUserData(signedOut: Bool = false) {
        selectedThread = nil
        threads = []
        hasCompletedOnboarding = false
        if signedOut { pendingDeepLink = nil }
        requestedSettingsPane = nil
    }

    /// Fetch user's threads (personal-only, local store)
    func fetchThreads() async throws {
        let threads = try await ThreadService.shared.loadThreads(covenId: nil)
        self.threads = threads
    }

}
