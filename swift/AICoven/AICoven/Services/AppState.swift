import Foundation
import SwiftUI
internal import Combine

/// Deep link destinations supported by the app.
enum DeepLinkTarget: Equatable {
    case connectedApps
    case providerKeys
    case budgets
    case usage
    case settings
}

/// Global app state management
@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var selectedThread: Thread?
    @Published var threads: [Thread] = []
    @Published var pendingDeepLink: DeepLinkTarget?
    /// Whether the current user has completed the FTUE onboarding flow.
    @Published var hasCompletedOnboarding: Bool = false

    private init() {}

    /// Handle incoming deep links.
    func handleDeepLink(_ url: URL) {
        guard let target = AppState.parseDeepLink(url) else { return }
        pendingDeepLink = target
    }

    /// Consume and clear pending deep link target.
    func consumeDeepLink() -> DeepLinkTarget? {
        let target = pendingDeepLink
        pendingDeepLink = nil
        return target
    }

    private static func parseDeepLink(_ url: URL) -> DeepLinkTarget? {
        guard url.scheme == "aicoven" else { return nil }

        let host = url.host ?? ""
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        switch host {
        case "connected-services", "connected-apps":
            return .connectedApps
        case "settings":
            switch path {
            case "connected-apps":
                return .connectedApps
            case "providers":
                return .providerKeys
            case "budgets":
                return .budgets
            case "usage":
                return .usage
            default:
                return .settings
            }
        case "providers":
            return .providerKeys
        case "budgets":
            return .budgets
        case "usage":
            return .usage
        default:
            return nil
        }
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

    /// Fetch user's threads (personal-only, local store)
    func fetchThreads() async throws {
        let threads = try await ThreadService.shared.loadThreads(covenId: nil)
        self.threads = threads
    }

}
