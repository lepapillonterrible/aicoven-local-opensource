import XCTest
@testable import AICoven

@MainActor
final class OpenClawLLMClientTests: XCTestCase {

    private func makeClient(withResponseBody body: Data, statusCode: Int = 200, expectedPathSuffix: String) -> OpenClawLLMClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]

        MockURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.path.hasSuffix(expectedPathSuffix) == true)
            XCTAssertEqual(request.httpMethod, "POST")

            // OpenClaw might not use an API key, but if it does, it should be in the header
            if let _ = request.value(forHTTPHeaderField: "Authorization") {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer TEST_KEY")
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let session = URLSession(configuration: config)
        return OpenClawLLMClient(baseURL: URL(string: "http://localhost:3000")!, apiKey: "TEST_KEY", urlSession: session)
    }

    func testCompleteChat_decodesSuccessfulResponse() async throws {
        let json = """
        {
          "id": "chatcmpl-test",
          "object": "chat.completion",
          "choices": [
            {
              "index": 0,
              "message": {"role": "assistant", "content": "Hello from OpenClaw"}
            }
          ],
          "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15},
          "model": "openclaw-model"
        }
        """.data(using: .utf8)!

        let client = makeClient(withResponseBody: json, expectedPathSuffix: "/v1/chat/completions")

        let messages = [LLMMessage(role: .user, content: "Hi")]
        let options = ChatOptions(temperature: 0.3, maxTokens: nil, stream: false)

        let response = try await client.completeChat(messages: messages, model: "openclaw-model", options: options)

        XCTAssertEqual(response.message.content, "Hello from OpenClaw")
        XCTAssertEqual(response.providerID, "openclaw")
        XCTAssertEqual(response.modelID, "openclaw-model")
        XCTAssertEqual(response.usage?.promptTokens, 10)
        XCTAssertEqual(response.usage?.completionTokens, 5)
        XCTAssertEqual(response.usage?.totalTokens, 15)
    }

    func testCompleteChat_decodesToolCalls() async throws {
        let json = """
        {
          "id": "chatcmpl-test",
          "object": "chat.completion",
          "choices": [
            {
              "index": 0,
              "message": {
                "role": "assistant",
                "content": null,
                "tool_calls": [
                  {
                    "id": "call_123",
                    "type": "function",
                    "function": {
                      "name": "get_weather",
                      "arguments": "{\\"location\\": \\"Paris\\"}"
                    }
                  }
                ]
              }
            }
          ],
          "model": "openclaw-model"
        }
        """.data(using: .utf8)!

        let client = makeClient(withResponseBody: json, expectedPathSuffix: "/v1/chat/completions")

        let messages = [LLMMessage(role: .user, content: "What is the weather in Paris?")]
        let options = ChatOptions(temperature: 0.3, maxTokens: nil, stream: false)

        let response = try await client.completeChat(messages: messages, model: "openclaw-model", options: options)

        XCTAssertTrue(response.message.content.isEmpty)
        XCTAssertEqual(response.toolCalls?.count, 1)

        let toolCall = response.toolCalls?.first
        XCTAssertEqual(toolCall?.name, "get_weather")
        XCTAssertEqual(toolCall?.arguments["location"]?.value as? String, "Paris")
    }

    func testCompleteChat_handlesErrorResponse() async throws {
        let json = """
        {
          "error": {
            "message": "Invalid request",
            "type": "invalid_request_error"
          }
        }
        """.data(using: .utf8)!

        let client = makeClient(withResponseBody: json, statusCode: 400, expectedPathSuffix: "/v1/chat/completions")

        let messages = [LLMMessage(role: .user, content: "Hi")]
        let options = ChatOptions(temperature: 0.3, maxTokens: nil, stream: false)

        do {
            _ = try await client.completeChat(messages: messages, model: "openclaw-model", options: options)
            XCTFail("Expected completeChat to throw an error")
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.code, 400)
            XCTAssertTrue(nsError.localizedDescription.contains("OpenClaw HTTP 400"))
            XCTAssertFalse(nsError.localizedDescription.contains("Invalid request"))
            XCTAssertTrue(nsError.localizedDescription.contains("Response body omitted"))
        }
    }
}
