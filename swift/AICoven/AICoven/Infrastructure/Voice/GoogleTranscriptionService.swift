import Foundation

/// Puts a recording into words with the person's own Google key: a
/// Gemini model is given the recording and asked for its words, through
/// `generateContent`. The key and the recording go to Google only, the
/// key in a header and never in an address.
nonisolated struct GoogleTranscriptionService {
    typealias Failure = TranscriptionFailure

    /// What the model is asked, as the cloud app asks it.
    static let instruction = "Transcribe the provided audio exactly. Return only the transcript text with no additional commentary."

    /// The model that is asked where the key lists none made to
    /// transcribe, if the key lists it: a chat model that takes audio.
    static let chatModel = "gemini-flash-latest"

    /// The most pages of the key's models that are read.
    static let mostPagesOfModels = 5

    let apiKey: String
    var host = "generativelanguage.googleapis.com"
    var session: URLSession = .shared

    // MARK: - Transcribing

    /// The words of the recording at `url`.
    func transcribe(fileAt url: URL, model: String? = nil) async throws -> String {
        try await transcribe(VoiceAudio.bytes(ofFileAt: url), mimeType: VoiceAudio.mimeType(ofFileNamed: url.lastPathComponent), model: model)
    }

    /// The words of a recording. With no `model`, the key's models are
    /// tried in order (`candidates(among:)`) until one answers; a refused
    /// key ends the trying, and so does a stop.
    func transcribe(_ audio: Data, mimeType: String, model: String? = nil) async throws -> String {
        guard !audio.isEmpty else { throw Failure.nothingRecorded }
        guard audio.count <= VoiceAudio.largest else { throw Failure.tooLarge }
        let candidates: [String]
        if let model, !model.isEmpty {
            candidates = [model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model]
        } else {
            do {
                candidates = try await Self.candidates(among: listedModels())
            } catch {
                // Stopped while the models were listed, however that showed.
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                throw error
            }
            try Task.checkCancellation()
            guard !candidates.isEmpty else { throw Failure.noModel }
        }
        // The recording is written out once, whatever is asked.
        let encoded = audio.base64EncodedString()
        var last: Error = Failure.noWords
        for candidate in candidates {
            try Task.checkCancellation()
            do {
                let heard = try await attempt(encoded, mimeType: mimeType, model: candidate)
                // Stopped while the answer was being read: it is not given.
                try Task.checkCancellation()
                return heard
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                switch error as? Failure {
                case .keyRefused, .noWords: throw error
                default: last = error
                }
            }
        }
        throw last
    }

    /// Whether a model of that name is made to transcribe a recording
    /// sent whole: its name holds "transcribe", and it is not one for
    /// speaking or for a live session.
    static func transcribes(_ id: String) -> Bool {
        let name = id.lowercased()
        guard name.contains("transcribe") else { return false }
        return !["tts", "live", "realtime", "diarize"].contains { name.contains($0) }
    }

    /// The models to try, of those a key lists that take
    /// `generateContent`: the ones made to transcribe, last by name
    /// first (the newer ones), then the chat model that takes audio if it
    /// is listed; no more than `OpenAITranscriptionService.mostAttempts`.
    static func candidates(among listed: [String]) -> [String] {
        let made = listed.filter(transcribes).sorted(by: >)
        let chat = listed.filter { $0.lowercased() == chatModel }
        return Array((made + chat).prefix(OpenAITranscriptionService.mostAttempts))
    }

    // MARK: - Google

    private func address(_ steps: [String], verb: String = "", query: [URLQueryItem] = []) throws -> URL {
        guard let path = RequestPath.path(of: ["v1beta"] + steps), var components = URLComponents(string: "https://\(host)\(path)\(verb)") else {
            throw Failure.refused(status: 0, message: "The model's name cannot be asked for.")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw Failure.refused(status: 0, message: "The model's name cannot be asked for.") }
        return url
    }

    /// The key's models that take `generateContent`, by their ids.
    /// Throws if the key is refused.
    func listedModels() async throws -> [String] {
        struct Listing: Decodable {
            struct Model: Decodable {
                let name: String
                let supportedGenerationMethods: [String]?
            }

            let models: [Model]?
            let nextPageToken: String?
        }
        var found: [String] = []
        var page: String?
        for _ in 0 ..< Self.mostPagesOfModels {
            var query = [URLQueryItem(name: "pageSize", value: "200")]
            if let page { query.append(URLQueryItem(name: "pageToken", value: page)) }
            var request = try URLRequest(url: address(["models"], query: query))
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard !GoogleImageGenerationService.refusesTheKey(status: status, data: data) else { throw Failure.keyRefused }
            guard (200 ..< 300).contains(status) else { throw Failure.refused(status: status, message: ImageGenerationService.refusal(in: data)) }
            guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else { throw Failure.refused(status: status, message: nil) }
            for model in listing.models ?? [] where model.supportedGenerationMethods?.contains("generateContent") == true {
                found.append(model.name.hasPrefix("models/") ? String(model.name.dropFirst("models/".count)) : model.name)
            }
            guard let next = listing.nextPageToken, !next.isEmpty else { break }
            page = next
        }
        return found
    }

    private func attempt(_ encoded: String, mimeType: String, model: String) async throws -> String {
        struct Body: Encodable {
            struct Content: Encodable {
                struct Part: Encodable {
                    struct Inline: Encodable {
                        let mimeType: String
                        let data: String
                    }

                    var text: String?
                    var inlineData: Inline?
                }

                let role = "user"
                let parts: [Part]
            }

            let contents: [Content]
        }
        struct Answer: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable {
                        let text: String?
                        /// A part that is the model's thinking, not its answer.
                        let thought: Bool?
                    }

                    let parts: [Part]?
                }

                let content: Content?
                let finishReason: String?
            }

            struct Feedback: Decodable {
                let blockReason: String?
            }

            let candidates: [Candidate]?
            let promptFeedback: Feedback?
        }
        var request = try URLRequest(url: address(["models", model], verb: ":generateContent"))
        request.httpMethod = "POST"
        request.timeoutInterval = OpenAITranscriptionService.timeout
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(contents: [.init(parts: [
            .init(text: Self.instruction),
            .init(inlineData: .init(mimeType: mimeType, data: encoded)),
        ])]))

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard !GoogleImageGenerationService.refusesTheKey(status: status, data: data) else { throw Failure.keyRefused }
        guard (200 ..< 300).contains(status) else {
            throw Failure.refused(status: status, message: ImageGenerationService.refusal(in: data))
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            throw Failure.refused(status: status, message: "the answer held no transcript")
        }
        // The first candidate's words, without its thinking.
        let parts = answer.candidates?.first?.content?.parts ?? []
        let heard = parts.filter { $0.thought != true }.compactMap(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty else {
            // Google says why where it would not answer.
            if let why = answer.promptFeedback?.blockReason ?? answer.candidates?.compactMap(\.finishReason).first(where: { $0 != "STOP" }) {
                throw Failure.refused(status: status, message: "no transcript came back (\(why))")
            }
            throw Failure.noWords
        }
        return heard
    }
}
