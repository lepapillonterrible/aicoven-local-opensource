internal import Combine
import Foundation

/// What each of the signed-in account's threads is doing, for the lists
/// of threads: one place that puts together the turns the engine runs,
/// the approvals asked, what is stored with each thread, and which
/// threads are on screen. It also keeps the read marks: a thread is read
/// up to the moment it comes on screen, up to each message stored in it
/// while it is there, and up to the moment it leaves.
@MainActor
final class ThreadActivities: ObservableObject {
    static let shared: ThreadActivities = {
        let activities = ThreadActivities()
        activities.follow(TurnEngine.shared, ToolApprovals.shared)
        return activities
    }()

    struct Dependencies {
        var currentAccount: @MainActor () -> String
        var loadMarks: @Sendable (_ account: String) async throws -> [String: ThreadMarks]
        var markRead: @Sendable (_ threadID: String, _ date: Date, _ account: String) async throws -> Void
        /// Each of the account's threads' coven, by thread id (none for a
        /// personal thread, or one that is archived: a reply in a thread
        /// put away marks its row, not its coven).
        var loadCovens: @Sendable () async throws -> [String: String]
        /// Whether a thread's composer holds something unsent, where that
        /// is known since the app started.
        var holdsDraft: @MainActor (_ threadID: String) -> Bool?
        var now: @MainActor () -> Date

        static let live = Dependencies(
            currentAccount: { UserScope.currentUserID },
            loadMarks: { try await ThreadRepository.shared.threadMarks(for: $0) },
            markRead: { try await ThreadRepository.shared.markRead(threadID: $0, at: $1, for: $2) },
            loadCovens: { try await ThreadService.shared.covensOfThreads() },
            holdsDraft: { ComposerDrafts.shared.holdsDraft(for: $0) },
            now: { Date() }
        )
    }

    /// What each thread is doing, by thread id; a thread doing nothing a
    /// row says is not in it.
    @Published private(set) var activity: [String: ConversationActivity] = [:]
    /// The covens with a thread holding a reply not yet seen.
    @Published private(set) var covensWithUnread: Set<String> = []

