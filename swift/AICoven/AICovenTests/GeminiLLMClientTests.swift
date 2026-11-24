import XCTest
@testable import AICoven

/// Tests for GeminiLLMClient using a mocked URLSession.
final class GeminiLLMClientTests: XCTestCase {

    private func makeClient(
        withResponseBody body: Data,
        statusCode: Int = 200,
        expectedPathSuffix: String
    ) -> GeminiLLMClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]

        MockURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.path.hasSuffix(expectedPathSuffix) == true)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            // The key goes in its header, and nowhere in the address.
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "TEST_KEY")
            XCTAssertFalse(request.url?.absoluteString.contains("TEST_KEY") ?? true)
            XCTAssertNil(request.url?.query)

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

    /// A model stored without the API's "models/" prefix (typed in an
    /// agent's Model ID, or named in code) is asked for under it: the API
    /// answers 404 to a bare id.
    func testABareModelIDIsAskedForAsTheModelsResource() async throws {
        let json = #"{"candidates":[{"content":{"parts":[{"text":"Hi"}]}}]}"#.data(using: .utf8)!
        let client = makeClient(withResponseBody: json, expectedPathSuffix: "/v1/models/gemini-2.5-flash:generateContent")
        let response = try await client.completeChat(
            messages: [LLMMessage(role: .user, content: "Hi")], model: "gemini-2.5-flash",
            options: ChatOptions(temperature: 0.5, maxTokens: nil, stream: false)
        )
        XCTAssertEqual(response.message.content, "Hi")
    }

    func testAModelsResourceName_isTakenAsItIsAndNothingElseReachesThePath() {
        XCTAssertEqual(GeminiLLMClient.resourceName(of: "models/gemini-2.5-flash"), "models/gemini-2.5-flash")
        XCTAssertEqual(GeminiLLMClient.resourceName(of: "gemini-flash-latest"), "models/gemini-flash-latest")
        XCTAssertEqual(GeminiLLMClient.resourceName(of: "gemini_3.5-flash"), "models/gemini_3.5-flash")
        for notAModel in ["", "models/", "..", "../files", "gemini/../x", "gemini?key=x", "gemini:generateContent", "gemini 2", "models/models/x", "gémini", "gemini-\u{212A}", "gemini-e\u{301}"] {
            XCTAssertNil(GeminiLLMClient.resourceName(of: notAModel), notAModel)
        }
    }

    /// A stored model that is no model's id sends nothing, and the turn is
    /// told why.
    func testAStoredModelThatIsNoModelsID_sendsNothing() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { request in
            XCTFail("Nothing is sent for a model that is no model's id: \(request.url?.absoluteString ?? "")")
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        let client = try GeminiLLMClient(apiKey: "TEST_KEY", baseURL: XCTUnwrap(URL(string: "https://example.com/v1")), urlSession: URLSession(configuration: config))
        for model in ["", "a/b", "../files", "gemini?x=1"] {
            do {
                _ = try await client.completeChat(
                    messages: [LLMMessage(role: .user, content: "Hi")], model: model,
                    options: ChatOptions(temperature: 0.5, maxTokens: nil, stream: false)
                )
                XCTFail("Refused: \(model)")
            } catch {
                XCTAssertEqual(error.localizedDescription, "That is not a Gemini model's name. Choose another Gemini model.", model)
            }
        }
    }

    /// The models a Google key can use are asked for with the key in its
    /// header, and nowhere in the address, on every page.
    func testTheModelListIsAskedForWithTheKeyInItsHeader() {
        for token in [nil, "next-page"] {
            let request = ProviderAccountService.geminiModelsRequest(apiKey: "TEST_KEY", pageToken: token)
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "TEST_KEY")
            XCTAssertFalse(request.url?.absoluteString.contains("TEST_KEY") ?? true)
            XCTAssertEqual(request.url?.path, "/v1beta/models")
            XCTAssertEqual(request.url?.query, token.map { "pageToken=\($0)" })
        }
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

    func testAToolIsCalledByTheNameItWasDeclaredUnder_withItsOwnUnderscoresKept() async throws {
        let json = Data(#"""
        {"candidates": [{"content": {"parts": [
          {"functionCall": {"name": "google_docs_update", "args": {"document_id": "doc1", "content": "Hi"}}},
          {"functionCall": {"name": "web_search", "args": {"query": "swift"}}},
          {"functionCall": {"name": "file_read", "args": {"path": "a.txt"}}},
          {"functionCall": {"name": "file_read_", "args": {}}},
          {"functionCall": {"name": "not_declared", "args": {}}}
        ]}}]}
        """#.utf8)
        let modelName = "models/gemini-pro"
        let client = makeClient(withResponseBody: json, expectedPathSuffix: "/v1/\(modelName):generateContent")
        let sent = Sent()
        let answer = MockURLProtocol.handler
        MockURLProtocol.handler = { request in
            sent.note(request)
            return try XCTUnwrap(answer)(request)
        }
        let tools = ["google_docs.update", "web_search", "file.read", "file_read"].map {
            LLMToolDefinition(name: $0, description: "A tool", parameters: [LLMToolParameter(name: "requests", type: "array", description: "A list", required: false)])
        }

        let response = try await client.completeChat(messages: [LLMMessage(role: .user, content: "Hi")], model: modelName, options: ChatOptions(tools: tools))

        XCTAssertEqual(response.toolCalls?.map(\.name), ["google_docs.update", "web_search", "file.read", "file_read", "not.declared"])
        XCTAssertEqual(sent.declaredNames, ["google_docs_update", "web_search", "file_read", "file_read_"], "Each name without its dots, and no two the same")
    }

    /// What was sent to Gemini. Sendable by hand: `names` is read and
    /// written under `lock`.
    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []

        var declaredNames: [String] {
            lock.withLock { names }
        }

        func note(_ request: URLRequest) {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                stream.close()
            }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let declarations = ((body?["tools"] as? [[String: Any]])?.first?["functionDeclarations"] as? [[String: Any]]) ?? []
            lock.withLock { names = declarations.compactMap { $0["name"] as? String } }
        }
    }
}
