@testable import AICoven
import XCTest

/// A voice message is put into words with whichever of the person's keys
/// can transcribe, and on the device where none can.
final class VoiceTranscriptionTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Scripted services

    /// What was asked of a provider. Sendable by hand, under `lock`.
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [(request: URLRequest, body: Data)] = []

        var requests: [(request: URLRequest, body: Data)] {
            lock.withLock { kept }
        }

        var paths: [String] {
            requests.map { $0.request.url?.path ?? "" }
        }

        func note(_ request: URLRequest) {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 65536)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                stream.close()
            }
            lock.withLock { kept.append((request, data)) }
        }
    }

    /// A session answered by `answer`, given each request and how many
    /// came before it.
    private func session(_ asked: Asked, answering answer: @escaping @Sendable (URLRequest, Int) throws -> (Int, String)) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { request in
            let before = asked.requests.count
            asked.note(request)
            let (status, body) = try answer(request, before)
            return try (XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)), Data(body.utf8))
        }
        return URLSession(configuration: config)
    }

    private static let recording = Data("not really audio".utf8)

    private static func models(_ ids: [String]) -> String {
        #"{"data": [\#(ids.map { #"{"id": "\#($0)"}"# }.joined(separator: ","))]}"#
    }

    private func thrown(_ run: () async throws -> some Any) async -> Error? {
        do {
            _ = try await run()
            return nil
        } catch {
            return error
        }
    }

    // MARK: - OpenAI

    func testOpenAI_theModelsThatTranscribe_andTheirOrder() {
        let listed = ["gpt-4o", "whisper-1", "gpt-4o-transcribe-diarize", "gpt-transcribe", "gpt-4o-mini-transcribe-2025-12-15", "gpt-live-transcribe", "gpt-realtime-whisper", "gpt-4o-mini-transcribe", "gpt-audio", "gpt-4o-mini-tts", "gpt-4o-transcribe"]
        XCTAssertEqual(
            OpenAITranscriptionService.candidates(among: listed),
            ["gpt-4o-mini-transcribe", "gpt-4o-transcribe", "gpt-transcribe", "whisper-1"],
            "Those named without a date, then whisper-1; four at most"
        )
        XCTAssertEqual(OpenAITranscriptionService.candidates(among: ["gpt-4o", "tts-1"]), [])
        XCTAssertEqual(OpenAITranscriptionService.candidates(among: ["whisper-1", "gpt-4o-transcribe-2026-01-01"]), ["whisper-1", "gpt-4o-transcribe-2026-01-01"])
    }

    func testOpenAI_sendsTheRecordingAsAFile_andReadsTheWords() async throws {
        let asked = Asked()
        let service = OpenAITranscriptionService(apiKey: "TEST_KEY", session: session(asked) { request, _ in
            request.url?.path.hasSuffix("/models") == true
                ? (200, Self.models(["gpt-4o", "gpt-4o-mini-transcribe"]))
                : (200, #"{"text": "  Send this to the team at nine.\n", "usage": {"type": "tokens"}}"#)
        })

        let heard = try await service.transcribe(Self.recording, named: "voice-note-1.m4a")

        XCTAssertEqual(heard, "Send this to the team at nine.")
        XCTAssertEqual(asked.paths, ["/v1/models", "/v1/audio/transcriptions"])
        let sent = try XCTUnwrap(asked.requests.last)
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Authorization"), "Bearer TEST_KEY")
        let type = try XCTUnwrap(sent.request.value(forHTTPHeaderField: "Content-Type"))
        let boundary = try XCTUnwrap(type.components(separatedBy: "boundary=").last)
        XCTAssertTrue(type.hasPrefix("multipart/form-data; boundary="))
        XCTAssertEqual(sent.body, OpenAITranscriptionService.form(audio: Self.recording, fileName: "voice-note-1.m4a", model: "gpt-4o-mini-transcribe", boundary: boundary))
        let form = String(decoding: sent.body, as: UTF8.self)
        XCTAssertEqual(
            form,
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-4o-mini-transcribe\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voice-note-1.m4a\"\r\nContent-Type: audio/mp4\r\n\r\nnot really audio\r\n--\(boundary)--\r\n"
        )

        // A model that is named is the one asked, and no list is read.
        let named = Asked()
        let direct = OpenAITranscriptionService(apiKey: "TEST_KEY", session: session(named) { _, _ in (200, #"{"text": "Hi"}"#) })
        let again = try await direct.transcribe(Self.recording, named: "v.m4a", model: "whisper-1")
        XCTAssertEqual(again, "Hi")
        XCTAssertEqual(named.paths, ["/v1/audio/transcriptions"])
    }

    func testOpenAI_aFileNameCannotEndItsOwnHeader() {
        let form = String(decoding: OpenAITranscriptionService.form(audio: Data("a".utf8), fileName: "x\".m4a\r\nX-Other: 1", model: "m", boundary: "b"), as: UTF8.self)
        XCTAssertTrue(form.contains("filename=\"x.m4aX-Other: 1\"\r\nContent-Type: application/octet-stream\r\n\r\na\r\n"), form)
        // A name of which only the ending can be sent is given a stem, and keeps its type.
        let japanese = String(decoding: OpenAITranscriptionService.form(audio: Data("a".utf8), fileName: "録音.m4a", model: "m", boundary: "b"), as: UTF8.self)
        XCTAssertTrue(japanese.contains("filename=\"voice-note.m4a\"\r\nContent-Type: audio/mp4\r\n"), japanese)
        let wav = String(decoding: OpenAITranscriptionService.form(audio: Data("a".utf8), fileName: "é.wav", model: "m", boundary: "b"), as: UTF8.self)
        XCTAssertTrue(wav.contains("filename=\"voice-note.wav\"\r\nContent-Type: audio/wav\r\n"), wav)
        let controls = String(decoding: OpenAITranscriptionService.form(audio: Data("a".utf8), fileName: "v\u{7F}\u{1}é.m4a", model: "m", boundary: "b"), as: UTF8.self)
        XCTAssertTrue(controls.contains("filename=\"v.m4a\"\r\n"), controls)
        let unnamed = String(decoding: OpenAITranscriptionService.form(audio: Data("a".utf8), fileName: "\n", model: "m", boundary: "b"), as: UTF8.self)
        XCTAssertTrue(unnamed.contains("filename=\"voice-note.m4a\"\r\nContent-Type: audio/mp4"))
    }

    func testOpenAI_aModelThatFailsIsPassedOver_andARefusedKeyOrSilenceEndsTheTrying() async {
        // The first model fails; the second answers.
        var asked = Asked()
        var service = OpenAITranscriptionService(apiKey: "TEST_KEY", session: session(asked) { _, before in
            [(200, Self.models(["gpt-transcribe", "gpt-4o-transcribe"])), (400, #"{"error": {"message": "This model does not take m4a"}}"#), (200, #"{"text": "Second."}"#)][before]
        })
        let heard = try? await service.transcribe(Self.recording, named: "v.m4a")
        XCTAssertEqual(heard, "Second.")
        XCTAssertEqual(asked.requests.count, 3)

        // Every model fails: what the last said is told.
        asked = Asked()
        service = OpenAITranscriptionService(apiKey: "TEST_KEY", session: session(asked) { _, before in
            before == 0 ? (200, Self.models(["gpt-transcribe", "whisper-1"])) : (500, #"{"error": {"message": "Try later"}}"#)
        })
        var error = await thrown { try await service.transcribe(Self.recording, named: "v.m4a") }
        XCTAssertEqual(error as? TranscriptionFailure, .refused(status: 500, message: "Try later"))
        XCTAssertEqual(asked.requests.count, 3)

        // The key is refused: no other model is tried with it.
        asked = Asked()
        service = OpenAITranscriptionService(apiKey: "TEST_KEY", session: session(asked) { _, before in
            before == 0 ? (200, Self.models(["gpt-transcribe", "whisper-1"])) : (401, "{}")
        })
        error = await thrown { try await service.transcribe(Self.recording, named: "v.m4a") }
        XCTAssertEqual(error as? TranscriptionFailure, .keyRefused)
        XCTAssertEqual(asked.requests.count, 2)

        // Refused while its models are listed.
        asked = Asked()
        service = OpenAITranscriptionService(apiKey: "TEST_KEY", session: session(asked) { _, _ in (401, "{}") })
        error = await thrown { try await service.transcribe(Self.recording, named: "v.m4a") }
        XCTAssertEqual(error as? TranscriptionFailure, .keyRefused)

        // It was heard, and holds no words: the next model is not asked.
        asked = Asked()
        service = OpenAITranscriptionService(apiKey: "TEST_KEY", session: session(asked) { _, before in
            before == 0 ? (200, Self.models(["gpt-transcribe", "whisper-1"])) : (200, #"{"text": "  "}"#)
        })
        error = await thrown { try await service.transcribe(Self.recording, named: "v.m4a") }
        XCTAssertEqual(error as? TranscriptionFailure, .noWords)
        XCTAssertEqual(asked.requests.count, 2)

        // An answer without a transcript is a failure of that model.
        asked = Asked()
        service = OpenAITranscriptionService(apiKey: "TEST_KEY", session: session(asked) { _, _ in (200, #"{"words": []}"#) })
        error = await thrown { try await service.transcribe(Self.recording, named: "v.m4a", model: "whisper-1") }
        XCTAssertEqual(error as? TranscriptionFailure, .refused(status: 200, message: "the answer held no transcript"))
    }

    func testOpenAI_whatIsNotSent() async {
        let asked = Asked()
        let service = OpenAITranscriptionService(apiKey: "TEST_KEY", session: session(asked) { _, _ in (200, Self.models(["gpt-4o", "tts-1"])) })

        var error = await thrown { try await service.transcribe(Data(), named: "v.m4a") }
        XCTAssertEqual(error as? TranscriptionFailure, .nothingRecorded)
        error = await thrown { try await service.transcribe(Data(count: VoiceAudio.largest + 1), named: "v.m4a") }
        XCTAssertEqual(error as? TranscriptionFailure, .tooLarge)
        XCTAssertEqual(asked.requests.count, 0, "Neither is sent, nor a list read for it")

        // A key with no model that transcribes.
        error = await thrown { try await service.transcribe(Self.recording, named: "v.m4a") }
        XCTAssertEqual(error as? TranscriptionFailure, .noModel)
        XCTAssertEqual(asked.paths, ["/v1/models"])

        // A model's name that could end its own line in the form is not sent.
        error = await thrown { try await service.transcribe(Self.recording, named: "v.m4a", model: "whisper-1\r\nX: 1") }
        XCTAssertEqual(error as? TranscriptionFailure, .refused(status: 0, message: "The model's name cannot be asked for."))
        XCTAssertEqual(asked.requests.count, 1)
    }

    func testAStop_isToldAsAStop() async {
        let asked = Asked()
        let openAI = OpenAITranscriptionService(apiKey: "TEST_KEY", session: session(asked) { _, _ in throw URLError(.cancelled) })
        var error = await thrown { try await openAI.transcribe(Self.recording, named: "v.m4a") }
        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")
        error = await thrown { try await openAI.transcribe(Self.recording, named: "v.m4a", model: "whisper-1") }
        XCTAssertTrue(error is CancellationError)

        let google = GoogleTranscriptionService(apiKey: "TEST_KEY", session: session(asked) { _, _ in throw URLError(.cancelled) })
        error = await thrown { try await google.transcribe(Self.recording, mimeType: "audio/mp4") }
        XCTAssertTrue(error is CancellationError)
        error = await thrown { try await google.transcribe(Self.recording, mimeType: "audio/mp4", model: "gemini-flash-latest") }
        XCTAssertTrue(error is CancellationError)

        // Stopped before anything is asked: nothing is.
        let none = Asked()
        let service = OpenAITranscriptionService(apiKey: "TEST_KEY", session: session(none) { _, _ in (200, #"{"text": "Hi"}"#) })
        let stopped = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await self.thrown { try await service.transcribe(Self.recording, named: "v.m4a", model: "whisper-1") }
        }
        let result = await stopped.value
        XCTAssertTrue(result is CancellationError)
        XCTAssertEqual(none.requests.count, 0)
    }

    // MARK: - Google

    func testGoogle_theModelsThatTranscribe_andTheirOrder() {
        let listed = ["gemini-2.5-flash", "gemini-3.5-transcribe", "gemini-flash-latest", "gemini-live-transcribe", "gemini-4.0-transcribe", "gemini-2.5-flash-preview-tts"]
        XCTAssertEqual(GoogleTranscriptionService.candidates(among: listed), ["gemini-4.0-transcribe", "gemini-3.5-transcribe", "gemini-flash-latest"])
        XCTAssertEqual(GoogleTranscriptionService.candidates(among: ["gemini-2.5-flash", "gemini-flash-latest"]), ["gemini-flash-latest"])
        XCTAssertEqual(GoogleTranscriptionService.candidates(among: ["gemini-2.5-pro"]), [])
    }

    func testGoogle_givesTheModelTheRecording_andReadsItsWords() async throws {
        let asked = Asked()
        let listing = #"{"models": [{"name": "models/gemini-3.5-transcribe", "supportedGenerationMethods": ["generateContent"]}, {"name": "models/gemini-9-transcribe", "supportedGenerationMethods": ["bidiGenerateContent"]}, {"name": "models/gemini-flash-latest", "supportedGenerationMethods": ["generateContent", "countTokens"]}]}"#
        let service = GoogleTranscriptionService(apiKey: "TEST_KEY", session: session(asked) { request, _ in
            request.httpMethod == "GET"
                ? (200, listing)
                : (200, #"{"candidates": [{"content": {"parts": [{"text": "thinking about it", "thought": true}, {"text": "Send this to the team ", "thoughtSignature": "abc"}, {"text": "at nine.\n"}], "role": "model"}, "finishReason": "STOP"}]}"#)
        })

        let heard = try await service.transcribe(Self.recording, mimeType: "audio/mp4")

        XCTAssertEqual(heard, "Send this to the team at nine.")
        XCTAssertEqual(asked.paths, ["/v1beta/models", "/v1beta/models/gemini-3.5-transcribe:generateContent"], "A model that does not take generateContent is not asked")
        for request in asked.requests.map(\.request) {
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "TEST_KEY")
            XCTAssertFalse(request.url?.absoluteString.contains("TEST_KEY") ?? true, "The key is in no address")
            XCTAssertEqual(request.url?.host, "generativelanguage.googleapis.com")
        }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(asked.requests.last).body) as? NSDictionary)
        XCTAssertEqual(body, [
            "contents": [["role": "user", "parts": [
                ["text": GoogleTranscriptionService.instruction],
                ["inlineData": ["mimeType": "audio/mp4", "data": Self.recording.base64EncodedString()]],
            ]]],
        ] as NSDictionary)

        // A named model is asked for by its id, with or without "models/".
        let named = Asked()
        let direct = GoogleTranscriptionService(apiKey: "TEST_KEY", session: session(named) { _, _ in (200, #"{"candidates": [{"content": {"parts": [{"text": "Hi"}]}}]}"#) })
        _ = try await direct.transcribe(Self.recording, mimeType: "audio/mp4", model: "models/gemini-flash-latest")
        XCTAssertEqual(named.paths, ["/v1beta/models/gemini-flash-latest:generateContent"])
    }

    func testGoogle_whatItAnswersWhenItDoesNotTranscribe() async {
        func service(_ status: Int, _ body: String) -> GoogleTranscriptionService {
            GoogleTranscriptionService(apiKey: "TEST_KEY", session: session(Asked()) { _, _ in (status, body) })
        }
        func failure(_ status: Int, _ body: String) async -> TranscriptionFailure? {
            let asked = service(status, body)
            return await thrown { try await asked.transcribe(Self.recording, mimeType: "audio/mp4", model: "gemini-flash-latest") } as? TranscriptionFailure
        }
        var failed = await failure(400, #"{"error": {"message": "API key not valid. Please pass a valid API key."}}"#)
        XCTAssertEqual(failed, .keyRefused)
        failed = await failure(403, "{}")
        XCTAssertEqual(failed, .keyRefused)
        failed = await failure(429, #"{"error": {"message": "Quota exceeded"}}"#)
        XCTAssertEqual(failed, .refused(status: 429, message: "Quota exceeded"))
        failed = await failure(200, #"{"candidates": [{"content": {"parts": [{"text": " "}]}, "finishReason": "STOP"}]}"#)
        XCTAssertEqual(failed, .noWords)
        failed = await failure(200, #"{"promptFeedback": {"blockReason": "SAFETY"}}"#)
        XCTAssertEqual(failed, .refused(status: 200, message: "no transcript came back (SAFETY)"))
        failed = await failure(200, "not json")
        XCTAssertEqual(failed, .refused(status: 200, message: "the answer held no transcript"))

        // A key that lists no model to ask.
        let listing = service(200, #"{"models": [{"name": "models/gemini-2.5-pro", "supportedGenerationMethods": ["generateContent"]}]}"#)
        let none = await thrown { try await listing.transcribe(Self.recording, mimeType: "audio/mp4") }
        XCTAssertEqual(none as? TranscriptionFailure, .noModel)

        // A model's name that is not one step of an address is not asked for.
        let asked = Asked()
        let odd = GoogleTranscriptionService(apiKey: "TEST_KEY", session: session(asked) { _, _ in (200, "{}") })
        let refused = await thrown { try await odd.transcribe(Self.recording, mimeType: "audio/mp4", model: "..") }
        XCTAssertEqual(refused as? TranscriptionFailure, .refused(status: 0, message: "The model's name cannot be asked for."))
        XCTAssertEqual(asked.requests.count, 0)
    }

    // MARK: - Which is asked

    /// A transcriber that answers from a script and counts its calls.
    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [TranscriptionSource] = []

        var asked: [TranscriptionSource] {
            lock.withLock { kept }
        }

        func transcriber(_ source: TranscriptionSource, _ answer: Result<String, Error>) -> Transcriber {
            Transcriber(source: source) { _ in
                self.lock.withLock { self.kept.append(source) }
                return try answer.get()
            }
        }
    }

    private let anywhere = URL(fileURLWithPath: "/dev/null")

    func testTheOrderTranscribersAreAskedIn() {
        let script = Script()
        let all = [script.transcriber(.device, .success("")), script.transcriber(.openai, .success("")), script.transcriber(.google, .success(""))]
        XCTAssertEqual(VoiceTranscription.ordered(all, preferring: nil).map(\.source), [.openai, .google, .device])
        XCTAssertEqual(VoiceTranscription.ordered(all, preferring: .google).map(\.source), [.google, .openai, .device])
        XCTAssertEqual(VoiceTranscription.ordered(all, preferring: .device).map(\.source), [.openai, .google, .device], "The device is asked last, whatever is preferred")
        XCTAssertEqual(VoiceTranscription.ordered(Array(all.prefix(1)), preferring: .openai).map(\.source), [.device])
        XCTAssertEqual(VoiceTranscription.ordered(all, preferring: .openai, onDeviceOnly: true).map(\.source), [.device])
        XCTAssertEqual(TranscriptionSource(providerID: "Gemini"), .google)
        XCTAssertEqual(TranscriptionSource(providerID: "openai"), .openai)
        XCTAssertNil(TranscriptionSource(providerID: "anthropic"))
        XCTAssertNil(TranscriptionSource(providerID: "device"))
    }

    func testTheFirstThatHearsWordsIsTheOneHeard_andOneThatFailsIsPassedOver() async throws {
        var script = Script()
        var heard = try await VoiceTranscription.transcribe(anywhere, with: [script.transcriber(.openai, .success(" Hello. \n")), script.transcriber(.device, .success("Hullo"))])
        XCTAssertEqual(heard, VoiceTranscription.Heard(text: "Hello.", source: .openai))
        XCTAssertEqual(script.asked, [.openai], "A key that can transcribe is used; the device is not asked")

        script = Script()
        heard = try await VoiceTranscription.transcribe(anywhere, with: [
            script.transcriber(.openai, .failure(TranscriptionFailure.keyRefused)),
            script.transcriber(.google, .failure(URLError(.notConnectedToInternet))),
            script.transcriber(.device, .success("Hullo")),
        ], preferring: .google)
        XCTAssertEqual(heard, VoiceTranscription.Heard(text: "Hullo", source: .device))
        XCTAssertEqual(script.asked, [.google, .openai, .device])

        // A message for a model on this device is heard on this device,
        // whatever keys there are.
        script = Script()
        heard = try await VoiceTranscription.transcribe(anywhere, with: [script.transcriber(.openai, .success("Hello")), script.transcriber(.device, .success("Hullo"))], onDeviceOnly: true)
        XCTAssertEqual(heard, VoiceTranscription.Heard(text: "Hullo", source: .device))
        XCTAssertEqual(script.asked, [.device])

        // No key: the device.
        script = Script()
        heard = try await VoiceTranscription.transcribe(anywhere, with: [script.transcriber(.device, .success("Hullo"))], preferring: .openai)
        XCTAssertEqual(heard.source, .device)
    }

    func testWhenNoneGivesWords_whatTheFirstSaidIsTold() async {
        var script = Script()
        var error = await thrown {
            try await VoiceTranscription.transcribe(self.anywhere, with: [
                script.transcriber(.openai, .failure(TranscriptionFailure.keyRefused)),
                script.transcriber(.device, .failure(TranscriptionFailure.speechNotAllowed)),
            ])
        }
        XCTAssertEqual(error as? VoiceTranscription.Unheard, .init(source: .openai, message: "OpenAI refused the key. Check the OpenAI connection in Settings."))
        XCTAssertEqual(script.asked, [.openai, .device])

        // Heard, and no words in it: no one else is asked.
        script = Script()
        error = await thrown {
            try await VoiceTranscription.transcribe(self.anywhere, with: [script.transcriber(.google, .success("  ")), script.transcriber(.device, .success("Hullo"))])
        }
        XCTAssertEqual(error as? VoiceTranscription.Unheard, .init(source: .google, message: "No words were heard in the recording."))
        XCTAssertEqual(script.asked, [.google])

        // A key failed, and the next heard no words: the asking ends, and
        // what the first said is still what is told.
        script = Script()
        error = await thrown {
            try await VoiceTranscription.transcribe(self.anywhere, with: [
                script.transcriber(.openai, .failure(TranscriptionFailure.keyRefused)),
                script.transcriber(.google, .success(" ")),
                script.transcriber(.device, .success("Hullo")),
            ])
        }
        XCTAssertEqual(error as? VoiceTranscription.Unheard, .init(source: .openai, message: "OpenAI refused the key. Check the OpenAI connection in Settings."))
        XCTAssertEqual(script.asked, [.openai, .google])

        // Nothing recorded: no one else is asked.
        script = Script()
        error = await thrown {
            try await VoiceTranscription.transcribe(self.anywhere, with: [script.transcriber(.openai, .failure(TranscriptionFailure.nothingRecorded)), script.transcriber(.device, .success("Hullo"))])
        }
        XCTAssertEqual((error as? VoiceTranscription.Unheard)?.message, "Nothing was recorded.")
        XCTAssertEqual(script.asked, [.openai])

        // Only the device, and it cannot.
        script = Script()
        error = await thrown {
            try await VoiceTranscription.transcribe(self.anywhere, with: [script.transcriber(.device, .failure(TranscriptionFailure.notOnThisDevice(language: "Romanian")))])
        }
        XCTAssertEqual((error as? VoiceTranscription.Unheard)?.message, "This device cannot transcribe Romanian on its own. An OpenAI or Google key that can transcribe would be used instead.")

        // Where keys are not asked, the person is not told a key would help.
        script = Script()
        error = await thrown {
            try await VoiceTranscription.transcribe(self.anywhere, with: [
                script.transcriber(.openai, .success("Hello")),
                script.transcriber(.device, .failure(TranscriptionFailure.speechNotAllowed)),
            ], onDeviceOnly: true)
        }
        XCTAssertEqual(
            (error as? VoiceTranscription.Unheard)?.message,
            "Speech recognition is not allowed for AICoven on this device. That is set in the device's privacy settings. A message for a model on this device or network is transcribed on this device only."
        )
        XCTAssertEqual(script.asked, [.device])
        XCTAssertNil(VoiceTranscription.whatElse(after: TranscriptionFailure.deviceFailed(message: "Busy"), onDeviceOnly: true))
        XCTAssertNil(VoiceTranscription.whatElse(after: URLError(.timedOut), onDeviceOnly: false))

        // Nothing to ask at all.
        error = await thrown { try await VoiceTranscription.transcribe(self.anywhere, with: []) }
        XCTAssertEqual((error as? VoiceTranscription.Unheard)?.source, .device)

        // A stop ends the asking and is told as one.
        script = Script()
        error = await thrown {
            try await VoiceTranscription.transcribe(self.anywhere, with: [script.transcriber(.openai, .failure(CancellationError())), script.transcriber(.device, .success("Hullo"))])
        }
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(script.asked, [.openai])
    }

    func testAStopWithNoOneToAsk_isStillAStop() async {
        let none = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await self.thrown { try await VoiceTranscription.transcribe(self.anywhere, with: []) }
        }
        let error = await none.value
        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")

        let script = Script()
        let keyOnly = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await self.thrown { try await VoiceTranscription.transcribe(self.anywhere, with: [script.transcriber(.openai, .success("Hello"))], onDeviceOnly: true) }
        }
        let other = await keyOnly.value
        XCTAssertTrue(other is CancellationError)
        XCTAssertEqual(script.asked, [])
    }

    func testAnAnswerAwaitedOnce_isGivenOnce_andAStopAnswersItWheneverItComes() async {
        // Stopped before anyone waits: they are answered so, and nothing starts.
        var awaited = AwaitedOnce<String>()
        awaited.stop()
        var started = false
        var error = await thrown {
            try await withCheckedThrowingContinuation { continuation in
                started = awaited.waiting(continuation)
            }
        }
        XCTAssertTrue(error is CancellationError)
        XCTAssertFalse(started)
        let calledOffAtOnce = Counter()
        awaited.whenStopped { calledOffAtOnce.add() }
        XCTAssertEqual(calledOffAtOnce.count, 1, "What is given to call the work off, after the stop, is run at once")

        // Stopped while they wait: the work is called off, and they are answered.
        awaited = AwaitedOnce<String>()
        let calledOff = Counter()
        error = await thrown { [awaited] in
            try await withCheckedThrowingContinuation { continuation in
                XCTAssertTrue(awaited.waiting(continuation))
                awaited.whenStopped { calledOff.add() }
                awaited.stop()
                // The work's own answer, arriving after, is not given.
                awaited.finish(.success("late"))
                awaited.stop()
            }
        }
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(calledOff.count, 1)

        // Answered: the first answer is the one given.
        awaited = AwaitedOnce<String>()
        let heard = try? await withCheckedThrowingContinuation { [awaited] continuation in
            XCTAssertTrue(awaited.waiting(continuation))
            awaited.finish(.success("first"))
            awaited.finish(.failure(TranscriptionFailure.noWords))
        }
        XCTAssertEqual(heard, "first")
    }

    /// A count kept under a lock. Sendable by hand.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var kept = 0

        var count: Int {
            lock.withLock { kept }
        }

        func add() {
            lock.withLock { kept += 1 }
        }
    }

    func testWhatAFailureIsToldAs() {
        XCTAssertEqual(VoiceTranscription.said(URLError(.timedOut), of: .google), "Google could not be reached.")
        XCTAssertEqual(VoiceTranscription.said(NSError(domain: "x", code: 1), of: .openai), "OpenAI could not transcribe the recording.")
        XCTAssertEqual(TranscriptionFailure.refused(status: 400, message: "Bad audio").said(of: .openai), "OpenAI did not transcribe the recording (400): Bad audio")
        XCTAssertEqual(TranscriptionFailure.refused(status: 500, message: nil).said(of: .google), "Google did not transcribe the recording (500).")
        XCTAssertEqual(TranscriptionFailure.noModel.said(of: .google), "Google lists no model that can transcribe for this key.")
        XCTAssertEqual(TranscriptionFailure.tooLarge.said(of: .openai), "The recording is too long to transcribe (more than 10 MB).")
        XCTAssertEqual(TranscriptionFailure.deviceFailed(message: "Busy").said(of: .device), "This device could not transcribe the recording: Busy")
    }

    // MARK: - The recording, and the device

    func testARecordingsBytesAndType() throws {
        XCTAssertEqual(VoiceAudio.mimeType(ofFileNamed: "voice-note-1.M4A"), "audio/mp4")
        XCTAssertEqual(VoiceAudio.mimeType(ofFileNamed: "a.wav"), "audio/wav")
        XCTAssertEqual(VoiceAudio.mimeType(ofFileNamed: "a"), "application/octet-stream")
        XCTAssertEqual(VoiceAudio.mimeType(ofFileNamed: "clip.mp4"), "application/octet-stream")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceTranscriptionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("v.m4a")
        try Self.recording.write(to: file)
        XCTAssertEqual(try VoiceAudio.bytes(ofFileAt: file), Self.recording)
        try Data().write(to: file)
        XCTAssertThrowsError(try VoiceAudio.bytes(ofFileAt: file)) { XCTAssertEqual($0 as? TranscriptionFailure, .nothingRecorded) }
        XCTAssertThrowsError(try VoiceAudio.bytes(ofFileAt: folder.appendingPathComponent("gone.m4a"))) { XCTAssertEqual($0 as? TranscriptionFailure, .nothingRecorded) }
        try Data(count: VoiceAudio.largest + 1).write(to: file)
        XCTAssertThrowsError(try VoiceAudio.bytes(ofFileAt: file)) { XCTAssertEqual($0 as? TranscriptionFailure, .tooLarge) }
        XCTAssertThrowsError(try VoiceAudio.check(fileAt: file)) { XCTAssertEqual($0 as? TranscriptionFailure, .tooLarge) }
        XCTAssertThrowsError(try VoiceAudio.check(fileAt: folder.appendingPathComponent("gone.m4a"))) { XCTAssertEqual($0 as? TranscriptionFailure, .nothingRecorded) }
        try Data().write(to: file)
        XCTAssertThrowsError(try VoiceAudio.check(fileAt: file)) { XCTAssertEqual($0 as? TranscriptionFailure, .nothingRecorded) }
        try Self.recording.write(to: file)
        XCTAssertNoThrow(try VoiceAudio.check(fileAt: file))
    }

    func testWhatTheDevicesFailuresReadAs() {
        XCTAssertEqual(DeviceTranscriptionService.failure(of: NSError(domain: "kAFAssistantErrorDomain", code: 1110)) as? TranscriptionFailure, .noWords)
        XCTAssertEqual(
            DeviceTranscriptionService.failure(of: NSError(domain: "kAFAssistantErrorDomain", code: 1101, userInfo: [NSLocalizedDescriptionKey: "Recognition is busy"])) as? TranscriptionFailure,
            .deviceFailed(message: "Recognition is busy")
        )
        XCTAssertEqual(DeviceTranscriptionService.failure(of: TranscriptionFailure.speechNotAllowed) as? TranscriptionFailure, .speechNotAllowed)
        XCTAssertTrue(DeviceTranscriptionService.failure(of: CancellationError()) is CancellationError)
    }
}
