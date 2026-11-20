internal import Combine
import Foundation
import SwiftUI

/// A thread's voice messages: records one, has it put into words, and
/// hands the words to the thread's view to send as a message. The words
/// are sent like typed ones; the recording is not kept.
///
/// A recording belongs to the thread and the account it was started in.
/// What was heard is handed on only while that account is still the one
/// signed in, and says which thread it is for.
@MainActor
final class VoiceMessages: ObservableObject {
    /// Where a voice message is going: the thread, and who answers there.
    struct Destination: Equatable {
        let threadID: String
        var roleID: String?
        var agentName: String?
    }

    /// How a recording is put into words: whose key is asked first, and
    /// whether only this device is asked.
    struct Route: Equatable {
        var preferring: TranscriptionSource?
        var onDeviceOnly = false
    }

    /// The words of a voice message, to be sent to their thread.
    struct Heard: Equatable, Identifiable {
        let id = UUID()
        let text: String
        let destination: Destination
        /// Whose words they are: they are sent only as that account.
        let account: String

        static func == (lhs: Heard, rhs: Heard) -> Bool {
            lhs.id == rhs.id
        }
    }

    /// A recording is running.
    @Published private(set) var isRecording = false
    /// A recording is being started, or one is being put into words.
    @Published private(set) var isBusy = false
    /// Why the last voice message was not sent, for the person.
    @Published private(set) var failure: String?
    /// The thread that voice message was for: it is shown there only.
    private(set) var failureThreadID: String?
    /// Words waiting to be sent by the thread's view (`takeHeard`).
    @Published private(set) var heard: Heard?

    /// What is said of a recording too short to hold anything.
    nonisolated static let tooShort = "That recording was too short to send."
    /// Why words heard for a thread that has left the screen were not sent.
    nonisolated static let leftTheThread = "The thread was left before your voice message was ready."

    private let capture: VoiceCapturing
    private let currentUser: () -> String
    private let route: (Destination) async -> Route
    private let transcribe: (URL, Route) async throws -> VoiceTranscription.Heard
    private let keep: @MainActor (_ text: String, _ threadID: String) -> Void
    /// A recording shorter than this is a slip of the finger (or was let
    /// go of while the person was asked for the microphone): not sent.
    private let shortest: Duration
    private var startedAt: ContinuousClock.Instant?
    /// The thread's view is on screen to send what is heard.
    private var isShown = true

    /// The thread and the account the recording under way is for.
    private var owner: (destination: Destination, account: String)?
    private var startTask: Task<Void, Never>?
    private var workTask: Task<Void, Never>?

    init(
        capture: VoiceCapturing? = nil,
        currentUser: @escaping () -> String = { UserScope.currentUserID },
        route: @escaping (Destination) async -> Route = { await ChatService.shared.voiceRoute(roleID: $0.roleID) },
        transcribe: @escaping (URL, Route) async throws -> VoiceTranscription.Heard = { url, route in
            try await VoiceTranscription.transcribe(
                url,
                with: VoiceTranscription.transcribersWithTheStoredKeys(),
                preferring: route.preferring,
                onDeviceOnly: route.onDeviceOnly
            )
        },
        keep: @escaping @MainActor (_ text: String, _ threadID: String) -> Void = { text, threadID in
            TurnEngine.shared.keepUnsent(text, for: threadID, because: VoiceMessages.leftTheThread)
        },
        shortest: Duration = .milliseconds(500)
    ) {
        let capture = capture ?? VoiceCaptureService()
        self.capture = capture
        self.currentUser = currentUser
        self.route = route
        self.transcribe = transcribe
        self.keep = keep
        self.shortest = shortest
        // A recording that ended itself at its longest is sent as it is.
        capture.onReachedLongest = { [weak self] in self?.stop() }
    }

