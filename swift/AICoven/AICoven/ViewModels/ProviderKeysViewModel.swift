internal import Combine
import Foundation

/// Where an account's Test button is: at rest, testing, or showing how the
/// last test went.
enum ProviderAccountTestActionState: Equatable {
    case idle
    case testing
    case success(message: String)
    case failure(message: String)

    /// The finished test's message; `nil` at rest and while testing.
    var resultMessage: String? {
        switch self {
        case let .success(message), let .failure(message): message
        case .idle, .testing: nil
        }
    }
}

/// The state of the AI connections list: the accounts, each one's Test, and
/// the delete confirmation. The add and edit forms keep their own state.
@MainActor
final class ProviderKeysViewModel: ObservableObject {
    @Published private(set) var providerAccounts: [ProviderAccount] = []
    @Published private(set) var loading = true
    /// Why the last load or delete failed; `nil` when it did not.
    @Published private(set) var lastErrorMessage: String?
    @Published var showAddSheet = false
    @Published var selectedAccount: ProviderAccount?
    /// The account whose delete confirmation is open.
    @Published var pendingDelete: ProviderAccount?
    @Published private(set) var testActionStates: [String: ProviderAccountTestActionState] = [:]

    /// Counts account loads; only the newest applies its result.
    private var loadGeneration = 0
    private let service = ProviderAccountService.shared
    /// How long a test's tick or cross shows before its button reads Test
    /// again.
    private let testResultDisplayDuration: Duration
    private var testResultClearTasks: [String: Task<Void, Never>] = [:]

    init(testResultDisplayDuration: Duration = .seconds(2)) {
        self.testResultDisplayDuration = testResultDisplayDuration
    }

    func testActionState(for account: ProviderAccount) -> ProviderAccountTestActionState {
        testActionStates[account.id] ?? .idle
    }

    /// The delete confirmation's message.
    static func deleteMessage(for account: ProviderAccount) -> String {
        let message = "AICoven removes this connection from this device, with any key saved for it. This can't be undone."
        // AICoven holds no OpenRouter management key, so deleting the account
        // here cannot revoke the key itself.
        guard account.provider.lowercased() == "openrouter" else { return message }
        return message + " AICoven deletes its copy of the key; the key stays active in your OpenRouter account until you delete it there."
    }

    /// Reads the accounts. Only the newest load changes the list, the error,
    /// and the loading flag.
    func loadProviderAccounts() async {
        loadGeneration += 1
        let generation = loadGeneration
        loading = true
        defer {
            if generation == loadGeneration { loading = false }
        }
        do {
            let accounts = try await service.loadProviderAccounts()
            guard generation == loadGeneration else { return }
            providerAccounts = accounts
            lastErrorMessage = nil
        } catch {
            guard generation == loadGeneration else { return }
            lastErrorMessage = error.localizedDescription
            AppErrorReporter.log(error: error, context: "ProviderKeysViewModel.loadProviderAccounts")
        }
    }

    func testConnection(for account: ProviderAccount) async {
        guard testActionState(for: account) != .testing else { return }
        setTestActionState(.testing, for: account.id)
        do {
            let models = try await service.testConnection(accountId: account.id)
            let found = models == 1 ? "1 model" : "\(models) models"
            setTestActionState(.success(message: models == 0 ? "Connected. No models found." : "Connected. \(found)."), for: account.id)
        } catch {
            setTestActionState(.failure(message: error.localizedDescription), for: account.id)
        }
        // The test recorded the account's status.
        await loadProviderAccounts()
    }

    func deleteAccount(_ account: ProviderAccount) async {
        do {
            try await service.deleteProviderAccount(id: account.id)
        } catch {
            lastErrorMessage = error.localizedDescription
            AppErrorReporter.log(error: error, context: "ProviderKeysViewModel.deleteAccount")
            return
        }
        await loadProviderAccounts()
    }

    /// Sets an account's test state. A result returns to rest after
    /// `testResultDisplayDuration`, unless a newer state replaced it first.
    private func setTestActionState(_ state: ProviderAccountTestActionState, for accountId: String) {
        testResultClearTasks.removeValue(forKey: accountId)?.cancel()
        testActionStates[accountId] = state
        guard state.resultMessage != nil else { return }
        let duration = testResultDisplayDuration
        testResultClearTasks[accountId] = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, testActionStates[accountId] == state else { return }
            testResultClearTasks.removeValue(forKey: accountId)
            testActionStates.removeValue(forKey: accountId)
        }
    }
}
