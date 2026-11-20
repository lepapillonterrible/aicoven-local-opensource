@testable import AICoven
import XCTest

/// A voice message is recorded, put into words, and handed to its thread
/// to be sent, for the account and the thread it was started in.
@MainActor
final class VoiceMessagesTests: XCTestCase {

    // MARK: - Holding to talk

    func testMacSpaceHoldRequiresVoiceCallbacksAndIdleComposer() {
        func eligible(text: String = "", isDisabled: Bool = false, isVoiceBusy: Bool = false, isRecordingVoice: Bool = false, isAttaching: Bool = false, hasVoiceCallbacks: Bool = true) -> Bool {
            VoiceHoldToTalkPolicy.isMacSpaceHoldEligible(messageText: text, isDisabled: isDisabled, isVoiceBusy: isVoiceBusy, isRecordingVoice: isRecordingVoice, isAttaching: isAttaching, hasVoiceCallbacks: hasVoiceCallbacks)
        }
        XCTAssertTrue(eligible())
        XCTAssertTrue(eligible(text: "  \n"))
        XCTAssertFalse(eligible(text: "Hello"), "Space never takes typing")
        XCTAssertFalse(eligible(hasVoiceCallbacks: false))
        XCTAssertFalse(eligible(isDisabled: true))
        XCTAssertFalse(eligible(isVoiceBusy: true))
        XCTAssertFalse(eligible(isAttaching: true))
    }

    func testMacSpaceHoldAllowsReleaseWhileRecordingEvenIfBusy() {
        XCTAssertTrue(VoiceHoldToTalkPolicy.isMacSpaceHoldEligible(messageText: "", isDisabled: true, isVoiceBusy: true, isRecordingVoice: true, isAttaching: false, hasVoiceCallbacks: true))
        // While the recording is still starting (busy, not yet recording),
        // letting go and Esc must still reach the composer.
        XCTAssertTrue(VoiceHoldToTalkPolicy.isMacSpaceHoldEligible(messageText: "", isDisabled: false, isVoiceBusy: true, isRecordingVoice: false, isPressActive: true, isAttaching: false, hasVoiceCallbacks: true))
        XCTAssertFalse(VoiceHoldToTalkPolicy.isMacSpaceHoldEligible(messageText: "", isDisabled: false, isVoiceBusy: true, isRecordingVoice: false, isPressActive: false, isAttaching: false, hasVoiceCallbacks: true))
        XCTAssertFalse(VoiceHoldToTalkPolicy.isMicDisabled(isRecordingVoice: false, isPressActive: true, isVoiceBusy: true, isDisabled: false, isSubmittingSend: false, isAttaching: false, hasVoiceCallbacks: true), "A finger on the mic keeps it on while the recording starts")
        XCTAssertTrue(VoiceHoldToTalkPolicy.isMicDisabled(isRecordingVoice: false, isPressActive: true, isVoiceBusy: true, isDisabled: false, isSubmittingSend: true, isAttaching: false, hasVoiceCallbacks: true))
    }

    func testWordsAreSentOnlyIntoTheThreadTheyWereSaidIn_whileItIsOnScreen() {
        XCTAssertTrue(PersonalChatView.sendsVoiceMessage(for: "a", shown: "a", thread: "a", isOnScreen: true))
        XCTAssertFalse(PersonalChatView.sendsVoiceMessage(for: "a", shown: "a", thread: "a", isOnScreen: false), "The thread's view has gone")
        XCTAssertFalse(PersonalChatView.sendsVoiceMessage(for: "a", shown: "b", thread: "b", isOnScreen: true))
        XCTAssertFalse(PersonalChatView.sendsVoiceMessage(for: "a", shown: "a", thread: "b", isOnScreen: true))
        XCTAssertFalse(PersonalChatView.sendsVoiceMessage(for: "a", shown: nil, thread: "a", isOnScreen: true))
    }