    private let dependencies: Dependencies
    /// What is stored with each thread, as last read, and whose they are.
    private var marks: [String: ThreadMarks] = [:]
    private var covens: [String: String] = [:]
    private var marksAccount: String?
    /// Up to when each thread was read here, by thread id, for the account
    /// `readHereAccount`: a reading of the store that began before a thread
    /// was read does not bring its older mark back.
    private var readHere: [String: Date] = [:]
    private var readHereAccount: String?
    private var turns: [String: ConversationActivity.Turn] = [:]
    private var asking: Set<String> = []
    private var ended: [String: TurnOutcome] = [:]
    /// Threads the engine holds something unsent for.
    private var handedBack: Set<String> = []
    private var keptUnsent: Set<String> = []
    /// How many places show each thread now.
    private var shown: [String: Int] = [:]
    /// Counts the readings of the store, so that only the latest is kept.
    private var readings = 0
    private var followed: Set<AnyCancellable> = []

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    /// Follows the engine's turns, the approvals asked, and messages
    /// stored.
    func follow(_ engine: TurnEngine, _ approvals: ToolApprovals) {
        engine.$running
            .map { $0.mapValues { ConversationActivity.Turn(message: $0.message, isStopping: $0.isStopping) } }
            .removeDuplicates()
            .sink { [weak self] in self?.setTurns($0) }
            .store(in: &followed)
        engine.$endings
            .map { $0.mapValues(\.outcome) }
            .removeDuplicates()
            .sink { [weak self] in self?.setEnded($0) }
            .store(in: &followed)
        engine.$returned
            .map { Set($0.keys) }
            .removeDuplicates()
            .sink { [weak self] in self?.setUnsent(handedBack: $0) }
            .store(in: &followed)
        engine.$unsent
            .map { Set($0.keys) }
            .removeDuplicates()
            .sink { [weak self] in self?.setUnsent(kept: $0) }
            .store(in: &followed)
        approvals.$askingThreadIDs
            .removeDuplicates()
            .sink { [weak self] in self?.setAsking($0) }
            .store(in: &followed)
        NotificationCenter.default.publisher(for: ThreadService.threadUsed)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &followed)
    }

    // MARK: - What it is told

    func setTurns(_ turns: [String: ConversationActivity.Turn]) {
        self.turns = turns
        work()
    }

    func setEnded(_ ended: [String: TurnOutcome]) {
        self.ended = ended
        work()
    }

    func setAsking(_ asking: Set<String>) {
        self.asking = asking
        work()
    }

    func setUnsent(handedBack: Set<String>? = nil, kept: Set<String>? = nil) {
        if let handedBack { self.handedBack = handedBack }
        if let kept { keptUnsent = kept }
        work()
    }

    /// A thread came on screen: it is read up to now.
    @discardableResult
    func show(_ threadID: String) -> Task<Void, Never> {
        shown[threadID, default: 0] += 1
        let reading = read(threadID)
        // A thread nothing is held of (made since the store was last read):
        // the store is read again, so its row can say what it is doing.
        guard marksAccount != dependencies.currentAccount() || marks[threadID] == nil else { return reading }
        return Task {
            await reading.value
            await reload().value
        }
    }

    /// Another account signed in, or this one signed out: nothing of the
    /// one before is said, and the store is read for the one there is now.
    @discardableResult
    func accountChanged() -> Task<Void, Never> {
        marks = [:]
        covens = [:]
        marksAccount = nil
        readHere = [:]
        readHereAccount = nil
        work()
        return reload()
    }

    /// A thread left the screen (once for each time it came on): it is
    /// read up to now, and what its composer holds is from now an unsent
    /// message.
    @discardableResult
    func hide(_ threadID: String) -> Task<Void, Never> {
        if let count = shown[threadID] {
            shown[threadID] = count > 1 ? count - 1 : nil
        }
        return read(threadID)
    }

    /// Reads again what is stored with the account's threads. First, the
    /// threads on screen are read up to now: what was stored in them was
    /// seen as it arrived.
    @discardableResult
    func reload() -> Task<Void, Never> {
        readings += 1
        let reading = readings
        let account = dependencies.currentAccount()
        let now = dependencies.now()
        let onScreen = Array(shown.keys)
        return Task { [dependencies] in
            for threadID in onScreen {
                do {
                    try await dependencies.markRead(threadID, now, account)
                } catch {
                    // The kind of failure only.
                    AppErrorReporter.log(message: "Could not keep a read mark (\(type(of: error)))", context: "ThreadActivities.reload")
                }
            }
            do {
                let marks = try await dependencies.loadMarks(account)
                let covens = try await dependencies.loadCovens()
                // Only the latest reading, and only as the account it was read
                // for. Either way what is said is worked out again: nothing
                // of an account that is gone stays said.
                guard reading == readings, dependencies.currentAccount() == account else {
                    work()
                    return
                }
                self.marks = readHereAccount == account ? marks.readUp(to: readHere) : marks
                self.covens = covens
                marksAccount = account
            } catch {
                guard reading == readings else {
                    work()
                    return
                }
                // The kind of failure only: nothing of what was read.
                AppErrorReporter.log(message: "Could not read the threads' marks (\(type(of: error)))", context: "ThreadActivities.reload")
                if dependencies.currentAccount() != marksAccount {
                    marks = [:]
                    covens = [:]
                    marksAccount = nil
                }
            }
            work()
        }
    }

    // MARK: - What it works out

    /// Notes a thread as read up to now, here at once and in the store.
    private func read(_ threadID: String) -> Task<Void, Never> {
        let account = dependencies.currentAccount()
        let now = dependencies.now()
        if readHereAccount != account {
            readHere = [:]
            readHereAccount = account
        }
        readHere[threadID] = max(now, readHere[threadID] ?? now)
        if marksAccount == account { marks = marks.readUp(to: [threadID: now]) }
        work()
        return Task { [dependencies] in
            do {
                try await dependencies.markRead(threadID, now, account)
            } catch {
                // The kind of failure only.
                AppErrorReporter.log(message: "Could not keep a read mark (\(type(of: error)))", context: "ThreadActivities.markRead")
            }
        }
    }

    /// Works out what each thread is doing from what is held now.
    private func work() {
        // What is stored is one account's: another's is not gone by.
        let stored = marksAccount == dependencies.currentAccount() ? marks : [:]
        var activity: [String: ConversationActivity] = [:]
        var unreadCovens: Set<String> = []
        // Only of the threads read from the store for this account: what
        // the engine holds is by thread, whoever's the thread is.
        for threadID in stored.keys {
            let isShown = shown[threadID] != nil
            let hasUnsent = handedBack.contains(threadID) || keptUnsent.contains(threadID)
                || dependencies.holdsDraft(threadID) ?? stored[threadID]?.hasDraft ?? false
            let current = ConversationActivity.of(
                turn: turns[threadID],
                needsOK: asking.contains(threadID),
                ended: ended[threadID],
                marks: stored[threadID],
                hasUnsent: hasUnsent,
                isShown: isShown
            )
            activity[threadID] = current
            if !isShown, stored[threadID]?.isUnread == true, let coven = covens[threadID] {
                unreadCovens.insert(coven)
            }
        }
        if activity != self.activity { self.activity = activity }
        if unreadCovens != covensWithUnread { covensWithUnread = unreadCovens }
    }
}

extension [String: ThreadMarks] {
    /// These marks, each thread in `read` read up to its time there, never
    /// to an earlier time than its mark says.
    func readUp(to read: [String: Date]) -> [String: ThreadMarks] {
        var marks = self
        for (threadID, date) in read {
            guard var mark = marks[threadID], (mark.readAt ?? .distantPast) < date else { continue }
            mark.readAt = date
            marks[threadID] = mark
        }
        return marks
    }
}
