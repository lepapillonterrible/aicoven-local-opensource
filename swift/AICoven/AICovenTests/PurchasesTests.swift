@testable import AICoven
import XCTest

/// What an account owns of the Apple ID's purchases: what it bought, on any
/// device, and nothing refunded or bought by another account.
final class PurchasesTests: XCTestCase {
    private typealias Entitlement = StoreService.Entitlement

    func testAnAccountsToken_isTheSameEveryTime_andDiffersFromAnothers() {
        XCTAssertEqual(StoreService.accountToken(for: "ada"), StoreService.accountToken(for: "ada"), "The same on every device")
        XCTAssertNotEqual(StoreService.accountToken(for: "ada"), StoreService.accountToken(for: "grace"))
        let text = StoreService.accountToken(for: "ada").uuidString
        XCTAssertEqual(Array(text)[14], "5", "A well-formed UUID (version 5 bits)")
    }

    func testRestore_givesBackWhatTheAccountBought_onAnyDevice() {
        let ada = StoreService.accountToken(for: "ada")
        let owned = StoreService.owned(
            of: [
                Entitlement(productID: StoreService.creatorID, accountToken: ada, isRevoked: false),
                Entitlement(productID: StoreService.toolsPackID, accountToken: ada, isRevoked: false),
            ],
            by: "ada"
        )
        XCTAssertEqual(owned, [StoreService.creatorID, StoreService.toolsPackID], "Nothing needs to have been cached on this device")
    }

    func testWhatAnotherAccountBought_onTheSameAppleID_isNotGiven() {
        let grace = StoreService.accountToken(for: "grace")
        let owned = StoreService.owned(of: [Entitlement(productID: StoreService.everythingID, accountToken: grace, isRevoked: false)], by: "ada")
        XCTAssertEqual(owned, [])
    }

    func testARefundOrRevocation_takesItAway() {
        let ada = StoreService.accountToken(for: "ada")
        let owned = StoreService.owned(of: [Entitlement(productID: StoreService.toolsPackID, accountToken: ada, isRevoked: true)], by: "ada")
        XCTAssertEqual(owned, [])
    }

    func testAPurchaseFromBeforePurchasesCarriedAToken_isGivenToTheAccountSignedIn() {
        let owned = StoreService.owned(of: [Entitlement(productID: StoreService.creatorID, accountToken: nil, isRevoked: false)], by: "ada")
        XCTAssertEqual(owned, [StoreService.creatorID])
    }

    func testOnlyTheAppsOwnProductsCount() {
        let ada = StoreService.accountToken(for: "ada")
        let owned = StoreService.owned(of: [Entitlement(productID: "com.example.other", accountToken: ada, isRevoked: false)], by: "ada")
        XCTAssertEqual(owned, [])
    }

    func testTheUpgradesAreNamedAsTheAppStoreNamesThem() {
        XCTAssertEqual(StoreService.shownName(of: StoreService.creatorID), "Starter Pack")
        XCTAssertEqual(StoreService.shownName(of: StoreService.toolsPackID), "Connected Apps")
        XCTAssertEqual(StoreService.shownName(of: StoreService.everythingID), "Everything Forever")
    }
}
