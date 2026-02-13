import XCTest
@testable import AICoven

final class ChatToolingTests: XCTestCase {

    func testChatToolInvocation_parsesSimpleJSON() {
        let json = "{" + "\"tool\":\"web_search\",\"input\":\"hello\",\"reason\":\"test\"" + "}"
        guard let invocation = ChatToolInvocation.from(jsonString: json) else {
            XCTFail("Expected ChatToolInvocation to parse simple JSON")
            return
        }
        XCTAssertEqual(invocation.tool, "web_search")
        // Input is decoded into AnyJSONValue and may be a plain string
        XCTAssertEqual(invocation.input?.value as? String, "hello")
        XCTAssertEqual(invocation.reason, "test")
    }

    func testCurrentMaxToolSteps_defaultsAndCap() {
        let key = "chat_max_tool_steps"
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: key)

        // Default when unset is 5 (conservative to prevent tool thrash)
        XCTAssertEqual(ChatService.currentMaxToolSteps(), 5)

        // Custom value within cap
        defaults.set(3, forKey: key)
        XCTAssertEqual(ChatService.currentMaxToolSteps(), 3)

        // Values above hard cap are clamped to 15
        defaults.set(50, forKey: key)
        XCTAssertEqual(ChatService.currentMaxToolSteps(), 15)
    }

    func testMaybeForceSearchQuery_forWeatherRefusal() async {
        let service = ChatService.shared
        let user = "What is the weather in London right now?"
        let reply = "I do not have access to real-time weather data and cannot tell you the current weather."

        let forced = await service.maybeForceSearchQuery(userMessage: user, modelReply: reply)

        XCTAssertEqual(forced, "weather in London right now?")
    }
}
