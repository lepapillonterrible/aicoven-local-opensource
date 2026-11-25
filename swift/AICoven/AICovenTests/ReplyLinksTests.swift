@testable import AICoven
import XCTest

/// What a reply can have opened: an `https` or `mailto` address, and
/// nothing else.
@MainActor
final class ReplyLinksTests: XCTestCase {
    /// The addresses that are links in `markdown` as a reply shows it
    /// (`MarkdownView` draws a reply's text with `MarkdownInlineText`).
    private func links(in markdown: String) -> [String] {
        MarkdownInlineText.attributedInline(markdown).runs.compactMap { $0.link?.absoluteString }
    }

    func testAReplysLinks_openOnlyHttpsAndMail() {
        XCTAssertEqual(links(in: "See [the docs](https://example.com/docs) or [write](mailto:ada@example.com)."), [
            "https://example.com/docs", "mailto:ada@example.com",
        ])
        XCTAssertEqual(links(in: "[Docs](HTTPS://example.com)"), ["HTTPS://example.com"], "Whatever the case of the scheme")

        // Anything else keeps its words and is no link: this app's own scheme, a file, another app's, a number, a script, plain http.
        for address in [
            "aicoven://settings/providers", "file:///etc/passwd", "shortcuts://run-shortcut?name=x", "tel:+15551234567",
            "javascript:alert(1)", "http://example.com", "x-apple.systempreferences:com.apple.preference.security", "relative/path",
        ] {
            let shown = MarkdownInlineText.attributedInline("Tap [here](\(address)) now.")
            XCTAssertEqual(shown.runs.compactMap(\.link), [], address)
            XCTAssertEqual(String(shown.characters), "Tap here now.", address)
        }

        // One that does not open takes no other with it.
        XCTAssertEqual(links(in: "[a](aicoven://settings) and [b](https://example.com)"), ["https://example.com"])
    }

    func testTheFileButtonsOfAReply_openOnlyWhatALinkWould() throws {
        XCTAssertTrue(try ReplyLinks.opens(XCTUnwrap(URL(string: "https://example.com/report.pdf"))))
        for address in ["file:///Users/ada/Documents/GeneratedFiles/run.terminal", "aicoven://strix/new-thread", "http://example.com/a", "ftp://example.com/a"] {
            XCTAssertFalse(try ReplyLinks.opens(XCTUnwrap(URL(string: address))), address)
        }
    }
}
