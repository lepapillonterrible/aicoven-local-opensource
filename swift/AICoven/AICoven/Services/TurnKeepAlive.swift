internal import Combine
import Foundation
#if os(iOS)
import UIKit
#endif

/// Keeps the app at its work while a turn runs, as far as the system lets
/// it, so that a turn the person walks away from can finish (and say so).
/// On the Mac the app says it is busy, so the system does not slow it down
/// behind other apps; the Mac may still sleep when left idle. On the
/// iPhone and iPad it asks for the time the system gives an app that has
/// left the screen to finish what it is doing: about half a minute, never
/// promised, after which the system may suspend the app or end it. A turn
/// of the app's own that was cut off says so when the app is opened again;
/// an agent of the person's own goes on by itself and is followed again.
/// It is held from the first turn that runs until the last has ended and
/// what tells of the endings has been told; otherwise nothing is held.
@MainActor
final class TurnKeepAlive {
    static let shared: TurnKeepAlive = {
        let keeping = TurnKeepAlive()
        keeping.follow(TurnEngine.shared)
        return keeping
    }()

    /// The system's side, which a test replaces: `begin` asks to be kept
    /// at work and gives what ends the asking, or nil if the system
    /// refused; `expired` is called if the system says the time is up.
    struct System {
        var begin: @MainActor (_ expired: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)?

        static let live = System { expired in
            #if os(macOS)
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "A turn is running")
            return { ProcessInfo.processInfo.endActivity(activity) }
            #else
            // The system calls this on the main thread and gives the app
            // only until it returns: the asking is ended in the call itself.
            let task = UIApplication.shared.beginBackgroundTask(withName: "A turn is running") {
                MainActor.assumeIsolated { expired() }
            }
            // Refused: nothing is held, and nothing is to be ended.
            guard task != .invalid else { return nil }
            return { UIApplication.shared.endBackgroundTask(task) }
            #endif
        }
    }

    private let system: System
    /// What ends the asking that is under way; nil while nothing is held.
    private var end: (@MainActor () -> Void)?
    private var turnsAreRunning = false
    /// How much of what finishes a turn is still under way (`keep(until:)`).
    private var finishing = 0
    /// The system said the time was up: it is not asked again until the
    /// app has been in front.
    private var timeWasUp = false
    private var followed: AnyCancellable?

    /// The system's own side unless a test gives another.
    init(system: System? = nil) {
        self.system = system ?? .live
    }

    func follow(_ engine: TurnEngine) {
        followed = engine.$running
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { [weak self] in self?.turnsChanged(areRunning: $0) }
    }

    /// A turn started, or the last one ended.
    func turnsChanged(areRunning: Bool) {
        turnsAreRunning = areRunning
        hold()
    }

    /// Keeps the app at its work until `work` is done too: what tells the
    /// person that a turn ended is made after the turn has ended, and is
    /// what they walked away to be told. Answers with what is done once
    /// `work` no longer counts.
    @discardableResult
    func keep(until work: Task<Void, Never>) -> Task<Void, Never> {
        finishing += 1
        hold()
        return Task {
            await work.value
            finishing -= 1
            hold()
        }
    }

    /// The app is in front again: the system may be asked anew.
    func appCameToFront() {
        timeWasUp = false
        hold()
    }

    private func hold() {
        guard turnsAreRunning || finishing > 0 else {
            release()
            return
        }
        guard end == nil, !timeWasUp else { return }
        // Refused, nothing is held: it is asked again when something next changes.
        end = system.begin { [weak self] in
            // The system's time is up: the asking must end at once.
            self?.timeWasUp = true
            self?.release()
        }
        // The time was up before the asking was even given: it is ended all the same.
        if timeWasUp { release() }
    }

    private func release() {
        end?()
        end = nil
    }
}
