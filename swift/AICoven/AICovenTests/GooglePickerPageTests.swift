@testable import AICoven
import XCTest

/// Google's Picker is opened on the app's own page in the system's browser,
/// and its answer comes back at `aicoven-local://google-picker`, which
/// anything can open: only the page's own answer, with its state, is read.
final class GooglePickerPageTests: XCTestCase {
    private let state = "abcdefghijklmnopqrstuvwxyz012345"

    private func encoded(_ json: String) -> String {
        Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func answer(_ query: String) -> GooglePickerPage.Answer? {
        GooglePickerPage.answer(of: URL(string: "aicoven-local://google-picker?\(query)")!, state: state)
    }

    func testThePageIsGivenWhatItNeeds_inTheFragmentOnly() throws {
        let url = try XCTUnwrap(GooglePickerPage.url(token: "ya29.a+b/c=", appID: "870439799161", state: state))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "https")
        XCTAssertEqual(parts.host, "lepapillonterrible.github.io")
        XCTAssertNil(parts.query, "nothing of it goes to the server")
        let fragment = try XCTUnwrap(parts.percentEncodedFragment)
        XCTAssertFalse(fragment.contains("+"), "a + would read as a space on the page")
        var read = URLComponents()
        read.percentEncodedQuery = fragment
        let items = Dictionary(uniqueKeysWithValues: (read.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items, ["token": "ya29.a+b/c=", "app_id": "870439799161", "state": state])
    }

    func testWhatDoesNotReadAsItMust_opensNoPage() {
        XCTAssertNil(GooglePickerPage.url(token: "", appID: "870439799161", state: state))
        XCTAssertNil(GooglePickerPage.url(token: "a b", appID: "870439799161", state: state))
        XCTAssertNil(GooglePickerPage.url(token: "t", appID: "87x", state: state))
        XCTAssertNil(GooglePickerPage.url(token: "t", appID: "870439799161", state: "short"))
    }

    func testAStateIsNewEachTime() throws {
        let one = try XCTUnwrap(GooglePickerPage.newState())
        let two = try XCTUnwrap(GooglePickerPage.newState())
        XCTAssertNotEqual(one, two)
        XCTAssertTrue(GoogleToolArguments.isID(one))
        XCTAssertGreaterThanOrEqual(one.count, 16)
    }

    func testTheFilesChosenAreRead() {
        let files = encoded(#"[{"id":"1AbC_d-e","name":"Plan\n2027","mimeType":"application/vnd.google-apps.document"},{"id":"1AbC_d-e","name":"again","mimeType":"text/plain"}]"#)
        XCTAssertEqual(answer("state=\(state)&status=picked&files=\(files)"), .picked([
            GooglePickerFile(id: "1AbC_d-e", name: "Plan 2027", mimeType: "application/vnd.google-apps.document")
        ]))
    }

    func testCancelAndFailure() {
        XCTAssertEqual(answer("state=\(state)&status=cancel"), .cancelled)
        XCTAssertEqual(answer("state=\(state)&status=error"), .failed)
    }

    func testAnythingElseIsNoAnswer() {
        let files = encoded(#"[{"id":"abc","name":"n","mimeType":"text/plain"}]"#)
        let other = "zyxwvutsrqponmlkjihgfedcba012345"
        for query in [
            "state=\(other)&status=picked&files=\(files)",
            "status=picked&files=\(files)",
            "state=\(state)&state=\(state)&status=cancel",
            "state=\(state)&status=cancel&files=\(files)",
            "state=\(state)&status=picked",
            "state=\(state)&status=picked&files=\(encoded("[]"))",
            "state=\(state)&status=picked&files=\(encoded(#"[{"id":"../x","name":"n","mimeType":"text/plain"}]"#))",
            "state=\(state)&status=picked&files=\(encoded(#"[{"id":"abc","name":"n","mimeType":"text plain"}]"#))",
            "state=\(state)&status=picked&files=%%%",
            "state=\(state)&status=done",
            "state=\(state)&status=cancel&extra=1"
        ] {
            XCTAssertNil(answer(query), query)
        }
        for address in [
            "aicoven-local://google-picker/x?state=\(state)&status=cancel",
            "aicoven-local://other?state=\(state)&status=cancel",
            "aicoven://google-picker?state=\(state)&status=cancel",
            "aicoven-local://google-picker?state=\(state)&status=cancel#more",
            "aicoven-local://u@google-picker?state=\(state)&status=cancel"
        ] {
            XCTAssertNil(GooglePickerPage.answer(of: URL(string: address)!, state: state), address)
        }
    }

    func testNoMoreFilesThanThePageGives() {
        let many = (0 ... GooglePickerPage.mostFiles).map { #"{"id":"f\#($0)","name":"n","mimeType":"text/plain"}"# }
        XCTAssertNil(answer("state=\(state)&status=picked&files=\(encoded("[\(many.joined(separator: ","))]"))"))
    }
}
