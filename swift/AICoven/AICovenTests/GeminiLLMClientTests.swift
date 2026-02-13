import XCTest
@testable import AICoven

/// Tests for GeminiLLMClient using a mocked URLSession.
final class GeminiLLMClientTests: XCTestCase {

    private func makeClient(
        withResponseBody body: Data,
        statusCode: Int = 200,
        expectedPathSuffix: String,
        expectedQueryItemName: String = "key",
        expectedQueryItemValue: String = "TEST_KEY"
    ) -> GeminiLLMClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]

        MockURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.path.hasSuffix(expectedPathSuffix) == true)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            if let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                let items = components.queryItems ?? []
                XCTAssertTrue(items.contains(where: { $0.name == expectedQueryItemName && $0.value == expectedQueryItemValue }))
            } else {
                XCTFail("Expected URL with query items for Gemini request")
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let session = URLSession(configuration: config)
        return GeminiLLMClient(
            apiKey: "TEST_KEY",
            baseURL: URL(string: "https://example.com/v1")!,
            urlSession: session
        )
    }

    func testCompleteChat_decodesSuccessfulResponse() async throws {
        let json = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  { "text": "Hello from Gemini" }
                ]
              }
            }
          ],
          "modelVersion": "models/gemini-pro"
        }
        """.data(using: .utf8)!

        let modelName = "models/gemini-pro"
        let client = makeClient(
            withResponseBody: json,
            expectedPathSuffix: "/v1/\(modelName):generateContent"
        )

        let messages = [LLMMessage(role: .user, content: "Hi")]
        let options = ChatOptions(temperature: 0.5, maxTokens: nil, stream: false)

        let response = try await client.completeChat(
            messages: messages,
            model: modelName,
            options: options
        )

        XCTAssertEqual(response.message.content, "Hello from Gemini")
        XCTAssertEqual(response.providerID, "google")
        XCTAssertEqual(response.modelID, "models/gemini-pro")
        XCTAssertNil(response.usage)
    }

    func testEmbed_throwsUnsupportedError() async throws {
        let client = try GeminiLLMClient(
            apiKey: "TEST_KEY",
            baseURL: XCTUnwrap(URL(string: "https://example.com/v1"))
        )
        do {
            _ = try await client.embed(texts: ["hello"], model: "test-model")
            XCTFail("Expected embed(texts:model:) to throw for GeminiLLMClient")
        } catch {
            // As with Anthropic, callers only rely on the fact that this
            // operation is unsupported, not the precise error details.
        }
    }
}
