@testable import AICoven
import XCTest

/// A picture is made with whichever of the person's keys can make one:
/// Google's as well as OpenAI's.
final class GoogleImageGenerationTests: XCTestCase {
    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        await ToolExecutionService.shared.setImageMakers(ToolExecutionService.imageMakersWithTheStoredKeys)
        await ToolExecutionService.shared.setWhitelist(for: "chat", tools: [])
        try await super.tearDown()
    }

    /// What Google was asked. Sendable by hand, under `lock`.
    private final class Asked: @unchecked Sendable {
        struct Request {
            let method: String
            let url: String
            let key: String?
            let authorization: String?
            let body: [String: Any]
        }

        private let lock = NSLock()
        private var kept: [Request] = []

        var requests: [Request] {
            lock.withLock { kept }
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
            let noted = Request(
                method: request.httpMethod ?? "GET",
                url: request.url?.absoluteString ?? "",
                key: request.value(forHTTPHeaderField: "x-goog-api-key"),
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                body: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            )
            lock.withLock { kept.append(noted) }
        }
    }

    private func service(keeping asked: Asked, answer: @escaping @Sendable (URLRequest) -> (Int, String)) -> GoogleImageGenerationService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { request in
            asked.note(request)
            let (status, body) = answer(request)
            return try (XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil)), Data(body.utf8))
        }
        return GoogleImageGenerationService(apiKey: "TEST_KEY", session: URLSession(configuration: config))
    }

    private let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])

    private var picture: String {
        #"{"candidates": [{"content": {"parts": [{"text": "Here it is."}, {"inlineData": {"mimeType": "image/jpeg", "data": "\#(bytes.base64EncodedString())"}}]}, "finishReason": "STOP"}]}"#
    }

    // MARK: - Asking Google

    func testAnImage_isAskedOfTheNamedModelWithTheKeyInAHeader_andReadFromItsBytes() async throws {
        let asked = Asked()
        let answer = picture
        let service = service(keeping: asked) { _ in (200, answer) }

        let image = try await service.generate(prompt: "A lighthouse", model: "models/gemini-3.1-flash-image", size: "1536x1024")

        XCTAssertEqual(image.data, bytes)
        XCTAssertEqual(image.mimeType, "image/jpeg")
        XCTAssertEqual(image.model, "gemini-3.1-flash-image")
        XCTAssertEqual(image.size, "16:9", "The shape Google was asked for")
        XCTAssertNil(image.quality)
        let requests = asked.requests
        XCTAssertEqual(requests.map(\.url), ["https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-image:generateContent"], "A named model is asked at once, and the key is not in the address")
        XCTAssertEqual(requests.first?.method, "POST")
        XCTAssertEqual(requests.first?.key, "TEST_KEY")
        XCTAssertNil(requests.first?.authorization)
        let body = try XCTUnwrap(requests.first?.body)
        XCTAssertEqual(body["contents"] as? NSArray, [["role": "user", "parts": [["text": "A lighthouse"]]]] as NSArray)
        XCTAssertEqual(body["generationConfig"] as? NSDictionary, ["responseModalities": ["TEXT", "IMAGE"], "imageConfig": ["aspectRatio": "16:9"]] as NSDictionary)
    }

    func testWithNoModelNamed_theKeysImageModelsAreTriedInOrderUntilOneMakesIt() async throws {
        let asked = Asked()
        let answer = picture
        let service = service(keeping: asked) { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/models?") {
                return url.contains("pageToken=next")
                    ? (200, #"{"models": [{"name": "models/gemini-3.1-flash-lite-image", "supportedGenerationMethods": ["generateContent"]}, {"name": "models/imagen-4.0-generate-001", "supportedGenerationMethods": ["predict"]}]}"#)
                    : (200, #"{"models": [{"name": "models/gemini-3-pro", "supportedGenerationMethods": ["generateContent"]}, {"name": "models/gemini-2.5-flash-image", "supportedGenerationMethods": ["generateContent", "countTokens"]}, {"name": "models/gemini-image-embedding", "supportedGenerationMethods": ["embedContent"]}], "nextPageToken": "next"}"#)
            }
            return url.contains("flash-lite-image") ? (500, #"{"error": {"message": "Overloaded"}}"#) : (200, answer)
        }

        let image = try await service.generate(prompt: "A lighthouse")

        XCTAssertEqual(image.model, "gemini-2.5-flash-image")
        XCTAssertEqual(image.size, "1:1")
        XCTAssertEqual(asked.requests.map(\.url), [
            "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200",
            "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200&pageToken=next",
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite-image:generateContent",
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-image:generateContent",
        ], "Only models that answer with a picture through generateContent, the last by name first")
        XCTAssertEqual(Set(asked.requests.map(\.key)), ["TEST_KEY"])

        XCTAssertEqual(
            GoogleImageGenerationService.candidates(among: ["gemini-2.5-flash-image", "gemini-3-pro-image", "gemini-3.1-flash-image", "gemini-3.1-flash-lite-image", "gemini-3-pro-image-preview"]),
            ["gemini-3.1-flash-lite-image", "gemini-3.1-flash-image", "gemini-3-pro-image-preview", "gemini-3-pro-image"],
            "Four at most"
        )
    }

    func testWhatGoogleSaysWhenItMakesNoImage() async {
        func failure(model: String? = "gemini-3.1-flash-image", _ answer: @escaping @Sendable (URLRequest) -> (Int, String)) async -> ImageGenerationService.Failure? {
            do {
                _ = try await service(keeping: Asked(), answer: answer).generate(prompt: "A lighthouse", model: model)
                return nil
            } catch {
                return error as? ImageGenerationService.Failure
            }
        }
        var why = await failure { _ in (400, #"{"error": {"code": 400, "message": "API key not valid. Please pass a valid API key.", "status": "INVALID_ARGUMENT"}}"#) }
        XCTAssertEqual(why, .keyRefused, "Google's answer to a key that is not one")
        why = await failure { _ in (403, #"{"error": {"message": "Permission denied"}}"#) }
        XCTAssertEqual(why, .keyRefused)
        why = await failure { _ in (400, #"{"error": {"message": "Unknown aspect ratio"}}"#) }
        XCTAssertEqual(why, .refused(status: 400, message: "Unknown aspect ratio"))
        why = await failure { _ in (200, #"{"promptFeedback": {"blockReason": "SAFETY"}}"#) }
        XCTAssertEqual(why, .refused(status: 200, message: "Google made no image (SAFETY)."))
        why = await failure { _ in (200, #"{"candidates": [{"content": {"parts": [{"text": "I cannot."}]}, "finishReason": "IMAGE_SAFETY"}]}"#) }
        XCTAssertEqual(why, .refused(status: 200, message: "Google made no image (IMAGE_SAFETY)."))
        why = await failure { _ in (200, #"{"candidates": [{"content": {"parts": [{"text": "Here."}]}, "finishReason": "STOP"}]}"#) }
        XCTAssertEqual(why, .noPicture)
        why = await failure(model: nil) { _ in (200, #"{"models": [{"name": "models/gemini-3-pro", "supportedGenerationMethods": ["generateContent"]}]}"#) }
        XCTAssertEqual(why, .noImageModel)
        why = await failure(model: nil) { _ in (403, "{}") }
        XCTAssertEqual(why, .keyRefused, "A refused key ends it at the listing")

        XCTAssertEqual(ImageGenerationService.Failure.keyRefused.said(of: .google), "Google refused the key. Check the Google connection in Settings.")
        XCTAssertEqual(ImageGenerationService.Failure.noPicture.said(of: .openai), "OpenAI answered without an image.")
        XCTAssertEqual(ImageGenerationService.Failure.noPicture.errorDescription, "OpenAI answered without an image.")
    }

    /// The task that is making a picture, so that it can be stopped from
    /// where Google answers. Sendable by hand, under `lock`.
    private final class Making: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<ImageGenerationService.Generated, Error>?
        private var stopped = false

        func set(_ task: Task<ImageGenerationService.Generated, Error>) {
            let stopNow: Bool = lock.withLock {
                self.task = task
                return stopped
            }
            if stopNow { task.cancel() }
        }

        func stop() {
            let task: Task<ImageGenerationService.Generated, Error>? = lock.withLock {
                stopped = true
                return self.task
            }
            task?.cancel()
        }
    }

    func testATurnStoppedWhileGoogleIsAsked_isSaidToBeStopped_whateverGoogleAnswers() async {
        // The stop lands as Google answers, before the answer is handed
        // over. (Where exactly it lands after that cannot be placed from a
        // test; the service looks again after each wait.)
        for answer in [picture, #"{"candidates": [{"content": {"parts": [{"text": "Here."}]}, "finishReason": "STOP"}]}"#, #"{"error": {"message": "Overloaded"}}"#, #"{"models": []}"#] {
            for model in ["gemini-3.1-flash-image", nil] {
                let making = Making()
                let service = service(keeping: Asked()) { _ in
                    making.stop()
                    return (answer.contains("error") ? 500 : 200, answer)
                }
                let task = Task { try await service.generate(prompt: "A lighthouse", model: model) }
                making.set(task)
                do {
                    _ = try await task.value
                    XCTFail("It was stopped")
                } catch {
                    XCTAssertTrue(error is CancellationError, "\(error) for \(answer.prefix(30)) with \(model ?? "no model")")
                }
            }
        }
    }

    func testTheShapeAskedOfGoogle_isTheNearestToTheSize() {
        XCTAssertEqual(GoogleImageGenerationService.shape(for: "1024x1024"), "1:1")
        XCTAssertEqual(GoogleImageGenerationService.shape(for: "1536x1024"), "16:9")
        XCTAssertEqual(GoogleImageGenerationService.shape(for: "1024x1536"), "9:16")
        XCTAssertEqual(GoogleImageGenerationService.shape(for: "1200x1000"), "1:1")
        XCTAssertEqual(GoogleImageGenerationService.shape(for: "large"), "1:1")
        XCTAssertEqual(GoogleImageGenerationService.shape(for: "0x10"), "1:1")
        for notASize in ["1536xx1024", "1536xgarbagex1024", "1536x1024x2", "x1536x1024", " 1536x1024", "1536.5x1024"] {
            XCTAssertEqual(GoogleImageGenerationService.shape(for: notASize), "1:1", notASize)
        }
    }

    func testWhoseAModelIs_andWhatAProviderIsCalled() {
        XCTAssertEqual(ImageProvider.ofModel("gemini-3.1-flash-image"), .google)
        XCTAssertEqual(ImageProvider.ofModel("models/gemini-3-pro-image"), .google)
        XCTAssertEqual(ImageProvider.ofModel("Imagen-4.0-generate-001"), .google)
        XCTAssertEqual(ImageProvider.ofModel("gpt-image-2.6-sunburst"), .openai)
        XCTAssertEqual(ImageProvider.ofModel("dall-e-3"), .openai)
        XCTAssertNil(ImageProvider.ofModel("flux-pro"))
        XCTAssertEqual(ImageProvider(named: "GOOGLE"), .google)
        XCTAssertEqual(ImageProvider(named: "gemini"), .google)
        XCTAssertEqual(ImageProvider(named: "OpenAI"), .openai)
        XCTAssertNil(ImageProvider(named: "anthropic"))
        XCTAssertEqual(ToolExecutionService.generatedImageName(for: "image/jpeg"), "Generated image.jpg")
        XCTAssertEqual(ToolExecutionService.generatedImageName(for: "image/png"), "Generated image.png")
    }

    // MARK: - Which key is asked

    private func makeThread() async throws -> String {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        await MainActor.run { DatabaseManager.shared.configureIfNeeded() }
        await ThreadService.shared.reloadForCurrentUser()
        let threadID = try await ThreadService.shared.createThread(title: "Images \(UUID().uuidString)").id
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await ThreadService.shared.deleteThread(threadId: threadID)
            await ThreadService.shared.reloadForCurrentUser()
            await DataEncryptionService.shared.lock()
        }
        return threadID
    }

    /// The makers that were asked, in order, with the model each was asked for.
    private actor Calls {
        private(set) var made: [String] = []

        func note(_ call: String) {
            made.append(call)
        }
    }

    /// A small real picture, so that it can be kept.
    private func png() throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        try CGImageDestinationAddImage(destination, XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func maker(_ provider: ImageProvider, _ calls: Calls, makes picture: Data?, failing failure: ImageGenerationService.Failure = .noImageModel) -> ImageMaker {
        ImageMaker(provider: provider) { _, model, size, _ in
            await calls.note("\(provider.rawValue):\(model ?? "-")")
            guard let picture else { throw failure }
            return .init(data: picture, mimeType: "image/png", model: model ?? "its-best", size: size, quality: nil, revisedPrompt: nil)
        }
    }

    func testThePersonsKeyThatCanMakeAPicture_isTheOneAsked() async throws {
        let threadID = try await makeThread()
        let picture = try png()
        await ToolExecutionService.shared.setWhitelist(for: "chat", tools: ["image.generate"])
        let service = ToolExecutionService.shared

        // Both keys, nothing named: OpenAI's is asked, and makes it.
        var calls = Calls()
        var both = [maker(.openai, calls, makes: picture), maker(.google, calls, makes: picture)]
        await service.setImageMakers { [both] in both }
        var result = await service.execute(toolCall: ParsedToolCall(name: "image.generate", args: ["prompt": .string("A lighthouse")]), agentType: "chat", threadID: threadID)
        XCTAssertEqual(result.status, "ok")
        XCTAssertEqual(result.result?["provider"]?.value as? String, "openai")
        var made = await calls.made
        XCTAssertEqual(made, ["openai:-"])

        // Google named, or a Gemini model named: Google's is asked, alone.
        calls = Calls()
        both = [maker(.openai, calls, makes: picture), maker(.google, calls, makes: picture)]
        await service.setImageMakers { [both] in both }
        result = await service.execute(toolCall: ParsedToolCall(name: "image.generate", args: ["prompt": .string("A"), "provider": .string("google")]), agentType: "chat", threadID: threadID)
        XCTAssertEqual(result.result?["provider"]?.value as? String, "google")
        result = await service.execute(toolCall: ParsedToolCall(name: "image.generate", args: ["prompt": .string("A"), "model": .string("gemini-3.1-flash-image")]), agentType: "chat", threadID: threadID)
        XCTAssertEqual(result.result?["provider"]?.value as? String, "google")
        XCTAssertEqual(result.result?["model"]?.value as? String, "gemini-3.1-flash-image")
        made = await calls.made
        XCTAssertEqual(made, ["google:-", "google:gemini-3.1-flash-image"])

        // Only a Google key: it is the one asked, with nothing named.
        calls = Calls()
        let googleOnly = [maker(.google, calls, makes: picture)]
        await service.setImageMakers { googleOnly }
        result = await service.execute(toolCall: ParsedToolCall(name: "image.generate", args: ["prompt": .string("A")]), agentType: "chat", threadID: threadID)
        XCTAssertEqual(result.status, "ok")
        XCTAssertEqual(result.result?["provider"]?.value as? String, "google")

        // Nothing named, and the first key cannot make it: the next is asked.
        calls = Calls()
        let firstFails = [maker(.openai, calls, makes: nil), maker(.google, calls, makes: picture)]
        await service.setImageMakers { firstFails }
        result = await service.execute(toolCall: ParsedToolCall(name: "image.generate", args: ["prompt": .string("A")]), agentType: "chat", threadID: threadID)
        XCTAssertEqual(result.status, "ok")
        XCTAssertEqual(result.result?["provider"]?.value as? String, "google")
        made = await calls.made
        XCTAssertEqual(made, ["openai:-", "google:-"])

        // Neither can: what the last one asked said of it.
        calls = Calls()
        let neither = [maker(.openai, calls, makes: nil), maker(.google, calls, makes: nil, failing: .keyRefused)]
        await service.setImageMakers { neither }
        result = await service.execute(toolCall: ParsedToolCall(name: "image.generate", args: ["prompt": .string("A")]), agentType: "chat", threadID: threadID)
        XCTAssertEqual(result.error, "Google refused the key. Check the Google connection in Settings.")

        // A provider is named and the other key fails nothing over to it.
        calls = Calls()
        let openAIFails = [maker(.openai, calls, makes: nil), maker(.google, calls, makes: picture)]
        await service.setImageMakers { openAIFails }
        result = await service.execute(toolCall: ParsedToolCall(name: "image.generate", args: ["prompt": .string("A"), "provider": .string("openai")]), agentType: "chat", threadID: threadID)
        XCTAssertEqual(result.error, "OpenAI lists no image model for this key.")
        made = await calls.made
        XCTAssertEqual(made, ["openai:-"], "Google was not asked in OpenAI's place")

        // A provider is named and there is no key for it; and no key at all.
        await service.setImageMakers { googleOnly }
        result = await service.execute(toolCall: ParsedToolCall(name: "image.generate", args: ["prompt": .string("A"), "provider": .string("openai")]), agentType: "chat", threadID: threadID)
        XCTAssertEqual(result.error, "Image generation needs an OpenAI connection with a key.")
        XCTAssertEqual(result.errorType, "image_provider_key_required")
        await service.setImageMakers { [] }
        result = await service.execute(toolCall: ParsedToolCall(name: "image.generate", args: ["prompt": .string("A"), "model": .string("gemini-3.1-flash-image")]), agentType: "chat", threadID: threadID)
        XCTAssertEqual(result.error, "Image generation needs a Google connection with a key.")
        result = await service.execute(toolCall: ParsedToolCall(name: "image.generate", args: ["prompt": .string("A")]), agentType: "chat", threadID: threadID)
        XCTAssertEqual(result.error, "Image generation needs an OpenAI or Google connection with a key.")
    }
}
