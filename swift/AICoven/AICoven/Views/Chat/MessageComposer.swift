import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// A role that can be @mentioned in a thread.
struct MentionableRole: Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String?
    /// The agent's face: its symbol, the key of its tint, and its provider.
    var iconSymbol: String?
    var iconTint: String?
    var provider: String?
}

/// What a composer holds unsent: its text and its attachments.
nonisolated struct ComposerDraft: Equatable {
    var text = ""
    var attachments: [FileAttachmentDetail] = []

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    /// This draft with `later` after it: the texts a blank line apart, an
    /// empty one left out, and the attachments one after the other.
    func followed(by later: ComposerDraft) -> ComposerDraft {
        let texts = [text, later.text].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return ComposerDraft(text: texts.joined(separator: "\n\n"), attachments: attachments + later.attachments)
    }
}

/// What the composer decides from its state, apart from how it draws it.
nonisolated enum ComposerRules {
    /// The most photos taken from the library at once.
    static let mostPhotosAtOnce = 10

    /// What a picture pasted or dropped as bytes is called; the store adds
    /// the extension of the kind it is kept as.
    static let pastedPictureName = "Pasted image"

    /// Whether something to attach is taken now. Never while an attaching
    /// is under way. What comes back from a chooser is otherwise taken:
    /// the (+) that opened it was on. What is pasted or dropped is not
    /// taken while a message is being sent or the composer is off.
    static func takesAttachments(isAttaching: Bool, isFromAChooser: Bool, isBusy: Bool, isDisabled: Bool) -> Bool {
        guard !isAttaching else { return false }
        return isFromAChooser || !(isBusy || isDisabled)
    }

    /// What a photo taken or picked is called: the library and the camera
    /// give it no name of its own.
    static func photoName(fileExtension: String?) -> String {
        guard let fileExtension, !fileExtension.isEmpty else { return "Photo" }
        return "Photo.\(fileExtension)"
    }

    /// What the trailing slot is.
    enum Slot: Equatable {
        case send
        case stop
    }

    /// One trailing place: Stop while a turn runs and the field is empty,
    /// Send otherwise, so the button under the pointer never moves. While
    /// a voice message is recorded it is Send (off): the mic sends it,
    /// and Stop would stop the turn, not the recording.
    static func slot(text: String, isAgentRunning: Bool, canStop: Bool, isRecordingVoice: Bool = false) -> Slot {
        isAgentRunning && canStop && !isRecordingVoice && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .stop : .send
    }

    /// Whether Send sends: there is text, and nothing is in its way. While
    /// a turn runs it sends too; the message then waits for the turn. Not
    /// while a voice message is recorded.
    static func canSend(text: String, isDisabled: Bool, isBusy: Bool, isRecordingVoice: Bool = false) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isDisabled && !isBusy && !isRecordingVoice
    }

    /// What the composer says of a message sent now, while a turn runs: it
    /// waits for the turn. Nothing when no turn runs.
    static func waitNote(isAgentRunning: Bool, runningName: String) -> String? {
        isAgentRunning ? "Sends when \(runningName) finishes" : nil
    }

    /// The unfinished "@query" the text ends in, or nil: suggestions show
    /// while there is one.
    static func mentionQuery(in text: String) -> String? {
        guard let atIndex = text.lastIndex(of: "@") else { return nil }
        let query = text[text.index(after: atIndex)...]
        guard !query.contains(where: { $0.isWhitespace || $0 == "@" }) else { return nil }
        return String(query)
    }

    /// The roles to suggest for a query: the first six whose name holds it,
    /// or the first six with no query.
    static func suggestions(for query: String, among roles: [MentionableRole]) -> [MentionableRole] {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return Array(roles.prefix(6)) }
        return Array(roles.filter { $0.name.lowercased().contains(wanted) }.prefix(6))
    }

    /// The text with its trailing "@query" replaced by "@Name ".
    static func inserting(mention name: String, into text: String) -> String {
        guard let atIndex = text.lastIndex(of: "@") else { return text }
        return String(text[..<atIndex]) + "@" + name + " "
    }
}

