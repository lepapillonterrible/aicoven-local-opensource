import XCTest
@testable import AICoven

@MainActor
final class HermesLLMClientTests: XCTestCase {

    private func makeClient(withResponseBody body: Data, statusCode: Int = 200, expectedPathSuffix: String) -> HermesLLMClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]

        MockURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.path.hasSuffix(expectedPathSuffix) == true)
            XCTAssertEqual(request.httpMethod, "POST")

            // Hermes client uses Bearer token for API keys
            if let _ = request.value(forHTTPHeaderField: "Authorization") {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer TEST_KEY")
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let session = URLSession(configuration: config)
        return HermesLLMClient(apiKey: "TEST_KEY", baseURL: URL(string: "https://api.together.xyz")!, urlSession: session)
    }

    func testCompleteChat_decodesSuccessfulResponse() async throws {
        let json = """
        {
          "id": "chatcmpl-test",
          "object": "chat.completion",
          "choices": [
            {
              "index": 0,
              "message": {"role": "assistant", "content": "Hello from Hermes"}
            }
          ],
          "usage": {"prompt_tokens": 12, "completion_tokens": 8, "total_tokens": 20},
          "model": "NousResearch/Hermes-3-Llama-3.1-405B-Turbo"
        }
        """.data(using: .utf8)!

        let client = makeClient(withResponseBody: json, expectedPathSuffix: "/v1/chat/completions")

        let messages = [LLMMessage(role: .user, content: "Hi")]
        let options = ChatOptions(temperature: 0.3, maxTokens: nil, stream: false)

        let response = try await client.completeChat(messages: messages, model: "hermes-3", options: options)

        XCTAssertEqual(response.message.content, "Hello from Hermes")
        XCTAssertEqual(response.providerID, "hermes")
        // The client returns the actual model ID from the response if present
        XCTAssertEqual(response.modelID, "NousResearch/Hermes-3-Llama-3.1-405B-Turbo")
        XCTAssertEqual(response.usage?.promptTokens, 12)
        XCTAssertEqual(response.usage?.completionTokens, 8)
        XCTAssertEqual(response.usage?.totalTokens, 20)
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
                    "id": "call_abc",
                    "type": "function",
                    "function": {
                      "name": "search_web",
                      "arguments": "{\\"query\\": \\"latest news\\"}"
                    }
                  }
                ]
              }
            }
          ],
          "model": "NousResearch/Hermes-3-Llama-3.1-405B-Turbo"
        }
        """.data(using: .utf8)!

        let client = makeClient(withResponseBody: json, expectedPathSuffix: "/v1/chat/completions")

        let messages = [LLMMessage(role: .user, content: "Search the web")]
        let options = ChatOptions(temperature: 0.3, maxTokens: nil, stream: false)

        let response = try await client.completeChat(messages: messages, model: "hermes-3", options: options)

        XCTAssertTrue(response.message.content.isEmpty)
        XCTAssertEqual(response.toolCalls?.count, 1)

        let toolCall = response.toolCalls?.first
        XCTAssertEqual(toolCall?.name, "search_web")
        XCTAssertEqual(toolCall?.arguments["query"]?.value as? String, "latest news")
    }

    func testCompleteChat_handlesErrorResponse() async throws {
        let json = """
        {
          "error": {
            "message": "Invalid API key",
            "type": "authentication_error"
          }
        }
        """.data(using: .utf8)!

        let client = makeClient(withResponseBody: json, statusCode: 401, expectedPathSuffix: "/v1/chat/completions")

        let messages = [LLMMessage(role: .user, content: "Hi")]
        let options = ChatOptions(temperature: 0.3, maxTokens: nil, stream: false)

        do {
            _ = try await client.completeChat(messages: messages, model: "hermes-3", options: options)
            XCTFail("Expected completeChat to throw an error")
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.code, 401)
            XCTAssertTrue(nsError.localizedDescription.contains("Hermes HTTP 401"))
            XCTAssertFalse(nsError.localizedDescription.contains("Invalid API key"))
            XCTAssertTrue(nsError.localizedDescription.contains("Response body omitted"))
        }
    }

    func testModelAliasMapping() throws {
        // Just verify the client resolves model IDs based on whether it is Together AI
        let session = URLSession(configuration: .ephemeral)

        let togetherURL = try XCTUnwrap(URL(string: "https://api.together.xyz"))
        let togetherClient = HermesLLMClient(apiKey: "TEST", baseURL: togetherURL, urlSession: session)
        let resolvedTogether = togetherClient.resolveModelID("hermes-3", isSelfHosted: false)
        XCTAssertEqual(resolvedTogether, "NousResearch/Hermes-3-Llama-3.1-405B-Turbo", "Should map alias on Together AI")

        let customURL = try XCTUnwrap(URL(string: "https://custom.server.com"))
        let selfHostedClient = HermesLLMClient(apiKey: "TEST", baseURL: customURL, urlSession: session)
        let resolvedCustom = selfHostedClient.resolveModelID("hermes-3", isSelfHosted: true)
        XCTAssertEqual(resolvedCustom, "hermes-3", "Should pass alias directly for self-hosted instances")
    }
}
