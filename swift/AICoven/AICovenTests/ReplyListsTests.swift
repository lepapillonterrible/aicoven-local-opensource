@testable import AICoven
import XCTest

/// A reply's lists keep their items apart, as the full QA found they did
/// not: "List three fruits as a bulleted list, then three vegetables as a
/// numbered list" was drawn on the Mac as "AppleBananaOrange" and
/// "CarrotBroccoliSpinach".
@MainActor
final class ReplyListsTests: XCTestCase {
    func testABulletedAndANumberedList_areListsOfTheirItems() {
        XCTAssertEqual(MarkdownBlockParser.parse("- Apple\n- Banana\n- Orange\n\n1. Carrot\n2. Broccoli\n3. Spinach"), [
            .unorderedList([
                MarkdownListItem(indent: 0, text: "Apple", ordinal: nil, isChecked: nil),
                MarkdownListItem(indent: 0, text: "Banana", ordinal: nil, isChecked: nil),
                MarkdownListItem(indent: 0, text: "Orange", ordinal: nil, isChecked: nil),
            ]),
            .orderedList([
                MarkdownListItem(indent: 0, text: "Carrot", ordinal: 1, isChecked: nil),
                MarkdownListItem(indent: 0, text: "Broccoli", ordinal: 2, isChecked: nil),
                MarkdownListItem(indent: 0, text: "Spinach", ordinal: 3, isChecked: nil),
            ]),
        ])
    }

    /// A list right under the line that introduces it, with no blank line
    /// between, as models often write it.
    func testAListRightUnderItsLine_isAListAfterThatLine() {
        XCTAssertEqual(MarkdownBlockParser.parse("Three colours for the logo:\n- Deep navy\n- Teal\n- Coral"), [
            .paragraph("Three colours for the logo:"),
            .unorderedList([
                MarkdownListItem(indent: 0, text: "Deep navy", ordinal: nil, isChecked: nil),
                MarkdownListItem(indent: 0, text: "Teal", ordinal: nil, isChecked: nil),
                MarkdownListItem(indent: 0, text: "Coral", ordinal: nil, isChecked: nil),
            ]),
        ])
    }

    #if os(macOS)
    /// What the Mac draws: each item on a line of its own, with its marker.
    func testOnTheMac_eachItemIsDrawnOnALineOfItsOwnWithItsMarker() {
        let drawn = String(MarkdownView.attributedMessage(
            MarkdownBlockParser.parse("- Apple\n- Banana\n- Orange\n\n1. Carrot\n2. Broccoli\n3. Spinach"), compact: false
        ).characters)
        XCTAssertEqual(drawn, "• Apple\n• Banana\n• Orange\n\n1. Carrot\n2. Broccoli\n3. Spinach")
    }
    #endif

    /// On the Mac a reply's prose is one selectable text: its lists are in it.
    func testOnTheMac_aReplysListsAreInItsSelectableText() {
        XCTAssertEqual(MarkdownView.macOSRenderPlan(for: "Fruits:\n- Apple\n- Banana"), [
            .selectableProse([
                .paragraph("Fruits:"),
                .unorderedList([
                    MarkdownListItem(indent: 0, text: "Apple", ordinal: nil, isChecked: nil),
                    MarkdownListItem(indent: 0, text: "Banana", ordinal: nil, isChecked: nil),
                ]),
            ]),
        ])
    }
}
