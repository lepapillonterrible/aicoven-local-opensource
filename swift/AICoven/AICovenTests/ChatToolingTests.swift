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
        // The key used by ChatService.currentMaxToolSteps() depends on UserScope.scopedKey(),
        // which may return different values based on Firebase auth state.
        // We get the scoped key at test time and use it consistently.
        let defaults = UserDefaults.standard
        let baseKey = "chat_max_tool_steps"
        let scopedKey = UserScope.scopedKey(baseKey)

        // Clean up both possible keys at start to ensure clean state
        defaults.removeObject(forKey: baseKey)
        defaults.removeObject(forKey: scopedKey)
        defaults.synchronize()

        // Default when unset is 5 (conservative to prevent tool thrash)
        XCTAssertEqual(ChatService.currentMaxToolSteps(), 5, "Default should be 5")

        // Custom value within cap - set using the same scoped key ChatService uses
        defaults.set(3, forKey: scopedKey)
        defaults.synchronize()
        XCTAssertEqual(ChatService.currentMaxToolSteps(), 3, "Should respect custom value of 3")

        // Values above hard cap are clamped to 15
        defaults.set(50, forKey: scopedKey)
        defaults.synchronize()
        XCTAssertEqual(ChatService.currentMaxToolSteps(), 15, "Should clamp values > 15 to 15")

        // Cleanup both possible keys
        defaults.removeObject(forKey: baseKey)
        defaults.removeObject(forKey: scopedKey)
        defaults.synchronize()
    }

    func testMaybeForceSearchQuery_forWeatherRefusal() async {
        let service = ChatService.shared
        let user = "What is the weather in London right now?"
        let reply = "I do not have access to real-time weather data and cannot tell you the current weather."

        let forced = await service.maybeForceSearchQuery(userMessage: user, modelReply: reply)

        XCTAssertEqual(forced, "weather in London right now?")
    }
}
