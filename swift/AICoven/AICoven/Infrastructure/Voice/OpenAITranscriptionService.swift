import Foundation

/// Puts a recording into words with the person's own OpenAI key and
/// OpenAI's transcription endpoint. The key and the recording go to
/// OpenAI only.
nonisolated struct OpenAITranscriptionService {
    typealias Failure = TranscriptionFailure

    /// The most models tried for one recording: each that fails costs a
    /// round trip.
    static let mostAttempts = 4

    /// A recording of some minutes can take a while to be heard.
    static let timeout: TimeInterval = 120

    let apiKey: String
    var baseURL = URL(string: "https://api.openai.com/v1")!
    var session: URLSession = .shared

    // MARK: - Transcribing

    /// The words of the recording at `url`.
    func transcribe(fileAt url: URL, model: String? = nil) async throws -> String {
        try await transcribe(VoiceAudio.bytes(ofFileAt: url), named: url.lastPathComponent, model: model)
    }

    /// The words of a recording. With no `model`, the key's models that
    /// transcribe are tried in order (`candidates(among:)`) until one
    /// answers; a refused key ends the trying, and so does a stop.
    func transcribe(_ audio: Data, named fileName: String, model: String? = nil) async throws -> String {
        guard !audio.isEmpty else { throw Failure.nothingRecorded }
        guard audio.count <= VoiceAudio.largest else { throw Failure.tooLarge }
        let candidates: [String]
        if let model, !model.isEmpty {
            candidates = [model]
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
        var last: Error = Failure.noWords
        for candidate in candidates {
            try Task.checkCancellation()
            do {
                let heard = try await attempt(audio, named: fileName, model: candidate)
                // Stopped while the answer was being read: it is not given.
                try Task.checkCancellation()
                return heard
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                // A refused key is refused for every model; a recording
                // that was heard and holds no words holds none for the next.
                switch error as? Failure {
                case .keyRefused, .noWords: throw error
                default: last = error
                }
            }
        }
        throw last
    }

    /// Whether a model of that id transcribes a recording sent whole, as
    /// the cloud app reads a catalog: its id holds "transcribe", and it
    /// is not one for speaking, for a live or realtime session, or for
    /// telling speakers apart. `whisper-1` does too.
    static func transcribes(_ id: String) -> Bool {
        let name = id.lowercased()
        if name == "whisper-1" { return true }
        guard name.contains("transcribe") else { return false }
        return !["tts", "live", "realtime", "diarize"].contains { name.contains($0) }
    }

    /// The models to try, of those a key lists: the ones named without a
    /// date first (a dated one is a fixed copy of one of them), each kind
    /// by name; `whisper-1` after them; no more than `mostAttempts`.
    static func candidates(among listed: [String]) -> [String] {
        let able = listed.filter(transcribes)
        let whisper = able.filter { $0.lowercased() == "whisper-1" }
        let named = able.filter { $0.lowercased() != "whisper-1" }
        let dated = named.filter { $0.range(of: #"-[0-9]{4}-[0-9]{2}-[0-9]{2}\z"#, options: .regularExpression) != nil }
        let undated = named.filter { !dated.contains($0) }
        return Array((undated.sorted() + whisper + dated.sorted()).prefix(mostAttempts))
    }

    // MARK: - OpenAI

    /// The ids of the key's models. Throws if the key is refused.
    func listedModels() async throws -> [String] {
        struct Listing: Decodable {
            struct Model: Decodable {
                let id: String
            }

            let data: [Model]
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status != 401 else { throw Failure.keyRefused }
        guard (200 ..< 300).contains(status) else { throw Failure.refused(status: status, message: ImageGenerationService.refusal(in: data)) }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else {
            throw Failure.refused(status: status, message: nil)
        }
        return listing.data.map(\.id)
    }

    /// The body of the request: a form with the model's id and the
    /// recording as a file, as OpenAI takes it.
    static func form(audio: Data, fileName: String, model: String, boundary: String) -> Data {
        // A name that could end its own header is not sent as it is.
        let safeName = String(fileName.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7F && $0 != "\"" && $0 != "\\" })
        let name = safeName.isEmpty ? "voice-note.m4a" : safeName
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n".utf8))
        // Its type is by the name it has, whatever of it can be sent.
        let type = safeName.isEmpty && fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? VoiceAudio.mimeType(ofFileNamed: name) : VoiceAudio.mimeType(ofFileNamed: fileName)
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: \(type)\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private func attempt(_ audio: Data, named fileName: String, model: String) async throws -> String {
        struct Answer: Decodable {
            let text: String?
        }
        // A model's id goes into the form as it is: one that could end
        // its own line is none.
        guard !model.contains(where: \.isNewline) else { throw Failure.refused(status: 0, message: "The model's name cannot be asked for.") }
        let boundary = "aicoven-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.form(audio: audio, fileName: fileName, model: model, boundary: boundary)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status != 401 else { throw Failure.keyRefused }
        guard (200 ..< 300).contains(status) else {
            throw Failure.refused(status: status, message: ImageGenerationService.refusal(in: data))
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data), let text = answer.text else {
            throw Failure.refused(status: status, message: "the answer held no transcript")
        }
        let heard = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty else { throw Failure.noWords }
        return heard
    }
}
