import Foundation

/// What holding to talk does, in one place, so that the touch gesture and
/// the Mac's Space key do not come to differ.
nonisolated enum VoiceHoldToTalkPolicy {
    enum ReleaseAction: Equatable {
        case send
        case cancel
        case none
    }

    /// How long Space is held in an empty field before it means talking;
    /// let go sooner, it types a space.
    static let spaceHoldDelay: Duration = .milliseconds(300)

    /// How far a finger moves from where it pressed before letting go
    /// cancels.
    static let cancelDistance: CGFloat = 72

    /// Holding Space never takes typing: it talks only while the composer
    /// is otherwise idle and holds no text. Once a press has begun (the
    /// recording starting, or running), letting go and Esc still count
    /// though the composer is by then busy.
    static func isMacSpaceHoldEligible(
        messageText: String,
        isDisabled: Bool,
        isVoiceBusy: Bool,
        isRecordingVoice: Bool,
        isPressActive: Bool = false,
        isAttaching: Bool,
        hasVoiceCallbacks: Bool
    ) -> Bool {
        guard hasVoiceCallbacks else { return false }
        guard messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !isAttaching else { return false }
        if isRecordingVoice || isPressActive { return true }
        return !isDisabled && !isVoiceBusy
    }

    static func releaseAction(isRecordingVoice: Bool, wasPressActive: Bool, wasCancelled: Bool) -> ReleaseAction {
        guard isRecordingVoice || wasPressActive else { return .none }
        return wasCancelled ? .cancel : .send
    }

    /// Whether the mic is off. While a recording runs, or a press of it
    /// is under way (the recording still starting), it stays on: it is
    /// how the recording is sent or called off. Not during a send.
    static func isMicDisabled(
        isRecordingVoice: Bool,
        isPressActive: Bool = false,
        isVoiceBusy: Bool,
        isDisabled: Bool,
        isSubmittingSend: Bool,
        isAttaching: Bool,
        hasVoiceCallbacks: Bool
    ) -> Bool {
        if isSubmittingSend || !hasVoiceCallbacks || isAttaching { return true }
        if isRecordingVoice || isPressActive { return false }
        return isVoiceBusy || isDisabled
    }
}
