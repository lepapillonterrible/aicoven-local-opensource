@testable import AICoven
import CoreGraphics
import CoreText
import XCTest

/// What a model was asked, so a test can read what it was given.
private final class ListeningModel: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [[LLMMessage]] = []

    /// What the person said in the last thing it was asked.
    var lastUserMessage: String? {
        lock.withLock { heard.last?.last { $0.role == .user }?.content }
    }

    func completeChat(messages: [LLMMessage], model: String, options _: ChatOptions) async throws -> LLMChatResponse {
        lock.withLock { heard.append(messages) }
        return LLMChatResponse(message: LLMMessage(role: .assistant, content: "Read."), providerID: "test", modelID: model, usage: nil)
    }

    func embed(texts: [String], model _: String) async throws -> [[Float]] {
        Array(repeating: [0, 1], count: texts.count)
    }
}

private struct Unreadable: Error {}

/// A turn is told what could be read from the files attached to its
/// message: text as it is, a PDF's text, and a note for the rest.
final class AttachmentContextTests: XCTestCase {
    private func attachment(_ name: String, mimeType: String? = nil, id: String = UUID().uuidString, url: URL? = nil) -> FileAttachmentDetail {
        FileAttachmentDetail(id: id, name: name, mimeType: mimeType, sizeBytes: nil, width: nil, height: nil, url: url)
    }

    /// A PDF with a page for each text; a page with no text for an empty one.
    private func pdf(pages: [String]) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        for text in pages {
            context.beginPDFPage(nil)
            if !text.isEmpty {
                let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
                context.textPosition = CGPoint(x: 72, y: 700)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// Bytes that are no text: a JPEG's first ones.
    private let notText = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])

    // MARK: - Text

    func testATextFile_isGivenBetweenFencesUnderItsName() async {
        let notes = attachment("notes.md", mimeType: "text/markdown")

        let block = await AttachmentContext.block(for: [notes]) { _ in Data("The launch is on Friday.".utf8) }

        XCTAssertEqual(block, "\n\n[Attachment: notes.md]\n```\nThe launch is on Friday.\n```\n")
    }

    func testWithNoAttachments_nothingIsAdded() async {
        let block = await AttachmentContext.block(for: []) { _ in
            XCTFail("There is nothing to read")
            return Data()
        }
        XCTAssertEqual(block, "")
    }

    func testTextLongerThanTheLimit_isCutThereAndMarked() {
        let whole = String(repeating: "a", count: AttachmentContext.longestText)
        XCTAssertEqual(AttachmentContext.body(of: Data(whole.utf8), mimeType: "text/plain"), "```\n\(whole)\n```", "Text at the limit is whole")

        let longer = AttachmentContext.body(of: Data((whole + "b").utf8), mimeType: "text/plain")
        XCTAssertEqual(longer, "```\n\(whole)\n...(truncated)...\n```")

        XCTAssertEqual(AttachmentContext.body(of: Data("abcdef".utf8), mimeType: nil, longestText: 4), "```\nabcd\n...(truncated)...\n```", "A turn can be given less")
        XCTAssertEqual(AttachmentContext.cut("née", at: 2), "né\n...(truncated)...", "Characters are counted, not bytes")
    }

    func testAFileWithFencesOfItsOwn_isGivenALongerFence() {
        let readme = "Run it:\n```\nmake\n```\nand ````four```` too"
        XCTAssertEqual(
            AttachmentContext.body(of: Data(readme.utf8), mimeType: "text/markdown"),
            "`````\n\(readme)\n`````",
            "Nothing in the file reads as the end of it"
        )
        XCTAssertEqual(AttachmentContext.fenced("a `word` in code"), "```\na `word` in code\n```")
    }

    func testAFileName_isGivenOnOneLine() async {
        let odd = attachment("a]\n\n[Attachment: b\u{0}.txt")
        let block = await AttachmentContext.block(for: [odd]) { _ in Data("x".utf8) }
        XCTAssertEqual(block, "\n\n[Attachment: a]  [Attachment: b .txt]\n```\nx\n```\n")
    }

    // MARK: - PDFs

    func testAPDF_isGivenAsTheTextOfItsPages() throws {
        let data = try pdf(pages: ["First page", "Second page", "Third page"])

        XCTAssertEqual(AttachmentContext.text(ofPDF: data), "First page\nSecond page\nThird page")
        XCTAssertEqual(AttachmentContext.body(of: data, mimeType: "application/pdf"), "First page\nSecond page\nThird page", "As it is, with no fence")
        XCTAssertEqual(AttachmentContext.body(of: data, mimeType: nil), "First page\nSecond page\nThird page", "A PDF is known by its bytes too")
        XCTAssertEqual(
            AttachmentContext.body(of: data, mimeType: "application/pdf", longestText: 15),
            "First page\nSeco\n...(truncated)...",
            "Cut at the limit, like any text"
        )
    }

    func testAPDFWithNoText_isSaidToHaveNone() throws {
        let scan = try pdf(pages: ["", ""])
        XCTAssertEqual(AttachmentContext.text(ofPDF: scan), "")
        XCTAssertEqual(AttachmentContext.body(of: scan, mimeType: "application/pdf"), "(A PDF with no text that could be read)")
    }

    func testAFileSaidToBeAPDFThatIsNot_isReadAsWhatItIs() {
        XCTAssertNil(AttachmentContext.text(ofPDF: Data("only words".utf8)))
        XCTAssertEqual(AttachmentContext.body(of: Data("only words".utf8), mimeType: "application/pdf"), "```\nonly words\n```")
        XCTAssertEqual(AttachmentContext.body(of: notText, mimeType: "application/pdf"), "(Binary file, could not extract text)")
    }

