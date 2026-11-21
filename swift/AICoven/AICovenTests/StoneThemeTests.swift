@testable import AICoven
import SwiftUI
import XCTest

#if os(macOS)
final class StoneThemeTests: XCTestCase {
    func testSurface_isDayStoneInLightAndDuskStoneInDark() throws {
        XCTAssertEqual(try hex(of: .aicovenSurface, in: .aqua), "E8E2D6")
        XCTAssertEqual(try hex(of: .aicovenSurface, in: .darkAqua), "2C2925")
    }

    func testAccentAtDusk_isTheFillWaterWhiteLabelsStayReadableOn() throws {
        XCTAssertEqual(try hex(of: .aicovenTeal, in: .darkAqua), "517D79")
    }

    private func hex(of color: Color, in appearance: NSAppearance.Name) throws -> String {
        var resolved: NSColor?
        try XCTUnwrap(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        let rgb = try XCTUnwrap(resolved)
        return String(
            format: "%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }
}
#endif
