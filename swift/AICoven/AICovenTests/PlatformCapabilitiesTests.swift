@testable import AICoven
import SwiftUI
import XCTest

/// Which layout a device shows, and what the stone chrome decides from it.
final class PlatformCapabilitiesTests: XCTestCase {
    func testTheCurrentPlatformIsTheOneCompiledFor() {
        #if os(macOS)
        XCTAssertEqual(PlatformCapabilities.current.platform, .macOS)
        #else
        XCTAssertEqual(PlatformCapabilities.current.platform, .iOS)
        #endif
    }

    @MainActor
    func testTheMacIsNeitherAnIPadNorAnIPhone() async {
        #if os(macOS)
        XCTAssertFalse(PlatformCapabilities.isPad)
        XCTAssertFalse(PlatformCapabilities.isPhone)
        #else
        XCTAssertNotEqual(PlatformCapabilities.isPad, PlatformCapabilities.isPhone, "One or the other")
        #endif
        await Task.yield()
    }

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

    func testOnlyTheMacShowsAnAutomaticSidebar() {
        XCTAssertTrue(PlatformCapabilities(platform: .macOS).automaticallyShowsSidebar)
        XCTAssertFalse(PlatformCapabilities(platform: .iOS).automaticallyShowsSidebar)
    }

    func testControlsDoNotTakeTheIPadsShapeUnlessTheShellSaysSo() {
        XCTAssertFalse(EnvironmentValues().isPadLayout)
        var values = EnvironmentValues()
        values.isPadLayout = true
        XCTAssertTrue(values.isPadLayout)
    }

    // MARK: - The stone chrome

    @MainActor
    func testTheSplitViewsOwnStateDecidesTheSidebarToggle_evenWhenTheVisibilityIsAutomatic() async {
        // A window whose shape says "shown" while the split view hides it (Stage Manager): the first tap must
        // open the sidebar.
        XCTAssertFalse(StoneSidebarToggle.isShowing(.automatic, system: false))
        XCTAssertTrue(StoneSidebarToggle.isShowing(.automatic, system: true))
        XCTAssertFalse(StoneSidebarToggle.isShowing(.all, system: false))
        XCTAssertTrue(StoneSidebarToggle.isShowing(.detailOnly, system: true))
        await Task.yield()
    }

    @MainActor
    func testWithNoSplitViewToRead_theVisibilityAndThePlatformDecide() async {
        XCTAssertTrue(StoneSidebarToggle.isShowing(.all, system: nil))
        XCTAssertFalse(StoneSidebarToggle.isShowing(.detailOnly, system: nil))
        XCTAssertEqual(
            StoneSidebarToggle.isShowing(.automatic, system: nil),
            PlatformCapabilities.current.automaticallyShowsSidebar
        )
        // The Mac has no split view to ask: its toggle goes by the visibility, as before.
        #if os(macOS)
        XCTAssertNil(SplitViewProbe().sidebarIsShowing())
        #endif
        await Task.yield()
    }

    func testToolbarButtonsAreSmallerInTheIPadsLayout() {
        XCTAssertEqual(StoneChrome.toolbarButtonSide(isPadLayout: true), 40)
        XCTAssertEqual(StoneChrome.toolbarButtonSide(isPadLayout: false), 44)
    }
}
