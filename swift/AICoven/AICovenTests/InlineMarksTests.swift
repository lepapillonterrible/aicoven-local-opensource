@testable import AICoven
import SwiftUI
import XCTest

/// An inline mark (underline, strikethrough, superscript, subscript,
/// keyboard) covers the words it was put around, whatever Markdown takes
/// out before or inside it. The renderer sets SwiftUI's attributes, which
/// is what `Text` draws.
@MainActor
final class InlineMarksTests: XCTestCase {
    /// The words of `text` that carry `attribute`.
    private func words(
        in text: AttributedString,
        with attribute: (AttributedString.Runs.Run) -> Bool
    ) -> [String] {
        text.runs.filter(attribute).map { String(text[$0.range].characters) }
    }

    private func underlined(_ markdown: String) -> [String] {
        let text = MarkdownInlineText.attributedInline(markdown)
        return words(in: text) { $0.swiftUI.underlineStyle != nil }
    }

    func testAMarkAroundBoldWords_coversThoseWordsOnly() {
        XCTAssertEqual(underlined("<u>**bold**</u> next"), ["bold"])
        let struck = MarkdownInlineText.attributedInline("~~**old**~~ next")
        XCTAssertEqual(String(struck.characters), "old next")
        XCTAssertEqual(words(in: struck) { $0.swiftUI.strikethroughStyle != nil }, ["old"])
    }

    func testAMarkAfterALinkOrCode_coversItsWords() {
        XCTAssertEqual(underlined("[a long link text](https://example.com/a/very/long/address) then <u>under</u> end"), ["under"])
        XCTAssertEqual(underlined("`some code` then <u>under</u> end"), ["under"])
        XCTAssertEqual(underlined("*one* **two** then <u>under</u>"), ["under"])
    }

    /// Emphasis inside a mark is still emphasis: nothing of the mark is
    /// parsed with it.
    func testEmphasisInsideAMark_isStillEmphasis() {
        for (markdown, words) in [
            ("<u>_italic_</u> next", "italic"), ("<u>__bold__</u> next", "bold"), ("<u>**Note:**</u> next", "Note:"),
            ("<u>**(x)**</u> next", "(x)"), ("~~*a*~~ next", "a"),
        ] {
            let text = MarkdownInlineText.attributedInline(markdown)
            XCTAssertEqual(String(text.characters), "\(words) next", markdown)
            XCTAssertNotNil(text.runs.first?.inlinePresentationIntent, markdown)
            let marked = self.words(in: text) { $0.swiftUI.underlineStyle != nil || $0.swiftUI.strikethroughStyle != nil }
            XCTAssertEqual(marked, [words], markdown)
        }
    }

    /// An entity in code is shown as written, and a mark after it covers its
    /// own words.
    func testAMarkAfterAnEntityInCode_coversItsWords() {
        XCTAssertEqual(underlined("`&amp;` then <u>under</u>"), ["under"])
        XCTAssertEqual(underlined("[x](https://y.example) then <u>y</u>"), ["y"])
    }

    func testAMarkAroundAnEntity_coversTheDecodedWords() {
        XCTAssertEqual(underlined("<u>AT&T &amp; Co</u> <script>bad()</script>"), ["AT&T & Co"])
    }

    func testAMarkedAddress_isStillALinkToItsAddress() {
        let text = MarkdownInlineText.attributedInline("See <u>https://example.com/page</u> now")
        XCTAssertEqual(String(text.characters), "See https://example.com/page now")
        XCTAssertEqual(text.runs.compactMap(\.link?.absoluteString), ["https://example.com/page"])
        XCTAssertEqual(words(in: text) { $0.swiftUI.underlineStyle != nil }, ["https://example.com/page"])
    }

    /// A reply cannot mark its own words by writing the markers itself.
    func testAReplysOwnMarkerCharacters_markNothingAndAreNotShown() {
        let open = String(MarkdownInlineText.InlineMark.underline.open)
        let close = String(MarkdownInlineText.InlineMark.underline.close)
        let text = MarkdownInlineText.attributedInline("a \(open)b\(close) c")
        XCTAssertEqual(String(text.characters), "a b c")
        XCTAssertEqual(words(in: text) { $0.swiftUI.underlineStyle != nil }, [])
    }

    func testAnUnclosedTag_staysText() {
        let text = MarkdownInlineText.attributedInline("<u>open only")
        XCTAssertEqual(String(text.characters), "<u>open only")
    }

    /// An image whose alt text holds code is a placeholder too; an image
    /// written inside a code span is code.
    func testAnImage_isAPlaceholderEvenWithCodeInItsAltText() {
        let text = String(MarkdownInlineText.attributedInline("Before ![chart `v1`](https://example.com/chart.png) after.").characters)
        XCTAssertTrue(text.hasPrefix("Before Image: chart v1"), text)
        XCTAssertFalse(text.contains("!["), text)
        XCTAssertEqual(String(MarkdownInlineText.attributedInline("`![a](b)` stays").characters), "![a](b) stays")
    }
}
