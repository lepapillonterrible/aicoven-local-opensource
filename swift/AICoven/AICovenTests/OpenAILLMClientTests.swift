import XCTest
@testable import AICoven

/// URLProtocol that allows tests to intercept requests and provide canned
/// responses without hitting the real OpenAI API.
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockURLProtocol", code: -1))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class OpenAILLMClientTests: XCTestCase {

    private func makeClient(withResponseBody body: Data, statusCode: Int = 200, expectedPathSuffix: String) -> OpenAILLMClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]

        MockURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.path.hasSuffix(expectedPathSuffix) == true)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer TEST_KEY")
            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let session = URLSession(configuration: config)
        return OpenAILLMClient(apiKey: "TEST_KEY", baseURL: URL(string: "https://example.com/v1")!, urlSession: session)
    }

    func testCompleteChat_decodesSuccessfulResponse() async throws {
        let json = """
        {
          "id": "chatcmpl-test",
          "object": "chat.completion",
          "choices": [
            {
              "index": 0,
              "message": {"role": "assistant", "content": "Hello from OpenAI"}
            }
          ],
          "usage": {"prompt_tokens": 10, "completion_tokens": 5},
          "model": "gpt-4o-mini"
        }
        """.data(using: .utf8)!

        let client = makeClient(withResponseBody: json, expectedPathSuffix: "/chat/completions")

        let messages = [LLMMessage(role: .user, content: "Hi")]
        let options = ChatOptions(temperature: 0.3, maxTokens: nil, stream: false)

        let response = try await client.completeChat(messages: messages, model: "gpt-4o-mini", options: options)

        XCTAssertEqual(response.message.content, "Hello from OpenAI")
        XCTAssertEqual(response.providerID, "openai")
        XCTAssertEqual(response.modelID, "gpt-4o-mini")
        XCTAssertEqual(response.usage?.promptTokens, 10)
        XCTAssertEqual(response.usage?.completionTokens, 5)
    }

    func testEmbed_decodesEmbeddingResponse() async throws {
        let json = """
        { "data": [ { "embedding": [0.1, 0.2, 0.3] } ] }
        """.data(using: .utf8)!

        let client = makeClient(withResponseBody: json, expectedPathSuffix: "/embeddings")

        let result = try await client.embed(texts: ["hello"], model: "text-embedding-3-small")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first, [0.1, 0.2, 0.3])
    }
}
