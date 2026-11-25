import SwiftUI
import XCTest
@testable import AICoven

@MainActor
final class MarkdownBlockParserTests: XCTestCase {
    func testParsesHeadingsH1ThroughH4AsDistinctBlocks() {
        let blocks = MarkdownBlockParser.parse("""
        # Title
        ## Section
        ### Subsection
        #### Detail
        """)

        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Title"),
            .heading(level: 2, text: "Section"),
            .heading(level: 3, text: "Subsection"),
            .heading(level: 4, text: "Detail")
        ])
    }

    func testParsesNestedOrderedAndUnorderedListsWithoutSplittingNestedItems() {
        let blocks = MarkdownBlockParser.parse("""
        - First unordered item
          1. Ordered child one
          2. Ordered child two
        - Second unordered item

        3. First ordered item
           - Unordered child one
           - Unordered child two
        4. Second ordered item
        """)

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0], .unorderedList([
            MarkdownListItem(indent: 0, text: "First unordered item", ordinal: nil, isChecked: nil),
            MarkdownListItem(indent: 1, text: "Ordered child one", ordinal: 1, isChecked: nil),
            MarkdownListItem(indent: 1, text: "Ordered child two", ordinal: 2, isChecked: nil),
            MarkdownListItem(indent: 0, text: "Second unordered item", ordinal: nil, isChecked: nil)
        ]))
        XCTAssertEqual(blocks[1], .orderedList([
            MarkdownListItem(indent: 0, text: "First ordered item", ordinal: 3, isChecked: nil),
            MarkdownListItem(indent: 1, text: "Unordered child one", ordinal: nil, isChecked: nil),
            MarkdownListItem(indent: 1, text: "Unordered child two", ordinal: nil, isChecked: nil),
            MarkdownListItem(indent: 0, text: "Second ordered item", ordinal: 4, isChecked: nil)
        ]))
    }

    func testParsesTaskListsSeparatelyFromPlainUnorderedLists() {
        let blocks = MarkdownBlockParser.parse("""
        - First
          - Nested

        - [x] Done
        - [ ] Next
        - [X] Uppercase done
        """)

        XCTAssertEqual(blocks[0], .unorderedList([
            MarkdownListItem(indent: 0, text: "First", ordinal: nil, isChecked: nil),
            MarkdownListItem(indent: 1, text: "Nested", ordinal: nil, isChecked: nil)
        ]))
        XCTAssertEqual(blocks[1], .taskList([
            MarkdownListItem(indent: 0, text: "Done", ordinal: nil, isChecked: true),
            MarkdownListItem(indent: 0, text: "Next", ordinal: nil, isChecked: false),
            MarkdownListItem(indent: 0, text: "Uppercase done", ordinal: nil, isChecked: true)
        ]))
    }

    func testParsesTablesAndCodeFencesWithLanguageLabels() {
        let blocks = MarkdownBlockParser.parse("""
        | A | B |
        |---|---|
        | **bold** | `code` |

        ```swift
        print("hi")
        ```
        """)

        XCTAssertEqual(blocks[0], .table(header: ["A", "B"], rows: [["**bold**", "`code`"]]))
        XCTAssertEqual(blocks[1], .code("print(\"hi\")", lang: "swift"))
    }

    func testFencedCodeParserFeedsExactBodyToCodeBlockAffordances() {
        let blocks = MarkdownBlockParser.parse("""
        ```swift
        struct Fixture {
            let value: String
        }

        ```

        ```bash
        printf '%s\\n' "$HOME"
        ```
        """)

        XCTAssertEqual(blocks[0], .code("""
        struct Fixture {
            let value: String
        }

        """, lang: "swift"))
        XCTAssertEqual(blocks[1], .code("printf '%s\\n' \"$HOME\"", lang: "bash"))
    }

    func testParsesWideTablesWithoutDroppingLongCells() {
        let blocks = MarkdownBlockParser.parse("""
        | Step | Owner | Status | Evidence | Risk | Next |
        | --- | --- | --- | --- | --- | --- |
        | Markdown hardening | Track A | complete | a/very/long/path/that/should/remain/inspectable/in/a/horizontally/scrollable/table.md | safe-content policy explicit | run focused xcodebuild |
        """)

        XCTAssertEqual(blocks, [
            .table(
                header: ["Step", "Owner", "Status", "Evidence", "Risk", "Next"],
                rows: [[
                    "Markdown hardening",
                    "Track A",
                    "complete",
                    "a/very/long/path/that/should/remain/inspectable/in/a/horizontally/scrollable/table.md",
                    "safe-content policy explicit",
                    "run focused xcodebuild"
                ]]
            )
        ])
    }

    func testParsesMarkdownImagesAsSafePlaceholderBlocks() {
        let blocks = MarkdownBlockParser.parse("""
        ![Architecture diagram](https://example.com/diagram.png "System view")
        ![Local screenshot](local-fixture.png)
        """)

        XCTAssertEqual(blocks, [
            .image(MarkdownImage(
                altText: "Architecture diagram",
                source: "https://example.com/diagram.png",
                title: "System view"
            )),
            .image(MarkdownImage(
                altText: "Local screenshot",
                source: "local-fixture.png",
                title: nil
            ))
        ])
    }

    func testInlineMarkdownImagesRemainInertPlaceholderText() {
        let attributed = MarkdownInlineText.attributedInline("""
        Before ![inline diagram](https://example.com/inline.png "Caption") after.
        """)

        XCTAssertEqual(
            String(attributed.characters),
            "Before Image: inline diagram — https://example.com/inline.png after."
        )
        let runDescription = attributed.runs.map { String(describing: $0) }.joined(separator: "\n")
        XCTAssertFalse(runDescription.contains("NSImageURL"))
    }

    func testInlineMarkdownImagesInsideParagraphBlocksStayInert() {
        let blocks = MarkdownBlockParser.parse("""
        Before ![inline diagram](https://example.com/inline.png "Caption") after.
        """)

        XCTAssertEqual(blocks, [
            .paragraph("Before ![inline diagram](https://example.com/inline.png \"Caption\") after.")
        ])

        let attributed = MarkdownInlineText.attributedInline("Before ![inline diagram](https://example.com/inline.png \"Caption\") after.")
        XCTAssertEqual(
            String(attributed.characters),
            "Before Image: inline diagram — https://example.com/inline.png after."
        )
        let runDescription = attributed.runs.map { String(describing: $0) }.joined(separator: "\n")
        XCTAssertFalse(runDescription.contains("NSImageURL"))
    }

    func testReferenceStyleInlineImagesRemainInertPlaceholderText() {
        let attributed = MarkdownInlineText.attributedInline("Before ![diagram][fig], ![logo][], and ![shortcut] after.")

        XCTAssertEqual(
            String(attributed.characters),
            "Before Image: diagram — reference fig, Image: logo — reference logo, and Image: shortcut — reference shortcut after."
        )
        let runDescription = attributed.runs.map { String(describing: $0) }.joined(separator: "\n")
        XCTAssertFalse(runDescription.contains("NSImageURL"))
    }

    func testAngleBracketAutolinksRemainLinksWithoutHTMLPromotion() {
        let attributed = MarkdownInlineText.attributedInline("See <https://example.com/path?q=1&x=2> and <script>bad()</script>.")

        XCTAssertEqual(
            String(attributed.characters),
            "See https://example.com/path?q=1&x=2 and <script>bad()</script>."
        )
        let runDescription = attributed.runs.map { String(describing: $0) }.joined(separator: "\n")
        XCTAssertTrue(runDescription.contains("https://example.com/path?q=1&x=2"))
        XCTAssertFalse(runDescription.contains("NSImageURL"))
    }

    func testAngleBracketAutolinksAndInlineMarkersShareSegmentSafely() {
        let attributed = MarkdownInlineText.attributedInline("Visit <https://example.com/path?q=1&x=2> for ~~old~~ and <u>underlined</u> info.")

        XCTAssertEqual(
            String(attributed.characters),
            "Visit https://example.com/path?q=1&x=2 for old and underlined info."
        )
        let runDescription = attributed.runs.map { String(describing: $0) }.joined(separator: "\n")
        XCTAssertTrue(runDescription.contains("https://example.com/path?q=1&x=2"))
        XCTAssertFalse(runDescription.contains("NSImageURL"))
    }

    func testInlineCodeSpansPreserveHTMLAndMarkdownLiterals() {
        let attributed = MarkdownInlineText.attributedInline("Use `Array<String>`, `a & b`, `![literal](image.png)`, and `<u>literal</u>`.")

        XCTAssertEqual(
            String(attributed.characters),
            "Use Array<String>, a & b, ![literal](image.png), and <u>literal</u>."
        )
        let runDescription = attributed.runs.map { String(describing: $0) }.joined(separator: "\n")
        XCTAssertFalse(runDescription.contains("NSImageURL"))
    }

    func testExplicitMarkdownLinkDestinationsPreserveQueryEntities() {
        let attributed = MarkdownInlineText.attributedInline("Read [docs](https://example.com/docs?a=1&b=2).")

        XCTAssertEqual(String(attributed.characters), "Read docs.")
        let runDescription = attributed.runs.map { String(describing: $0) }.joined(separator: "\n")
        XCTAssertTrue(runDescription.contains("https://example.com/docs?a=1&b=2"))
    }

    func testRawHTMLPolicyPreservesExistingEntitiesAsText() {
        let attributed = MarkdownInlineText.attributedInline("""
        <u>AT&T &amp; Co</u> <script>bad()</script>
        """)

        XCTAssertEqual(
            String(attributed.characters),
            "AT&T & Co <script>bad()</script>"
        )
        let rendered = String(attributed.characters)
        guard let stringRange = rendered.range(of: "AT&T & Co"),
              let attributedRange = Range(stringRange, in: attributed) else {
            XCTFail("Expected underlined range in attributed text")
            return
        }
        // SwiftUI's underline, which is what `Text` draws (AppKit's has the
        // same name and is not set).
        XCTAssertNotNil(attributed[attributedRange].swiftUI.underlineStyle)
    }

    func testMalformedTablesAndImagesFallBackToPredictableProse() {
        let blocks = MarkdownBlockParser.parse("""
        | Missing | separator |
        | still prose | because no divider |

        ![missing close](https://example.com/image.png
        ![]( )
        """)

        XCTAssertEqual(blocks, [
            .paragraph("| Missing | separator |\n| still prose | because no divider |"),
            .paragraph("![missing close](https://example.com/image.png\n![]( )")
        ])
    }

    func testParsesSingleLineFencedCodeAsCodeBlock() {
        let blocks = MarkdownBlockParser.parse("```copy to edit```")

        XCTAssertEqual(blocks, [.code("copy to edit", lang: nil)])
    }

    func testParsesBlockquotesHorizontalRulesDefinitionsAndFootnotes() {
        let blocks = MarkdownBlockParser.parse("""
        > This is a quote
        > with **bold** text

        ---

        Term 1
        : Definition one
        : Definition two

        [^1]: Footnote content.
        """)

        XCTAssertEqual(blocks[0], .blockquote("This is a quote\nwith **bold** text"))
        XCTAssertEqual(blocks[1], .horizontalRule)
        XCTAssertEqual(blocks[2], .definitionList([
            MarkdownDefinitionEntry(term: "Term 1", definitions: ["Definition one", "Definition two"])
        ]))
        XCTAssertEqual(blocks[3], .footnote(id: "1", text: "Footnote content."))
    }

    func testPreservesInlineMarkdownAutolinksAndEscapedCharactersAsProseText() {
        let blocks = MarkdownBlockParser.parse(#"""
        Use `inline code`, [docs](https://example.com/docs), https://example.com/raw, and escaped \*not emphasis\*.
        """#)

        XCTAssertEqual(blocks, [
            .paragraph("Use `inline code`, [docs](https://example.com/docs), https://example.com/raw, and escaped \\*not emphasis\\*.")
        ])
    }

    func testRawHTMLPolicyAllowsOnlyKnownSafeInlineTags() {
        let attributed = MarkdownInlineText.attributedInline("""
        <u>underlined</u> <kbd>Cmd</kbd> H<sub>2</sub>O mc<sup>2</sup> <script>alert("x")</script> <img src=x onerror=alert(1)>
        """)

        XCTAssertEqual(
            String(attributed.characters),
            #"underlined Cmd H2O mc2 <script>alert("x")</script> <img src=x onerror=alert(1)>"#
        )
    }

    func testMalformedAndTruncatedCodeFencesStayInCodeBlocks() {
        let blocks = MarkdownBlockParser.parse("""
        ```json
        {"partial": true}
        """)

        XCTAssertEqual(blocks, [
            .code("{\"partial\": true}", lang: "json")
        ])
    }

    func testApprovalLookingMarkdownRemainsOrdinaryMarkdownBlocks() {
        let blocks = MarkdownBlockParser.parse("""
        Approval required: approve this run.

        - [x] Always allow writes
        - deny: do not continue
        """)

        XCTAssertEqual(blocks, [
            .paragraph("Approval required: approve this run."),
            .taskList([
                MarkdownListItem(indent: 0, text: "Always allow writes", ordinal: nil, isChecked: true)
            ]),
            .unorderedList([
                MarkdownListItem(indent: 0, text: "deny: do not continue", ordinal: nil, isChecked: nil)
            ])
        ])
    }
}
