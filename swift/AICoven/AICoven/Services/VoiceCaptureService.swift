import AVFoundation
import Foundation

nonisolated enum VoiceCaptureError: LocalizedError, Equatable {
    case permissionDenied
    case recordingAlreadyActive
    case recorderStartFailed
    case notRecording
    case missingRecordingFile

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Microphone access is required to record voice messages."
        case .recordingAlreadyActive:
            "A voice recording is already in progress."
        case .recorderStartFailed:
            "Unable to start voice recording."
        case .notRecording:
            "No voice recording is currently active."
        case .missingRecordingFile:
            "The recorded audio file could not be found."
        }
    }
}

/// What records a voice message. Tests give one that records nothing.
@MainActor
protocol VoiceCapturing: AnyObject {
    /// Starts recording, asking for the microphone the first time.
    func startRecording() async throws
    /// Ends the recording; where it was written. The caller removes it.
    func stopRecording() throws -> URL
    /// Ends the recording and removes what was written.
    func cancelRecording()
    /// Told when the recording ended itself, at its longest.
    var onReachedLongest: (() -> Void)? { get set }
}

/// Records a voice message from the microphone into a file of its own in
/// the temporary folder: AAC in an MPEG-4 file, as the cloud app records.
@MainActor
final class VoiceCaptureService: NSObject, VoiceCapturing, AVAudioRecorderDelegate {
    /// The longest a recording runs: at its bitrate, under what is sent to
    /// be transcribed (`VoiceAudio.largest`). It then ends itself.
    nonisolated static let longest: TimeInterval = 9 * 60

    private(set) var isRecording = false
    var onReachedLongest: (() -> Void)?

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

    func startRecording() async throws {
        guard !isRecording else { throw VoiceCaptureError.recordingAlreadyActive }

        let granted = await Self.requestMicrophonePermission()
        guard granted else { throw VoiceCaptureError.permissionDenied }
        // Started again, or called off, while the person was asked.
        guard !isRecording else { throw VoiceCaptureError.recordingAlreadyActive }
        try Task.checkCancellation()

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let destination = Self.makeRecordingURL()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 128_000
        ]
        do {
            let recorder = try AVAudioRecorder(url: destination, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = false
            guard recorder.prepareToRecord(), recorder.record(forDuration: Self.longest) else {
                throw VoiceCaptureError.recorderStartFailed
            }
            self.recorder = recorder
            recordingURL = destination
            isRecording = true
        } catch {
            try? FileManager.default.removeItem(at: destination)
            Self.endAudioSession()
            throw error
        }
    }

    func stopRecording() throws -> URL {
        guard isRecording else { throw VoiceCaptureError.notRecording }
        recorder?.stop()
        isRecording = false
        Self.endAudioSession()
        guard let output = recordingURL else {
            reset(keepFile: false)
            throw VoiceCaptureError.missingRecordingFile
        }
        reset(keepFile: true)
        return output
    }

    func cancelRecording() {
        guard isRecording else {
            reset(keepFile: false)
            return
        }
        recorder?.stop()
        isRecording = false
        reset(keepFile: false)
        Self.endAudioSession()
    }

    private static func endAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private nonisolated static func requestMicrophonePermission() async -> Bool {
        #if os(iOS)
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        #elseif os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
        #else
        return false
        #endif
    }

    private func reset(keepFile: Bool) {
        let previous = recordingURL
        recorder?.delegate = nil
        recorder = nil
        recordingURL = nil
        if !keepFile, let previous {
            try? FileManager.default.removeItem(at: previous)
        }
    }

    /// The recorder ended on its own: at its longest (its file is whole),
    /// or because it could not go on.
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard self.isRecording, self.recorder === recorder else { return }
            self.onReachedLongest?()
        }
    }

    private static func makeRecordingURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("voice-note-\(UUID().uuidString).m4a")
    }
}
