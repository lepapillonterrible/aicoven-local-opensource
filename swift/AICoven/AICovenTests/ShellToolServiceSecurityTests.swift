import XCTest
@testable import AICoven

final class ShellToolServiceSecurityTests: XCTestCase {
    func testShellExecute_requiresExplicitWorkingDirectory() async {
        let result = await ShellToolService.shared.execute(
            command: "pwd",
            workingDir: nil,
            timeoutSeconds: 1
        )

        XCTAssertEqual(result.status, "denied")
        XCTAssertEqual(result.errorType, "permission_denied")
        XCTAssertTrue(result.error?.contains("explicit working directory") == true)
    }

    func testShellExecute_rejectsEmptyWorkingDirectory() async {
        let result = await ShellToolService.shared.execute(
            command: "pwd",
            workingDir: "   ",
            timeoutSeconds: 1
        )

        XCTAssertEqual(result.status, "denied")
        XCTAssertEqual(result.errorType, "permission_denied")
        XCTAssertTrue(result.error?.contains("explicit working directory") == true)
    }
}
