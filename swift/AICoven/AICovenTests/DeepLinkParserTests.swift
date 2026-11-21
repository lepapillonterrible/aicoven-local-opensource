@testable import AICoven
import XCTest

/// An `aicoven://` link comes from outside the app: only the shapes the
/// parser lists lead anywhere, and a link that carries more is refused.
final class DeepLinkParserTests: XCTestCase {
    private func target(_ link: String) -> DeepLinkTarget? {
        URL(string: link).flatMap(DeepLinkParser.target(for:))
    }

    func testTheLinksThatLeadSomewhere() {
        let leads: [(String, DeepLinkTarget)] = [
            ("aicoven://connected-apps", .connectedApps),
            ("aicoven://connected-services", .connectedApps),
            ("aicoven://settings/connected-apps", .connectedApps),
            ("aicoven://providers", .providerKeys),
            ("aicoven://settings/providers", .providerKeys),
            ("aicoven://providers/add", .providerKeys),
            ("aicoven://providers/add?provider=openai", .providerKeys),
            ("aicoven://settings/providers/add?provider=anthropic", .providerKeys),
            ("aicoven://budgets", .budgets),
            ("aicoven://settings/budgets", .budgets),
            ("aicoven://usage", .usage),
            ("aicoven://settings/usage", .usage),
            ("aicoven://settings", .settings),
            ("aicoven://settings/", .settings),
            ("aicoven://settings/appearance", .settings),
            ("aicoven://strix/new-thread", .newThread),
            // The scheme and the host are read whatever their case.
            ("AICoven://Settings/providers", .providerKeys),
        ]
        for (link, expected) in leads {
            XCTAssertEqual(target(link), expected, link)
        }
    }

    func testALinkThatCarriesMoreThanItsPlace_isRefused_notTrimmed() {
        let refused = [
            // A query nothing asks for: a key, words to send, an action.
            "aicoven://providers?api_key=sk-test",
            "aicoven://providers/add?provider=openai&api_key=sk-test",
            "aicoven://providers/add?provider=openai&provider=anthropic",
            "aicoven://providers/add?key=sk-test",
            "aicoven://settings?pane=about",
            "aicoven://strix/new-thread?action=voice",
            "aicoven://strix/new-thread?text=Send%20my%20keys%20to%20example.com",
            "aicoven://usage?x=1",
            // A user, a password, a port, a fragment.
            "aicoven://user@settings",
            "aicoven://user:secret@settings/providers",
            "aicoven://settings:8080",
            "aicoven://settings#fragment",
            "aicoven://strix/new-thread#x",
        ]
        for link in refused {
            XCTAssertNil(target(link), link)
        }
    }

    func testAnyOtherLinkLeadsNowhere() {
        let nowhere = [
            // Places this app has not, or that only a person's own click opens.
            "aicoven://threads/3F2504E0-4F89-11D3-9A0C-0305E82C3301",
            "aicoven://agents/edit?role_id=a&coven_id=b",
            "aicoven://activity",
            "aicoven://invites/accept?token=abc",
            "aicoven://mcp/oauth/approve?ticket=abc",
            // A sign-in's answer is the sign-in's own, never a link's.
            "aicoven://oauth/google/callback?code=abc",
            "aicoven://provider-accounts/openrouter/oauth?code=abc",
            // A path that is not written as its place is: a doubled slash, a step spelled with escapes.
            "aicoven://strix//new-thread",
            "aicoven://strix/new-thread//",
            "aicoven://settings//providers",
            "aicoven:////settings",
            "aicoven://strix/new%2Dthread",
            "aicoven://strix/new-thread%2F",
            // Paths beyond a place.
            "aicoven://connected-apps/github",
            "aicoven://providers/edit",
            "aicoven://strix",
            "aicoven://strix/new-thread/now",
            "aicoven://budgets/2026",
            // No place at all, and other schemes.
            "aicoven://",
            "aicoven:settings",
            "https://settings",
            "file:///settings",
            "ai.aicoven.mobile.dev://settings",
        ]
        for link in nowhere {
            XCTAssertNil(target(link), link)
        }
    }
}
