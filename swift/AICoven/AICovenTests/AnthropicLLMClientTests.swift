import XCTest
@testable import AICoven

/// Tests for AnthropicLLMClient using a mocked URLSession.
final class AnthropicLLMClientTests: XCTestCase {

    private func makeClient(
        withResponseBody body: Data,
        statusCode: Int = 200,
        expectedPathSuffix: String
    ) -> AnthropicLLMClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]

        MockURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.path.hasSuffix(expectedPathSuffix) == true)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "TEST_KEY")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let session = URLSession(configuration: config)
        return AnthropicLLMClient(
            apiKey: "TEST_KEY",
            baseURL: URL(string: "https://example.com/v1")!,
            urlSession: session
        )
    }

    func testCompleteChat_decodesSuccessfulResponse() async throws {
        let json = """
        {
          "content": [
            { "text": "Hello from Claude" }
          ],
          "model": "claude-3-haiku-20240307"
        }
        """.data(using: .utf8)!

        let client = makeClient(withResponseBody: json, expectedPathSuffix: "/v1/messages")

        let messages = [LLMMessage(role: .user, content: "Hi")]
        let options = ChatOptions(temperature: 0.2, maxTokens: 128, stream: false)

        let response = try await client.completeChat(
            messages: messages,
            model: "claude-3-haiku-20240307",
            options: options
        )

        XCTAssertEqual(response.message.content, "Hello from Claude")
        XCTAssertEqual(response.providerID, "anthropic")
        XCTAssertEqual(response.modelID, "claude-3-haiku-20240307")
        XCTAssertNil(response.usage)
    }

    func testEmbed_throwsUnsupportedError() async throws {
        let client = try AnthropicLLMClient(
            apiKey: "TEST_KEY",
            baseURL: XCTUnwrap(URL(string: "https://example.com/v1"))
        )
        do {
            _ = try await client.embed(texts: ["hello"], model: "test-model")
            XCTFail("Expected embed(texts:model:) to throw for AnthropicLLMClient")
        } catch {
            // We just assert that an error is thrown; the exact domain/code is
            // not important for callers.
        }
    }
}
