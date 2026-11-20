import Foundation

/// What can put a voice message into words. The app supplies no key of
/// its own: a recording is transcribed with whichever of the person's
/// keys can transcribe, and on the device where none can.
nonisolated enum TranscriptionSource: String, CaseIterable, Equatable {
    case openai
    case google
    /// This device's own speech recognition; the recording goes nowhere.
    case device

    var displayName: String {
        switch self {
        case .openai: "OpenAI"
        case .google: "Google"
        case .device: "This device"
        }
    }

    /// The source that is a provider's key, by the provider's id
    /// (`openai`, `google` or `gemini`), or nil for any other provider.
    init?(providerID: String) {
        switch providerID.lowercased() {
        case "openai": self = .openai
        case "google", "gemini": self = .google
        default: return nil
        }
    }
}

/// Why a recording was not put into words. It is told to the person by
/// `said(of:)`, which names what was asked (so it is no `LocalizedError`:
/// a description of its own could not say whose key or which device).
nonisolated enum TranscriptionFailure: Error, Equatable {
    /// The key was refused: no other model is tried with it.
    case keyRefused
    /// The key's models include none that transcribes.
    case noModel
    /// The provider refused or failed the request, with what it said of it.
    case refused(status: Int, message: String?)
    /// It answered, and heard no words.
    case noWords
    /// The recording has nothing in it, or could not be read.
    case nothingRecorded
    /// The recording is larger than is sent to be transcribed.
    case tooLarge
    /// The person has not let the app recognise speech on this device.
    case speechNotAllowed
    /// This device cannot recognise that language on its own.
    case notOnThisDevice(language: String)
    /// The device's recognition failed, with what it said of it.
    case deviceFailed(message: String)

    /// What went wrong, naming what was asked.
    func said(of source: TranscriptionSource) -> String {
        let name = source.displayName
        switch self {
        case .keyRefused:
            return "\(name) refused the key. Check the \(name) connection in Settings."
        case .noModel:
            return "\(name) lists no model that can transcribe for this key."
        case let .refused(status, message):
            if let message, !message.isEmpty {
                return "\(name) did not transcribe the recording (\(status)): \(message)"
            }
            return "\(name) did not transcribe the recording (\(status))."
        case .noWords:
            return "No words were heard in the recording."
        case .nothingRecorded:
            return "Nothing was recorded."
        case .tooLarge:
            return "The recording is too long to transcribe (more than 10 MB)."
        case .speechNotAllowed:
            return "Speech recognition is not allowed for AICoven on this device. That is set in the device's privacy settings."
        case let .notOnThisDevice(language):
            return "This device cannot transcribe \(language) on its own."
        case let .deviceFailed(message):
            return "This device could not transcribe the recording: \(message)"
        }
    }
}

/// A recording as it is sent to be transcribed.
nonisolated enum VoiceAudio {
    /// The most bytes of a recording that are sent: as much as a file
    /// attached to a message may hold.
    static let largest = 10 * 1024 * 1024

    /// The type a recording is sent as, by its file's extension. What the
    /// app records is AAC in an MPEG-4 file (`.m4a`).
    static func mimeType(ofFileNamed name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "m4a": "audio/mp4"
        case "aac": "audio/aac"
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "caf": "audio/x-caf"
        case "flac": "audio/flac"
        case "ogg": "audio/ogg"
        case "webm": "audio/webm"
        default: "application/octet-stream"
        }
    }

    /// Checks the recording at `url` without reading it: that it is
    /// there, holds something, and not more than `largest`.
    static func check(fileAt url: URL) throws {
        guard let size = size(ofFileAt: url), size > 0 else { throw TranscriptionFailure.nothingRecorded }
        guard size <= largest else { throw TranscriptionFailure.tooLarge }
    }

    /// The size of the file at `url` as it is now (asked of the file
    /// system each time: a URL keeps what it was told before).
    private static func size(ofFileAt url: URL) -> Int? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue
    }

    /// The bytes of the recording at `url`: not more than `largest`, and
    /// not none.
    static func bytes(ofFileAt url: URL) throws -> Data {
        if let size = size(ofFileAt: url), size > largest { throw TranscriptionFailure.tooLarge }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { throw TranscriptionFailure.nothingRecorded }
        guard data.count <= largest else { throw TranscriptionFailure.tooLarge }
        return data
    }
}

/// One way a recording can be put into words, and how it is asked.
nonisolated struct Transcriber {
    let source: TranscriptionSource
    let transcribe: @Sendable (_ recording: URL) async throws -> String

    init(source: TranscriptionSource, transcribe: @escaping @Sendable (_ recording: URL) async throws -> String) {
        self.source = source
        self.transcribe = transcribe
    }

    init(_ openAI: OpenAITranscriptionService) {
        self.init(source: .openai) { try await openAI.transcribe(fileAt: $0) }
    }

    init(_ google: GoogleTranscriptionService) {
        self.init(source: .google) { try await google.transcribe(fileAt: $0) }
    }

    init(_ device: DeviceTranscriptionService) {
        self.init(source: .device) { try await device.transcribe(fileAt: $0) }
    }
}

