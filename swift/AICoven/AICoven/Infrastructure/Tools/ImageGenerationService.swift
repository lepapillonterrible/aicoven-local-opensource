import Foundation

/// A provider whose key can make pictures. The app supplies no key of its
/// own: a picture is made with whichever of the person's keys can make
/// one.
nonisolated enum ImageProvider: String, CaseIterable {
    case openai
    case google

    var displayName: String {
        switch self {
        case .openai: "OpenAI"
        case .google: "Google"
        }
    }

    /// A connection to it, as a sentence names one.
    var aConnection: String {
        switch self {
        case .openai: "an OpenAI connection"
        case .google: "a Google connection"
        }
    }

    /// The provider a call names (`openai`, `google` or `gemini`, in any
    /// case), or nil for a name that is neither.
    init?(named name: String) {
        switch name.lowercased() {
        case "openai": self = .openai
        case "google", "gemini": self = .google
        default: return nil
        }
    }

    /// The provider whose model this reads as, by its name, or nil where
    /// the name does not say.
    static func ofModel(_ model: String) -> ImageProvider? {
        let name = model.lowercased()
        if name.hasPrefix("models/gemini") || name.hasPrefix("gemini") || name.hasPrefix("imagen") { return .google }
        if name.hasPrefix("gpt-image") || name.hasPrefix("dall-e") || name.hasPrefix("chatgpt-image") { return .openai }
        return nil
    }
}

/// One of the person's keys that can make pictures, and how a picture is
/// asked of it.
nonisolated struct ImageMaker {
    let provider: ImageProvider
    let make: @Sendable (_ prompt: String, _ model: String?, _ size: String, _ quality: String?) async throws -> ImageGenerationService.Generated

    init(provider: ImageProvider, make: @escaping @Sendable (_ prompt: String, _ model: String?, _ size: String, _ quality: String?) async throws -> ImageGenerationService.Generated) {
        self.provider = provider
        self.make = make
    }

    init(_ openAI: ImageGenerationService) {
        self.init(provider: .openai) { try await openAI.generate(prompt: $0, model: $1, size: $2, quality: $3) }
    }

    /// Google takes no quality.
    init(_ google: GoogleImageGenerationService) {
        self.init(provider: .google) { prompt, model, size, _ in try await google.generate(prompt: prompt, model: model, size: size) }
    }
}

