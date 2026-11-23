internal import Combine
import SwiftUI

/// One place's tasks as its Tasks page shows them: a coven's, or Strix's.
/// It reads them, adds one, and marks one done, closed or open again, each
/// as the account that asked. Only the latest reading is shown, and
/// nothing read or done for an account that is no longer signed in.
@MainActor
final class TasksModel: ObservableObject {
    /// The store's side, which a test replaces.
    struct Source {
        var tasks: @Sendable (_ covenID: String?, _ account: String) async throws -> TaskListing
        var create: @Sendable (_ title: String, _ covenID: String?, _ account: String) async throws -> TaskItem
        var change: @Sendable (_ id: String, _ change: TaskChange, _ account: String) async throws -> Void

        static let live = Source(
            tasks: { try await TaskRepository.shared.tasks(inCoven: $0, as: $1) },
            create: { try await TaskRepository.shared.create(title: $0, inCoven: $1, as: $2) },
            change: { try await TaskRepository.shared.change($0, $1, as: $2) }
        )
    }

    /// The tasks still open, the one last changed first.
    @Published private(set) var open: [TaskItem] = []
    /// The finished ones last changed, as many as a listing gives.
    @Published private(set) var finished: [TaskItem] = []
    /// How many are finished in all, listed or not.
    @Published private(set) var finishedCount = 0
    /// Whether the tasks were read at least once.
    @Published private(set) var hasRead = false
    /// What went wrong with the last thing asked, in words.
    @Published private(set) var errorMessage: String?
    /// Whether a task is being added: one at a time.
    @Published private(set) var isAdding = false
    /// The tasks whose change is on its way: one change at a time for a task.
    @Published private(set) var saving: Set<TaskItem.ID> = []

    static let couldNotLoad = "Couldn't load tasks."
    static let couldNotAdd = "Couldn't add the task. Try again."
    static let tooManyOpen = "As many open tasks as can be kept are kept here already. Mark some done or close them first."
    static let needsUnlock = "Unlock your data to change tasks."
    static let unreadable = "Your encryption key can't open this task."

    /// How a task is named in what is said of it.
    static func name(of task: TaskItem) -> String {
        task.isUnreadable ? "the task" : task.title
    }

    static func couldNotSave(_ task: TaskItem) -> String {
        "Couldn't save the change to \(task.isUnreadable ? "the task" : "“\(task.title)”"). Try again."
    }

    /// The coven whose tasks these are; nil for Strix's.
    let covenID: String?
    private let source: Source
    private let signedIn: () -> String
    /// Tells VoiceOver what came of what was asked, as it happens: each
    /// is said, also two that end in the same moment.
    private let announce: (String) -> Void
    /// Counts the readings, and remembers the latest that landed: one
    /// that lands after a later one did is not shown over it. A reading
    /// that was called off lands nothing, so one asked before it still can.
    private var readings = 0
    private var landed = 0

    /// The app's own store, account and voice unless a test gives others.
    init(covenID: String?, source: Source? = nil, signedIn: (() -> String)? = nil, announce: ((String) -> Void)? = nil) {
        self.covenID = covenID
        self.source = source ?? .live
        self.signedIn = signedIn ?? { UserScope.currentUserID }
        self.announce = announce ?? { AccessibilityNotification.Announcement($0).post() }
    }

    /// Whether there is no task at all, open or finished.
    var isEmpty: Bool {
        open.isEmpty && finishedCount == 0
    }

    /// Reads the place's tasks. One that fails after a reading that worked
    /// leaves the list as it is, and says so. Answers whether the tasks
    /// were read: by this reading, or by a later one that landed first.
    @discardableResult
    func load() async -> Bool {
        readings += 1
        let reading = readings
        let account = signedIn()
        do {
            let listing = try await source.tasks(covenID, account)
            guard signedIn() == account else { return false }
            // A later reading has landed: what is shown is newer than this.
            guard reading > landed else { return true }
            landed = reading
            open = listing.tasks.filter { !$0.isFinished }
            finished = listing.tasks.filter(\.isFinished)
            finishedCount = listing.finished
            hasRead = true
            if errorMessage == Self.couldNotLoad { errorMessage = nil }
            return true
        } catch is CancellationError {
            // Whoever asked was called off: nothing was read, and what is shown stays.
            return false
        } catch {
            guard reading > landed, signedIn() == account else { return false }
            landed = reading
            // The kind of failure only.
            AppErrorReporter.log(message: "Could not read the tasks (\(type(of: error)))", context: "TasksModel.load")
            report(Self.couldNotLoad)
            return false
        }
    }