/// The one composer on the Mac, the iPad, and the iPhone: `(+) field
/// (mic) (Send | Stop)` in a raised stone box with rounded corners, who the
/// message goes to at its bottom left, no formatting controls.
///
/// While a turn runs the slot is Stop with an empty field and Send once
/// there is text; what is sent then waits (the parent queues it).
/// Return sends and Shift+Return starts a new line on the Mac and with a
/// hardware keyboard.
struct MessageComposer: View {
    @Binding var messageText: String
    /// The files to go with the message. The parent holds them with the
    /// text, as the thread's draft.
    @Binding var attachments: [FileAttachmentDetail]
    /// Sends the text with these attachments, or queues it while a turn
    /// runs. False if it was neither: the attachments then stay in the
    /// composer.
    let onSend: ([FileAttachmentDetail]) async -> Bool
    /// Stops the running turn; nil means this composer has no turn to stop.
    var onStop: (() -> Void)?
    /// The field and Send are off.
    var isDisabled: Bool = false
    /// The thread has a turn that has not ended.
    var isAgentRunning: Bool = false
    /// That turn is being stopped: Stop has been pressed already.
    var isStopping: Bool = false
    let threadId: String
    var mentionableRoles: [MentionableRole] = []
    /// Claims keyboard focus when the composer appears.
    var autoFocus: Bool = false
    /// Who the next message goes to.
    let recipientName: String
    /// The agents the message can go to, where there is a choice (a new
    /// thread in a coven); none shows no menu. `recipientID` is the one
    /// chosen.
    var recipientChoices: [Role] = []
    var recipientID: String?
    var onChooseRecipient: ((Role) -> Void)?
    /// The thread files attached here are kept under, where that is not
    /// `threadId`: a thread that is not made yet keeps them elsewhere
    /// until it is.
    var fileThread: (() async throws -> String)?
    /// Something the thread has to say above the box: why waiting messages
    /// were not sent. Whoever sets it announces it, once.
    var notice: String?
    /// Whether text and attachments were handed back to this thread's
    /// composer while it is on screen (waiting messages that were not
    /// sent, or one taken back to be edited), and how they are taken,
    /// once. What was handed back before the thread was opened comes with
    /// its draft, from the parent.
    var hasReturnedDraft: Bool = false
    var takeReturnedDraft: (() -> ComposerDraft?)?
    /// Told when the field takes or loses keyboard focus, and when Send
    /// is pressed with something to send: approvals are held back while
    /// the person composes.
    var onFocusChange: ((Bool) -> Void)?
    var onSent: (() -> Void)?
    /// Sets the field's text for the composer when it is not typed (what
    /// was handed back), so the parent does not take it for typing; nil
    /// sets it through the binding.
    var putInTheField: ((String) -> Void)?
    /// A voice message: starts recording one, ends it to be sent, or
    /// calls it off. With any of them nil the mic is off.
    var onVoiceRecordStart: (() -> Void)?
    var onVoiceRecordStop: (() -> Void)?
    var onVoiceRecordCancel: (() -> Void)?
    /// A voice message is being recorded.
    var isRecordingVoice: Bool = false
    /// One is being started, or put into words.
    var isVoiceBusy: Bool = false

    /// The attaching under way, if one is. Cleared when the composer moves
    /// to another thread, so files chosen for one thread are never taken
    /// into another's message.
    @State private var attachingTask: UUID?
    @State private var isSubmittingSend = false
    /// Why the last attachment could not be taken.
    @State private var attachFailure: String?
    @State private var showMentionSuggestions = false
    @State private var mentionQuery = ""
    /// The mic is held down (or was clicked on), and whether the finger
    /// has moved far enough away to call the recording off.
    @State private var isVoicePressActive = false
    @State private var isVoicePressCancelled = false
    #if os(iOS)
    /// A finger is on the mic now: its press ends when it is lifted.
    @State private var isFingerOnMic = false
    /// The touch on the mic, as the system has it: it goes false when the
    /// finger is lifted and also when the touch is taken away (a system
    /// prompt comes up over it), which ends no gesture.
    @GestureState private var isTouchingMic = false
    #endif
    #if os(macOS)
    /// The recording was started by holding Space, not by clicking the mic.
    @State private var isSpaceHoldRecording = false
    #endif
    #if os(iOS)
    @State private var showFileImporter = false
    @FocusState private var isTextFieldFocused: Bool
    @ScaledMetric(relativeTo: .body) private var phoneControlSide: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var padControlSide: CGFloat = 40
    #else
    @State private var macInputHeight: CGFloat = GrowingTextEditor.emptyHeight
    #endif
    /// The file chooser open, if one is. Cleared when the composer moves to
    /// another thread, which can happen under it (the Mac's panel does not
    /// block the window): what it then returns is not taken.
    @State private var choosingFiles: UUID?
    /// The photo library or the camera open, if one is. Cleared like
    /// `choosingFiles`; what was picked or taken for a thread the composer
    /// has left is not taken.
    @State private var choosingPictures: UUID?
    @State private var showPhotoLibrary = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    #if os(iOS)
    @State private var showCamera = false
    #endif

    private var isAttaching: Bool {
        attachingTask != nil
    }