    func testTheRouteIsByTheProviderATurnIsFor() {
        XCTAssertEqual(ChatService.voiceRoute(provider: "openai", isLocal: false), .init(preferring: .openai, onDeviceOnly: false))
        XCTAssertEqual(ChatService.voiceRoute(provider: "gemini", isLocal: false), .init(preferring: .google, onDeviceOnly: false))
        XCTAssertEqual(ChatService.voiceRoute(provider: "anthropic", isLocal: false), .init(preferring: nil, onDeviceOnly: false))
        XCTAssertEqual(ChatService.voiceRoute(provider: "ollama", isLocal: true), .init(preferring: nil, onDeviceOnly: true), "What is said to a local model goes to no provider")
        XCTAssertEqual(ChatService.voiceRoute(provider: "openai_compatible", isLocal: true), .init(preferring: nil, onDeviceOnly: true))
    }

    func testReleaseActionSendsOnlyWhenRecordingWasNotCancelled() {
        XCTAssertEqual(VoiceHoldToTalkPolicy.releaseAction(isRecordingVoice: true, wasPressActive: true, wasCancelled: false), .send)
        XCTAssertEqual(VoiceHoldToTalkPolicy.releaseAction(isRecordingVoice: false, wasPressActive: true, wasCancelled: false), .send, "Let go while the recording is still starting")
        XCTAssertEqual(VoiceHoldToTalkPolicy.releaseAction(isRecordingVoice: true, wasPressActive: true, wasCancelled: true), .cancel)
        XCTAssertEqual(VoiceHoldToTalkPolicy.releaseAction(isRecordingVoice: false, wasPressActive: false, wasCancelled: false), .none)
    }

    func testWhenTheMicIsOff() {
        func off(isRecordingVoice: Bool = false, isVoiceBusy: Bool = false, isDisabled: Bool = false, isSubmittingSend: Bool = false, isAttaching: Bool = false, hasVoiceCallbacks: Bool = true) -> Bool {
            VoiceHoldToTalkPolicy.isMicDisabled(isRecordingVoice: isRecordingVoice, isVoiceBusy: isVoiceBusy, isDisabled: isDisabled, isSubmittingSend: isSubmittingSend, isAttaching: isAttaching, hasVoiceCallbacks: hasVoiceCallbacks)
        }
        XCTAssertFalse(off())
        XCTAssertTrue(off(hasVoiceCallbacks: false))
        XCTAssertTrue(off(isVoiceBusy: true))
        XCTAssertTrue(off(isDisabled: true))
        XCTAssertTrue(off(isSubmittingSend: true))
        XCTAssertTrue(off(isAttaching: true))
        // While recording it stays on: it is how the recording is sent.
        XCTAssertFalse(off(isRecordingVoice: true, isVoiceBusy: true, isDisabled: true))
        XCTAssertTrue(off(isRecordingVoice: true, isSubmittingSend: true))
    }

    func testTheSlotAndSendWhileAVoiceMessageIsRecorded() {
        XCTAssertEqual(ComposerRules.slot(text: "", isAgentRunning: true, canStop: true), .stop)
        XCTAssertEqual(ComposerRules.slot(text: "", isAgentRunning: true, canStop: true, isRecordingVoice: true), .send, "Stop would stop the turn, not the recording")
        XCTAssertTrue(ComposerRules.canSend(text: "Hi", isDisabled: false, isBusy: false))
        XCTAssertFalse(ComposerRules.canSend(text: "Hi", isDisabled: false, isBusy: false, isRecordingVoice: true))
        XCTAssertNil(PersonalChatView.notice(notSent: nil, voice: nil))
        XCTAssertEqual(PersonalChatView.notice(notSent: "Not sent.", voice: nil), "Not sent.")
        XCTAssertEqual(PersonalChatView.notice(notSent: "Not sent.", voice: "No words were heard in the recording."), "Not sent.\nNo words were heard in the recording.")
        XCTAssertEqual(PersonalChatView.notice(notSent: "", voice: "No mic."), "No mic.")
    }

    // MARK: - A recorder that records nothing