    /// Adds a task with this title for `account`, who asked, and reads the
    /// list again. One at a time: a second ask while one is under way does
    /// nothing. Says whether it was added; nothing is said to another
    /// account.
    func add(title: String, as account: String) async -> Bool {
        let title = TaskRepository.keptTitle(title)
        guard !title.isEmpty, !isAdding else { return false }
        isAdding = true
        defer { isAdding = false }
        errorMessage = nil
        do {
            let task = try await source.create(title, covenID, account)
            guard signedIn() == account else { return false }
            // Read in a task of its own: whoever asked may be called off,
            // and what was added is still to be shown.
            let read = await Task { await self.load() }.value
            guard signedIn() == account else { return false }
            // If the list could not be read again, what was added is shown
            // all the same, first, as the one last changed. Read again, the
            // list says where the task stands now, which may be elsewhere.
            if !read, !(open + finished).contains(where: { $0.id == task.id }) { open.insert(task, at: 0) }
            say("Added \(task.title)")
            return true
        } catch {
            guard signedIn() == account else { return false }
            switch error {
            case TaskError.tooMany: report(Self.tooManyOpen)
            case RepositoryError.dataLocked: report(Self.needsUnlock)
            default:
                if !(error is TaskError), !(error is RepositoryError) {
                    AppErrorReporter.log(message: "Could not add a task (\(type(of: error)))", context: "TasksModel.add")
                }
                report(Self.couldNotAdd)
            }
            return false
        }
    }

    /// Marks an open task done, or opens a finished one again.
    func setDone(_ task: TaskItem, _ done: Bool, as account: String) async {
        await change(task, to: done ? .done : .open, saying: done ? "Marked \(Self.name(of: task)) done" : "Reopened \(Self.name(of: task))", as: account)
    }

    /// Closes a task without its being done.
    func close(_ task: TaskItem, as account: String) async {
        await change(task, to: .closed, saying: "Closed \(Self.name(of: task))", as: account)
    }

    /// Changes a task's status for `account`, who asked, and reads the
    /// list again. One change at a time for a task: a second ask while one
    /// is under way does nothing. What came of it is said, to that account
    /// only; a task that is gone is not said to have failed (the list,
    /// read again, shows so).
    private func change(_ task: TaskItem, to status: TaskStatus, saying done: String, as account: String) async {
        guard saving.insert(task.id).inserted else { return }
        defer { saving.remove(task.id) }
        errorMessage = nil
        do {
            try await source.change(task.id, TaskChange(status: status), account)
            if signedIn() == account { say(done) }
        } catch TaskError.noSuchTask {
            // Gone, with its coven or its account.
        } catch {
            guard signedIn() == account else { return }
            switch error {
            case TaskError.tooMany: report(Self.tooManyOpen)
            case RepositoryError.dataLocked: report(Self.needsUnlock)
            default:
                if !(error is TaskError), !(error is RepositoryError) {
                    AppErrorReporter.log(message: "Could not change a task (\(type(of: error)))", context: "TasksModel.change")
                }
                report(Self.couldNotSave(task))
            }
        }
        guard signedIn() == account else { return }
        // In a task of its own: whoever asked may be called off, and how
        // the task stands now is still to be shown.
        await Task { await self.load() }.value
    }

    /// Shows what went wrong, and says it.
    private func report(_ words: String) {
        errorMessage = words
        say(words)
    }

    private func say(_ words: String) {
        announce(words)
    }
}
