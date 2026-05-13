import XCTest
@testable import AICoven

@MainActor
final class CacheManagementServiceTests: XCTestCase {
    func testClearLocalCachesDoesNotReportUserDataDeletion() {
        let result = CacheManagementService.clearLocalCaches()

        XCTAssertGreaterThanOrEqual(result.removedItems, 0)
        XCTAssertTrue(result.userMessage.contains("chats") || result.userMessage.contains("No cached files"))
        XCTAssertTrue(result.userMessage.contains("provider keys") || result.userMessage.contains("No cached files"))
    }

    func testPricingCacheClearRemovesFetchMarker() {
        UserDefaults.standard.set(Date(), forKey: "model_pricing.last_fetched")

        let removedItems = PricingUpdateService.shared.clearCachedOverrides()

        XCTAssertNil(UserDefaults.standard.object(forKey: "model_pricing.last_fetched"))
        XCTAssertGreaterThanOrEqual(removedItems, 1)
    }
}
