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
/// promised, after which the turn waits until the app is opened again.
/// While no turn runs, nothing is held.
@MainActor
final class TurnKeepAlive {
    static let shared: TurnKeepAlive = {
        let keeping = TurnKeepAlive()
        keeping.follow(TurnEngine.shared)
        return keeping
    }()

    /// The system's side, which a test replaces: `begin` asks to be kept
    /// at work and gives what ends the asking; `expired` is called if the
    /// system says the time is up.
    struct System {
        var begin: @MainActor (_ expired: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)

        static let live = System { expired in
            #if os(macOS)
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "A turn is running")
            return { ProcessInfo.processInfo.endActivity(activity) }
            #else
            let task = UIApplication.shared.beginBackgroundTask(withName: "A turn is running") {
                Task { @MainActor in expired() }
            }
            return { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
            #endif
        }
    }

    private let system: System
    /// What ends the asking that is under way; nil while nothing is held.
    private var end: (@MainActor () -> Void)?
    private var turnsAreRunning = false
    /// The system said the time was up: it is not asked again until the
    /// app has been in front.
    private var timeWasUp = false
    private var followed: AnyCancellable?

    init(system: System = .live) {
        self.system = system
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

    /// The app is in front again: the system may be asked anew.
    func appCameToFront() {
        timeWasUp = false
        hold()
    }

    private func hold() {
        guard turnsAreRunning else {
            release()
            return
        }
        guard end == nil, !timeWasUp else { return }
        end = system.begin { [weak self] in
            // The system's time is up: the asking must end at once.
            self?.timeWasUp = true
            self?.release()
        }
    }

    private func release() {
        end?()
        end = nil
    }
}
