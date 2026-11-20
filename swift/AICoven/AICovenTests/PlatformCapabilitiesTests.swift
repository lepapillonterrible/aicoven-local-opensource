@testable import AICoven
import SwiftUI
import XCTest

/// Which layout a device shows, and what the stone chrome decides from it.
final class PlatformCapabilitiesTests: XCTestCase {
    func testAnIPhoneIsSplitOnlyWhenWidthAndHeightAreRegular() {
        XCTAssertTrue(PlatformCapabilities.usesSplitLayout(isPhone: true, horizontal: .regular, vertical: .regular))
        // A large iPhone in landscape.
        XCTAssertFalse(PlatformCapabilities.usesSplitLayout(isPhone: true, horizontal: .regular, vertical: .compact))
        XCTAssertFalse(PlatformCapabilities.usesSplitLayout(isPhone: true, horizontal: .compact, vertical: .regular))
        XCTAssertFalse(PlatformCapabilities.usesSplitLayout(isPhone: true, horizontal: nil, vertical: nil))
        // An iPad is split unless compact; the Mac has no size classes.
        XCTAssertTrue(PlatformCapabilities.usesSplitLayout(isPhone: false, horizontal: .regular, vertical: .compact))
        XCTAssertFalse(PlatformCapabilities.usesSplitLayout(isPhone: false, horizontal: .compact, vertical: .regular))
        XCTAssertTrue(PlatformCapabilities.usesSplitLayout(isPhone: false, horizontal: nil, vertical: nil))
    }

    // MARK: - The stone chrome

    @MainActor
    func testTheSplitViewsOwnStateDecidesTheSidebarToggle_evenWhenTheVisibilityIsAutomatic() {
        // A window whose shape says "shown" while the split view hides it (Stage Manager): the first tap must
        // open the sidebar.
        XCTAssertFalse(StoneSidebarToggle.isShowing(.automatic, system: false))
        XCTAssertTrue(StoneSidebarToggle.isShowing(.automatic, system: true))
        XCTAssertFalse(StoneSidebarToggle.isShowing(.all, system: false))
        XCTAssertTrue(StoneSidebarToggle.isShowing(.detailOnly, system: true))
    }

    @MainActor
    func testWithNoSplitViewToRead_theVisibilityDecides_andThePlatformForAutomatic() {
        XCTAssertTrue(StoneSidebarToggle.isShowing(.all, system: nil))
        XCTAssertFalse(StoneSidebarToggle.isShowing(.detailOnly, system: nil))
        // An automatic sidebar shows on the Mac only: there the toggle's first press hides it.
        XCTAssertTrue(PlatformCapabilities(platform: .macOS).automaticallyShowsSidebar)
        XCTAssertFalse(PlatformCapabilities(platform: .iOS).automaticallyShowsSidebar)
        #if os(macOS)
        XCTAssertTrue(StoneSidebarToggle.isShowing(.automatic, system: nil))
        #else
        XCTAssertFalse(StoneSidebarToggle.isShowing(.automatic, system: nil))
        #endif
    }
}