    private final class FakeCapture: VoiceCapturing {
        var onReachedLongest: (() -> Void)?
        private(set) var isRecording = false
        private(set) var started = 0
        private(set) var cancelled = 0
        private(set) var written: [URL] = []
        var startFailure: Error?
        /// Held until the test lets the start go on (the person being
        /// asked for the microphone).
        var beforeStarting: (() async -> Void)?

        func startRecording() async throws {
            await beforeStarting?()
            if let startFailure { throw startFailure }
            started += 1
            isRecording = true
        }

        func stopRecording() throws -> URL {
            guard isRecording else { throw VoiceCaptureError.notRecording }
            isRecording = false
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("voice-note-test-\(UUID().uuidString).m4a")
            try Data("audio".utf8).write(to: file)
            written.append(file)
            return file
        }

        func cancelRecording() {
            if isRecording { cancelled += 1 }
            isRecording = false
        }
    }

    /// Who is signed in, which a test can change under way.
    private final class Account {
        var id = "ada"
    }

    /// What was kept for a thread whose view had left the screen.
    private final class Kept {
        var words: [(text: String, threadID: String)] = []
    }

    private struct World {
        let voice: VoiceMessages
        let capture: FakeCapture
        let account: Account
        let kept: Kept
    }

    private let here = VoiceMessages.Destination(threadID: "thread-1", roleID: "role-1", agentName: "Strix")

    private func world(
        route: VoiceMessages.Route = .init(preferring: .openai),
        shortest: Duration = .zero,
        transcribe: @escaping (URL, VoiceMessages.Route) async throws -> VoiceTranscription.Heard = { _, _ in .init(text: "Hello there.", source: .openai) }
    ) -> World {
        let capture = FakeCapture()
        let account = Account()
        let kept = Kept()
        let voice = VoiceMessages(capture: capture, currentUser: { account.id }, route: { _ in route }, transcribe: transcribe, keep: { kept.words.append(($0, $1)) }, shortest: shortest)
        return World(voice: voice, capture: capture, account: account, kept: kept)
    }

    /// Waits until `done`, for what the controller does in tasks of its own.
    private func wait(_ what: String, until done: @MainActor () -> Bool) async {
        for _ in 0 ..< 2000 where !done() {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(done(), what)
    }

    // MARK: - Recording and sending

    func testARecording_isPutIntoWords_andHandedToItsThreadOnce() async {
        var routed: [VoiceMessages.Route] = []
        var heardFile: URL?
        let world = world(route: .init(preferring: .google, onDeviceOnly: true)) { url, route in
            routed.append(route)
            heardFile = url
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "The recording is there while it is listened to")
            return .init(text: "Send this at nine.", source: .device)
        }

        world.voice.start(for: here)
        XCTAssertTrue(world.voice.isBusy, "Starting")
        await wait("recording") { world.voice.isRecording }
        XCTAssertFalse(world.voice.isBusy)

        world.voice.stop()
        await wait("heard") { world.voice.heard != nil }

        XCTAssertFalse(world.voice.isRecording)
        XCTAssertFalse(world.voice.isBusy)
        XCTAssertNil(world.voice.failure)
        XCTAssertEqual(routed, [.init(preferring: .google, onDeviceOnly: true)], "Heard as the thread's model has it")
        let heard = world.voice.takeHeard()
        XCTAssertEqual(heard?.text, "Send this at nine.")
        XCTAssertEqual(heard?.destination, here)
        XCTAssertEqual(heard?.account, "ada", "Whose words they are goes with them")
        XCTAssertNil(world.voice.takeHeard(), "Taken once")
        XCTAssertNil(world.voice.heard)
        let file = try? XCTUnwrap(heardFile)
        XCTAssertEqual(file.map { FileManager.default.fileExists(atPath: $0.path) }, false, "The recording is not kept")
    }

