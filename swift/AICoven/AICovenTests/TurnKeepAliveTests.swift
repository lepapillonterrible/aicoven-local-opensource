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

        var system: TurnKeepAlive.System {
            TurnKeepAlive.System { [self] expired in
                begun += 1
                expire = expired
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
}