    /// Starts recording a message for `destination`.
    func start(for destination: Destination) {
        guard !isRecording, !isBusy, startTask == nil else { return }
        failure = nil
        let account = currentUser()
        isBusy = true
        startTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.startTask = nil
                self.isBusy = false
            }
            do {
                try await capture.startRecording()
                // The account changed while the person was asked for the
                // microphone: this is no longer theirs to record.
                guard currentUser() == account else {
                    capture.cancelRecording()
                    return
                }
                owner = (destination, account)
                startedAt = .now
                isRecording = true
                AccessibilityAnnouncements.say("Listening")
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                // Said only to the one who asked.
                guard currentUser() == account else { return }
                say("Unable to start recording: \(error.localizedDescription)", for: destination.threadID)
            }
        }
    }

    /// Ends the recording and has it put into words, to be sent.
    func stop() {
        guard workTask == nil else { return }
        workTask = Task { [weak self] in
            guard let self else { return }
            defer { self.workTask = nil }
            await startTask?.value
            guard isRecording else { return }
            await submit()
        }
    }

    /// Ends the recording and sends nothing. (A message already being
    /// put into words is not a recording any more, and goes on.)
    func cancel() {
        guard isRecording || startTask != nil else { return }
        failure = nil
        Task { [weak self] in
            guard let self else { return }
            await startTask?.value
            let wasRecording = isRecording
            capture.cancelRecording()
            isRecording = false
            owner = nil
            if wasRecording { AccessibilityAnnouncements.say("Voice message cancelled") }
        }
    }

    /// Whether the thread's view is on screen. What is heard while it is
    /// not is kept for its thread, to come back with it, and not sent
    /// unseen.
    func setShown(_ shown: Bool) {
        isShown = shown
    }

    /// The words waiting to be sent, once.
    func takeHeard() -> Heard? {
        defer { heard = nil }
        return heard
    }

    func clearFailure() {
        failure = nil
        failureThreadID = nil
    }

    private func submit() async {
        guard let owner else {
            capture.cancelRecording()
            isRecording = false
            return
        }
        self.owner = nil
        // Too short to hold anything: ended, and said so.
        if let startedAt, ContinuousClock.now - startedAt < shortest {
            capture.cancelRecording()
            isRecording = false
            say(Self.tooShort, for: owner.destination.threadID)
            return
        }
        isBusy = true
        defer { isBusy = false }
        AccessibilityAnnouncements.say("Sending your voice message…")
        let recording: URL
        do {
            recording = try capture.stopRecording()
            isRecording = false
        } catch {
            isRecording = false
            say("Voice message failed: \(error.localizedDescription)", for: owner.destination.threadID)
            return
        }
        defer { try? FileManager.default.removeItem(at: recording) }
        // Only for the account that recorded it, and to nowhere while
        // another is signed in: its keys are not this recording's.
        guard currentUser() == owner.account, !Task.isCancelled else { return }
        do {
            let route = await route(owner.destination)
            guard currentUser() == owner.account, !Task.isCancelled else { return }
            let words = try await transcribe(recording, route)
            guard currentUser() == owner.account, !Task.isCancelled else { return }
            if isShown {
                heard = Heard(text: words.text, destination: owner.destination, account: owner.account)
            } else {
                keep(words.text, owner.destination.threadID)
            }
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            guard currentUser() == owner.account else { return }
            if let unheard = error as? VoiceTranscription.Unheard {
                say(unheard.message, for: owner.destination.threadID)
            } else {
                say("Voice message failed: \(error.localizedDescription)", for: owner.destination.threadID)
            }
        }
    }

    /// Why the last voice message for this thread was not sent; nil for
    /// any other thread (the person may have moved on while it was heard).
    func failure(for threadID: String) -> String? {
        failureThreadID == threadID ? failure : nil
    }

    private func say(_ message: String, for threadID: String) {
        failureThreadID = threadID
        failure = message
        AccessibilityAnnouncements.say(message)
    }
}

/// Tells VoiceOver what changed on screen without taking focus.
enum AccessibilityAnnouncements {
    @MainActor
    static func say(_ message: String?) {
        guard let message, !message.isEmpty else { return }
        AccessibilityNotification.Announcement(message).post()
    }
}