/// Puts a voice message into words with whatever of the person's can:
/// a key that can transcribe where there is one, and this device where
/// there is none or none of them did.
nonisolated enum VoiceTranscription {
    /// What was heard, and what heard it.
    struct Heard: Equatable {
        let text: String
        let source: TranscriptionSource
    }

    /// Why no words came of a recording: what the first thing asked said,
    /// which is the one the person can do something about.
    struct Unheard: LocalizedError, Equatable {
        let source: TranscriptionSource
        let message: String

        var errorDescription: String? {
            message
        }
    }

    /// Everything that can transcribe for the signed-in person, in the
    /// order it is asked: their OpenAI key, their Google key, then this
    /// device. Tests give transcribers that answer from a script.
    @MainActor
    static func transcribersWithTheStoredKeys() -> [Transcriber] {
        var transcribers: [Transcriber] = []
        if let key = ProviderAccountService.apiKeyFromKeychain(forProvider: "openai"), !key.isEmpty {
            transcribers.append(Transcriber(OpenAITranscriptionService(apiKey: key)))
        }
        if let key = ProviderAccountService.apiKeyFromKeychain(forProvider: "google"), !key.isEmpty {
            transcribers.append(Transcriber(GoogleTranscriptionService(apiKey: key)))
        }
        transcribers.append(Transcriber(DeviceTranscriptionService()))
        return transcribers
    }

    /// The order transcribers are asked in: the one of the provider the
    /// message is going to first (as the cloud app asks the thread's own
    /// account first), the rest as given, and the device always last.
    /// `onDeviceOnly` leaves only the device: a message going to a model
    /// on this device or this network is not sent to a provider to be
    /// heard.
    static func ordered(_ transcribers: [Transcriber], preferring preferred: TranscriptionSource?, onDeviceOnly: Bool = false) -> [Transcriber] {
        let keyed = onDeviceOnly ? [] : transcribers.filter { $0.source != .device }
        let first = keyed.filter { $0.source == preferred }
        let rest = keyed.filter { $0.source != preferred }
        return first + rest + transcribers.filter { $0.source == .device }
    }

    /// The words of the recording at `url`, from the first transcriber
    /// that hears any. One that fails is passed over for the next; one
    /// that listened and heard no words ends the asking, and so does a
    /// stop. If none gives words, what the first one said is thrown
    /// (`Unheard`).
    static func transcribe(_ url: URL, with transcribers: [Transcriber], preferring preferred: TranscriptionSource? = nil, onDeviceOnly: Bool = false) async throws -> Heard {
        var first: Unheard?
        for transcriber in ordered(transcribers, preferring: preferred, onDeviceOnly: onDeviceOnly) {
            try Task.checkCancellation()
            do {
                let text = try await transcriber.transcribe(url).trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                guard !text.isEmpty else { throw TranscriptionFailure.noWords }
                return Heard(text: text, source: transcriber.source)
            } catch {
                // Stopped, however that showed.
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                let unheard = Unheard(source: transcriber.source, message: said(error, of: transcriber.source) + (whatElse(after: error, onDeviceOnly: onDeviceOnly).map { " \($0)" } ?? ""))
                // A recording with nothing in it, or one that was listened
                // to and held no words, is so whoever is asked next.
                // (What is told is still what the first one asked said.)
                switch error as? TranscriptionFailure {
                case .nothingRecorded, .noWords: throw first ?? unheard
                default: first = first ?? unheard
                }
            }
        }
        // Stopped with no one to ask is still stopped.
        try Task.checkCancellation()
        throw first ?? Unheard(source: .device, message: "There is nothing to transcribe with.")
    }

    /// What else the person is told where this device cannot hear the
    /// recording itself: that a key would (true only where keys are asked
    /// at all), or why none is asked. (It is the first failure only where
    /// no key was there to be asked before it.)
    static func whatElse(after error: Error, onDeviceOnly: Bool) -> String? {
        switch error as? TranscriptionFailure {
        case .speechNotAllowed, .notOnThisDevice:
            onDeviceOnly
                ? "A message for a model on this device or network is transcribed on this device only."
                : "An OpenAI or Google key that can transcribe would be used instead."
        default:
            nil
        }
    }

    /// What a failure is told as, naming what was asked.
    static func said(_ error: Error, of source: TranscriptionSource) -> String {
        if let failure = error as? TranscriptionFailure { return failure.said(of: source) }
        if error is URLError { return "\(source.displayName) could not be reached." }
        return "\(source.displayName) could not transcribe the recording."
    }
}
