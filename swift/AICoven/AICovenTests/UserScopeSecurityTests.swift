import XCTest
@testable import AICoven

final class UserScopeSecurityTests: XCTestCase {
    func testScopedKeysUseExplicitLocalOwnerWhenFirebaseIsUnavailable() {
        XCTAssertEqual(UserScope.currentUserID, UserScope.firebaseUserID ?? UserScope.localUserID)
        XCTAssertEqual(UserScope.scopedKey("provider_accounts.v1"), "\(UserScope.currentUserID).provider_accounts.v1")
        XCTAssertEqual(UserScope.scopedKeychainService("AICovenProviderKeys"), "AICovenProviderKeys.\(UserScope.currentUserID)")
        XCTAssertEqual(UserScope.scopedFilename("personal_threads", extension: "json"), "personal_threads_\(UserScope.currentUserID).json")
    }

    func testScopedKeysNeverFallBackToUnscopedBaseNames() {
        XCTAssertNotEqual(UserScope.scopedKey("provider_accounts.v1"), "provider_accounts.v1")
        XCTAssertNotEqual(UserScope.scopedKeychainService("AICovenProviderKeys"), "AICovenProviderKeys")
        XCTAssertNotEqual(UserScope.scopedFilename("personal_threads", extension: "json"), "personal_threads.json")
    }
}
