import Foundation
import Speech

/// Puts a recording into words on this device, with the system's speech
/// recognition. It is asked to work on the device only: the recording is
/// not sent to anyone, and a language the device cannot recognise on its
/// own is not transcribed here.
nonisolated struct DeviceTranscriptionService {
    typealias Failure = TranscriptionFailure

    /// The language that is listened for: the person's own.
    var locale: Locale = .current

    /// Whether the person lets the app recognise speech, asking them the
    /// first time.
    static func isAllowed() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            true
        case .notDetermined:
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            false
        }
    }

    /// The name of the language listened for, as the person reads it.
    var language: String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// The words of the recording at `url`.
    func transcribe(fileAt url: URL) async throws -> String {
        // A recording with nothing in it is told so before anyone is asked.
        _ = try VoiceAudio.bytes(ofFileAt: url)
        guard await Self.isAllowed() else { throw Failure.speechNotAllowed }
        try Task.checkCancellation()
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            throw Failure.notOnThisDevice(language: language)
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        // The recogniser is kept for as long as it listens.
        let running = Running(recognizer)
        let heard: String
        do {
            heard = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    running.waiting(continuation)
                    let task = recognizer.recognitionTask(with: request) { result, error in
                        if let error {
                            running.finish(.failure(error))
                        } else if let result, result.isFinal {
                            running.finish(.success(result.bestTranscription.formattedString))
                        }
                    }
                    running.started(task)
                }
            } onCancel: {
                running.cancel()
            }
        } catch {
            // Stopped, however the system told it.
            if Task.isCancelled { throw CancellationError() }
            throw Self.failure(of: error)
        }
        try Task.checkCancellation()
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.noWords }
        return text
    }

    /// What the system's "no speech was found" reads as: no words, and
    /// any other failure with what the system said of it.
    static func failure(of error: Error) -> Error {
        if error is CancellationError || error is Failure { return error }
        let system = error as NSError
        // 1110: no speech detected; 203: nothing recognised to return.
        if system.domain == "kAFAssistantErrorDomain", [1110, 203].contains(system.code) { return Failure.noWords }
        return Failure.deviceFailed(message: String(system.localizedDescription.prefix(300)))
    }

    /// One recognition under way: it answers once, and can be called off
    /// (which answers it, whether or not the system then does). Sendable
    /// by hand, under `lock`.
    private final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private let recognizer: SFSpeechRecognizer
        private var task: SFSpeechRecognitionTask?
        private var continuation: CheckedContinuation<String, Error>?
        private var cancelled = false

        init(_ recognizer: SFSpeechRecognizer) {
            self.recognizer = recognizer
        }

        func waiting(_ continuation: CheckedContinuation<String, Error>) {
            lock.withLock { self.continuation = continuation }
        }

        func started(_ task: SFSpeechRecognitionTask) {
            let callOff = lock.withLock {
                self.task = task
                return cancelled
            }
            if callOff { task.cancel() }
        }

        /// Answers the one waiting, the first time only.
        func finish(_ answer: Result<String, Error>) {
            let waiting = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(with: answer)
        }

        func cancel() {
            let task = lock.withLock {
                cancelled = true
                return self.task
            }
            task?.cancel()
            finish(.failure(CancellationError()))
        }
    }
}
