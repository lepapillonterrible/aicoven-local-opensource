import Foundation

/// Keeps the reminders the system holds in step with the store: a task's
/// reminder is a notification the system itself shows at its time, also
/// with the app closed (there is no server to send one). Whenever tasks
/// change, the account or its notification choices change, or the app
/// comes to the front, the signed-in account's reminders are read and
/// handed to `LocalNotifications`, which makes what waits match them.
@MainActor
final class TaskReminders {
    static let shared = TaskReminders()

    /// The store's and the system's side, which a test replaces.
    struct Hands {
        /// The reminders of the account's open tasks.
        var reminders: @Sendable (_ account: String) async throws -> [TaskReminderDue]
        /// Makes what the system holds match them.
        var hold: @MainActor (_ due: [TaskReminderDue], _ account: String) async -> Void
        /// This device's permission, and the asking for it.
        var permission: @MainActor () async -> LocalNotifications.Permission?
        var ask: @MainActor () async -> Void

        static let live = Hands(
            reminders: { try await TaskRepository.shared.reminders(as: $0) },
            hold: { await LocalNotifications.shared.setReminders($0, as: $1) },
            permission: {
                await LocalNotifications.shared.refreshPermission()
                return LocalNotifications.shared.permission
            },
            ask: { await LocalNotifications.shared.turnOn() }
        )
    }

    private let hands: Hands
    private let signedIn: () -> String
    /// The refresh under way, and whether another was asked for meanwhile:
    /// one at a time, and the last ask is always answered by a reading
    /// made after it.
    private var refreshing: Task<Void, Never>?
    private var isAskedAgain = false
    private var watching: NSObjectProtocol?

    init(hands: Hands = .live, signedIn: @escaping () -> String = { UserScope.currentUserID }) {
        self.hands = hands
        self.signedIn = signedIn
    }

    /// Starts following the store and the account's notification
    /// choices: a task made or changed, notifications turned on or off,
    /// details chosen, or the system's question answered is read for.
    /// Called once, as the app starts.
    func start() {
        guard watching == nil else { return }
        watching = NotificationCenter.default.addObserver(forName: TaskItem.didChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        LocalNotifications.shared.whenChoicesChange = { [weak self] in self?.refresh() }
    }

    /// Reads the signed-in account's reminders and has the system hold
    /// them. Answers with the work, for whoever waits for it. While the
    /// account's data is locked nothing is read, and what waits stays as
    /// it is: it was the account's own when it was handed over.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        if let refreshing {
            isAskedAgain = true
            return refreshing
        }
        let work = Task {
            repeat {
                isAskedAgain = false
                await readAndHold()
            } while isAskedAgain
            refreshing = nil
        }
        refreshing = work
        return work
    }

    private func readAndHold() async {
        let account = signedIn()
        guard !account.isEmpty else { return }
        do {
            let due = try await hands.reminders(account)
            guard signedIn() == account else { return }
            await hands.hold(due, account)
        } catch {
            // Locked, or another account's by now: nothing is said of it.
            // Anything else is logged by its kind only.
            if !(error is RepositoryError), !(error is CancellationError) {
                AppErrorReporter.log(message: "Could not read the reminders (\(type(of: error)))", context: "TaskReminders.refresh")
            }
        }
    }

    /// The person has just set a reminder: if this device was never asked
    /// whether the app may notify, it is asked now (they have just asked
    /// to be reminded), and the reminders are handed over with the answer.
    func reminderWasSet() async {
        if await hands.permission() == .notAsked {
            await hands.ask()
        }
        await refresh().value
    }
}