    func testLettingGoBeforeTheRecordingHasStarted_stillSendsIt_andCancellingThenSendsNothing() async {
        // The person is asked for the microphone; they let go meanwhile.
        var world = world()
        var letGo: CheckedContinuation<Void, Never>?
        world.capture.beforeStarting = { await withCheckedContinuation { letGo = $0 } }
        world.voice.start(for: here)
        await wait("asked") { letGo != nil }
        world.voice.stop()
        XCTAssertNil(world.voice.heard)
        letGo?.resume()
        await wait("heard") { world.voice.heard != nil }
        XCTAssertEqual(world.voice.takeHeard()?.text, "Hello there.")

        // Called off meanwhile: the recording that then starts is ended, unsent.
        world = self.world()
        var calledOff: CheckedContinuation<Void, Never>?
        let capture = world.capture
        capture.beforeStarting = { await withCheckedContinuation { calledOff = $0 } }
        world.voice.start(for: here)
        await wait("asked") { calledOff != nil }
        world.voice.cancel()
        calledOff?.resume()
        await wait("called off") { capture.cancelled == 1 }
        XCTAssertFalse(world.voice.isRecording)
        XCTAssertNil(world.voice.heard)
        XCTAssertEqual(capture.written, [])
    }

    func testARecordingCalledOff_sendsNothing_andASecondStartWhileOneRunsDoesNothing() async {
        let world = world()
        world.voice.start(for: here)
        await wait("recording") { world.voice.isRecording }
        world.voice.start(for: .init(threadID: "thread-2"))
        XCTAssertEqual(world.capture.started, 1)

        world.voice.cancel()
        await wait("called off") { !world.voice.isRecording }
        XCTAssertEqual(world.capture.cancelled, 1)
        XCTAssertNil(world.voice.heard)
        XCTAssertNil(world.voice.failure)

        // With nothing recording, stopping and cancelling do nothing.
        world.voice.stop()
        world.voice.cancel()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(world.voice.heard)
        XCTAssertEqual(world.capture.written, [])
    }

    func testWhatIsSaidWhenAVoiceMessageFails() async {
        // The microphone is not allowed.
        var world = world()
        world.capture.startFailure = VoiceCaptureError.permissionDenied
        world.voice.start(for: here)
        await wait("failed") { world.voice.failure != nil }
        XCTAssertEqual(world.voice.failure, "Unable to start recording: Microphone access is required to record voice messages.")
        XCTAssertFalse(world.voice.isRecording)
        XCTAssertFalse(world.voice.isBusy)

        // A new try replaces what was said.
        world.capture.startFailure = nil
        world.voice.start(for: here)
        XCTAssertNil(world.voice.failure)
        await wait("recording") { world.voice.isRecording }
        world.voice.cancel()

        // No words came of it: what the transcriber said is said.
        world = self.world { _, _ in throw VoiceTranscription.Unheard(source: .openai, message: "OpenAI refused the key. Check the OpenAI connection in Settings.") }
        world.voice.start(for: here)
        await wait("recording") { world.voice.isRecording }
        world.voice.stop()
        await wait("failed") { world.voice.failure != nil }
        XCTAssertEqual(world.voice.failure, "OpenAI refused the key. Check the OpenAI connection in Settings.")
        XCTAssertNil(world.voice.heard)
        XCTAssertFalse(world.voice.isBusy)
        XCTAssertEqual(world.capture.written.filter { FileManager.default.fileExists(atPath: $0.path) }, [], "The recording is not kept")
        world.voice.clearFailure()
        XCTAssertNil(world.voice.failure)

        // A stop while it was put into words says nothing.
        world = self.world { _, _ in throw CancellationError() }
        world.voice.start(for: here)
        await wait("recording") { world.voice.isRecording }
        world.voice.stop()
        await wait("done") { !world.voice.isRecording && !world.voice.isBusy }
        XCTAssertNil(world.voice.failure)
        XCTAssertNil(world.voice.heard)
    }

