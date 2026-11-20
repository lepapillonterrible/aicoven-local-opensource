import Foundation

/// Makes a picture from a description with the person's own Google key:
/// one of the Gemini models that answer with a picture, asked through
/// `generateContent`. The key and the description go to Google only, the
/// key in a header and never in an address.
nonisolated struct GoogleImageGenerationService {
    typealias Generated = ImageGenerationService.Generated
    typealias Failure = ImageGenerationService.Failure

    let apiKey: String
    var host = "generativelanguage.googleapis.com"
    var session: URLSession = .shared

    /// The most pages of the key's models that are read to find those that
    /// make pictures.
    static let mostPagesOfModels = 5

    // MARK: - Making a picture

    /// A picture of `prompt`. With no `model`, the key's image models are
    /// tried in order (`candidates(among:)`) until one makes it; a refused
    /// key ends the trying. `size` is width by height in pixels, of which
    /// Google is asked for the nearest shape.
    func generate(prompt: String, model: String? = nil, size: String = ImageGenerationService.defaultSize) async throws -> Generated {
        let candidates: [String]
        if let model, !model.isEmpty {
            candidates = [model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model]
        } else {
            do {
                candidates = try await Self.candidates(among: listedImageModels())
            } catch {
                // Stopped while the models were listed, however that showed.
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                throw error
            }
            try Task.checkCancellation()
            guard !candidates.isEmpty else { throw Failure.noImageModel }
        }
        var last: Error = Failure.noPicture
        for candidate in candidates {
            try Task.checkCancellation()
            do {
                let made = try await attempt(prompt: prompt, model: candidate, shape: Self.shape(for: size))
                // Stopped while the answer was being read: it is not given.
                try Task.checkCancellation()
                return made
            } catch {
                // Stopped, however that showed (the request cancelled, or
                // an answer read after the stop): that is what is said,
                // whatever the answer was.
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if case Failure.keyRefused = error { throw error }
                last = error
            }
        }
        throw last
    }

    /// The image models to try, of those a key lists: last by name first
    /// (the newer and lighter ones, as the cloud app orders them), and no
    /// more than `ImageGenerationService.mostAttempts`.
    static func candidates(among listed: [String]) -> [String] {
        Array(listed.sorted(by: >).prefix(ImageGenerationService.mostAttempts))
    }

    /// The shape Google is asked for, for a size in pixels: wide, tall or
    /// square, as the cloud app reads it. A size that does not read as one
    /// is square.
    static func shape(for size: String) -> String {
        guard ImageGenerationService.isSize(size) else { return "1:1" }
        let sides = size.split(separator: "x").compactMap { Double($0) }
        guard sides.count == 2, sides[0] > 0, sides[1] > 0 else { return "1:1" }
        let ratio = sides[0] / sides[1]
        if ratio > 1.3 { return "16:9" }
        if ratio < 0.77 { return "9:16" }
        return "1:1"
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

    /// Whether Google's answer says the key is the trouble: 401, 403, or
    /// its 400 for a key that is not one.
    static func refusesTheKey(status: Int, data: Data) -> Bool {
        if status == 401 || status == 403 { return true }
        return status == 400 && (ImageGenerationService.refusal(in: data)?.localizedCaseInsensitiveContains("API key") ?? false)
    }

    /// The key's models that answer with a picture: those whose names
    /// hold "image" and that take `generateContent`. (Imagen's models are
    /// asked another way and are left out.) Throws if the key is refused.
    func listedImageModels() async throws -> [String] {
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
            guard !Self.refusesTheKey(status: status, data: data) else { throw Failure.keyRefused }
            guard (200 ..< 300).contains(status) else { throw Failure.refused(status: status, message: ImageGenerationService.refusal(in: data)) }
            guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else { throw Failure.refused(status: status, message: nil) }
            for model in listing.models ?? [] {
                let id = model.name.hasPrefix("models/") ? String(model.name.dropFirst("models/".count)) : model.name
                let name = id.lowercased()
                guard name.contains("image"), !name.contains("imagen"), model.supportedGenerationMethods?.contains("generateContent") == true else { continue }
                found.append(id)
            }
            guard let next = listing.nextPageToken, !next.isEmpty else { break }
            page = next
        }
        return found
    }

    private func attempt(prompt: String, model: String, shape: String) async throws -> Generated {
        struct Body: Encodable {
            struct Content: Encodable {
                struct Part: Encodable {
                    let text: String
                }

                let role = "user"
                let parts: [Part]
            }

            struct Config: Encodable {
                struct Image: Encodable {
                    let aspectRatio: String
                }

                let responseModalities = ["TEXT", "IMAGE"]
                let imageConfig: Image
            }

            let contents: [Content]
            let generationConfig: Config
        }
        struct Answer: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable {
                        struct Inline: Decodable {
                            let mimeType: String?
                            let data: String?
                        }

                        let inlineData: Inline?
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
        request.timeoutInterval = ImageGenerationService.timeout
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(contents: [.init(parts: [.init(text: prompt)])], generationConfig: .init(imageConfig: .init(aspectRatio: shape))))

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard !Self.refusesTheKey(status: status, data: data) else { throw Failure.keyRefused }
        guard (200 ..< 300).contains(status) else {
            throw Failure.refused(status: status, message: ImageGenerationService.refusal(in: data))
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw Failure.noPicture }
        let pictures = (answer.candidates ?? []).flatMap { $0.content?.parts ?? [] }.compactMap(\.inlineData)
        guard let picture = pictures.first(where: { $0.data?.isEmpty == false }), let encoded = picture.data, let bytes = Data(base64Encoded: encoded), !bytes.isEmpty else {
            // Google says why where it would not make it.
            if let why = answer.promptFeedback?.blockReason ?? answer.candidates?.compactMap(\.finishReason).first(where: { $0 != "STOP" }) {
                throw Failure.refused(status: status, message: "no image came back (\(why))")
            }
            throw Failure.noPicture
        }
        guard bytes.count <= ImageGenerationService.largestPicture else { throw Failure.tooLarge }
        return Generated(data: bytes, mimeType: picture.mimeType ?? "image/png", model: model, size: shape, quality: nil, revisedPrompt: nil)
    }
}
