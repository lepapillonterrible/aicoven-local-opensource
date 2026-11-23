internal import Combine
import SwiftUI

/// One place's tasks as its Tasks page shows them (a coven's, or
/// Strix's), or every place's as On me shows them. It reads them, adds
/// one, changes one, and hands one to an agent, each as the account that
/// asked. Only the latest reading is shown, and nothing read or done for
/// an account that is no longer signed in.
@MainActor
final class TasksModel: ObservableObject {
    /// Whose tasks a page shows.
    nonisolated enum Scope: Equatable {
        /// One place's: a coven's, or Strix's for nil.
        case place(covenID: String?)
        /// Every task of the account's, in whichever coven or with Strix.
        case onMe
    }

    /// The store's side, which a test replaces.
    struct Source {
        /// The place's listing, which also lists the task named (the one
        /// whose details are on screen) where it would be left out.
        var tasks: @Sendable (_ scope: Scope, _ alsoListing: String?, _ account: String) async throws -> TaskListing
        var create: @Sendable (_ title: String, _ covenID: String?, _ account: String) async throws -> TaskItem
        var change: @Sendable (_ id: String, _ change: TaskChange, _ account: String) async throws -> Void
        /// Keeps for today (until the time given) or clears the pins of
        /// these tasks that have run out, and answers with those it changed.
        var answerLapsedPins: @Sendable (_ ids: [String], _ keepUntil: Date?, _ account: String) async throws -> Set<String>

        static let live = Source(
            tasks: { scope, shown, account in
                switch scope {
                case let .place(covenID): try await TaskRepository.shared.tasks(inCoven: covenID, alsoListing: shown, as: account)
                case .onMe: try await TaskRepository.shared.allTasks(alsoListing: shown, as: account)
                }
            },
            create: { try await TaskRepository.shared.create(title: $0, inCoven: $1, as: $2) },
            change: { try await TaskRepository.shared.change($0, $1, as: $2) },
            answerLapsedPins: { try await TaskRepository.shared.answerLapsedPins(of: $0, keepUntil: $1, as: $2) }
        )
    }

    /// An agent a task can be handed to.
    struct Agent: Identifiable, Equatable {
        let id: String
        let name: String
        /// Where it runs, as the menu says under its name.
        var runsOn = ""

        /// Strix, which answers in Strix's own place and in a coven with
        /// no agents: no stored agent, so a task it is handed names no
        /// lead agent.
        static let strix = Agent(id: "strix", name: "Strix")

        /// Whether this is Strix, wherever it is said to run.
        var isStrix: Bool {
            id == Self.strix.id
        }
    }

    /// The threads' and the agents' side, which a test replaces.
    struct Hands {
        /// A coven's agents; nil where they could not be read.
        var agents: @Sendable (_ covenID: String) async -> [Agent]?
        /// Strix, with where it runs for `account` (nothing said of it
        /// where its settings could not be read).
        var strix: @MainActor (_ account: String) async -> Agent
        var thread: @MainActor (_ id: String, _ account: String) async throws -> Thread
        /// Makes a thread in the place, for the agent given (Strix for nil).
        var createThread: @MainActor (_ title: String, _ covenID: String?, _ agent: Agent?, _ account: String) async throws -> Thread
        /// Starts a turn in the thread with these words as the person's
        /// message, answered by the agent given (Strix as itself, whoever
        /// the thread's own agent is; the thread's own for nil), and
        /// answers with the turn's id.
        var startTurn: @MainActor (_ thread: Thread, _ text: String, _ agent: Agent?) async throws -> String
        /// Undoes a thread made for a task that could not be given it:
        /// only as the account it was made for; one that cannot be
        /// deleted is left, empty.
        var discardThread: @MainActor (_ thread: Thread, _ account: String) async -> Void
        /// Hands words that could not be sent into a thread to the
        /// thread's composer, which says why.
        var handBack: @MainActor (_ text: String, _ threadID: String, _ error: Error) -> Void
        /// The turn the app is running in a thread now.
        var liveTurn: @MainActor (_ threadID: String) -> TaskLiveTurn?