/// Makes a picture from a description, with the person's own OpenAI key
/// and OpenAI's image endpoint. The key and the description go to OpenAI
/// only; where an older model answers with a link to the picture, the
/// picture is fetched from that link, without the key.
nonisolated struct ImageGenerationService {
    /// A picture as a provider made it.
    struct Generated: Equatable {
        let data: Data
        let mimeType: String
        let model: String
        let size: String
        /// The quality asked for, where the model takes one.
        let quality: String?
        /// The description the model worked from, where it says it changed it.
        let revisedPrompt: String?
    }

    enum Failure: LocalizedError, Equatable {
        /// The key was refused: no other model is tried with it.
        case keyRefused
        /// The key's models include none that makes pictures.
        case noImageModel
        /// OpenAI refused or failed the request, with what it said of it.
        case refused(status: Int, message: String?)
        /// It answered without a picture.
        case noPicture
        /// It answered with a picture larger than the app keeps.
        case tooLarge

        var errorDescription: String? {
            said(of: .openai)
        }

        /// What went wrong, naming the provider that was asked.
        func said(of provider: ImageProvider) -> String {
            let name = provider.displayName
            switch self {
            case .keyRefused: return "\(name) refused the key. Check the \(name) connection in Settings."
            case .noImageModel: return "\(name) lists no image model for this key."
            case let .refused(status, message):
                if let message, !message.isEmpty {
                    return "\(name) did not make the image (\(status)): \(message)"
                }
                return "\(name) did not make the image (\(status))."
            case .noPicture: return "\(name) answered without an image."
            case .tooLarge: return "\(name)'s image is larger than 10 MB and was not kept."
            }
        }
    }

    /// The size asked for when none is given.
    static let defaultSize = "1024x1024"

    /// The models tried first when none is asked for, newest first, as the
    /// cloud app orders them; then whatever else the key lists.
    static let preferredModels = ["gpt-image-2.6-sunburst", "gpt-image-2.6-flare", "gpt-image-2.5-sunburst", "gpt-image-2.5-flare"]

    /// The most models tried for one picture: each that fails costs a
    /// round trip.
    static let mostAttempts = 4

    /// The most bytes of a picture that is taken: what the app keeps of one.
    static let largestPicture = 10 * 1024 * 1024

    /// Making a picture can take minutes.
    static let timeout: TimeInterval = 180

    let apiKey: String
    var baseURL = URL(string: "https://api.openai.com/v1")!
    var session: URLSession = .shared

    // MARK: - Making a picture

    /// A picture of `prompt`. With no `model`, the key's image models are
    /// tried in order (`candidates(among:)`) until one makes it; a refused
    /// key ends the trying.
    func generate(prompt: String, model: String? = nil, size: String = defaultSize, quality: String? = nil) async throws -> Generated {
        let candidates: [String]
        if let model, !model.isEmpty {
            candidates = [model]
        } else {
            do {
                candidates = try await Self.candidates(among: listedImageModels())
            } catch let error as URLError where error.code == .cancelled {
                // Stopped while the models were being listed.
                throw CancellationError()
            }
            guard !candidates.isEmpty else { throw Failure.noImageModel }
        }
        var last: Error = Failure.noPicture
        for candidate in candidates {
            try Task.checkCancellation()
            do {
                return try await attempt(prompt: prompt, model: candidate, size: size, quality: quality)
            } catch Failure.keyRefused {
                throw Failure.keyRefused
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                last = error
            }
        }
        throw last
    }

    /// The image models to try, of those a key lists: the preferred ones
    /// that are listed, in their order, then the others as listed, and no
    /// more than `mostAttempts` in all.
    static func candidates(among listed: [String]) -> [String] {
        let byLowercasedID = Dictionary(listed.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let preferred = preferredModels.compactMap { byLowercasedID[$0] }
        let others = listed.filter { !preferred.contains($0) }
        return Array((preferred + others).prefix(mostAttempts))
    }

    /// The quality to ask a model for, or nil to leave it to the model:
    /// only a value its family takes, with `hd` and `high` taken for each
    /// other across families.
    static func quality(_ quality: String?, for model: String) -> String? {
        guard let asked = quality?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !asked.isEmpty else { return nil }
        let name = model.lowercased()
        if name.hasPrefix("gpt-image") {
            if ["low", "medium", "high", "auto"].contains(asked) { return asked }
            return asked == "hd" ? "high" : nil
        }
        if name == "dall-e-3" {
            if ["standard", "hd"].contains(asked) { return asked }
            return asked == "high" ? "hd" : nil
        }
        return nil
    }

    /// Whether a size reads as width by height in pixels: the whole of it,
    /// in the digits 0 to 9, each side two to five digits not starting
    /// with 0.
    static func isSize(_ size: String) -> Bool {
        size.range(of: #"\A[1-9][0-9]{1,4}x[1-9][0-9]{1,4}\z"#, options: .regularExpression) != nil
    }

    // MARK: - OpenAI

    /// The key's models that make pictures (their ids hold "image" or
    /// "dall"), newest first by name. Throws if the key is refused.
    func listedImageModels() async throws -> [String] {
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
        guard (200 ..< 300).contains(status) else { throw Failure.refused(status: status, message: Self.refusal(in: data)) }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else {
            throw Failure.refused(status: status, message: nil)
        }
        return listing.data.map(\.id)
            .filter { $0.lowercased().contains("image") || $0.lowercased().contains("dall") }
            .sorted(by: >)
    }

    /// What OpenAI said of a request it did not carry out (`error.message`),
    /// at most 300 characters of it.
    static func refusal(in data: Data) -> String? {
        struct Refusal: Decodable {
            struct Detail: Decodable {
                let message: String?
            }

            let error: Detail?
        }
        return (try? JSONDecoder().decode(Refusal.self, from: data))?.error?.message.map { String($0.prefix(300)) }
    }

    private func attempt(prompt: String, model: String, size: String, quality: String?) async throws -> Generated {
        struct Body: Encodable {
            let model: String
            let prompt: String
            let size: String
            let n = 1
            var quality: String?
        }
        struct Answer: Decodable {
            struct Picture: Decodable {
                let b64_json: String?
                let url: String?
                let revised_prompt: String?
            }

            let data: [Picture]?
        }
        let asked = Self.quality(quality, for: model)
        var request = URLRequest(url: baseURL.appendingPathComponent("images/generations"))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(model: model, prompt: prompt, size: size, quality: asked))

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status != 401 else { throw Failure.keyRefused }
        guard (200 ..< 300).contains(status) else {
            throw Failure.refused(status: status, message: Self.refusal(in: data))
        }
        guard let picture = (try? JSONDecoder().decode(Answer.self, from: data))?.data?.first else { throw Failure.noPicture }
        let bytes: Data
        if let encoded = picture.b64_json, let decoded = Data(base64Encoded: encoded) {
            bytes = decoded
        } else if let link = picture.url.flatMap(URL.init(string:)), link.scheme == "https" {
            // An older model answers with where the picture is, for a while.
            var fetch = URLRequest(url: link)
            fetch.timeoutInterval = 30
            let (fetched, answer) = try await session.data(for: fetch)
            guard (200 ..< 300).contains((answer as? HTTPURLResponse)?.statusCode ?? 0) else { throw Failure.noPicture }
            bytes = fetched
        } else {
            throw Failure.noPicture
        }
        guard !bytes.isEmpty else { throw Failure.noPicture }
        guard bytes.count <= Self.largestPicture else { throw Failure.tooLarge }
        return Generated(data: bytes, mimeType: "image/png", model: model, size: size, quality: asked, revisedPrompt: picture.revised_prompt)
    }
}
