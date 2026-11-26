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

/// Google is asked only for `drive.file`, which it counts as non-sensitive:
/// the sensitive Docs and Sheets scopes put an unverified-app warning in
/// front of the sign-in.
final class GoogleScopesTests: XCTestCase {
    func testGoogleAsksForTheFilesThePersonPicksAndNoMore() {
        XCTAssertEqual(ConnectedAppProvider.googleDrive.defaultScopes, ["https://www.googleapis.com/auth/drive.file"])
    }

    func testThePickerKnowsTheProject_andHasNoPlaceholderKey() {
        XCTAssertEqual(OAuthClientIDs.googlePickerAppID, "870439799161")
        XCTAssertFalse(OAuthClientIDs.googlePickerAPIKey?.hasPrefix("YOUR_") ?? false)
    }
}