    /// The Mac's file panel is open: it does not block the window, and a
    /// second one would leave the first's files untaken.
    private var isChoosingOnTheMac: Bool {
        #if os(macOS)
        choosingFiles != nil
        #else
        false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let notice {
                Text(notice)
                    .font(.aicovenBodySmall)
                    .foregroundStyle(Color.aicovenError)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("composer-notice")
            }
            if let attachFailure {
                Text(attachFailure)
                    .font(.aicovenBodySmall)
                    .foregroundStyle(Color.aicovenError)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("composer-error")
            }
            block
            if showMentionSuggestions, !suggestedRoles.isEmpty {
                mentionSuggestions
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        #if os(macOS)
            // Esc calls a recording off wherever in the composer the keyboard
            // is (on the mic, say), not only in the field.
            .onExitCommand {
                if isRecordingVoice || isVoicePressActive { cancelVoicePress() }
            }
        #endif
            .onChange(of: messageText) { _, _ in suggestMentions() }
            // A press that no finger holds (a click on the Mac, VoiceOver's
            // activation) has no letting go of its own: it is over when the
            // recording could not start, or has ended some other way.
            .onChange(of: isVoiceBusy) { _, busy in
                if !busy, !isRecordingVoice { endPressNoFingerHolds() }
            }
            .onChange(of: isRecordingVoice) { _, recording in
                if !recording { endPressNoFingerHolds() }
            }
            .onAppear(perform: takeReturned)
            .onChange(of: hasReturnedDraft) { _, _ in takeReturned() }
            // The composer is gone (its thread view replaced or popped): what
            // is still being chosen or attached for it is not taken.
            .onDisappear {
                attachingTask = nil
                choosingFiles = nil
                #if os(iOS)
                // The camera covers the whole screen, the composer with it:
                // the composer is not gone for that, and the photo is still
                // taken. If the composer does go, the camera goes with it.
                if !showCamera { choosingPictures = nil }
                #else
                choosingPictures = nil
                #endif
            }
            .onChange(of: threadId) { _, _ in
                // A recording does not follow the composer to another thread
                // (its owner calls it off); nor does a press of the mic.
                isVoicePressActive = false
                isVoicePressCancelled = false
                #if os(iOS)
                isFingerOnMic = false
                #endif
                attachingTask = nil
                attachFailure = nil
                choosingFiles = nil
                choosingPictures = nil
                showPhotoLibrary = false
                #if os(iOS)
                showFileImporter = false
                showCamera = false
                #endif
            }
            .photosPicker(
                isPresented: $showPhotoLibrary,
                selection: $pickedPhotos,
                maxSelectionCount: ComposerRules.mostPhotosAtOnce,
                selectionBehavior: .ordered,
                matching: .images,
                preferredItemEncoding: .current
            )
            .onChange(of: pickedPhotos) { _, picked in
                guard !picked.isEmpty else { return }
                pickedPhotos = []
                // For the library that is open, or not taken.
                guard let choosing = choosingPictures else { return }
                Task { await attach(picked.map(AttachSource.photo), chosen: (.pictures, choosing)) }
            }
        #if os(iOS)
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                // For the chooser that is open, or not taken: the one a
                // thread was left with is closed, and returns nothing here.
                guard let choosing = choosingFiles else { return }
                switch result {
                case let .success(urls):
                    Task { await attach(urls.map(AttachSource.file), chosen: (.files, choosing)) }
                case let .failure(error):
                    choosingFiles = nil
                    Self.log("The file chooser failed", error)
                    say("The file could not be opened.", after: [])
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { photo in
                    // For the camera that is open, or not taken.
                    guard let choosing = choosingPictures else { return }
                    Task { await attach([.picture(photo, name: ComposerRules.photoName(fileExtension: "jpg"))], chosen: (.pictures, choosing)) }
                }
                .ignoresSafeArea()
            }
            .onChange(of: isDisabled) { _, disabled in
                // The composer can render before it can be typed in; focus once
                // it can.
                if autoFocus, !disabled { isTextFieldFocused = true }
            }
        #endif
    }

    // MARK: - The block

    private var block: some View {
        VStack(alignment: .leading, spacing: Spacing.xxxs) {
            if !attachments.isEmpty {
                AttachmentsListView(
                    attachments: attachments,
                    compact: true,
                    onRemove: { id in
                        guard !isSubmittingSend else { return }
                        attachments.removeAll { $0.id == id }
                        // Taken out unsent: its copy is not kept.
                        Task { await AttachmentStore.shared.removeUnsent([id]) }
                    },
                    // Not while a message is on its way with them.
                    showRemove: !isSubmittingSend
                )
            }
            HStack(alignment: .bottom, spacing: Spacing.xxs) {
                attachButton
                field
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                // No mic where a voice message has nowhere to go (a
                // thread that is not made yet), not one that does nothing.
                if hasVoiceCallbacks { micButton }
                // The field takes the spare width, never the slot's.
                actionSlot
                    .fixedSize()
            }
            recipientRow
        }
        .padding(blockInset)
        .background(
            RoundedRectangle(cornerRadius: blockRadius, style: .continuous)
                .fill(Color.aicovenSurfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: blockRadius, style: .continuous)
                .strokeBorder(Color.aicovenBorder, lineWidth: 1)
        )
    }

    /// The gap between the box's edge and its buttons.
    private var blockInset: CGFloat {
        #if os(iOS)
        5
        #else
        6
        #endif
    }

    /// The box's corner radius: 12 pt on the Mac, 14 pt on touch. It does
    /// not change as the box grows.
    private var blockRadius: CGFloat {
        #if os(iOS)
        14
        #else
        12
        #endif
    }

    #if os(iOS)
    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    /// The controls' height, growing with the text: 44 pt targets on iPhone,
    /// 40 pt on iPad.
    private var controlSide: CGFloat {
        isPad ? padControlSide : phoneControlSide
    }

    /// Send and Stop sit inside the target around them with a margin on each
    /// side: 4 pt on iPhone (36 of 44), 3 pt on iPad (34 of 40).
    private var slotSide: CGFloat {
        controlSide - (isPad ? 6 : 8)
    }

    /// The + and mic buttons' width stays put, so larger text leaves the
    /// field its room.
    private var iconControlWidth: CGFloat {
        isPad ? 40 : 44
    }
    #else
    /// The controls' height: 30 pt, the editor's height for one 16 pt line,
    /// so the controls and that line share a centre. Where a line is taller
    /// the editor is higher than the controls, and they share a bottom edge.
    private var controlSide: CGFloat {
        GrowingTextEditorLayout.minHeight
    }

    private var slotSide: CGFloat {
        controlSide
    }

    private var iconControlWidth: CGFloat {
        controlSide
    }
    #endif

    /// Send and Stop's corners, concentric with the box's: the box's radius
    /// less the gap between the slot and the box's edge.
    private var slotRadius: CGFloat {
        blockRadius - (blockInset + (controlSide - slotSide) / 2)
    }

    private var isBusy: Bool {
        isAttaching || isSubmittingSend
    }

    // MARK: - Field

    private var field: some View {
        ZStack(alignment: .leading) {
            textInput
                // Kept in place while recording, so that a held Space
                // still reaches the editor when it is let go.
                .opacity(isRecordingVoice ? 0 : 1)
                .accessibilityHidden(isRecordingVoice)
            if isRecordingVoice {
                listening
            }
        }
    }

    /// No running time: the dot and the words say it is listening.
    private var listening: some View {
        HStack(spacing: Spacing.xs) {
            Circle()
                .fill(Color.aicovenWater)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text("Listening")
                .font(.aicovenBody)
                .foregroundStyle(Color.aicovenTextSecondary)
            Text(listeningHint)
                .font(.aicovenBodySmall)
                .foregroundStyle(Color.aicovenTextTertiary)
                .lineLimit(2)
        }
        .padding(.horizontal, 4)
        .frame(minHeight: controlSide)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("composer-listening")
    }

    private var listeningHint: String {
        #if os(macOS)
        isSpaceHoldRecording ? "Release Space to send · Esc to cancel" : "Click the mic to send · Esc to cancel"
        #else
        "Let go to send, slide away to cancel"
        #endif
    }

    @ViewBuilder
    private var textInput: some View {
        #if os(macOS)
        ZStack(alignment: .leading) {
            GrowingTextEditor(
                text: $messageText,
                height: $macInputHeight,
                isDisabled: isDisabled,
                autoFocus: autoFocus,
                onSend: send,
                onFocusChange: onFocusChange,
                onAttach: { files, pictures in attachPastedOrDropped(files: files, pictures: pictures) },
                // Whether Space may start talking changes as the composer
                // does; letting go of it, and calling it off, are always
                // heard, or a hold under way could not be ended.
                onVoiceHoldStart: spaceHoldEligible ? { beginVoicePress(bySpace: true) } : nil,
                onVoiceHoldStop: hasVoiceCallbacks ? { endVoicePress() } : nil,
                onVoiceHoldCancel: hasVoiceCallbacks ? { cancelVoicePress() } : nil,
                onEscape: isRecordingVoice || isVoicePressActive ? { cancelVoicePress() } : nil,
                isTalking: isRecordingVoice || isVoicePressActive
            )
            .frame(height: macInputHeight)
            if messageText.isEmpty {
                // The editor has no placeholder; this matches its inset,
                // centred like its one line.
                Text("Message")
                    .font(.aicovenBody)
                    .foregroundStyle(Color.aicovenTextTertiary)
                    .padding(.leading, 4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        #else
        TextField(
            "",
            text: $messageText,
            prompt: Text("Message").foregroundStyle(Color.aicovenTextTertiary),
            axis: .vertical
        )
        .focused($isTextFieldFocused)
        .onChange(of: isTextFieldFocused) { _, focused in onFocusChange?(focused) }
        .font(.aicovenBody)
        .foregroundStyle(Color.aicovenTextPrimary)
        .lineLimit(1 ... 8)
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .frame(minHeight: controlSide)
        .disabled(isDisabled)
        .accessibilityLabel("Message")
        .accessibilityIdentifier("composer")
        .onSubmit(send)
        // A hardware keyboard: Return sends, Shift+Return starts a new line.
        .onKeyPress(.return, phases: .down) { press in
            guard !press.modifiers.contains(.shift) else { return .ignored }
            send()
            return .handled
        }
        .task {
            if autoFocus, !isDisabled { isTextFieldFocused = true }
        }
        #endif
    }

    // MARK: - Attach

    /// The (+): a photo taken now (where there is a camera), photos from
    /// the library, or files.
    private var attachButton: some View {
        Menu {
            #if os(iOS)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    attachFailure = nil
                    choosingPictures = UUID()
                    showCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
            }
            #endif
            Button {
                attachFailure = nil
                pickedPhotos = []
                choosingPictures = UUID()
                showPhotoLibrary = true
            } label: {
                Label("Photo Library", systemImage: "photo")
            }
            Button {
                attachFailure = nil
                #if os(macOS)
                chooseFiles()
                #else
                choosingFiles = UUID()
                showFileImporter = true
                #endif
            } label: {
                Label("Choose File…", systemImage: "doc")
            }
        } label: {
            Group {
                if isAttaching {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus")
                        .font(.aicovenBody)
                        .foregroundStyle(Color.aicovenTextTertiary)
                }
            }
            .frame(width: iconControlWidth, height: controlSide)
            .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .frame(width: iconControlWidth, height: controlSide)
        .disabled(isBusy || isDisabled || isChoosingOnTheMac || isRecordingVoice)
        .accessibilityLabel("Attach")
        .accessibilityIdentifier("composer-attach")
        #if os(macOS)
            .help("Attach a photo or a file")
        #endif
    }

    /// What can be attached: a file, a photo picked in the library, or a
    /// picture's bytes (taken with the camera, pasted or dropped).
    private enum AttachSource {
        case file(URL)
        case photo(PhotosPickerItem)
        case picture(Data, name: String)

        /// What it is called when it cannot be attached.
        var name: String {
            switch self {
            case let .file(url): url.lastPathComponent
            case .photo: "A photo"
            case let .picture(_, name): name
            }
        }
    }

    /// The choosers something to attach comes back from.
    private enum Chooser {
        case files
        case pictures
    }

    /// Takes these as attachments. One that cannot be taken is said above
    /// the box; the rest are still taken. What comes back from a chooser
    /// (`chosen`) is taken only if that chooser is still the one open.
    @MainActor
    private func attach(_ sources: [AttachSource], chosen: (chooser: Chooser, token: UUID)?) async {
        // Checked as the attaching starts, not as the chooser returned: the
        // composer can have moved to another thread in between, and then
        // what was chosen is not this thread's.
        if let chosen {
            switch chosen.chooser {
            case .files:
                guard choosingFiles == chosen.token else { return }
                choosingFiles = nil
            case .pictures:
                guard choosingPictures == chosen.token else { return }
                choosingPictures = nil
            }
        }
        // Pasted or dropped while the composer is attaching, sending or
        // disabled, or anything while an attaching is under way: not
        // taken, and on the Mac said so with the system's sound.
        guard ComposerRules.takesAttachments(isAttaching: isAttaching, isFromAChooser: chosen != nil, isBusy: isBusy, isDisabled: isDisabled) else {
            #if os(macOS)
            NSSound.beep()
            #endif
            return
        }
        let task = UUID()
        attachingTask = task
        defer { if attachingTask == task { attachingTask = nil } }
        var failures: [String] = []
        for source in sources {
            do {
                // Copied into the app's own store now, so it is there to
                // send whatever becomes of the original.
                let detail = try await kept(source, while: task)
                // The composer can have moved to another thread meanwhile:
                // it was attached for the thread it left, and is not kept
                // for no message.
                guard attachingTask == task else {
                    await AttachmentStore.shared.removeUnsent([detail.id])
                    return
                }
                attachments.append(detail)
            } catch is CancellationError {
                return
            } catch {
                Self.log("An attachment could not be taken", error)
                guard attachingTask == task else { return }
                // The store says why of what it refuses (too large, not
                // readable); anything else is said plainly.
                let failure = (error as? AttachmentStore.Failure)?.errorDescription ?? "\(source.name) could not be attached."
                say(failure, after: failures)
                failures.append(failure)
            }
        }
    }

    /// The source copied into the app's own store for this thread. Throws
    /// `CancellationError` if the composer left the thread while a photo
    /// was being fetched from the library: it is then not kept at all.
    private func kept(_ source: AttachSource, while task: UUID) async throws -> FileAttachmentDetail {
        // Where this composer's files are kept: its thread, or, for a
        // thread that is not made yet, where they wait for it.
        let threadId = try await fileThread?() ?? threadId
        switch source {
        case let .file(url):
            return try await AttachmentStore.shared.add(fileAt: url, toThread: threadId)
        case let .picture(data, name):
            return try await AttachmentStore.shared.add(data, named: name, mimeType: AttachmentImage.mimeType(forFileNamed: name), toThread: threadId)
        case let .photo(item):
            // Its bytes as the library has them; the store writes a still
            // picture out afresh, upright and without where it was taken.
            // The library has none to give, or could not fetch them (a
            // photo in iCloud while offline): either way it was not read.
            let loaded: Data?
            do {
                loaded = try await item.loadTransferable(type: Data.self)
            } catch {
                Self.log("A photo could not be loaded", error)
                loaded = nil
            }
            guard let data = loaded else { throw AttachmentStore.Failure.unreadable(name: source.name) }
            guard attachingTask == task else { throw CancellationError() }
            let name = ComposerRules.photoName(fileExtension: item.supportedContentTypes.first?.preferredFilenameExtension)
            return try await AttachmentStore.shared.add(data, named: name, mimeType: AttachmentImage.mimeType(forFileNamed: name), toThread: threadId)
        }
    }

    #if os(macOS)
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        let choosing = UUID()
        choosingFiles = choosing
        panel.begin { response in
            let urls = response == .OK ? panel.urls : []
            Task { await attach(urls.map(AttachSource.file), chosen: (.files, choosing)) }
        }
    }

    /// Files and pictures pasted or dropped into the field.
    private func attachPastedOrDropped(files: [URL], pictures: [Data]) {
        attachFailure = nil
        let sources = files.map(AttachSource.file) + pictures.map { AttachSource.picture($0, name: ComposerRules.pastedPictureName) }
        Task { await attach(sources, chosen: nil) }
    }
    #endif

    // MARK: - Mic

    /// Hold to talk on the iPhone and iPad (let go to send, slide away to
    /// cancel); a click to start and a click to send on the Mac, and for
    /// VoiceOver everywhere.
    private var micButton: some View {
        #if os(iOS)
        micLabel
            .frame(width: iconControlWidth, height: controlSide)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isTouchingMic) { _, touching, _ in touching = true }
                    .onChanged { value in
                        isFingerOnMic = true
                        if !isVoicePressActive { beginVoicePress(bySpace: false) }
                        let distance = hypot(value.translation.width, value.translation.height)
                        isVoicePressCancelled = isVoicePressCancelled || distance > VoiceHoldToTalkPolicy.cancelDistance
                    }
                    .onEnded { value in
                        let distance = hypot(value.translation.width, value.translation.height)
                        isVoicePressCancelled = isVoicePressCancelled || distance > VoiceHoldToTalkPolicy.cancelDistance
                        isFingerOnMic = false
                        endVoicePress()
                    }
            )
            // The touch was taken away without the gesture ending (the
            // microphone prompt came up over it): the press is called off,
            // once whatever ended it has had its say.
            .onChange(of: isTouchingMic) { _, touching in
                guard !touching else { return }
                Task { @MainActor in
                    guard isFingerOnMic else { return }
                    isFingerOnMic = false
                    cancelVoicePress()
                }
            }
            .allowsHitTesting(!micIsDisabled)
            .opacity(micIsDisabled ? 0.4 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityRespondsToUserInteraction(!micIsDisabled)
            .accessibilityLabel(isRecordingVoice ? "Send voice message" : "Record voice message")
            .accessibilityHint("Press and hold to record. Release to send. Drag away to cancel.")
            .accessibilityAction { toggleVoiceRecording() }
            .accessibilityIdentifier("composer-mic")
        #else
        Button(action: toggleVoiceRecording) {
            micLabel
                .frame(width: iconControlWidth, height: controlSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(micIsDisabled)
        .opacity(micIsDisabled ? 0.4 : 1)
        .help(isRecordingVoice ? "Click to send, or press Esc to cancel" : "Click, or hold Space in an empty field, to talk")
        .accessibilityLabel(isRecordingVoice ? "Send voice message" : "Record voice message")
        .accessibilityIdentifier("composer-mic")
        #endif
    }

    @ViewBuilder
    private var micLabel: some View {
        if isVoiceBusy, !isRecordingVoice {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: isRecordingVoice ? "mic.fill" : "mic")
                .font(.aicovenBody)
                .foregroundStyle(isRecordingVoice ? Color.aicovenWater : Color.aicovenTextTertiary)
        }
    }

    private var hasVoiceCallbacks: Bool {
        onVoiceRecordStart != nil && onVoiceRecordStop != nil && onVoiceRecordCancel != nil
    }

    private var micIsDisabled: Bool {
        VoiceHoldToTalkPolicy.isMicDisabled(
            isRecordingVoice: isRecordingVoice,
            isPressActive: isVoicePressActive,
            isVoiceBusy: isVoiceBusy,
            isDisabled: isDisabled,
            isSubmittingSend: isSubmittingSend,
            isAttaching: isAttaching,
            hasVoiceCallbacks: hasVoiceCallbacks
        )
    }

    #if os(macOS)
    private var spaceHoldEligible: Bool {
        VoiceHoldToTalkPolicy.isMacSpaceHoldEligible(
            messageText: messageText,
            isDisabled: isDisabled,
            isVoiceBusy: isVoiceBusy,
            isRecordingVoice: isRecordingVoice,
            isPressActive: isVoicePressActive,
            isAttaching: isAttaching,
            hasVoiceCallbacks: hasVoiceCallbacks
        )
    }
    #endif

    private func beginVoicePress(bySpace: Bool) {
        guard !micIsDisabled, !isRecordingVoice else { return }
        isVoicePressActive = true
        isVoicePressCancelled = false
        #if os(macOS)
        isSpaceHoldRecording = bySpace
        #endif
        onVoiceRecordStart?()
    }

    private func endVoicePress() {
        let action = VoiceHoldToTalkPolicy.releaseAction(
            isRecordingVoice: isRecordingVoice,
            wasPressActive: isVoicePressActive,
            wasCancelled: isVoicePressCancelled
        )
        isVoicePressActive = false
        isVoicePressCancelled = false
        switch action {
        case .send: onVoiceRecordStop?()
        case .cancel: onVoiceRecordCancel?()
        case .none: break
        }
    }

    private func endPressNoFingerHolds() {
        #if os(iOS)
        guard !isFingerOnMic else { return }
        #endif
        isVoicePressActive = false
        isVoicePressCancelled = false
    }

    private func cancelVoicePress() {
        let shouldCancel = isRecordingVoice || isVoicePressActive
        isVoicePressActive = false
        isVoicePressCancelled = false
        if shouldCancel { onVoiceRecordCancel?() }
    }

    /// A click on the Mac, and VoiceOver everywhere: start, then send.
    private func toggleVoiceRecording() {
        if isRecordingVoice {
            endVoicePress()
        } else {
            beginVoicePress(bySpace: false)
        }
    }

    // MARK: - Send | Stop

    @ViewBuilder
    private var actionSlot: some View {
        switch ComposerRules.slot(text: messageText, isAgentRunning: isAgentRunning, canStop: onStop != nil, isRecordingVoice: isRecordingVoice) {
        case .stop:
            Button(action: { onStop?() }, label: {
                Image(systemName: "stop.fill")
                    .font(.aicovenBodySmall)
            })
            .buttonStyle(slotStyle)
            .disabled(isStopping)
            .accessibilityLabel("Stop")
            .accessibilityHint("Stops \(recipientName)'s reply")
            .accessibilityIdentifier("composer-stop")
            #if os(macOS)
                .help("Stop")
            #endif
        case .send:
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.aicovenBodySmall.weight(.semibold))
            }
            .buttonStyle(slotStyle)
            .disabled(!canSend)
            .accessibilityLabel("Send")
            .accessibilityHint(ComposerRules.waitNote(isAgentRunning: isAgentRunning, runningName: recipientName) ?? "")
            .accessibilityIdentifier("composer-send")
            #if os(macOS)
                .help("Send")
            #endif
        }
    }

    private var slotStyle: ComposerSlotStyle {
        ComposerSlotStyle(side: slotSide, target: controlSide, radius: slotRadius)
    }

    private var canSend: Bool {
        ComposerRules.canSend(text: messageText, isDisabled: isDisabled, isBusy: isBusy, isRecordingVoice: isRecordingVoice)
    }

    private func send() {
        guard canSend else { return }
        let submitted = attachments
        isSubmittingSend = true
        // Told as Send is pressed, not when the message has been taken:
        // what is typed while that is waited for is the next message.
        onSent?()
        Task { @MainActor in
            let accepted = await onSend(submitted)
            isSubmittingSend = false
            guard accepted else { return }
            attachFailure = nil
            #if os(macOS)
            macInputHeight = GrowingTextEditor.emptyHeight
            #endif
            let sent = Set(submitted.map(\.id))
            attachments.removeAll { sent.contains($0.id) }
            // For the text as it is now: more can have been typed while
            // the send was under way.
            suggestMentions()
        }
    }

    /// What was handed back goes before whatever is in the field: it was
    /// written first.
    private func takeReturned() {
        guard hasReturnedDraft, let handedBack = takeReturnedDraft?() else { return }
        let merged = handedBack.followed(by: ComposerDraft(text: messageText, attachments: attachments))
        if let putInTheField {
            putInTheField(merged.text)
        } else {
            messageText = merged.text
        }
        attachments = merged.attachments
        // The field changes without being typed in, wherever focus is.
        AccessibilityNotification.Announcement("Your message is back in the message field").post()
    }

    /// Shows suggestions while the text ends in an unfinished @mention.
    private func suggestMentions() {
        if let query = ComposerRules.mentionQuery(in: messageText), !mentionableRoles.isEmpty {
            mentionQuery = query
            showMentionSuggestions = true
        } else {
            mentionQuery = ""
            showMentionSuggestions = false
        }
    }

    /// Shows a file's refusal above the box, under the ones before it, and
    /// tells VoiceOver of this one.
    private func say(_ failure: String, after earlier: [String]) {
        attachFailure = (earlier + [failure]).joined(separator: "\n")
        AccessibilityNotification.Announcement(failure).post()
    }

    /// Logs what failed and the error's kind, never its description: that
    /// can name the file or where it is.
    private static func log(_ what: String, _ error: Error) {
        let error = error as NSError
        AppErrorReporter.log(message: "\(what) (\(error.domain) \(error.code)).", context: "MessageComposer.attach")
    }

    // MARK: - Recipient

    /// The recipient's name; where there is a choice of agents, a menu of
    /// them, the chosen one checked.
    @ViewBuilder
    private var recipient: some View {
        let name = Text(recipientName)
            .font(.aicovenBodySmall.weight(.semibold))
            .foregroundStyle(Color.aicovenTextSecondary)
            // One line, so a long name shortens before it pushes past
            // the box.
            .lineLimit(1)
            .truncationMode(.tail)
        if recipientChoices.isEmpty {
            name
                .accessibilityLabel("To \(recipientName)")
                .accessibilityIdentifier("composer-recipient")
        } else {
            Menu {
                // A toggle for each agent gives it a checked state that
                // VoiceOver reports; the model is the row's second line.
                ForEach(recipientChoices) { role in
                    Toggle(isOn: Binding(
                        get: { recipientID == role.id },
                        set: { _ in onChooseRecipient?(role) }
                    )) {
                        Text(role.name)
                        if let model = role.model, !model.isEmpty {
                            Text(model)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    name
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(Color.aicovenTextTertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            #if os(macOS)
                .menuIndicator(.hidden)
            #endif
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("To \(recipientName)")
                .accessibilityHint("Choose who the next message goes to")
                .accessibilityIdentifier("composer-recipient")
        }
    }

    /// Who the message goes to, at the box's bottom left, with when it can
    /// be sent beside it once there is text while a turn runs.
    private var recipientRow: some View {
        HStack(spacing: Spacing.xs) {
            recipient
            if !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let note = ComposerRules.waitNote(isAgentRunning: isAgentRunning, runningName: recipientName) {
                Text(note)
                    .font(waitNoteFont)
                    .foregroundStyle(Color.aicovenTextTertiary)
                    .lineLimit(2)
                    // The name gives way to the note, never the reverse.
                    .layoutPriority(1)
                    .accessibilityIdentifier("composer-wait-note")
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, Spacing.xxs)
        .frame(minHeight: chipHeight)
    }

    /// The note beside the name: 13 pt on touch, 12 pt on the Mac.
    private var waitNoteFont: Font {
        #if os(iOS)
        .aicovenBodySmall
        #else
        .aicovenCaption
        #endif
    }

    private var chipHeight: CGFloat {
        #if os(iOS)
        isPad ? 30 : 32
        #else
        28
        #endif
    }

    // MARK: - Mentions

    private var suggestedRoles: [MentionableRole] {
        ComposerRules.suggestions(for: mentionQuery, among: mentionableRoles)
    }

    private var mentionSuggestions: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            ForEach(suggestedRoles) { role in
                Button {
                    messageText = ComposerRules.inserting(mention: role.name, into: messageText)
                    showMentionSuggestions = false
                    mentionQuery = ""
                } label: {
                    HStack(spacing: Spacing.xs) {
                        AgentFace(
                            symbol: role.iconSymbol ?? AgentFace.symbol(forEmoji: role.emoji),
                            tint: role.iconTint.flatMap(IconTint.init(rawValue:)),
                            provider: role.provider,
                            size: 20
                        )
                        Text(role.name)
                            .font(.aicovenBodySmall)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(Color.aicovenTextPrimary)
        .padding(Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: BorderRadius.md)
                .fill(Color.aicovenSurfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: BorderRadius.md)
                .strokeBorder(Color.aicovenBorder, lineWidth: 1)
        )
    }
}

#if os(iOS)
/// The system's camera, for one photo: gives its bytes as a JPEG and
/// closes, or closes with nothing if it is cancelled.
private struct CameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onCapture: (Data) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: UIImagePickerController, context _: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        init(parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                parent.onCapture(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
#endif

/// Send and Stop: a rounded rectangle at least `side` square, corner
/// `radius`, in the button fill, centred in a hit area at least `target`
/// square. The radius is the box's less the slot's gap to the box's edge,
/// never a circle.
private struct ComposerSlotStyle: ButtonStyle {
    let side: CGFloat
    let target: CGFloat
    let radius: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.aicovenSurfaceElevated)
            .frame(minWidth: side, minHeight: side)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.aicovenPurple))
            .frame(minWidth: target, minHeight: target)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .opacity(isEnabled ? 1 : 0.4)
    }
}
