@testable import AICoven
import CoreGraphics
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// What was asked of OpenAI, in order.
private final class Asked: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let key: String?
        let body: [String: Any]
    }

    private let lock = NSLock()
    private var stored: [Request] = []

    var requests: [Request] {
        lock.withLock { stored }
    }

    func note(_ request: URLRequest) {
        var data = Data()
        // URLProtocol hands a request's body over as a stream.
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
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        lock.withLock {
            stored.append(Request(
                method: request.httpMethod ?? "GET", path: request.url?.path ?? "",
                key: request.value(forHTTPHeaderField: "Authorization"), body: body
            ))
        }
    }
}

/// A model asks for an image; it is made with the person's OpenAI key,
/// kept on the device, and goes with the reply.
final class ImageGenerationTests: XCTestCase {
    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        await ToolExecutionService.shared.setImageMakers(ToolExecutionService.imageMakersWithTheStoredKeys)
        // As it is before any turn: nothing allowed until a turn says what is.
        await ToolExecutionService.shared.setWhitelist(for: "chat", tools: [])
        try await super.tearDown()
    }

    /// A small picture, as OpenAI would send one.
    private func png() throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.8, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        try CGImageDestinationAddImage(destination, XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// A service whose requests are answered by `answer`, by path.
    private func service(keeping asked: Asked, answer: @escaping @Sendable (URLRequest) -> (Int, String)) -> ImageGenerationService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { request in
            asked.note(request)
            let (status, body) = answer(request)
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        return ImageGenerationService(apiKey: "TEST_KEY", baseURL: URL(string: "https://example.com/v1")!, session: URLSession(configuration: config))
    }

    private func picture(_ data: Data, revised: String? = nil) -> String {
        let revision = revised.map { #", "revised_prompt": "\#($0)""# } ?? ""
        return #"{"data": [{"b64_json": "\#(data.base64EncodedString())"\#(revision)}]}"#
    }

    // MARK: - Asking OpenAI

    func testAnImage_isAskedOfTheNamedModelWithTheKeyAndReadFromItsBytes() async throws {
        let asked = Asked()
        let made = try png()
        let answer = picture(made, revised: "A lighthouse at dawn, in watercolour")
        let service = service(keeping: asked) { _ in (200, answer) }

        let image = try await service.generate(prompt: "A lighthouse", model: "gpt-image-9", size: "1536x1024", quality: "hd")

        XCTAssertEqual(image.data, made)
        XCTAssertEqual(image.mimeType, "image/png")
        XCTAssertEqual(image.model, "gpt-image-9")
        XCTAssertEqual(image.size, "1536x1024")
        XCTAssertEqual(image.quality, "high", "As this family calls it")
        XCTAssertEqual(image.revisedPrompt, "A lighthouse at dawn, in watercolour")
        let requests = asked.requests
        XCTAssertEqual(requests.map(\.path), ["/v1/images/generations"], "A named model is asked at once, with no listing")
        XCTAssertEqual(requests.first?.method, "POST")
        XCTAssertEqual(requests.first?.key, "Bearer TEST_KEY")
        let body = try XCTUnwrap(requests.first?.body)
        XCTAssertEqual(body["model"] as? String, "gpt-image-9")
        XCTAssertEqual(body["prompt"] as? String, "A lighthouse")
        XCTAssertEqual(body["size"] as? String, "1536x1024")
        XCTAssertEqual(body["n"] as? Int, 1)
        XCTAssertEqual(body["quality"] as? String, "high")
        XCTAssertEqual(Set(body.keys), ["model", "prompt", "size", "n", "quality"])
    }

    func testWithNoModelNamed_theKeysImageModelsAreTriedInOrderUntilOneMakesIt() async throws {
        let asked = Asked()
        let made = try png()
        let answer = picture(made)
        let service = service(keeping: asked) { request in
            if request.url?.path == "/v1/models" {
                return (200, #"{"data": [{"id": "gpt-9"}, {"id": "dall-e-3"}, {"id": "gpt-image-2.5-flare"}, {"id": "gpt-image-2.6-sunburst"}, {"id": "text-embedding-3"}]}"#)
            }
            return (200, answer)
        }

        let image = try await service.generate(prompt: "A lighthouse")

        XCTAssertEqual(image.model, "gpt-image-2.6-sunburst", "The first of the preferred models the key lists")
        XCTAssertNil(image.quality)
        XCTAssertEqual(asked.requests.map(\.path), ["/v1/models", "/v1/images/generations"])
        XCTAssertNil(asked.requests.last?.body["quality"], "Left to the model")
        XCTAssertEqual(asked.requests.last?.body["size"] as? String, "1024x1024")
    }

    func testAModelThatFails_isPassedOver_andARefusedKeyEndsTheTrying() async throws {
        let asked = Asked()
        let made = try png()
        let answer = picture(made)
        let passing = service(keeping: asked) { request in
            if request.url?.path == "/v1/models" {
                return (200, #"{"data": [{"id": "gpt-image-2.5-flare"}, {"id": "gpt-image-2.6-sunburst"}]}"#)
            }
            return asked.requests.count == 2 ? (403, #"{"error": {"message": "This model needs a verified organisation."}}"#) : (200, answer)
        }
        let image = try await passing.generate(prompt: "A lighthouse")
        XCTAssertEqual(image.model, "gpt-image-2.5-flare")
        XCTAssertEqual(asked.requests.compactMap { $0.body["model"] as? String }, ["gpt-image-2.6-sunburst", "gpt-image-2.5-flare"])

        let refusedAsked = Asked()
        let refused = service(keeping: refusedAsked) { request in
            if request.url?.path == "/v1/models" {
                return (200, #"{"data": [{"id": "gpt-image-2.5-flare"}, {"id": "gpt-image-2.6-sunburst"}]}"#)
            }
            return (401, #"{"error": {"message": "Incorrect API key provided."}}"#)
        }
        do {
            _ = try await refused.generate(prompt: "A lighthouse")
            XCTFail("The key was refused")
        } catch {
            XCTAssertEqual(error as? ImageGenerationService.Failure, .keyRefused)
        }
        XCTAssertEqual(refusedAsked.requests.map(\.path), ["/v1/models", "/v1/images/generations"], "No other model is tried with a refused key")
    }

    func testWhatOpenAIRefuses_isSaidAsItSaidIt() async throws {
        let all = service(keeping: Asked()) { _ in (400, #"{"error": {"message": "Your request was rejected by the safety system."}}"#) }
        do {
            _ = try await all.generate(prompt: "Something", model: "gpt-image-9")
            XCTFail("It was refused")
        } catch {
            XCTAssertEqual(error as? ImageGenerationService.Failure, .refused(status: 400, message: "Your request was rejected by the safety system."))
            XCTAssertEqual(error.localizedDescription, "OpenAI did not make the image (400): Your request was rejected by the safety system.")
        }

        let unlisted = service(keeping: Asked()) { _ in (429, #"{"error": {"message": "Rate limit reached for this organisation."}}"#) }
        do {
            _ = try await unlisted.generate(prompt: "Something")
            XCTFail("The models could not be listed")
        } catch {
            XCTAssertEqual(error as? ImageGenerationService.Failure, .refused(status: 429, message: "Rate limit reached for this organisation."), "What it said, also when the models could not be listed")
        }

        let huge = String(repeating: "A", count: (ImageGenerationService.largestPicture / 3 + 1) * 4)
        let tooLarge = service(keeping: Asked()) { _ in (200, #"{"data": [{"b64_json": "\#(huge)"}]}"#) }
        do {
            _ = try await tooLarge.generate(prompt: "Something", model: "gpt-image-9")
            XCTFail("It is larger than the app keeps")
        } catch {
            XCTAssertEqual(error as? ImageGenerationService.Failure, .tooLarge)
            XCTAssertEqual(error.localizedDescription, "OpenAI's image is larger than 10 MB and was not kept.")
        }

        let empty = service(keeping: Asked()) { _ in (200, #"{"data": []}"#) }
        do {
            _ = try await empty.generate(prompt: "Something", model: "gpt-image-9")
            XCTFail("There was no picture")
        } catch {
            XCTAssertEqual(error as? ImageGenerationService.Failure, .noPicture)
        }

        let none = service(keeping: Asked()) { _ in (200, #"{"data": [{"id": "gpt-9"}]}"#) }
        do {
            _ = try await none.generate(prompt: "Something")
            XCTFail("The key lists no image model")
        } catch {
            XCTAssertEqual(error as? ImageGenerationService.Failure, .noImageModel)
        }

        let lockedOut = service(keeping: Asked()) { _ in (401, "{}") }
        do {
            _ = try await lockedOut.generate(prompt: "Something")
            XCTFail("The key was refused")
        } catch {
            XCTAssertEqual(error as? ImageGenerationService.Failure, .keyRefused)
        }
    }

    func testAnOlderModelsLink_isFetchedWithoutTheKey_andOnlyOverHTTPS() async throws {
        let asked = Asked()
        let made = try png()
        // OpenAI answers with where the picture is; that place answers
        // with the picture.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { request in
            asked.note(request)
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return url.host == "files.example.com"
                ? (response, made)
                : (response, Data(#"{"data": [{"url": "https://files.example.com/made/1.png", "revised_prompt": "A lighthouse"}]}"#.utf8))
        }
        let fetching = try ImageGenerationService(apiKey: "TEST_KEY", baseURL: XCTUnwrap(URL(string: "https://example.com/v1")), session: URLSession(configuration: config))

        let image = try await fetching.generate(prompt: "A lighthouse", model: "dall-e-3")

        XCTAssertEqual(image.data, made)
        XCTAssertEqual(image.revisedPrompt, "A lighthouse")
        XCTAssertEqual(asked.requests.map(\.path), ["/v1/images/generations", "/made/1.png"])
        XCTAssertEqual(asked.requests.map(\.key), ["Bearer TEST_KEY", nil], "The key goes to OpenAI only")

        let plain = service(keeping: Asked()) { _ in (200, #"{"data": [{"url": "http://files.example.com/made/1.png"}]}"#) }
        do {
            _ = try await plain.generate(prompt: "A lighthouse", model: "dall-e-3")
            XCTFail("A link that is not https is not followed")
        } catch {
            XCTAssertEqual(error as? ImageGenerationService.Failure, .noPicture)
        }
    }

    func testTheOrderOfModels_theQualityAskedFor_andWhatReadsAsASize() {
        XCTAssertEqual(
            ImageGenerationService.candidates(among: ["gpt-image-9", "GPT-Image-2.5-Sunburst", "gpt-image-2.6-flare", "dall-e-3", "gpt-image-1", "dall-e-2"]),
            ["gpt-image-2.6-flare", "GPT-Image-2.5-Sunburst", "gpt-image-9", "dall-e-3"],
            "The preferred ones first, as the key names them; four at most"
        )
        XCTAssertEqual(ImageGenerationService.candidates(among: []), [])

        XCTAssertEqual(ImageGenerationService.quality("High", for: "gpt-image-2.6-sunburst"), "high")
        XCTAssertEqual(ImageGenerationService.quality("hd", for: "gpt-image-2.6-sunburst"), "high")
        XCTAssertNil(ImageGenerationService.quality("standard", for: "gpt-image-2.6-sunburst"), "Not one it takes: left out")
        XCTAssertEqual(ImageGenerationService.quality("high", for: "dall-e-3"), "hd")
        XCTAssertEqual(ImageGenerationService.quality("standard", for: "dall-e-3"), "standard")
        XCTAssertNil(ImageGenerationService.quality("high", for: "some-other-model"))
        XCTAssertNil(ImageGenerationService.quality(nil, for: "gpt-image-2.6-sunburst"))
        XCTAssertNil(ImageGenerationService.quality("  ", for: "gpt-image-2.6-sunburst"))

        for size in ["1024x1024", "1536x864", "64x64"] {
            XCTAssertTrue(ImageGenerationService.isSize(size), size)
        }
        for size in ["1024", "x1024", "1024x", "0x100", "1024x1024x3", "big", "1024 x 1024", "auto", "1x1", "12x12\n", "\n12x12", "1٢x1٢", ""] {
            XCTAssertFalse(ImageGenerationService.isSize(size), size)
        }
    }

    // MARK: - The tool

    func testWhatTheToolIsAskedFor_isReadFromItsArguments() {
        XCTAssertEqual(
            ToolExecutionService.imageRequest(from: ["prompt": .string("  A lighthouse  ")]),
            .success(.init(prompt: "A lighthouse", model: nil, size: "1024x1024", quality: nil))
        )
        XCTAssertEqual(
            ToolExecutionService.imageRequest(from: ["prompt": .string("A lighthouse"), "provider": .string("OpenAI"), "model": .string("gpt-image-9"), "size": .string("1536x1024"), "quality": .string("high")]),
            .success(.init(prompt: "A lighthouse", provider: .openai, model: "gpt-image-9", size: "1536x1024", quality: "high"))
        )
        // A provider that makes images is taken by name; where none is
        // named, a model says whose it is.
        XCTAssertEqual(
            ToolExecutionService.imageRequest(from: ["prompt": .string("A"), "provider": .string("Gemini")]),
            .success(.init(prompt: "A", provider: .google, model: nil, size: "1024x1024", quality: nil))
        )
        XCTAssertEqual(
            ToolExecutionService.imageRequest(from: ["prompt": .string("A"), "model": .string("gemini-3.1-flash-image")]),
            .success(.init(prompt: "A", provider: .google, model: "gemini-3.1-flash-image", size: "1024x1024", quality: nil))
        )
        XCTAssertEqual(
            ToolExecutionService.imageRequest(from: ["prompt": .string("A"), "model": .string("dall-e-3")]),
            .success(.init(prompt: "A", provider: .openai, model: "dall-e-3", size: "1024x1024", quality: nil))
        )
        XCTAssertEqual(
            ToolExecutionService.imageRequest(from: ["prompt": .string("A"), "provider": .string("openai"), "model": .string("gemini-3.1-flash-image")]),
            .success(.init(prompt: "A", provider: .openai, model: "gemini-3.1-flash-image", size: "1024x1024", quality: nil)),
            "The provider the call names is the one asked"
        )
        XCTAssertEqual(
            ToolExecutionService.imageRequest(from: ["prompt": .string("A"), "model": .string("some-new-model")]),
            .success(.init(prompt: "A", provider: nil, model: "some-new-model", size: "1024x1024", quality: nil)),
            "A model that does not say whose it is leaves it open"
        )
        XCTAssertEqual(ToolExecutionService.imageRequest(from: [:]), .failure(.init(message: "Missing required argument: 'prompt'", field: "prompt")))
        XCTAssertEqual(ToolExecutionService.imageRequest(from: ["prompt": .string("  ")]), .failure(.init(message: "Missing required argument: 'prompt'", field: "prompt")))
        guard case let .failure(provider) = ToolExecutionService.imageRequest(from: ["prompt": .string("A"), "provider": .string("anthropic")]) else {
            return XCTFail("Anthropic makes no images")
        }
        XCTAssertEqual(provider.field, "provider")
        XCTAssertEqual(provider.message, "Images are made with OpenAI or Google in this app; 'anthropic' is not available. Leave 'provider' out to use whichever is connected.")
        guard case let .failure(size) = ToolExecutionService.imageRequest(from: ["prompt": .string("A"), "size": .string("large")]) else {
            return XCTFail("Not a size")
        }
        XCTAssertEqual(size.field, "size")
        XCTAssertEqual(
            ToolExecutionService.imageRequest(from: ["prompt": .string("A"), "size": AnyJSONValue(NSNull())]),
            .success(.init(prompt: "A", model: nil, size: "1024x1024", quality: nil)),
            "Null is how a model writes what it leaves out"
        )
        // A size that was given must be one: only one left out is the default.
        for given: AnyJSONValue in [.string(""), .string("  "), .int(1024), .string("1024x1024\n")] {
            guard case let .failure(refusal) = ToolExecutionService.imageRequest(from: ["prompt": .string("A"), "size": given]) else {
                XCTFail("Not a size: \(given)")
                continue
            }
            XCTAssertEqual(refusal.field, "size")
        }
    }

    func testTheTool_isOfferedAsAnyOtherAndTellsTheModelThePersonHasTheImage() async {
        XCTAssertEqual(PromptTemplates.imageTools, ["image.generate"])
        XCTAssertTrue(PromptTemplates.allTools.isDisjoint(with: PromptTemplates.imageTools), "Not offered unless there is a key to make images with")
        // An agent run does not give what a tool makes to a reply, so it is
        // not offered the tool whatever keys there are; a chat turn is,
        // exactly where there is a key.
        let forAnAgentRun = await ContextBuilder.ToolConfig.connected()
        XCTAssertFalse(forAnAgentRun.enabledTools.contains("image.generate"))
        XCTAssertEqual(PromptTemplates.offeredImageTools(storedKeys: ["KEY", nil]), ["image.generate"])
        XCTAssertEqual(PromptTemplates.offeredImageTools(storedKeys: [nil, "KEY"]), ["image.generate"], "A Google key alone is enough")
        XCTAssertEqual(PromptTemplates.offeredImageTools(storedKeys: ["", nil]), [])
        XCTAssertEqual(PromptTemplates.offeredImageTools(storedKeys: [nil, nil]), [])
        XCTAssertEqual(PromptTemplates.offeredImageTools(storedKeys: []), [])
        XCTAssertEqual(PromptTemplates.storedImageKeys().count, ImageProvider.allCases.count)
        let forAChatTurn = await ContextBuilder.ToolConfig.connected(deliversFiles: true)
        XCTAssertEqual(forAChatTurn.enabledTools.contains("image.generate"), !PromptTemplates.offeredImageTools().isEmpty)
        XCTAssertEqual(forAChatTurn.enabledTools.subtracting(PromptTemplates.imageTools), forAnAgentRun.enabledTools)
        let offered = await PromptTemplates.llmToolDefinitions(for: PromptTemplates.imageTools)
        XCTAssertEqual(offered.map(\.name), ["image.generate"])
        XCTAssertEqual(offered.first?.parameters.filter(\.required).map(\.name), ["prompt"])
        XCTAssertEqual(offered.first?.parameters.map(\.name), ["prompt", "provider", "model", "size", "quality"])

        let made = ImageGenerationService.Generated(data: Data([1]), mimeType: "image/png", model: "gpt-image-9", size: "1024x1024", quality: nil, revisedPrompt: "A lighthouse at dawn")
        XCTAssertEqual(
            ToolExecutionService.imageContextBlock(for: made),
            "[Generated image]\nAn image was made with gpt-image-9 (1024x1024) and is shown to the user in the app, with your reply. Do not write a link or a file name for it.\nPrompt as the model revised it: A lighthouse at dawn"
        )
    }

    // MARK: - Made, kept, and given to the reply

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

    private func messageID(ofAttachment id: String) async throws -> String? {
        try await MainActor.run { DatabaseManager.shared.dbQueue }?.read { db in
            try String.fetchOne(db, sql: "SELECT message_id FROM attachments WHERE id = ?", arguments: [id])
        }
    }

    func testAnImageTheModelAsksFor_isMadeKeptOnTheDeviceAndHandedToTheTurn() async throws {
        let threadID = try await makeThread()
        let asked = Asked()
        let made = try png()
        let answer = picture(made)
        let scripted = service(keeping: asked) { _ in (200, answer) }
        await ToolExecutionService.shared.setImageService { scripted }
        await ToolExecutionService.shared.setWhitelist(for: "chat", tools: ["image.generate"])

        let outcome = try await ChatService.shared.executeChatToolCall(
            ChatToolInvocation(tool: "image.generate", input: AnyJSONValue(["prompt": "A lighthouse", "model": "gpt-image-9"]), reason: nil),
            threadID: threadID
        )

        XCTAssertEqual(outcome.summary, "🎨 Making an image…")
        XCTAssertEqual(outcome.contextBlock?.hasPrefix("[Generated image]\nAn image was made with gpt-image-9 (1024x1024)"), true)
        XCTAssertFalse(outcome.contextBlock?.contains("http") ?? true, "The model is given no link to it")
        let file = try XCTUnwrap(outcome.files.first)
        XCTAssertEqual(outcome.files.count, 1)
        XCTAssertTrue(["Generated image.png", "Generated image.jpg"].contains(file.name), file.name)
        XCTAssertEqual(file.mimeType?.hasPrefix("image/"), true)
        XCTAssertEqual([file.width, file.height], [32, 24])
        let kept = try await AttachmentStore.shared.data(of: file.id)
        XCTAssertFalse(kept.isEmpty, "Kept in the app's own store")
        let unmarked = try await messageID(ofAttachment: file.id)
        XCTAssertNil(unmarked, "Not yet any message's: the turn gives it to its reply")
        XCTAssertEqual(asked.requests.first?.body["prompt"] as? String, "A lighthouse")
    }

    func testWithNoKey_orNoThread_orARefusal_theModelIsToldAndNothingIsKept() async throws {
        let threadID = try await makeThread()
        await ToolExecutionService.shared.setWhitelist(for: "chat", tools: ["image.generate"])
        let call = ChatToolInvocation(tool: "image.generate", input: AnyJSONValue(["prompt": "A lighthouse", "model": "gpt-image-9"]), reason: nil)

        await ToolExecutionService.shared.setImageService { nil }
        let noKey = try await ChatService.shared.executeChatToolCall(call, threadID: threadID)
        XCTAssertEqual(noKey.contextBlock, "[Tool Error: image.generate]\nImage generation needs an OpenAI connection with a key.")
        XCTAssertEqual(noKey.files, [])

        let scripted = service(keeping: Asked()) { _ in (400, #"{"error": {"message": "Rejected by the safety system."}}"#) }
        await ToolExecutionService.shared.setImageService { scripted }
        let refused = try await ChatService.shared.executeChatToolCall(call, threadID: threadID)
        XCTAssertEqual(refused.contextBlock, "[Tool Error: image.generate]\nOpenAI did not make the image (400): Rejected by the safety system.")
        XCTAssertEqual(refused.files, [])

        let noThread = try await ChatService.shared.executeChatToolCall(call, threadID: nil)
        XCTAssertEqual(noThread.contextBlock, "[Tool Error: image.generate]\nAn image can be made only in a thread.")

        // Made, but its thread went while it was being made: it cannot be
        // kept, and that is what is said, not that OpenAI failed.
        let leaving = try await makeThread()
        let found = await MainActor.run { DatabaseManager.shared.dbQueue }
        let queue = try XCTUnwrap(found)
        let picture = try picture(png())
        let thenGone = service(keeping: Asked()) { _ in
            try? queue.write { db in try db.execute(sql: "DELETE FROM threads WHERE id = ?", arguments: [leaving]) }
            return (200, picture)
        }
        await ToolExecutionService.shared.setImageService { thenGone }
        let notKept = try await ChatService.shared.executeChatToolCall(call, threadID: leaving)
        XCTAssertEqual(notKept.contextBlock, "[Tool Error: image.generate]\nThe image was made but could not be kept on this device.")
        XCTAssertEqual(notKept.files, [])

        // A thread that is not the signed-in account's (a turn that outlived
        // its account): nothing is asked of OpenAI with this account's key.
        let notAsked = Asked()
        let anothers = service(keeping: notAsked) { _ in (200, "{}") }
        await ToolExecutionService.shared.setImageService { anothers }
        let wrongAccount = try await ChatService.shared.executeChatToolCall(call, threadID: "not-this-accounts-\(UUID().uuidString)")
        XCTAssertEqual(wrongAccount.contextBlock, "[Tool Error: image.generate]\nThis thread is not the signed-in account's: no image was made.")
        XCTAssertEqual(notAsked.requests.count, 0)

        let noPrompt = try await ChatService.shared.executeChatToolCall(ChatToolInvocation(tool: "image.generate", input: AnyJSONValue(["size": "1024x1024"]), reason: nil), threadID: threadID)
        XCTAssertEqual(noPrompt.contextBlock, "[Tool Error: image.generate]\nMissing required argument: 'prompt'")

        let rows = try await MainActor.run { DatabaseManager.shared.dbQueue }?.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attachments WHERE thread_id = ?", arguments: [threadID])
        }
        XCTAssertEqual(rows, 0)
    }

    func testWhatATurnMade_goesWithItsReplyHoweverItEnded() throws {
        let image = FileAttachmentDetail(id: "made", name: "Generated image.png", mimeType: "image/png", sizeBytes: 10, width: 32, height: 24, url: nil)

        var completed = TurnProgress(agentName: "Strix")
        completed.note(TurnState(answer: "", phase: .tooling, generatedFiles: [image]))
        var done = TurnState(answer: "Here it is.", status: .completed, phase: .finalizing)
        done.generatedFiles = [image]
        completed.note(done)
        let reply = completed.ending(in: "t", thrown: nil)
        XCTAssertEqual(reply.outcome, .completed)
        XCTAssertEqual(try FileAttachmentDetail.attachments(in: XCTUnwrap(reply.message.metadata)), [image])
        XCTAssertEqual(reply.message.metadata?["role_name"], AnyJSONValue("Strix"))

        var stopped = TurnProgress(agentName: nil)
        var half = TurnState(answer: "Here it", phase: .answering)
        half.generatedFiles = [image]
        stopped.note(half)
        let partial = stopped.ending(in: "t", thrown: nil, stopped: true)
        XCTAssertEqual(partial.outcome, .cancelled)
        XCTAssertEqual(try FileAttachmentDetail.attachments(in: XCTUnwrap(partial.message.metadata)), [image], "It was made: the person has it")

        var failed = TurnProgress(agentName: nil)
        failed.note(half)
        let broken = failed.ending(in: "t", thrown: URLError(.timedOut))
        XCTAssertEqual(broken.outcome, .failed)
        XCTAssertEqual(try FileAttachmentDetail.attachments(in: XCTUnwrap(broken.message.metadata)), [image])

        // Told from one report to the next, not stored with a state.
        let coded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(done)) as? [String: Any]
        XCTAssertNil(coded?["generated_files"])
        XCTAssertNil(coded?["generatedFiles"])
        XCTAssertEqual(try JSONDecoder().decode(TurnState.self, from: JSONEncoder().encode(done)).generatedFiles, [])

        var plain = TurnProgress(agentName: nil)
        plain.note(TurnState(answer: "Nothing made.", status: .completed, phase: .finalizing))
        XCTAssertEqual(plain.ending(in: "t", thrown: nil).message.metadata, [:], "A reply with nothing made keeps nothing of the kind, as before")
    }

    func testAReplysGeneratedFiles_areMarkedAsItsOwn_andLeftOutIfTheyCannotBe() async throws {
        let threadID = try await makeThread()
        let kept = try await AttachmentStore.shared.add(png(), named: "Generated image.png", mimeType: "image/png", toThread: threadID)
        let reply = TurnProgress.message(in: threadID, role: "assistant", content: "Here it is.", metadata: FileAttachmentDetail.messageMetadata(for: [kept]))

        let stored = await TurnProgress.keepingGeneratedFiles(of: reply, inThread: threadID)

        XCTAssertEqual(stored, reply)
        let marked = try await messageID(ofAttachment: kept.id)
        XCTAssertEqual(marked, reply.id, "The reply's from here on, and not cleared as unsent")

        // A file that is gone by the time the reply is stored.
        let gone = FileAttachmentDetail(id: UUID().uuidString, name: "Generated image.png", mimeType: "image/png", sizeBytes: 1, width: 1, height: 1, url: nil)
        var metadata = FileAttachmentDetail.messageMetadata(for: [gone]) ?? [:]
        metadata["role_name"] = AnyJSONValue("Strix")
        let without = await TurnProgress.keepingGeneratedFiles(of: TurnProgress.message(in: threadID, role: "assistant", content: "Here it is.", metadata: metadata), inThread: threadID)
        XCTAssertEqual(without.metadata, ["role_name": AnyJSONValue("Strix")], "Stored without what it could not keep")
        XCTAssertEqual(without.content, "Here it is.")

        // One of two that cannot be marked: neither goes with the reply,
        // and the one that was kept is not left for no message.
        let other = try await AttachmentStore.shared.add(png(), named: "Generated image.png", mimeType: "image/png", toThread: threadID)
        let both = TurnProgress.message(in: threadID, role: "assistant", content: "Two.", metadata: FileAttachmentDetail.messageMetadata(for: [other, gone]))
        let neither = await TurnProgress.keepingGeneratedFiles(of: both, inThread: threadID)
        XCTAssertNil(neither.metadata)
        do {
            _ = try await AttachmentStore.shared.data(of: other.id)
            XCTFail("It was removed")
        } catch {
            XCTAssertEqual(error as? AttachmentStore.Failure, .missing)
        }

        let plain = TurnProgress.message(in: threadID, role: "assistant", content: "Nothing made.")
        let same = await TurnProgress.keepingGeneratedFiles(of: plain, inThread: threadID)
        XCTAssertEqual(same, plain)
    }
}