        /// Who answers a turn started from a task: the agent chosen, where
        /// Strix chosen is Strix itself (no stored agent), whoever the
        /// thread's own agent is; the thread's own where nobody was chosen.
        static func answering(_ agent: Agent?, in thread: Thread) -> (roleID: String?, name: String?) {
            guard let agent else { return (thread.agentId, thread.agentName) }
            return (agent.isStrix ? nil : agent.id, agent.name)
        }

        static let live = Hands(
            agents: { covenID in
                guard let roles = try? await RoleService.shared.loadRoles(covenId: covenID) else { return nil }
                return roles.map { role in
                    Agent(
                        id: role.id, name: role.name,
                        runsOn: role.provider.flatMap { $0.isEmpty ? nil : providerDisplayName(slug: $0) } ?? "No connection set"
                    )
                }
            },
            strix: { account in
                var strix = Agent.strix
                guard let settings = try? await StrixSettingsService.shared.loadPersonalStrix(), UserScope.currentUserID == account else {
                    return strix
                }
                strix.runsOn = settings.provider.flatMap { $0.isEmpty ? nil : providerDisplayName(slug: $0) } ?? "No connection set"
                return strix
            },
            thread: { id, account in
                guard UserScope.currentUserID == account else { throw RepositoryError.accountChanged }
                return try await ThreadService.shared.getThread(threadId: id)
            },
            createThread: { title, covenID, agent, account in
                try await ThreadService.shared.createThread(title: title, covenId: covenID, agentId: agent?.id, agentName: agent?.name, as: account)
            },
            startTurn: { thread, text, agent in
                let answering = answering(agent, in: thread)
                return try await TurnEngine.shared.start(
                    with: TurnProgress.userMessage(in: thread.id, text: text, attachments: []), context: text,
                    roleID: answering.roleID, agentName: answering.name, attachments: nil
                )
            },
            discardThread: { thread, account in
                guard UserScope.currentUserID == account else { return }
                do {
                    try await ThreadService.shared.deleteThread(threadId: thread.id)
                } catch {
                    // The kind of failure only.
                    AppErrorReporter.log(
                        message: "Could not discard a thread its task was not given (\(type(of: error)))", context: "TasksModel.discardThread"
                    )
                }
            },
            handBack: { text, threadID, error in
                TurnEngine.shared.handBack(ComposerDraft(text: text), to: threadID, because: error)
            },
            liveTurn: { threadID in
                guard let turn = TurnEngine.shared.running[threadID] else { return nil }
                return TaskLiveTurn(turnID: turn.turnID, needsOK: ToolApprovals.shared.askingThreadIDs.contains(threadID), isStopping: turn.isStopping)
            }
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
    /// The task whose details are on screen, by its id: every reading
    /// lists it, also where it is finished and not among the ones last
    /// changed. Closed by a reading that does not find it: it is gone.
    @Published var detailsOf: String?
    /// Whether a task is being added: one at a time.
    @Published private(set) var isAdding = false
    /// The tasks whose change is on its way: one change at a time for a task.
    @Published private(set) var saving: Set<TaskItem.ID> = []
    /// The agents a task can be handed to, by the place it is in (a
    /// coven's id, none for Strix's): the coven's, or Strix alone in
    /// Strix's place and in a coven with none. A place has no entry until
    /// its agents are read.
    @Published private(set) var agentsByPlace: [String: [Agent]] = [:]
    /// The places whose agents could not be read.
    @Published private(set) var placesWhoseAgentsFailed: Set<String> = []
    /// The turns the app is running now in the threads of tasks handed
    /// to an agent, by thread id.
    @Published private(set) var liveTurns: [String: TaskLiveTurn] = [:]
    /// The agent, still there, that the place's latest hand-off went to,
    /// of every task of the place, listed or not.
    private var lastHandedTo: [String: String] = [:]
    /// The hand-off turns whose ending is still to be told, by turn id,
    /// each with whether it was seen at work here: one handed over on this
    /// page, or followed on it.
    private var awaited: [String: Bool] = [:]
    /// The turns the tasks were read again for once already: listed as
    /// running while nothing ran them.
    private var readAgainFor: Set<String> = []
    /// The turns whose wait for an OK was told (or passed over, with no
    /// screen up), until they stop waiting: told once for each wait.
    private var toldNeedsOK: Set<String> = []
    /// The readings of agents under way, by place: one at a time for a
    /// place, which whoever asks meanwhile waits for.
    private var agentReadings: [String: Task<Void, Never>] = [:]
    /// How many of the place's screens are up: the page, and a task's
    /// details where they are a screen of their own. What a hand-off's
    /// turn comes to is said only while one is.
    private var screensUp = 0

    static let couldNotLoad = "Couldn't load tasks."
    static let couldNotAdd = "Couldn't add the task. Try again."
    static let tooManyOpen = "As many open tasks as can be kept are kept here already. Mark some done or close them first."
    static let needsUnlock = "Unlock your data to change tasks."
    static let unreadable = "Your encryption key can't open this task."

    /// How a task is named in what is said of it.
    static func name(of task: TaskItem) -> String {
        task.isUnreadable ? "the task" : task.title
    }

    /// A task's title between quotation marks, as a failure names it.
    static func quoted(_ task: TaskItem) -> String {
        task.isUnreadable ? "the task" : "“\(task.title)”"
    }

    static func couldNotSave(_ task: TaskItem) -> String {
        "Couldn't save the change to \(quoted(task)). Try again."
    }

    /// Whose tasks these are.
    let scope: Scope
    private let source: Source
    private let hands: Hands
    private let signedIn: () -> String
    /// Tells VoiceOver what came of what was asked, as it happens: each
    /// is said, also two that end in the same moment.
    private let announce: (String) -> Void
    /// The time, and the person's calendar: a pin ends with their day or
    /// their week.
    private let now: () -> Date
    private let calendar: () -> Calendar
    /// Counts the readings, and remembers the latest that landed and the
    /// latest that landed with the tasks read: a listing that lands after
    /// a later listing did is not shown over it, and a failure that lands
    /// after a later reading did is not said. A reading that was called
    /// off lands nothing, so one asked before it still can.
    private var readings = 0
    private var landed = 0
    private var read = 0

    /// The app's own store, account, voice, clock and calendar unless a
    /// test gives others.
    init(
        scope: Scope, source: Source? = nil, hands: Hands? = nil, signedIn: (() -> String)? = nil, announce: ((String) -> Void)? = nil,
        now: (() -> Date)? = nil, calendar: (() -> Calendar)? = nil
    ) {
        self.scope = scope
        self.source = source ?? .live
        self.hands = hands ?? .live
        self.signedIn = signedIn ?? { UserScope.currentUserID }
        self.announce = announce ?? { AccessibilityNotification.Announcement($0).post() }
        self.now = now ?? { Date() }
        self.calendar = calendar ?? { .current }
    }

    /// The task with this id, as it was last read; nil for one that is
    /// gone, or among the finished ones no longer listed.
    func task(_ id: String) -> TaskItem? {
        (open + finished).first { $0.id == id }
    }

    /// Whether there is no task at all, open or finished.
    var isEmpty: Bool {
        open.isEmpty && finishedCount == 0
    }

    /// Reads the place's tasks. One that fails after a reading that worked
    /// leaves the list as it is, and says so. Answers whether the tasks
    /// were read: by this reading, or by a later one whose listing landed
    /// first (a later one that failed is no reading of them).
    @discardableResult
    func load() async -> Bool {
        readings += 1
        let reading = readings
        let account = signedIn()
        do {
            let shown = detailsOf
            let listing = try await source.tasks(scope, shown, account)
            guard signedIn() == account else { return false }
            // A later listing has landed: what is shown is newer than this.
            guard reading > read else { return true }
            read = reading
            open = listing.tasks.filter { !$0.isFinished }
            finished = listing.tasks.filter(\.isFinished)
            finishedCount = listing.finished
            lastHandedTo = listing.lastHandedTo
            hasRead = true
            if let open = detailsOf, !listing.tasks.contains(where: { $0.id == open }) {
                // Asked for by name and not found: it is gone, not merely
                // unlisted, and its details close.
                if open == shown {
                    detailsOf = nil
                } else {
                    // Its details were opened while this reading was under
                    // way, which did not ask for it: read again, asking.
                    return await load()
                }
            }
            // Unless a later reading has failed since: that is still so.
            if reading > landed {
                landed = reading
                if errorMessage == Self.couldNotLoad { errorMessage = nil }
            }
            // The agents of the places shown are read once the tasks are
            // (in On me the places are known only then), before anything
            // is said of a hand-off, so that it is said by its agent's
            // name. A place whose reading failed waits to be asked for
            // again.
            for place in placesShown where agentsByPlace[place] == nil && !placesWhoseAgentsFailed.contains(place) {
                await loadAgents(in: place)
            }
            guard signedIn() == account else { return false }
            // The turns the tasks follow are those of the tasks as read.
            // One that ended while they were read is read again for.
            let again = turnsChanged()
            tellEndings()
            await again?.value
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
        // A task is made in a place: On me adds none.
        guard case let .place(covenID) = scope, !title.isEmpty, !isAdding else { return false }
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
        await change(
            task, TaskChange(status: done ? .done : .open), saying: done ? "Marked \(Self.name(of: task)) done" : "Reopened \(Self.name(of: task))",
            orElse: Self.couldNotSave(task), as: account
        )
    }

    /// Closes a task without its being done.
    func close(_ task: TaskItem, as account: String) async {
        await change(task, TaskChange(status: .closed), saying: "Closed \(Self.name(of: task))", orElse: Self.couldNotSave(task), as: account)
    }

    /// Moves a task to a column of the Board: to a stage (a finished task
    /// is opened again there, while its place has room), or to Done,
    /// which marks it done (not while an agent is on it). Nothing is
    /// asked for the column it is in. A
    /// stage's column holds open tasks, so a move to one asks for the task
    /// to be open, whatever the card showed: the store decides against
    /// the task as it is then, also one finished since the card was drawn.
    func move(_ task: TaskItem, to column: TaskBoardColumn, as account: String) async {
        guard canMove(task, to: column) else {
            // Said, since a card dropped on Done just goes back: an agent is on it.
            if column == .done, !task.isFinished, signedIn() == account {
                report("\(agentName(for: task) ?? "An agent") is on \(Self.quoted(task)). Open its thread to see where it stands.")
            }
            return
        }
        let moved = switch column {
        case let .stage(stage): TaskChange(status: .open, stage: stage)
        case .done: TaskChange(status: .done)
        }
        await change(
            task, moved, saying: "Moved \(Self.name(of: task)) to \(column.title)", orElse: "Couldn't move \(Self.quoted(task)). Try again.",
            as: account
        )
    }

    /// Whether a task can be moved to a column of the Board: another than
    /// its own, and not to Done while an agent is on it (its thread is
    /// the way then, as in the List).
    func canMove(_ task: TaskItem, to column: TaskBoardColumn) -> Bool {
        TaskRules.moveTargets(for: task, handoff: handoff(of: task)).contains(column)
    }

    /// Gives a task another title. Nothing is asked for a title that
    /// says nothing, or the one it has.
    func rename(_ task: TaskItem, to title: String, as account: String) async {
        let title = TaskRepository.keptTitle(title)
        guard !title.isEmpty, title != task.title || task.isUnreadable else { return }
        await change(task, TaskChange(title: title), saying: "Renamed to \(title)", orElse: Self.couldNotSave(task), as: account)
    }

    /// Sets the day a task is due, with its time of day if it has one, or
    /// takes the day away (nil).
    func setDue(_ task: TaskItem, to due: TaskDue?, as account: String) async {
        await change(
            task, TaskChange(due: due.map { .to($0) } ?? .cleared), saying: due == nil ? "Due date removed" : "Due date set",
            orElse: "Couldn't change the due date of \(Self.quoted(task)). Try again.", as: account
        )
    }

    /// Pins an open task for today or for this week: until the end of the
    /// person's day, or of their week.
    func pin(_ task: TaskItem, for period: TaskPinPeriod, as account: String) async {
        guard !task.isFinished else { return }
        let pin = TaskPin(period: period, expiresAt: TaskRules.pinEnd(for: period, now: now(), calendar: calendar()))
        await change(
            task, TaskChange(pin: .to(pin)), saying: "Pinned \(Self.name(of: task)) for \(period.title.lowercased())",
            orElse: "Couldn't pin \(Self.quoted(task)). Try again.", as: account
        )
    }

    /// Takes a task's pin away.
    func unpin(_ task: TaskItem, as account: String) async {
        guard task.pin != nil else { return }
        await change(
            task, TaskChange(pin: .cleared), saying: "Unpinned \(Self.name(of: task))", orElse: "Couldn't unpin \(Self.quoted(task)). Try again.",
            as: account
        )
    }

    /// Answers "Still on today?" for these tasks, for `account`, who
    /// asked: keeps them for today, or clears their pins. Only those whose
    /// pin has run out are answered for, and none that is being changed.
    /// Says how many were kept or cleared.
    func answerLapsedPins(of tasks: [TaskItem], keep: Bool, as account: String) async {
        let moment = now()
        let ids = tasks.filter { TaskRules.pinState(of: $0, now: moment) == .review }.map(\.id)
        guard !ids.isEmpty, saving.isDisjoint(with: ids) else { return }
        saving.formUnion(ids)
        defer { saving.subtract(ids) }
        errorMessage = nil
        do {
            let answered = try await answer(ids, keep: keep, account)
            if signedIn() == account, !answered.isEmpty {
                say("\(keep ? "Kept for today" : "Cleared") \(answered.count) \(answered.count == 1 ? "task" : "tasks")")
            }
        } catch {
            guard signedIn() == account else { return }
            if case RepositoryError.dataLocked = error {
                report(Self.needsUnlock)
            } else {
                if !(error is TaskError), !(error is RepositoryError) {
                    AppErrorReporter.log(message: "Could not answer for pins (\(type(of: error)))", context: "TasksModel.answerLapsedPins")
                }
                report("Couldn't update \(ids.count) \(ids.count == 1 ? "task" : "tasks").")
            }
        }
        guard signedIn() == account else { return }
        await Task { await self.load() }.value
    }

    /// Keeps the pins until the end of today as it is when asked, or
    /// clears them. Asked just before midnight, the end of that day can
    /// have passed by the time it is written: it is then asked once more,
    /// for the day that has begun.
    private func answer(_ ids: [String], keep: Bool, _ account: String) async throws -> Set<String> {
        guard keep else { return try await source.answerLapsedPins(ids, nil, account) }
        do {
            return try await source.answerLapsedPins(ids, TaskRules.pinEnd(for: .today, now: now(), calendar: calendar()), account)
        } catch TaskError.pinEnded {
            return try await source.answerLapsedPins(ids, TaskRules.pinEnd(for: .today, now: now(), calendar: calendar()), account)
        }
    }

    /// Makes one change to a task for `account`, who asked, and reads the
    /// list again. One change at a time for a task: a second ask while one
    /// is under way does nothing. What came of it is said, to that account
    /// only; a task that is gone is not said to have failed (the list,
    /// read again, shows so).
    private func change(_ task: TaskItem, _ change: TaskChange, saying done: String, orElse failed: String, as account: String) async {
        guard saving.insert(task.id).inserted else { return }
        defer { saving.remove(task.id) }
        errorMessage = nil
        do {
            try await source.change(task.id, change, account)
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
                report(failed)
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

    // MARK: - Handing a task to an agent

    /// The place a task is in, as its agents are kept by: the page's own,
    /// or in On me the task's (a coven's id, none for Strix's).
    private func place(of task: TaskItem) -> String {
        covenID(of: task) ?? ""
    }

    private func covenID(of task: TaskItem) -> String? {
        if case let .place(covenID) = scope { return covenID }
        return task.covenID
    }

    /// The places whose agents the page needs: its own, or in On me
    /// those of the open tasks listed (only an open task is handed over,
    /// led or talked through with an agent).
    private var placesShown: [String] {
        switch scope {
        case let .place(covenID): return [covenID ?? ""]
        case .onMe:
            var seen: Set<String> = []
            return open.map(place(of:)).filter { seen.insert($0).inserted }
        }
    }

    /// Reads the agents of the places shown again (the tasks' own reading
    /// reads those not read yet; this is Try Again's): each coven's, or
    /// Strix alone where the place has none of its own. One reading at a time for a
    /// place: asked again while one is under way, it waits for that one
    /// and reads nothing more, so no earlier answer lands over a later
    /// one, and whoever asked has the agents when it returns. Nothing
    /// read for an account that is no longer signed in is kept.
    func loadAgents() async {
        for place in placesShown {
            await loadAgents(in: place)
        }
    }

    private func loadAgents(in place: String) async {
        if let reading = agentReadings[place] { return await reading.value }
        let reading = Task { await self.readAgents(in: place) }
        agentReadings[place] = reading
        await reading.value
        if agentReadings[place] == reading { agentReadings[place] = nil }
    }

    private func readAgents(in place: String) async {
        let account = signedIn()
        var read: [Agent]? = []
        if !place.isEmpty { read = await hands.agents(place) }
        if read?.isEmpty == true { read = await [hands.strix(account)] }
        guard signedIn() == account else { return }
        if let read {
            agentsByPlace[place] = read
            placesWhoseAgentsFailed.remove(place)
        } else {
            // Those read before stay, and it says so.
            placesWhoseAgentsFailed.insert(place)
        }
    }

    /// Whether the agents of a task's place are read, or could not be:
    /// what is said of the task can name its agent, or never will.
    private func agentsAreSettled(for task: TaskItem) -> Bool {
        let place = place(of: task)
        return agentsByPlace[place] != nil || placesWhoseAgentsFailed.contains(place)
    }

    /// Whether the agents of a task's place could not be read.
    func agentsFailed(for task: TaskItem) -> Bool {
        placesWhoseAgentsFailed.contains(place(of: task))
    }

    /// The page, or a task's details as a screen of their own, came on
    /// screen or left it. Work asked for on the page can end after the
    /// person has left it: how a hand-off's turn went is then told by its
    /// thread, Activity and notifications, not said here.
    func cameOnScreen() {
        screensUp += 1
    }

    func leftScreen() {
        screensUp = max(0, screensUp - 1)
    }

    /// Where a task handed to an agent stands.
    func handoff(of task: TaskItem) -> TaskHandoffState? {
        TaskRules.handoff(of: task, live: task.threadID.flatMap { liveTurns[$0] })
    }

    /// The name of the agent a task's line names: while it is handed
    /// over, the agent it was handed to, whoever leads it by now (Strix
    /// where it was handed to no stored agent; nil for one that is gone);
    /// otherwise its lead agent.
    func agentName(for task: TaskItem) -> String? {
        handoff(of: task) == nil ? name(ofAgent: task.leadAgentID, of: task) : handoffAgentName(for: task)
    }

    /// The name of the agent a task was handed to: Strix for no stored
    /// agent, nil for one that is gone or not read yet.
    private func handoffAgentName(for task: TaskItem) -> String? {
        guard let handoff = task.handoff else { return nil }
        guard let id = handoff.agentID else { return Agent.strix.name }
        return name(ofAgent: id, of: task)
    }

    /// An agent's name among those of the task's place.
    private func name(ofAgent id: String?, of task: TaskItem) -> String? {
        id.flatMap { id in agentsByPlace[place(of: task)]?.first { $0.id == id }?.name }
    }

    /// The agents a task can be handed to, those of its place: its lead
    /// agent first, or else the agent the place's latest hand-off went
    /// to. Nil while the place's agents are not read.
    func leadChoices(for task: TaskItem) -> TaskRules.LeadChoices<Agent>? {
        let place = place(of: task)
        guard let agents = agentsByPlace[place] else { return nil }
        return TaskRules.leadChoices(among: agents, id: \.id, leadAgentID: task.leadAgentID, lastUsedID: lastHandedTo[place])
    }

    /// The turns the app runs changed: follows those of the tasks handed
    /// to an agent, says when one newly waits for the person's OK (once
    /// the agents of its place are read, so that it names its agent), and
    /// reads the tasks again when one of them has ended, to learn how
    /// (answering with that reading, for whoever waits for it). A turn
    /// listed as running that nothing runs may have ended while the tasks
    /// were read (an agent's own run too, which is otherwise paused):
    /// they are read again for it, once.
    @discardableResult
    func turnsChanged() -> Task<Void, Never>? {
        var live: [String: TaskLiveTurn] = [:]
        var ended = false
        for task in open {
            guard let handoff = task.handoff, let threadID = task.threadID else { continue }
            if let turn = hands.liveTurn(threadID), turn.turnID == handoff.turnID {
                live[threadID] = turn
                awaited[turn.turnID] = true
                if !turn.needsOK || turn.isStopping {
                    toldNeedsOK.remove(turn.turnID)
                } else if agentsAreSettled(for: task), toldNeedsOK.insert(turn.turnID).inserted, screensUp > 0 {
                    // Once the agents of its place are read (the tasks'
                    // reading comes back to this when they are): it is
                    // said by its agent's name.
                    say("\(handoffAgentName(for: task) ?? "An agent") needs your OK on \(Self.name(of: task))")
                }
            } else if handoff.outcome == .running, readAgainFor.insert(handoff.turnID).inserted {
                if awaited[handoff.turnID] == nil { awaited[handoff.turnID] = false }
                ended = true
            }
        }
        if liveTurns.contains(where: { live[$0.key]?.turnID != $0.value.turnID }) { ended = true }
        if live != liveTurns { liveTurns = live }
        return ended ? Task { await self.load() } : nil
    }

    /// Says how the hand-off turns awaited have ended, as the tasks just
    /// read have them: that the agent finished, or that it could not
    /// start (a turn that failed before it was seen at work, as with no
    /// connection to answer) or stopped on a problem. A turn the person
    /// stopped, or that is gone, is told of by nothing, and nothing is
    /// said once the place has left the screen.
    private func tellEndings() {
        for task in open + finished {
            guard let handoff = task.handoff, let wasSeenAtWork = awaited[handoff.turnID] else { continue }
            if let threadID = task.threadID, liveTurns[threadID]?.turnID == handoff.turnID { continue }
            // Not stored as ended: the tasks are read again for it, or it
            // is an agent's own run that goes on.
            if handoff.outcome == .running { continue }
            awaited[handoff.turnID] = nil
            guard !task.isFinished, screensUp > 0 else { continue }
            let agent = handoffAgentName(for: task) ?? "An agent"
            switch handoff.outcome {
            case .completed: say("\(agent) finished \(Self.name(of: task))")
            case .failed:
                report(
                    wasSeenAtWork
                        ? "\(agent) stopped on a problem with \(Self.quoted(task)). Its thread shows what happened."
                        : Self.couldNotStart(agent, on: task)
                )
            default: break
            }
        }
    }

    static func couldNotStart(_ agent: String, on task: TaskItem) -> String {
        "\(agent) couldn't start on \(quoted(task)). Its thread shows what's happening there."
    }

    /// The task's thread, for Talk it through and Open thread: the one it
    /// has, or one made for it in its place, for an agent of the place,
    /// and given to it. A thread made here starts with the task, so that
    /// whoever answers knows what it is about, and none is made for a
    /// task whose title cannot be read. If
    /// those words could not be sent, they are handed to the thread's
    /// composer, which says why. Nil where it could not be opened, which
    /// is said, and where another account is signed in by then.
    func talkItThrough(_ task: TaskItem, as account: String) async -> Thread? {
        guard TaskRules.canBeTalkedThrough(task), saving.insert(task.id).inserted else { return nil }
        defer { saving.remove(task.id) }
        errorMessage = nil
        // A thread made for it goes to an agent of the place, as a new
        // thread there does: the agents are read first, or the reading
        // under way waited for.
        let place = place(of: task)
        if task.threadID == nil, agentsByPlace[place] == nil { await loadAgents(in: place) }
        guard signedIn() == account else { return nil }
        guard let thread = await thread(for: task, agent: talkAgent(for: task), as: account), signedIn() == account else { return nil }
        // A thread it had already is opened as it is.
        guard task.threadID == nil else { return thread }
        let words = TaskRules.talkThrough(task)
        do {
            _ = try await hands.startTurn(thread, words, nil)
        } catch {
            guard signedIn() == account else { return nil }
            // Said there, where the person is taken.
            hands.handBack(words, thread.id, error)
        }
        guard signedIn() == account else { return nil }
        await Task { await self.load() }.value
        return signedIn() == account ? thread : nil
    }

    /// Who a thread made for a task to be talked through goes to: the
    /// agent that leads the task, else the one the place last handed a
    /// task to, else the place's first; Strix (no stored agent) where
    /// the place has none of its own, or its agents could not be read.
    private func talkAgent(for task: TaskItem) -> Agent? {
        guard let choices = leadChoices(for: task), let agent = choices.marked ?? choices.others.first, !agent.isStrix else { return nil }
        return agent
    }

    /// How far a hand-off got: nothing kept, the lead agent kept but no
    /// turn started, or the turn started and kept with the task.
    enum HandOff: Equatable {
        case none
        case led
        case started
    }

    /// Do it for me, for an open task whose title can be read: makes
    /// `agent`, the one the person picked, the task's lead agent, sends the task to it in the task's thread, and keeps
    /// the turn with the task, so that the task follows it. The thread
    /// keeps its own agent; one made here starts with `agent`. One
    /// hand-off at a time for a task.
    @discardableResult
    func doItForMe(_ task: TaskItem, agent: Agent, as account: String) async -> HandOff {
        guard TaskRules.canBeHandedOver(task), saving.insert(task.id).inserted else { return .none }
        defer { saving.remove(task.id) }
        errorMessage = nil
        var outcome = HandOff.none
        // Strix is no stored agent: a task it is handed names no lead.
        let lead = agent.isStrix ? nil : agent
        if let lead {
            guard await keep(TaskChange(leadAgentID: .to(lead.id)), of: task, as: account) else { return .none }
            outcome = .led
        }
        var turn: String?
        if let thread = await thread(for: task, agent: lead, as: account), signedIn() == account {
            let words = TaskRules.request(for: task)
            do {
                let turnID = try await hands.startTurn(thread, words, agent)
                if signedIn() == account, await keep(TaskChange(handoffTurnID: turnID, handoffAgentID: lead?.id), of: task, as: account) {
                    outcome = .started
                    turn = turnID
                    // How it ends is told once it is read, also if it has
                    // ended by then.
                    if awaited[turnID] == nil { awaited[turnID] = false }
                }
            } catch {
                guard signedIn() == account else { return outcome }
                // The thread shows it: the words wait in its composer, which says why.
                hands.handBack(words, thread.id, error)
                report(Self.couldNotStart(agent.name, on: task))
            }
        }
        guard signedIn() == account else { return outcome }
        if outcome == .led { say("\(agent.name) leads \(Self.name(of: task))") }
        await Task { await self.load() }.value
        // Unless the reading has told how it ended already.
        if let turn, awaited[turn] != nil, signedIn() == account { say("\(agent.name) is on \(Self.name(of: task))") }
        return outcome
    }

    /// Change Lead Agent…: `agent` is listed first, as the lead agent, the
    /// next time Do it for me… is asked. A run under way keeps its agent.
    func changeLeadAgent(_ task: TaskItem, to agent: Agent, as account: String) async {
        guard !agent.isStrix else { return }
        await change(
            task, TaskChange(leadAgentID: .to(agent.id)), saying: "\(agent.name) leads \(Self.name(of: task))", orElse: Self.couldNotSave(task),
            as: account
        )
    }

    /// Keeps one change of a hand-off with its task; says why not.
    private func keep(_ change: TaskChange, of task: TaskItem, as account: String) async -> Bool {
        do {
            try await source.change(task.id, change, account)
            return signedIn() == account
        } catch {
            guard signedIn() == account else { return false }
            if case RepositoryError.dataLocked = error {
                report(Self.needsUnlock)
            } else {
                if !(error is TaskError), !(error is RepositoryError) {
                    AppErrorReporter.log(message: "Could not keep a hand-off (\(type(of: error)))", context: "TasksModel.keep")
                }
                report(Self.couldNotSave(task))
            }
            return false
        }
    }

    static let couldNotOpenThread = "Couldn't open the task's thread. Try again."

    /// The task's thread: the one it has, or one made in its place with
    /// `agent` as its agent and given to the task; one that could not be
    /// given to it is deleted again. Every step is for `account` only.
    /// Nil where it could not be had, which is said.
    private func thread(for task: TaskItem, agent: Agent?, as account: String) async -> Thread? {
        do {
            guard signedIn() == account else { return nil }
            if let threadID = task.threadID { return try await hands.thread(threadID, account) }
            let thread = try await hands.createThread(Self.name(of: task), covenID(of: task), agent, account)
            guard signedIn() == account else { return nil }
            do {
                try await source.change(task.id, TaskChange(threadID: thread.id), account)
            } catch {
                // A thread the task was not given is not kept: nothing
                // was sent into it, and asking again makes another.
                await hands.discardThread(thread, account)
                throw error
            }
            return signedIn() == account ? thread : nil
        } catch is CancellationError {
            return nil
        } catch {
            guard signedIn() == account else { return nil }
            if !(error is TaskError), !(error is RepositoryError) {
                AppErrorReporter.log(message: "Could not open a task's thread (\(type(of: error)))", context: "TasksModel.thread")
            }
            report(Self.couldNotOpenThread)
            return nil
        }
    }
}
