import XCTest
import SwiftUI
@testable import AICoven

/// Simple smoke tests to ensure key SwiftUI views can be constructed.
final class SwiftUIViewTests: XCTestCase {

    #if os(macOS)
    func testHomeViewInitializes() {
        let view = HomeView()
        // Accessing the type erasure ensures the view compiles in tests.
        _ = AnyView(view)
    }
    #endif

    func testMainTabViewInitializes() {
        let view = MainTabView()
        _ = AnyView(view)
    }
}