    // MARK: - What has no text

    func testAPictureAndOtherFilesWithNoText_areNamedWithANote() async {
        let files = [attachment("photo.jpg", mimeType: "image/jpeg"), attachment("archive.zip", mimeType: "application/zip")]
        let notText = notText

        let block = await AttachmentContext.block(for: files) { _ in notText }

        XCTAssertEqual(
            block,
            "\n\n[Attachment: photo.jpg]\n(A picture. You are not shown it.)\n\n\n[Attachment: archive.zip]\n(Binary file, could not extract text)\n"
        )
        XCTAssertEqual(
            AttachmentContext.body(of: Data("<svg/>".utf8), mimeType: "image/svg+xml"),
            "```\n<svg/>\n```",
            "A picture that is text is read as text"
        )
    }

    // MARK: - What cannot be read

    func testAnAttachmentThatCannotBeRead_isSaidSoAndTheOthersAreStillRead() async {
        let files = [attachment("gone.txt", id: "gone"), attachment("locked.txt", id: "locked"), attachment("kept.txt", id: "kept")]

        let block = await AttachmentContext.block(for: files) { file in
            switch file.id {
            case "gone": throw AttachmentStore.Failure.missing
            case "locked": throw Unreadable()
            default: return Data("still here".utf8)
            }
        }

        XCTAssertEqual(
            block,
            "\n\n[Attachment: gone.txt not found]\n\n\n[Attachment: locked.txt failed to process]\n\n\n[Attachment: kept.txt]\n```\nstill here\n```\n",
            "In the order they were attached"
        )
    }

    // MARK: - From the app's own store

    func testAnAttachedFile_isReadFromTheAppsStore() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        await MainActor.run { DatabaseManager.shared.configureIfNeeded() }
        await ThreadService.shared.reloadForCurrentUser()
        let threadID = try await ThreadService.shared.createThread(title: "Attachments \(UUID().uuidString)").id
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await ThreadService.shared.deleteThread(threadId: threadID)
            await ThreadService.shared.reloadForCurrentUser()
            await DataEncryptionService.shared.lock()
        }
        let kept = try await AttachmentStore.shared.add(Data("Kept on this device.".utf8), named: "notes.txt", mimeType: "text/plain", toThread: threadID)

        let read = await AttachmentContext.block(for: [kept])
        XCTAssertEqual(read, "\n\n[Attachment: notes.txt]\n```\nKept on this device.\n```\n")

        await AttachmentStore.shared.removeUnsent([kept.id])
        let gone = await AttachmentContext.block(for: [kept])
        XCTAssertEqual(gone, "\n\n[Attachment: notes.txt not found]\n")
    }

    // MARK: - To a model

    /// A chat whose only model is `model`, of this provider.
    private func chat(with model: ListeningModel, provider: String) -> ChatService {
        ChatService(
            contextBuilder: ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4)),
            modelRouter: HeuristicModelRouter(availableModels: [ModelDescriptor(
                providerID: provider, modelID: "model", maxContextTokens: 32768,
                supportsTools: false, supportsEmbeddings: false, costClass: .cheap
            )]),
            llmClients: [provider: model],
            threadStore: ThreadRepository.shared,
            toolService: ToolService.shared,
            shouldAutoRefreshEnvironment: false,
            hermesAgent: { nil },
            openClawTurn: { _ in nil }
        )
    }

    func testAModel_isGivenWhatWasReadAfterTheMessage_andOneOnThisDeviceLessOfIt() async throws {
        let defaults = UserDefaults.standard
        let key = UserScope.scopedKey("llm_provider")
        let saved = defaults.object(forKey: key)
        defer { defaults.set(saved, forKey: key) }
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        await MainActor.run { DatabaseManager.shared.configureIfNeeded() }
        await ThreadService.shared.reloadForCurrentUser()
        let threadID = try await ThreadService.shared.createThread(title: "Attachments \(UUID().uuidString)").id
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await ThreadService.shared.deleteThread(threadId: threadID)
            await ThreadService.shared.reloadForCurrentUser()
            await DataEncryptionService.shared.lock()
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("report-\(UUID().uuidString).txt")
        let text = String(repeating: "word ", count: 2000)
        try Data(text.utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let report = attachment("report.txt", mimeType: "text/plain", url: file)

        defaults.set("openai", forKey: key)
        let far = ListeningModel()
        try await chat(with: far, provider: "openai").streamMessage(threadId: threadID, message: "Sum this up", attachments: [report], onStateChange: { _ in })
        let givenWhole = try XCTUnwrap(far.lastUserMessage)
        XCTAssertEqual(givenWhole, "Sum this up\n\n[Attachment: report.txt]\n```\n\(text)\n```", "All 10,000 characters of it, after the message")

        defaults.set("ollama", forKey: key)
        let near = ListeningModel()
        try await chat(with: near, provider: "ollama").streamMessage(threadId: threadID, message: "Sum this up", attachments: [report], onStateChange: { _ in })
        let givenLess = try XCTUnwrap(near.lastUserMessage)
        XCTAssertEqual(
            givenLess,
            "Sum this up\n\n[Attachment: report.txt]\n```\n\(text.prefix(8000))\n...(truncated)...\n```",
            "A model on this device has less room"
        )
        await DataEncryptionService.shared.lock()
    }
}
