@testable import AICoven
import XCTest

/// A model that takes no temperature is asked without one, and one that
/// refuses it is asked again without.
final class ModelTemperatureTests: XCTestCase {
    /// The bodies of the requests a stubbed session was sent, in order.
    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [[String: Any]] = []

        var bodies: [[String: Any]] {
            lock.withLock { kept }
        }

        /// Notes a request's body and gives it back. URLProtocol hands a
        /// request's body over as a stream.
        func note(_ request: URLRequest) -> [String: Any] {
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
            let body = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
            lock.withLock { kept.append(body) }
            return body
        }
    }

    /// A session whose answer to each request is `answer`'s, given the
    /// request's body.
    private func session(keeping sent: Sent, answer: @escaping @Sendable ([String: Any]) -> (Int, String)) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { request in
            let (status, body) = answer(sent.note(request))
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        return URLSession(configuration: config)
    }

    private let openAIAnswer = #"{"model":"m","choices":[{"message":{"role":"assistant","content":"ok"}}]}"#
    private let anthropicAnswer = #"{"model":"m","content":[{"type":"text","text":"ok"}]}"#
    private let question = [LLMMessage(role: .user, content: "Hi")]
    private let options = ChatOptions(temperature: 0.2, maxTokens: nil, stream: false)

    // MARK: - By name

    func testWhichModelsTakeNoTemperatureByTheirNames() {
        // As each provider answered a request with a temperature in November 2026.
        let openAI: [(String, Bool)] = [
            ("gpt-4o", false), ("gpt-4o-mini", false), ("gpt-4.1", false), ("gpt-4.1-mini", false),
            ("gpt-5", true), ("gpt-5-mini", true), ("gpt-5-nano", true),
            ("gpt-5.1", false), ("gpt-5.2", false), ("gpt-5.3", false), ("gpt-5.4", false), ("gpt-5.4-mini", false), ("gpt-5.4-nano", false),
            ("gpt-5.5", true), ("gpt-5.6-sol", true), ("gpt-6-luna", true), ("gpt-6.1-terra", true), ("gpt-6.2-astra", true),
            ("o3", true), ("o1-mini", true), ("gpt-5-chat-latest", false), ("GPT-5-Mini", true),
        ]
        for (model, takesNone) in openAI {
            XCTAssertEqual(ModelTemperature.takesNoneByName(provider: "openai", model: model), takesNone, model)
        }
        let anthropic: [(String, Bool)] = [
            ("claude-fable-5-2", true), ("claude-haiku-5-5", true), ("claude-sonnet-5", true), ("claude-opus-5", true),
            ("claude-opus-4-8", true), ("claude-opus-4-7", true),
            ("claude-sonnet-4-6", false), ("claude-opus-4-6", false), ("claude-opus-4-5-20251101", false),
            ("claude-haiku-4-5-20251001", false), ("claude-sonnet-4-5-20250929", false), ("claude-sonnet-4-20250514", false),
            ("claude-3-5-sonnet-latest", false), ("claude-3-haiku-20240307", false),
        ]
        for (model, takesNone) in anthropic {
            XCTAssertEqual(ModelTemperature.takesNoneByName(provider: "anthropic", model: model), takesNone, model)
        }
        // Another provider's models are not judged by these names: a
        // model that refuses is asked again.
        XCTAssertFalse(ModelTemperature.takesNoneByName(provider: "openrouter", model: "openai/gpt-5"))
        XCTAssertFalse(ModelTemperature.takesNoneByName(provider: "google", model: "gemini-3.5-flash"))
    }

    func testWhatIsARefusalOfTheTemperature() {
        let openAI = #"{"error":{"message":"Unsupported value","type":"invalid_request_error","param":"temperature","code":"unsupported_value"}}"#
        let anthropic = #"{"type":"error","error":{"type":"invalid_request_error","message":"`temperature` is deprecated for this model."}}"#
        let other = #"{"error":{"message":"The model does not exist","param":"model"}}"#
        XCTAssertTrue(ModelTemperature.isRefusal(status: 400, body: Data(openAI.utf8)))
        XCTAssertTrue(ModelTemperature.isRefusal(status: 400, body: Data(anthropic.utf8)))
        XCTAssertFalse(ModelTemperature.isRefusal(status: 400, body: Data(other.utf8)))
        XCTAssertFalse(ModelTemperature.isRefusal(status: 401, body: Data(openAI.utf8)), "Only a bad request is one")
        XCTAssertFalse(ModelTemperature.isRefusal(status: 400, body: Data("temperature".utf8)), "An answer that is no error is none")
    }

    // MARK: - What the clients send

    func testOpenAIIsAskedWithATemperatureOnlyWhereTheModelTakesOne() async throws {
        let sent = Sent()
        let answer = openAIAnswer
        let client = try OpenAILLMClient(
            apiKey: "TEST_KEY", baseURL: XCTUnwrap(URL(string: "https://example.com/v1")),
            urlSession: session(keeping: sent) { _ in (200, answer) }
        )

        _ = try await client.completeChat(messages: question, model: "gpt-4o", options: options)
        _ = try await client.completeChat(messages: question, model: "gpt-5-mini", options: options)

        XCTAssertEqual(sent.bodies.count, 2)
        XCTAssertEqual(sent.bodies[0]["temperature"] as? Double, 0.2)
        XCTAssertNil(sent.bodies[1]["temperature"], "A reasoning model is asked without one")
        XCTAssertEqual(sent.bodies[1]["model"] as? String, "gpt-5-mini")
    }

    func testAnthropicIsAskedWithATemperatureOnlyWhereTheModelTakesOne() async throws {
        let sent = Sent()
        let answer = anthropicAnswer
        let client = try AnthropicLLMClient(
            apiKey: "TEST_KEY", baseURL: XCTUnwrap(URL(string: "https://example.com/v1")),
            urlSession: session(keeping: sent) { _ in (200, answer) }
        )

        _ = try await client.completeChat(messages: question, model: "claude-sonnet-4-6", options: options)
        _ = try await client.completeChat(messages: question, model: "claude-haiku-5-5", options: options)

        XCTAssertEqual(sent.bodies.count, 2)
        XCTAssertEqual(sent.bodies[0]["temperature"] as? Double, 0.2)
        XCTAssertNil(sent.bodies[1]["temperature"])
        XCTAssertEqual(sent.bodies[1]["max_tokens"] as? Int, 4096, "The rest of the request is as it was")
    }

    func testAModelThatRefusesATemperatureIsAskedAgainWithoutOne_andWithoutOneFromThenOn() async throws {
        // A name the rules do not know, of this test's own.
        let model = "new-model-\(UUID().uuidString)"
        let sent = Sent()
        let answer = anthropicAnswer
        let client = try AnthropicLLMClient(
            apiKey: "TEST_KEY", baseURL: XCTUnwrap(URL(string: "https://example.com/v1")),
            urlSession: session(keeping: sent) { body in
                body["temperature"] == nil
                    ? (200, answer)
                    : (400, #"{"type":"error","error":{"type":"invalid_request_error","message":"`temperature` is deprecated for this model."}}"#)
            }
        )
        XCTAssertTrue(ModelTemperature.isSent(provider: "anthropic", model: model))

        let first = try await client.completeChat(messages: question, model: model, options: options)

        XCTAssertEqual(first.message.content, "ok", "The turn is answered")
        XCTAssertEqual(sent.bodies.map { $0["temperature"] as? Double }, [0.2, nil])
        XCTAssertFalse(ModelTemperature.isSent(provider: "anthropic", model: model))

        _ = try await client.completeChat(messages: question, model: model, options: options)
        XCTAssertEqual(sent.bodies.count, 3, "Asked once, without one")
        XCTAssertNil(sent.bodies[2]["temperature"])
    }

    func testAServerBehindOpenClawThatRefusesATemperatureIsAskedAgainWithoutOne() async throws {
        let model = "served-model-\(UUID().uuidString)"
        let sent = Sent()
        let answer = openAIAnswer
        let client = try OpenClawLLMClient(
            baseURL: XCTUnwrap(URL(string: "https://example.com/v1")), apiKey: "TEST_KEY",
            urlSession: session(keeping: sent) { body in
                body["temperature"] == nil
                    ? (200, answer)
                    : (400, #"{"error":{"message":"Unsupported value","param":"temperature"}}"#)
            }
        )

        let reply = try await client.completeChat(messages: question, model: model, options: options)

        XCTAssertEqual(reply.message.content, "ok")
        XCTAssertEqual(sent.bodies.map { $0["temperature"] as? Double }, [0.2, nil])
    }

    func testAModelThatRefusesAgainIsNotAskedAThirdTime_andTheSecondAskingIsTheSameButForTheTemperature() async throws {
        let model = "stubborn-model-\(UUID().uuidString)"
        let sent = Sent()
        let client = try OpenClawLLMClient(
            baseURL: XCTUnwrap(URL(string: "https://example.com/v1")), apiKey: "TEST_KEY",
            urlSession: session(keeping: sent) { _ in (400, #"{"error":{"message":"Unsupported value","param":"temperature"}}"#) }
        )
        let tool = LLMToolDefinition(
            name: "web_search", description: "Searches the web",
            parameters: [LLMToolParameter(name: "query", type: "string", description: "What to look for", required: true)]
        )

        do {
            _ = try await client.completeChat(
                messages: question, model: model, options: ChatOptions(temperature: 0.2, maxTokens: 300, stream: false, tools: [tool])
            )
            XCTFail("A request refused twice is an error")
        } catch {
            XCTAssertEqual((error as NSError).code, 400)
        }

        XCTAssertEqual(sent.bodies.count, 2, "Asked once more, and no more")
        var first = sent.bodies[0]
        XCTAssertEqual(first.removeValue(forKey: "temperature") as? Double, 0.2)
        XCTAssertNil(sent.bodies[1]["temperature"])
        XCTAssertEqual(first as NSDictionary, sent.bodies[1] as NSDictionary, "The model, messages, tools and longest answer are as they were")
        XCTAssertEqual(sent.bodies[1]["max_tokens"] as? Int, 300)
        XCTAssertNotNil(sent.bodies[1]["tools"])
        XCTAssertTrue(ModelTemperature.isSent(provider: "openclaw", model: model), "It never answered without one: nothing is learned of it")
    }

    func testAnyOtherRefusalIsNotAskedAgain() async throws {
        let model = "other-model-\(UUID().uuidString)"
        let sent = Sent()
        let client = try OpenAILLMClient(
            apiKey: "TEST_KEY", baseURL: XCTUnwrap(URL(string: "https://example.com/v1")),
            urlSession: session(keeping: sent) { _ in (400, #"{"error":{"message":"The model does not exist","param":"model"}}"#) }
        )

        do {
            _ = try await client.completeChat(messages: question, model: model, options: options)
            XCTFail("A refused request is an error")
        } catch {
            XCTAssertEqual((error as NSError).code, 400)
        }
        XCTAssertEqual(sent.bodies.count, 1)
        XCTAssertTrue(ModelTemperature.isSent(provider: "openai", model: model), "It is still asked with one")
    }
}
