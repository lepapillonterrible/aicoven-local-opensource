@testable import AICoven
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// What a model was asked, so a test can read what it was given.
private final class SeeingModel: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [[LLMMessage]] = []

    /// What the person said in the last thing it was asked.
    var lastUserMessage: LLMMessage? {
        lock.withLock { heard.last?.last { $0.role == .user } }
    }

    func completeChat(messages: [LLMMessage], model: String, options _: ChatOptions) async throws -> LLMChatResponse {
        lock.withLock { heard.append(messages) }
        return LLMChatResponse(message: LLMMessage(role: .assistant, content: "Seen."), providerID: "test", modelID: model, usage: nil)
    }

    func embed(texts: [String], model _: String) async throws -> [[Float]] {
        Array(repeating: [0, 1], count: texts.count)
    }
}

/// The body of the last request a client sent.
private final class Sent: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()

    var body: Data {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func json() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}

/// A picture attached to a message is sent to a model that can see
/// pictures, made ready for it; a model that cannot is told of it by name.
final class PicturesToModelsTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Pictures to work with

    /// A picture as a camera writes it: `orientation` and where it was taken
    /// written into it. `alpha` under 1 makes it one that can be seen through.
    private func photo(width: Int, height: Int, orientation: Int = 1, type: UTType = .jpeg, alpha: CGFloat = 1) throws -> Data {
        let info: CGImageAlphaInfo = alpha < 1 ? .premultipliedLast : .noneSkipLast
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue
        ))
        if alpha > 0 {
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.4, alpha: alpha))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try encoded(XCTUnwrap(context.makeImage()), as: type, orientation: orientation)
    }

    /// A picture of noise, which a JPEG cannot make small.
    private func noise(side: Int) throws -> Data {
        var generator = SystemRandomNumberGenerator()
        var bytes = (0 ..< side * side * 4).map { _ in UInt8.random(in: 0 ... 255, using: &generator) }
        let image: CGImage = try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            return try XCTUnwrap(context.makeImage())
        }
        return try encoded(image, as: .png, orientation: 1)
    }

    private func encoded(_ image: CGImage, as type: UTType, orientation: Int) throws -> Data {
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 13.7563, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 100.5018, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Taken at home"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "A phone"],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private struct Read {
        let type: String?
        let frames: Int
        let width: Int?
        let height: Int?
        let properties: [CFString: Any]
        let image: CGImage
    }

    private func read(_ data: Data) throws -> Read {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return try Read(
            type: CGImageSourceGetType(source) as String?,
            frames: CGImageSourceGetCount(source),
            width: properties[kCGImagePropertyPixelWidth] as? Int,
            height: properties[kCGImagePropertyPixelHeight] as? Int,
            properties: properties,
            image: XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        )
    }

    /// The red, green and blue of the pixel at the picture's top left.
    private func firstPixel(of image: CGImage) throws -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: -(image.height - 1), width: image.width, height: image.height))
        }
        return Array(pixel.prefix(3))
    }

    private func attachment(_ name: String, mimeType: String?, url: URL? = nil) -> FileAttachmentDetail {
        FileAttachmentDetail(id: UUID().uuidString, name: name, mimeType: mimeType, sizeBytes: nil, width: nil, height: nil, url: url)
    }

    // MARK: - A picture made ready for a model

    func testAPictureForAModel_isAnUprightJPEGWithNothingWrittenIntoItAndNoLargerThanAModelTakes() throws {
        // Taken with the phone on its side: 6000 by 3000 as stored, to be
        // shown 3000 by 6000.
        let taken = try photo(width: 6000, height: 3000, orientation: 6)

        let sent = try read(XCTUnwrap(AttachmentImage.forModel(taken)))

        XCTAssertEqual(sent.type, UTType.jpeg.identifier)
        XCTAssertEqual([sent.width, sent.height], [2048, 4096], "Upright, its longest edge at most 4096")
        XCTAssertNil(sent.properties[kCGImagePropertyGPSDictionary], "Not where it was taken")
        XCTAssertNil((sent.properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment])
        XCTAssertNil((sent.properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel])
        XCTAssertTrue([nil, 1].contains(sent.properties[kCGImagePropertyOrientation] as? Int), "Nothing left to turn")
    }

    func testASmallPicture_isNotMadeLarger_andOneSeenThroughIsPutOnWhite() throws {
        let small = try read(XCTUnwrap(AttachmentImage.forModel(photo(width: 40, height: 30))))
        XCTAssertEqual([small.width, small.height], [40, 30])

        let clear = try read(XCTUnwrap(AttachmentImage.forModel(photo(width: 20, height: 20, type: .png, alpha: 0))))
        XCTAssertEqual(clear.type, UTType.jpeg.identifier)
        XCTAssertTrue([CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(clear.image.alphaInfo), "A JPEG cannot be seen through")
        for component in try firstPixel(of: clear.image) {
            XCTAssertGreaterThan(component, 245, "What could be seen through is white, not black")
        }
    }

    func testAPictureThatMoves_isSentAsItsFirstFrame() throws {
        // Its first frame all red, its second all blue.
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.gif.identifier as CFString, 2, nil))
        for colour in [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1)] {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: 16, height: 12, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            context.setFillColor(colour)
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
            try CGImageDestinationAddImage(destination, XCTUnwrap(context.makeImage()), nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertEqual(try read(output as Data).frames, 2)

        let sent = try read(XCTUnwrap(AttachmentImage.forModel(output as Data)))

        XCTAssertEqual(sent.type, UTType.jpeg.identifier)
        XCTAssertEqual(sent.frames, 1)
        XCTAssertEqual([sent.width, sent.height], [16, 12])
        let pixel = try firstPixel(of: sent.image)
        XCTAssertGreaterThan(pixel[0], 200, "Red, as its first frame is")
        XCTAssertLessThan(pixel[2], 60, "Not blue, as its second is")
    }

    func testAPictureTooLargeToSend_isMadeSmallerUntilItIsNot_orNotSentAtAll() throws {
        let busy = try noise(side: 400)
        let atFirst = try XCTUnwrap(AttachmentImage.forModel(busy)).count

        let smaller = try XCTUnwrap(AttachmentImage.forModel(busy, largest: atFirst - 1))
        XCTAssertLessThan(smaller.count, atFirst)
        XCTAssertEqual(try read(smaller).type, UTType.jpeg.identifier)

        XCTAssertNil(AttachmentImage.forModel(busy, largest: 100), "It cannot be made that small")
        XCTAssertNil(AttachmentImage.forModel(Data("not a picture".utf8)))
        XCTAssertNil(AttachmentImage.forModel(Data()))
    }

    // MARK: - What a turn is given

    func testATurnWhoseModelSeesPictures_isGivenThePictureAndNoWordOfIt() async throws {
        let picture = try photo(width: 64, height: 48, type: .png)
        let files = [attachment("notes.txt", mimeType: "text/plain"), attachment("photo.png", mimeType: "image/png"), attachment("more.txt", mimeType: "text/plain")]

        let shown = await AttachmentContext.read(for: files, showsPictures: true) { file in
            file.name == "photo.png" ? picture : Data(file.name.utf8)
        }

        XCTAssertEqual(shown.text, "\n\n[Attachment: notes.txt]\n```\nnotes.txt\n```\n\n\n[Attachment: more.txt]\n```\nmore.txt\n```\n", "The other files, in their order")
        XCTAssertEqual(shown.pictures.map(\.mimeType), ["image/jpeg"])
        let sent = try read(XCTUnwrap(shown.pictures.first?.data))
        XCTAssertEqual([sent.width, sent.height], [64, 48])

        let told = await AttachmentContext.read(for: files, showsPictures: false) { file in
            file.name == "photo.png" ? picture : Data(file.name.utf8)
        }
        XCTAssertEqual(told.pictures, [])
        XCTAssertTrue(told.text.contains("\n\n[Attachment: photo.png]\n(A picture. You are not shown it.)\n"), "A model that cannot see it is told of it")
    }

    func testAFileSaidToBeAPictureThatCannotBeDrawn_isNamedLikeAnyOtherFile() async {
        let files = [attachment("broken.png", mimeType: "image/png"), attachment("drawing.svg", mimeType: "image/svg+xml"), attachment("scan.jpg", mimeType: nil)]

        let given = await AttachmentContext.read(for: files, showsPictures: true) { file in
            switch file.name {
            case "broken.png": Data([0xFF, 0xD8, 0xFF, 0x00])
            case "drawing.svg": Data("<svg/>".utf8)
            default: Data([0xFF, 0xD8, 0xFF, 0x00])
            }
        }

        XCTAssertEqual(given.pictures, [])
        XCTAssertEqual(
            given.text,
            "\n\n[Attachment: broken.png]\n(A picture. You are not shown it.)\n\n\n[Attachment: drawing.svg]\n```\n<svg/>\n```\n\n\n[Attachment: scan.jpg]\n(Binary file, could not extract text)\n"
        )
    }

    // MARK: - Which models see pictures

    func testWhichModelsAreSentPictures() throws {
        XCTAssertTrue(ModelDescriptor.takesImages(providerID: "anthropic", modelID: "claude-sonnet-9"))
        XCTAssertTrue(ModelDescriptor.takesImages(providerID: "google", modelID: "gemini-9-flash"))
        XCTAssertTrue(ModelDescriptor.takesImages(providerID: "openai", modelID: "gpt-9"))
        XCTAssertFalse(ModelDescriptor.takesImages(providerID: "openai", modelID: "gpt-3.5-turbo"), "Text only")
        XCTAssertFalse(ModelDescriptor.takesImages(providerID: "openai", modelID: "o3-mini"))
        XCTAssertTrue(ModelDescriptor.takesImages(providerID: "openrouter", modelID: "vendor/sees", listed: true))
        XCTAssertFalse(ModelDescriptor.takesImages(providerID: "openrouter", modelID: "vendor/reads", listed: false))
        XCTAssertFalse(ModelDescriptor.takesImages(providerID: "openrouter", modelID: "vendor/unlisted"), "Not known to")
        for provider in ["ollama", "mlx", "openclaw", "openai_compatible", "hermes"] {
            XCTAssertFalse(ModelDescriptor.takesImages(providerID: provider, modelID: "llava", listed: true), "\(provider): nothing is known of its models")
        }

        // A model newer than the list, on a provider that is connected.
        let known = ModelDescriptor(providerID: "anthropic", modelID: "claude-old", maxContextTokens: 1000, supportsTools: true, supportsEmbeddings: false, costClass: .cheap)
        XCTAssertFalse(known.takesImages, "Not unless it is said to")
        let router = HeuristicModelRouter(availableModels: [known])
        XCTAssertEqual(router.findExact(providerID: "anthropic", modelID: "claude-new")?.takesImages, true)

        // A model chosen by name that the router is not given to pick from
        // (a role's OpenRouter model) is known by what the catalog says.
        let chosen = ModelDescriptor(providerID: "openrouter", modelID: "vendor/chosen", maxContextTokens: 1000, supportsTools: true, supportsEmbeddings: false, costClass: .cheap)
        let withCatalog = HeuristicModelRouter(availableModels: [chosen], imageModels: ["openrouter": ["vendor/sees"]])
        XCTAssertEqual(withCatalog.findExact(providerID: "openrouter", modelID: "vendor/sees")?.takesImages, true)
        XCTAssertEqual(withCatalog.findExact(providerID: "openrouter", modelID: "vendor/reads")?.takesImages, false)
        XCTAssertEqual(withCatalog.findExact(providerID: "openrouter", modelID: "vendor/chosen")?.takesImages, false, "The one it was given, as it was given")

        let catalog = Data("""
        {"data": [
          {"id": "vendor/sees", "name": "Sees", "context_length": 1000, "supported_parameters": ["tools"],
           "endpoints": ["/api/v1/chat/completions"], "architecture": {"input_modalities": ["text", "image"]}},
          {"id": "vendor/reads", "name": "Reads", "context_length": 1000, "supported_parameters": ["tools"],
           "endpoints": ["/api/v1/chat/completions"], "architecture": {"input_modalities": ["text"]}},
          {"id": "vendor/silent", "name": "Silent", "context_length": 1000, "supported_parameters": ["tools"],
           "endpoints": ["/api/v1/chat/completions"]}
        ]}
        """.utf8)
        let models = try ProviderAccountService.openRouterToolModels(from: catalog)
        XCTAssertEqual(models.map(\.id), ["vendor/sees", "vendor/reads", "vendor/silent"])
        XCTAssertEqual(models.map(\.takesImages), [true, false, false], "As OpenRouter's catalog says")
    }

    // MARK: - How each provider is sent them

    private let picture = LLMImage(data: Data([1, 2, 3]), mimeType: "image/jpeg")

    private func session(answering body: String, keeping sent: Sent) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { request in
            // URLProtocol hands a request's body over as a stream.
            if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                stream.close()
                sent.body = data
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        return URLSession(configuration: config)
    }

    private var asked: [LLMMessage] {
        [
            LLMMessage(role: .user, content: "Earlier"),
            LLMMessage(role: .assistant, content: "Noted"),
            LLMMessage(role: .user, content: "What is this?", images: [picture]),
        ]
    }

    func testOpenAIAndOpenRouter_areSentAPictureAsADataURLAfterTheText() async throws {
        let sent = Sent()
        let client = try OpenAILLMClient(
            apiKey: "TEST_KEY", baseURL: XCTUnwrap(URL(string: "https://example.com/v1")),
            urlSession: session(answering: #"{"choices": [{"index": 0, "message": {"role": "assistant", "content": "A cat"}}], "model": "gpt-9"}"#, keeping: sent)
        )

        let answer = try await client.completeChat(messages: asked, model: "gpt-9", options: ChatOptions(temperature: 0.3, maxTokens: nil, stream: false))

        XCTAssertEqual(answer.message.content, "A cat")
        let messages = try XCTUnwrap(sent.json()["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["content"] as? String, "Earlier", "A message with no picture is sent as text, as before")
        XCTAssertEqual(messages[1]["content"] as? String, "Noted")
        let parts = try XCTUnwrap(messages[2]["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0] as? [String: String], ["type": "text", "text": "What is this?"])
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        XCTAssertEqual(parts[1]["image_url"] as? [String: String], ["url": "data:image/jpeg;base64,AQID"])
        XCTAssertEqual(Set(parts[1].keys), ["type", "image_url"])
    }

    func testAnthropic_isSentAPictureAsABase64SourceAfterTheText() async throws {
        let sent = Sent()
        let client = try AnthropicLLMClient(
            apiKey: "TEST_KEY", baseURL: XCTUnwrap(URL(string: "https://example.com/v1")),
            urlSession: session(answering: #"{"content": [{"type": "text", "text": "A cat"}], "model": "claude-9"}"#, keeping: sent)
        )

        let answer = try await client.completeChat(messages: asked, model: "claude-9", options: ChatOptions(temperature: 0.2, maxTokens: 128, stream: false))

        XCTAssertEqual(answer.message.content, "A cat")
        let messages = try XCTUnwrap(sent.json()["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["content"] as? [[String: String]], [["type": "text", "text": "Earlier"]], "A message with no picture is sent as before")
        let parts = try XCTUnwrap(messages[2]["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0] as? [String: String], ["type": "text", "text": "What is this?"])
        XCTAssertEqual(parts[1]["type"] as? String, "image")
        XCTAssertEqual(parts[1]["source"] as? [String: String], ["type": "base64", "media_type": "image/jpeg", "data": "AQID"])
        XCTAssertEqual(Set(parts[1].keys), ["type", "source"])
    }

    func testGemini_isSentAPictureAsInlineDataAfterTheText() async throws {
        let sent = Sent()
        let client = try GeminiLLMClient(
            apiKey: "TEST_KEY", baseURL: XCTUnwrap(URL(string: "https://example.com/v1")),
            urlSession: session(answering: #"{"candidates": [{"content": {"parts": [{"text": "A cat"}]}}], "modelVersion": "models/gemini-9"}"#, keeping: sent)
        )

        let answer = try await client.completeChat(messages: asked, model: "models/gemini-9", options: ChatOptions(temperature: 0.5, maxTokens: nil, stream: false))

        XCTAssertEqual(answer.message.content, "A cat")
        let contents = try XCTUnwrap(sent.json()["contents"] as? [[String: Any]])
        XCTAssertEqual(contents[0]["parts"] as? [[String: String]], [["text": "Earlier"]], "A message with no picture is sent as before")
        let parts = try XCTUnwrap(contents[2]["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0] as? [String: String], ["text": "What is this?"])
        XCTAssertEqual(parts[1]["inlineData"] as? [String: String], ["mimeType": "image/jpeg", "data": "AQID"])
        XCTAssertEqual(Set(parts[1].keys), ["inlineData"])
    }

    // MARK: - Through a turn

    func testTheContext_carriesThePicturesOnThePersonsMessage() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        await MainActor.run { DatabaseManager.shared.configureIfNeeded() }
        addTeardownBlock { await DataEncryptionService.shared.lock() }
        let builder = ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4))

        let context = try await builder.buildContext(threadID: nil, userMessage: "What is this?", images: [picture], maxContextTokens: 4000, toolConfig: .noTools)

        let said = context.filter { $0.role == .user }
        XCTAssertEqual(said.map(\.content), ["What is this?"])
        XCTAssertEqual(said.first?.images, [picture])
        XCTAssertTrue(context.filter { $0.role != .user }.allSatisfy(\.images.isEmpty))
    }

    private func chat(with model: SeeingModel, provider: String, takesImages: Bool) -> ChatService {
        ChatService(
            contextBuilder: ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4)),
            modelRouter: HeuristicModelRouter(availableModels: [ModelDescriptor(
                providerID: provider, modelID: "model", maxContextTokens: 32768,
                supportsTools: false, supportsEmbeddings: false, costClass: .cheap, takesImages: takesImages
            )]),
            llmClients: [provider: model],
            threadStore: ThreadRepository.shared,
            toolService: ToolService.shared,
            shouldAutoRefreshEnvironment: false,
            hermesAgent: { nil },
            openClawTurn: { _ in nil }
        )
    }

    func testAModelThatSeesPictures_isSentThePictureWithTheMessage_andOneThatCannotIsToldOfIt() async throws {
        let defaults = UserDefaults.standard
        let key = UserScope.scopedKey("llm_provider")
        let saved = defaults.object(forKey: key)
        defer { defaults.set(saved, forKey: key) }
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        await MainActor.run { DatabaseManager.shared.configureIfNeeded() }
        await ThreadService.shared.reloadForCurrentUser()
        let threadID = try await ThreadService.shared.createThread(title: "Pictures \(UUID().uuidString)").id
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await ThreadService.shared.deleteThread(threadId: threadID)
            await ThreadService.shared.reloadForCurrentUser()
            await DataEncryptionService.shared.lock()
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cat-\(UUID().uuidString).png")
        try photo(width: 64, height: 48, type: .png).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let cat = attachment("cat.png", mimeType: "image/png", url: file)

        defaults.set("openai", forKey: key)
        let seeing = SeeingModel()
        try await chat(with: seeing, provider: "openai", takesImages: true)
            .streamMessage(threadId: threadID, message: "What is this?", attachments: [cat], onStateChange: { _ in })
        let shown = try XCTUnwrap(seeing.lastUserMessage)
        XCTAssertEqual(shown.content, "What is this?", "Nothing is said of a picture that is shown")
        XCTAssertEqual(shown.images.map(\.mimeType), ["image/jpeg"])
        let sent = try read(XCTUnwrap(shown.images.first?.data))
        XCTAssertEqual([sent.width, sent.height], [64, 48])

        // A turn that goes straight to its answer, with no tool step, is
        // sent the picture too.
        let answering = SeeingModel()
        try await chat(with: answering, provider: "openai", takesImages: true)
            .streamMessage(threadId: threadID, message: "Explain this", attachments: [cat], onStateChange: { _ in })
        let explained = try XCTUnwrap(answering.lastUserMessage)
        XCTAssertTrue(explained.content.hasPrefix("Explain this\n\nIMPORTANT: You must now answer the user directly"), "The request for the final answer")
        XCTAssertEqual(explained.images.count, 1)

        let reading = SeeingModel()
        try await chat(with: reading, provider: "openai", takesImages: false)
            .streamMessage(threadId: threadID, message: "What is this?", attachments: [cat], onStateChange: { _ in })
        let told = try XCTUnwrap(reading.lastUserMessage)
        XCTAssertEqual(told.content, "What is this?\n\n[Attachment: cat.png]\n(A picture. You are not shown it.)")
        XCTAssertEqual(told.images, [])
        await DataEncryptionService.shared.lock()
    }
}
