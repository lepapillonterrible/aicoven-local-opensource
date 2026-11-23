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
        /// The reminders of the account's open tasks, with their titles
        /// where the account chose details.
        var reminders: @Sendable (_ withTitles: Bool, _ account: String) async throws -> [TaskReminderDue]
        /// Whether the account chose details: a reminder then names its task.
        var showsDetails: @MainActor (_ account: String) -> Bool
        /// Makes what the system holds match them.
        var hold: @MainActor (_ due: [TaskReminderDue], _ account: String) async -> Void
        /// Whether the account has notifications on.
        var isOn: @MainActor (_ account: String) -> Bool
        /// This device's permission, and the asking for it.
        var permission: @MainActor () async -> LocalNotifications.Permission?
        var ask: @MainActor () async -> Void

        static let live = Hands(
            reminders: { try await TaskRepository.shared.reminders(withTitles: $0, as: $1) },
            showsDetails: { LocalNotifications.shared.showsDetails(for: $0) },
            hold: { await LocalNotifications.shared.setReminders($0, as: $1) },
            isOn: { LocalNotifications.shared.isOn(for: $0) },
            permission: { await LocalNotifications.shared.refreshPermission() },
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
            // A title is opened only to be shown.
            let withTitles = hands.showsDetails(account)
            let due = try await hands.reminders(withTitles, account)
            // A reading made for the other choice of details is not
            // handed over (one read without titles would be shown without
            // them): the change has asked for another reading.
            guard signedIn() == account, hands.showsDetails(account) == withTitles else { return }
            await hands.hold(due, account)
        } catch {
            // Locked, or another account's by now: nothing is said of it.
            // Anything else is logged by its kind only.
            if !(error is RepositoryError), !(error is CancellationError) {
                AppErrorReporter.log(message: "Could not read the reminders (\(type(of: error)))", context: "TaskReminders.refresh")
            }
        }
    }

    /// The person has just set a reminder, or asks for notifications
    /// under one that would not be shown: if this device was never asked
    /// whether the app may notify, it is asked now, and the reminders are
    /// handed over with the answer. An account that turned notifications
    /// off is not asked: its reminders would not be shown whatever the
    /// device answers.
    func reminderWasSet() async {
        let account = signedIn()
        if hands.isOn(account), await hands.permission() == .notAsked, signedIn() == account {
            await hands.ask()
        }
        await refresh().value
    }
}
