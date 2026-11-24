import Foundation
import XCTest
@testable import AICoven

@MainActor
final class MarkdownRenderingFixtureTests: XCTestCase {
    func testMacOSSelectionPlanGroupsProseAndWholeMessageCopyPreservesInteractiveBlocks() {
        let markdown = #"""
        # Copyable report

        Intro paragraph with **strong** text.

        - First bullet
        - Second bullet

        1. First step
          - Nested unordered child
        2. Second step

        - [x] Done item
        - [ ] Open item

        | Area | Status |
        | --- | --- |
        | Table | Preserved |

        ```swift
        let value = "copy me exactly"
        ```

        Final paragraph after code.
        """#

        let plan = MarkdownView.macOSRenderPlan(for: markdown)

        XCTAssertEqual(plan, [
            .selectableProse([
                .heading(level: 1, text: "Copyable report"),
                .paragraph("Intro paragraph with **strong** text."),
                .unorderedList([
                    MarkdownListItem(indent: 0, text: "First bullet", ordinal: nil, isChecked: nil),
                    MarkdownListItem(indent: 0, text: "Second bullet", ordinal: nil, isChecked: nil)
                ]),
                .orderedList([
                    MarkdownListItem(indent: 0, text: "First step", ordinal: 1, isChecked: nil),
                    MarkdownListItem(indent: 1, text: "Nested unordered child", ordinal: nil, isChecked: nil),
                    MarkdownListItem(indent: 0, text: "Second step", ordinal: 2, isChecked: nil)
                ]),
                .taskList([
                    MarkdownListItem(indent: 0, text: "Done item", ordinal: nil, isChecked: true),
                    MarkdownListItem(indent: 0, text: "Open item", ordinal: nil, isChecked: false)
                ])
            ]),
            .interactive(.table(
                header: ["Area", "Status"],
                rows: [["Table", "Preserved"]]
            )),
            .interactive(.code("let value = \"copy me exactly\"", lang: "swift")),
            .selectableProse([
                .paragraph("Final paragraph after code.")
            ])
        ])

        XCTAssertEqual(MarkdownView.plainCopyText(markdown), #"""
        # Copyable report

        Intro paragraph with **strong** text.

        - First bullet
        - Second bullet

        1. First step
          - Nested unordered child
        2. Second step

        - [x] Done item
        - [ ] Open item

        | Area | Status |
        | ---- | ------ |
        | Table | Preserved |

        ```swift
        let value = "copy me exactly"
        ```

        Final paragraph after code.
        """#)
    }

    func testResidualMarkdownSafetyFixtureParsesImagesHTMLAndWideTablesPredictably() {
        let blocks = MarkdownBlockParser.parse(#"""
        ![Remote architecture diagram](https://example.com/architecture.png)

        <script>alert("do not run")</script>
        <u>Supported underline</u> and <img src=x onerror=alert(1)> stay inert.

        | Column 01 | Column 02 | Column 03 | Column 04 | Column 05 | Column 06 | Column 07 | Column 08 |
        | --- | --- | --- | --- | --- | --- | --- | --- |
        | one | two | three | four | five | six | seven | eight-with-a-long-inspectable-value-that-should-not-be-dropped |
        """#)

        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0], .image(MarkdownImage(
            altText: "Remote architecture diagram",
            source: "https://example.com/architecture.png",
            title: nil
        )))
        XCTAssertEqual(blocks[1], .paragraph("""
        <script>alert("do not run")</script>
        <u>Supported underline</u> and <img src=x onerror=alert(1)> stay inert.
        """))
        XCTAssertEqual(blocks[2], .table(
            header: ["Column 01", "Column 02", "Column 03", "Column 04", "Column 05", "Column 06", "Column 07", "Column 08"],
            rows: [[
                "one",
                "two",
                "three",
                "four",
                "five",
                "six",
                "seven",
                "eight-with-a-long-inspectable-value-that-should-not-be-dropped"
            ]]
        ))
    }

    func testMarkdownTableLayoutKeepsCellsStructuredAndBounded() {
        let layout = MarkdownTableLayout(
            header: ["Area", "Expected baseline"],
            rows: [
                ["Markdown", "Parsed as serious agent output"],
                ["Artifacts", "Represented separately"],
                ["Approvals", "Native request only"]
            ]
        )

        XCTAssertEqual(layout.columnCount, 2)
        XCTAssertEqual(layout.header, ["Area", "Expected baseline"])
        XCTAssertEqual(layout.rows.count, 3)
        XCTAssertEqual(layout.columnWidths.count, 2)
        XCTAssertTrue(layout.columnWidths.allSatisfy { $0 >= MarkdownTableLayout.minColumnWidth })
        XCTAssertTrue(layout.columnWidths.allSatisfy { $0 <= MarkdownTableLayout.maxColumnWidth })
        XCTAssertEqual(layout.dividerOffset(afterColumn: 0), layout.columnWidths[0])
    }

    func testMarkdownTableLayoutCapsLongPathCellsAndPreservesEmptyCells() {
        let longPath = "a/very/long/path/that/should/remain/inspectable/in/a/horizontally/scrollable/table.md"
        let markdownLink = "[docs](https://example.com/a/very/long/path/that/should/stay/a/link)"
        let bareURL = "https://example.com/a/very/long/path/that/should/stay/a/url"
        let layout = MarkdownTableLayout(
            header: ["Step", "Evidence", "Risk"],
            rows: [
                ["Markdown hardening", longPath, ""],
                ["Link preservation", markdownLink, "wrapped visually by the cell"],
                ["URL preservation", bareURL, "wrapped visually by the cell"]
            ]
        )

        XCTAssertEqual(layout.columnCount, 3)
        XCTAssertEqual(layout.rows[0][2], "")
        XCTAssertLessThanOrEqual(layout.columnWidths[1], MarkdownTableLayout.maxColumnWidth)
        XCTAssertTrue(layout.rows[0][1].contains("\u{200B}"))
        XCTAssertEqual(layout.rows[1][1], markdownLink)
        XCTAssertEqual(layout.rows[2][1], bareURL)
        XCTAssertFalse(layout.rows[2][1].contains("\u{200B}"))
    }

    func testMalformedResidualMarkdownFixtureDoesNotCrashOrPromoteUnsafeBlocks() {
        let blocks = MarkdownBlockParser.parse(#"""
        ![broken image](https://example.com/broken.png

        | Header | Header |
        | --- |
        | one | two |

        <iframe src="https://example.com"></iframe>
        """#)

        XCTAssertEqual(blocks, [
            .paragraph("![broken image](https://example.com/broken.png"),
            .paragraph("""
            | Header | Header |
            | --- |
            | one | two |
            """),
            .paragraph(#"<iframe src="https://example.com"></iframe>"#)
        ])
    }
}
