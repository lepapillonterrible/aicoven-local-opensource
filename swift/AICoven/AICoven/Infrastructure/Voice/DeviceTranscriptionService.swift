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
        try VoiceAudio.check(fileAt: url)
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
        defer { withExtendedLifetime(recognizer) {} }
        let awaited = AwaitedOnce<String>()
        let heard: String
        do {
            heard = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    // Stopped already: it is answered so, and nothing is started.
                    guard awaited.waiting(continuation) else { return }
                    let task = recognizer.recognitionTask(with: request) { result, error in
                        if let error {
                            awaited.finish(.failure(error))
                        } else if let result, result.isFinal {
                            awaited.finish(.success(result.bestTranscription.formattedString))
                        }
                    }
                    awaited.whenStopped { task.cancel() }
                }
            } onCancel: {
                awaited.stop()
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
}

/// One answer that is waited for once, and that a stop answers if it comes
/// first: before anyone waits, while they wait, or as the answer arrives.
/// Whoever waits is answered exactly once. Sendable by hand, under `lock`.
final nonisolated class AwaitedOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var callOff: (() -> Void)?
    private var stopped = false

    /// Takes the one who waits. False if it was stopped already: they
    /// have been answered so, and there is nothing to start.
    func waiting(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        let stoppedAlready = lock.withLock {
            if !stopped { self.continuation = continuation }
            return stopped
        }
        if stoppedAlready { continuation.resume(throwing: CancellationError()) }
        return !stoppedAlready
    }

    /// What calls the work off on a stop; run at once if it has been
    /// stopped meanwhile.
    func whenStopped(_ callOff: @escaping () -> Void) {
        let now = lock.withLock {
            if !stopped { self.callOff = callOff }
            return stopped
        }
        if now { callOff() }
    }

    /// Answers the one waiting, the first time only.
    func finish(_ answer: Result<Value, Error>) {
        let waiting = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: answer)
    }

    /// Calls the work off and answers the one waiting that it was stopped.
    func stop() {
        let callOff = lock.withLock {
            stopped = true
            defer { self.callOff = nil }
            return self.callOff
        }
        callOff?()
        finish(.failure(CancellationError()))
    }
}