    func testWhatWasRecordedAsOneAccount_isNotHandedOnAsAnother() async {
        // Another account signs in while the recording is put into words.
        var world = world()
        var transcribing: CheckedContinuation<VoiceTranscription.Heard, Error>?
        world = self.world { _, _ in try await withCheckedThrowingContinuation { transcribing = $0 } }
        world.voice.start(for: here)
        await wait("recording") { world.voice.isRecording }
        world.voice.stop()
        await wait("listening") { transcribing != nil }
        world.account.id = "grace"
        transcribing?.resume(returning: .init(text: "Ada's words.", source: .openai))
        await wait("done") { !world.voice.isBusy }
        XCTAssertNil(world.voice.heard, "Ada's words are not sent as Grace")
        XCTAssertNil(world.voice.failure)

        // Another account signs in while it is recorded: it is not listened to at all.
        var asked = 0
        world = self.world { _, _ in
            asked += 1
            return .init(text: "x", source: .openai)
        }
        world.voice.start(for: here)
        await wait("recording") { world.voice.isRecording }
        world.account.id = "grace"
        world.voice.stop()
        await wait("done") { !world.voice.isRecording && !world.voice.isBusy }
        XCTAssertEqual(asked, 0)
        XCTAssertNil(world.voice.heard)
        XCTAssertEqual(world.capture.written.filter { FileManager.default.fileExists(atPath: $0.path) }, [])

        // Another account signs in while the person is asked for the microphone.
        world = self.world()
        var allowed: CheckedContinuation<Void, Never>?
        let capture = world.capture
        capture.beforeStarting = { await withCheckedContinuation { allowed = $0 } }
        world.voice.start(for: here)
        await wait("asked") { allowed != nil }
        world.account.id = "grace"
        allowed?.resume()
        await wait("ended") { capture.cancelled == 1 }
        XCTAssertFalse(world.voice.isRecording)
    }

    func testWhatIsHeardAfterTheThreadLeftTheScreen_isKeptForIt_notSentUnseen() async {
        var transcribing: CheckedContinuation<VoiceTranscription.Heard, Error>?
        let world = world { _, _ in try await withCheckedThrowingContinuation { transcribing = $0 } }
        world.voice.start(for: here)
        await wait("recording") { world.voice.isRecording }
        world.voice.stop()
        await wait("listening") { transcribing != nil }
        // The thread's view goes (the person went back to the list).
        world.voice.cancel()
        world.voice.setShown(false)
        transcribing?.resume(returning: .init(text: "Kept words.", source: .device))
        await wait("kept") { !world.kept.words.isEmpty }
        XCTAssertEqual(world.kept.words.map(\.text), ["Kept words."])
        XCTAssertEqual(world.kept.words.map(\.threadID), ["thread-1"])
        XCTAssertNil(world.voice.heard)
        XCTAssertEqual(VoiceMessages.leftTheThread, "The thread was left before your voice message was ready.")
    }

    func testARecordingTooShortToHoldAnything_isNotSent_andSaysSo() async {
        var asked = 0
        let world = world(shortest: .seconds(3600)) { _, _ in
            asked += 1
            return .init(text: "x", source: .openai)
        }
        world.voice.start(for: here)
        await wait("recording") { world.voice.isRecording }
        world.voice.stop()
        await wait("said") { world.voice.failure != nil }
        XCTAssertEqual(world.voice.failure, "That recording was too short to send.")
        XCTAssertEqual(asked, 0)
        XCTAssertFalse(world.voice.isRecording)
        XCTAssertFalse(world.voice.isBusy)
        XCTAssertEqual(world.capture.cancelled, 1)
        XCTAssertEqual(world.capture.written, [], "Nothing was written to be listened to")
    }

    func testARecordingThatEndedItselfAtItsLongest_isSentAsItIs() async {
        let world = world()
        world.voice.start(for: here)
        await wait("recording") { world.voice.isRecording }
        world.capture.onReachedLongest?()
        await wait("heard") { world.voice.heard != nil }
        XCTAssertEqual(world.voice.takeHeard()?.destination, here)
        XCTAssertGreaterThan(VoiceAudio.largest, Int(VoiceCaptureService.longest) * 128_000 / 8, "The longest recording is under what is sent")
    }
}
