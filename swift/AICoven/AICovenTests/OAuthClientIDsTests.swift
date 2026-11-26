@testable import AICoven
import XCTest

/// A client ID the build left as a placeholder is no ID: sent as it was,
/// GitHub answered 404 and Google refused the sign-in.
final class OAuthClientIDsTests: XCTestCase {
    func testAPlaceholderOrNothing_givesTheAppsOwnID() {
        for configured in [nil, "", "  ", "YOUR_GITHUB_OAUTH_CLIENT_ID", "$(GITHUB_OAUTH_CLIENT_ID)"] {
            XCTAssertEqual(OAuthClientIDs.id(configured, otherwise: "own"), "own", String(describing: configured))
        }
    }

    func testAForksOwnID_isUsed() {
        XCTAssertEqual(OAuthClientIDs.id(" Iv1.abc123 ", otherwise: "own"), "Iv1.abc123")
    }

    func testTheBuiltAppSignsInWithARealID() {
        for id in [OAuthClientIDs.github, OAuthClientIDs.google] {
            XCTAssertFalse(id.hasPrefix("YOUR_"), id)
            XCTAssertFalse(id.contains("$("), id)
        }
        XCTAssertTrue(OAuthClientIDs.google.hasSuffix(".apps.googleusercontent.com"))
    }
}
