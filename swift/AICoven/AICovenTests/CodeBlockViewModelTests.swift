import XCTest
@testable import AICoven

final class CodeBlockViewModelTests: XCTestCase {
    func testShowsTrimmedLanguageLabelWhenPresent() {
        let viewModel = CodeBlockViewModel(code: "print(\"hi\")", language: "  swift  ")

        XCTAssertEqual(viewModel.displayLanguage, "swift")
        XCTAssertEqual(viewModel.accessibilityLabel, "Code block, swift")
        XCTAssertEqual(viewModel.copyAccessibilityLabel, "Copy swift code")
        XCTAssertEqual(viewModel.copyText, "print(\"hi\")")
    }

    func testUsesNeutralNoLabelStateWhenLanguageIsAbsentOrBlank() {
        let absent = CodeBlockViewModel(code: "echo hi", language: nil)
        let blank = CodeBlockViewModel(code: "echo hi", language: "   \n")

        XCTAssertNil(absent.displayLanguage)
        XCTAssertNil(blank.displayLanguage)
        XCTAssertEqual(absent.accessibilityLabel, "Code block")
        XCTAssertEqual(absent.copyAccessibilityLabel, "Copy code")
        XCTAssertEqual(blank.copyAccessibilityLabel, "Copy code")
    }

    func testCopyTextPreservesExactSwiftBodyIncludingIndentationAndTrailingNewline() {
        let code = """
        struct Fixture {
            let value: String
        }

        """
        let viewModel = CodeBlockViewModel(code: code, language: "swift")

        XCTAssertEqual(viewModel.copyText, code)
        XCTAssertEqual(viewModel.lineCount, 4)
    }

    func testCopyTextPreservesExactBashAndJSONBodies() {
        let bash = #"""
        set -euo pipefail
        printf '%s\n' "$HOME"
        """#
        let json = """
        {
          "ok": true,
          "items": [1, 2, 3]
        }
        """

        XCTAssertTrue(bash.contains(#"\n"#))
        XCTAssertEqual(CodeBlockViewModel(code: bash, language: "bash").copyText, bash)
        XCTAssertEqual(CodeBlockViewModel(code: json, language: "json").copyText, json)
    }

    func testLongLineRemainsOnePreservedLineForHorizontalScrolling() {
        let longLine = "let generated = \"" + String(repeating: "abcdef", count: 30) + "\""
        let viewModel = CodeBlockViewModel(code: longLine, language: "swift")

        XCTAssertEqual(viewModel.lineCount, 1)
        XCTAssertEqual(viewModel.copyText, longLine)
        XCTAssertGreaterThan(viewModel.longestLineCharacterCount, 120)
    }
}
