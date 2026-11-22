internal import Combine
import Foundation

/// Tells `LocalNotifications` of what happens in the person's threads: a
/// reply that finished, a turn that stopped on a problem, a turn that
/// needs their OK. Each is told once. A turn the person stopped, or that
/// the app closed on, is told of by nothing.
@MainActor
final class NotificationSource {
    static let shared: NotificationSource = {
        let source = NotificationSource()
        source.follow(TurnEngine.shared, ToolApprovals.shared)
        return source
    }()

    struct Dependencies {
        var account: @MainActor () -> String
        /// A thread of the signed-in account's; nil if it has none by
        /// that id.
        var thread: @Sendable (_ id: String) async -> Thread?
        /// What the scope a thread is in is called: Strix, or its coven.
        var placeName: @Sendable (_ thread: Thread) async -> String
        var notify: @MainActor (_ event: NotificationEvent, _ thread: Thread, _ placeName: String, _ account: String) async -> Void
        /// A reply finished: the line that offers notifications may be
        /// due.
        var replyFinished: @MainActor (_ thread: Thread, _ account: String) async -> Void

        static let live = Dependencies(
            account: { UserScope.currentUserID },
            thread: { try? await ThreadService.shared.getThread(threadId: $0) },
            placeName: { thread in
                guard let covenID = thread.covenId else { return "Strix" }
                let covens = await (try? CovenService.shared.loadCovens()) ?? []
                return covens.first { $0.id == covenID }?.name ?? "A coven"
            },
            notify: { event, thread, placeName, account in
                await LocalNotifications.shared.notify(event, in: thread, placeName: placeName, as: account)
            },
            replyFinished: { thread, account in
                guard !LocalNotifications.shared.appIsInFront else { return }
                await LocalNotifications.shared.offerIfUseful(agentName: thread.agentName, as: account)
            }
        )
    }

    private let dependencies: Dependencies
    /// The turn each thread's ending was told of, by thread id.
    private var toldEndings: [String: String] = [:]
    /// The approvals told of, by id.
    private var toldApprovals: Set<String> = []
    private var followed: Set<AnyCancellable> = []

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    func follow(_ engine: TurnEngine, _ approvals: ToolApprovals) {
        engine.$endings
            .sink { [weak self] in self?.ended($0) }
            .store(in: &followed)
        approvals.$showing.combineLatest(approvals.$waiting, approvals.$held)
            .sink { [weak self] showing, waiting, held in
                self?.asked([showing?.phase == .asking ? showing?.approval : nil].compactMap(\.self) + waiting + held)
            }
            .store(in: &followed)
    }

    /// The turns that have ended, by thread id: each new ending is told
    /// of once, a reply as finished and a failure as a problem.
    @discardableResult
    func ended(_ endings: [String: TurnEngine.Ending]) -> [Task<Void, Never>] {
        var telling: [Task<Void, Never>] = []
        for (threadID, ending) in endings where toldEndings[threadID] != ending.turnID {
            toldEndings[threadID] = ending.turnID
            let said = ending.messages.first?.content ?? ""
            let event: NotificationEvent
            switch ending.outcome {
            case .completed: event = .finished(reply: said)
            case .failed: event = .problem(reason: said)
            case .cancelled, .interrupted, .running: continue
            }
            telling.append(tell(event, ofThread: threadID))
        }
        toldEndings = toldEndings.filter { endings[$0.key] != nil }
        return telling
    }

    /// Everything being asked of the person: each approval a turn waits
    /// on is told of once. A question that is no turn's (whether to
    /// remember something) is not.
    @discardableResult
    func asked(_ approvals: [ToolApproval]) -> [Task<Void, Never>] {
        var telling: [Task<Void, Never>] = []
        for approval in approvals where approval.isOfATurn && !toldApprovals.contains(approval.id) {
            toldApprovals.insert(approval.id)
            telling.append(tell(.needsOK(question: approval.question), ofThread: approval.threadID))
        }
        toldApprovals.formIntersection(approvals.map(\.id))
        return telling
    }

    /// Tells of `event` in a thread, as the account signed in when it
    /// happened: nothing if the thread is not theirs, or another account
    /// is signed in by the time the thread has been looked up.
    private func tell(_ event: NotificationEvent, ofThread threadID: String) -> Task<Void, Never> {
        let account = dependencies.account()
        return Task { [dependencies] in
            guard let thread = await dependencies.thread(threadID), thread.userId == account, dependencies.account() == account else { return }
            let placeName = await dependencies.placeName(thread)
            guard dependencies.account() == account else { return }
            await dependencies.notify(event, thread, placeName, account)
            if case .finished = event {
                await dependencies.replyFinished(thread, account)
            }
        }
    }
}
