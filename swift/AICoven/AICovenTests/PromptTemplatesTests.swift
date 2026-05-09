import XCTest
@testable import AICoven

final class PromptTemplatesTests: XCTestCase {
    func testFormatToolInputExampleJSON_rendersTypedJSON() {
        let json = PromptTemplates.formatToolInputExampleJSON([
            "query": "swift",
            "limit": 5,
            "includeArchived": false,
        ])

        XCTAssertEqual(json, #"{"includeArchived":false,"limit":5,"query":"swift"}"#)
    }

    func testFormatToolInputExampleJSON_emptyDictionary() {
        XCTAssertEqual(PromptTemplates.formatToolInputExampleJSON([:]), "{}")
    }
}
