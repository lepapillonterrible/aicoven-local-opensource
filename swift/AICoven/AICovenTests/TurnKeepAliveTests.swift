@testable import AICoven
import XCTest

/// While a turn runs the app asks the system to be kept at its work.
@MainActor
final class TurnKeepAliveTests: XCTestCase {
    /// The system's side, as the test stands in for it.
    private final class System {
        var begun = 0
        var ended = 0
        var expire: (@MainActor () -> Void)?
        /// Whether the system says the time is up while it is being asked.
        var expiresAsItIsAsked = false
        /// Whether the system refuses what it is asked.
        var refuses = false

        var system: TurnKeepAlive.System {
            TurnKeepAlive.System { [self] expired in
                begun += 1
                expire = expired
                if expiresAsItIsAsked { expired() }
                if refuses { return nil }
                return { [self] in ended += 1 }
            }
        }
    }

    func testItIsHeldFromTheFirstTurnThatRunsUntilTheLastHasEnded() {
        let system = System()
        let keeping = TurnKeepAlive(system: system.system)
        XCTAssertEqual(system.begun, 0, "Nothing is held while no turn runs")

        keeping.turnsChanged(areRunning: true)
        keeping.turnsChanged(areRunning: true)
        keeping.appCameToFront()
        XCTAssertEqual(system.begun, 1, "Once, however many turns run")
        XCTAssertEqual(system.ended, 0)

        keeping.turnsChanged(areRunning: false)
        XCTAssertEqual(system.ended, 1)
        keeping.turnsChanged(areRunning: false)
        XCTAssertEqual(system.ended, 1, "What is not held is not ended twice")

        keeping.turnsChanged(areRunning: true)
        XCTAssertEqual(system.begun, 2, "The next turn is held anew")
    }

    func testWhenTheSystemsTimeIsUpTheAskingEnds_andIsNotMadeAgainUntilTheAppHasBeenInFront() {
        let system = System()
        let keeping = TurnKeepAlive(system: system.system)
        keeping.turnsChanged(areRunning: true)

        system.expire?()
        XCTAssertEqual(system.ended, 1, "At once: the system ends an app that goes on asking")
        // The turn still runs; another starts. The system is not asked again from behind.
        keeping.turnsChanged(areRunning: true)
        XCTAssertEqual(system.begun, 1)

        keeping.appCameToFront()
        XCTAssertEqual(system.begun, 2, "With the app in front again, the turn that still runs is held")
        keeping.turnsChanged(areRunning: false)
        XCTAssertEqual(system.ended, 2)
    }

    func testTimeThatIsUpWhileTheSystemIsBeingAskedEndsTheAskingToo() {
        let system = System()
        system.expiresAsItIsAsked = true
        let keeping = TurnKeepAlive(system: system.system)

        keeping.turnsChanged(areRunning: true)
        XCTAssertEqual(system.begun, 1)
        XCTAssertEqual(system.ended, 1, "Nothing is left held that the system has called in")

        keeping.turnsChanged(areRunning: false)
        XCTAssertEqual(system.ended, 1, "And it is ended once")
    }

    func testItIsHeldUntilWhatTellsOfTheEndingIsDoneToo() async {
        let system = System()
        let keeping = TurnKeepAlive(system: system.system)
        let (waits, done) = AsyncStream<Void>.makeStream()
        let telling = Task { for await _ in waits {
            break
        } }

        keeping.turnsChanged(areRunning: true)
        let kept = keeping.keep(until: telling)
        keeping.turnsChanged(areRunning: false)
        XCTAssertEqual(system.begun, 1, "The one asking goes on")
        XCTAssertEqual(system.ended, 0, "The turn has ended; the person has not been told yet")

        done.yield()
        await kept.value
        XCTAssertEqual(system.ended, 1)
    }

    func testWhatTellsOfAnEndingIsKeptForByItself() async {
        let system = System()
        let keeping = TurnKeepAlive(system: system.system)
        let (waits, done) = AsyncStream<Void>.makeStream()
        let telling = Task { for await _ in waits {
            break
        } }

        let kept = keeping.keep(until: telling)
        XCTAssertEqual(system.begun, 1, "With no turn running any more")
        done.yield()
        await kept.value
        XCTAssertEqual(system.ended, 1)
    }

    func testAnAskingTheSystemRefusesIsNotTakenForHeld_andIsMadeAgain() {
        let system = System()
        system.refuses = true
        let keeping = TurnKeepAlive(system: system.system)

        keeping.turnsChanged(areRunning: true)
        XCTAssertEqual(system.begun, 1)
        system.refuses = false
        keeping.appCameToFront()
        XCTAssertEqual(system.begun, 2, "Asked again, with the turn still running")
        keeping.turnsChanged(areRunning: false)
        XCTAssertEqual(system.ended, 1, "Only what was given is ended")
    }
}
