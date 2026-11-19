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
    /// What the trailing slot is.
    enum Slot: Equatable {
        case send
        case stop
    }

    /// One trailing place: Stop while a turn runs and the field is empty,
    /// Send otherwise, so the button under the pointer never moves.
    static func slot(text: String, isAgentRunning: Bool, canStop: Bool) -> Slot {
        isAgentRunning && canStop && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .stop : .send
    }

    /// Whether Send sends: there is text, and nothing is in its way. While
    /// a turn runs it sends too; the message then waits for the turn.
    static func canSend(text: String, isDisabled: Bool, isBusy: Bool) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isDisabled && !isBusy
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
/// (Send | Stop)` in a raised stone box with rounded corners, who the
/// message goes to at its bottom left, no formatting controls.
///
/// While a turn runs the slot is Stop with an empty field and Send once
/// there is text; what is sent then waits (the parent queues it).
/// Return sends and Shift+Return starts a new line on the Mac and with a
/// hardware keyboard.
struct MessageComposer: View {
    @Binding var messageText: String
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
    /// Something the thread has to say above the box: why waiting messages
    /// were not sent.
    var notice: String?
    /// Whether text and attachments were handed back to this thread's
    /// composer (waiting messages that were not sent, or one taken back to
    /// be edited), and how they are taken, once.
    var hasReturnedDraft: Bool = false
    var takeReturnedDraft: (() -> ComposerDraft?)?

    @State private var attachments: [FileAttachmentDetail] = []
    /// The attaching under way, if one is. Cleared when the composer moves
    /// to another thread, so files chosen for one thread are never taken
    /// into another's message.
    @State private var attachingTask: UUID?
    @State private var isSubmittingSend = false
    /// Why the last file chosen could not be attached.
    @State private var attachFailure: String?
    @State private var showMentionSuggestions = false
    @State private var mentionQuery = ""
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
        .onChange(of: messageText) { _, _ in suggestMentions() }
        .onChange(of: attachFailure) { _, failure in
            if let failure { AccessibilityNotification.Announcement(failure).post() }
        }
        .onChange(of: notice) { _, notice in
            if let notice { AccessibilityNotification.Announcement(notice).post() }
        }
        .onAppear(perform: takeReturned)
        .onChange(of: hasReturnedDraft) { _, _ in takeReturned() }
        .onChange(of: threadId) { _, _ in
            attachingTask = nil
            attachFailure = nil
            choosingFiles = nil
            takeReturned()
            #if os(iOS)
            showFileImporter = false
            #endif
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
                Task { await attach(urls, chosenIn: choosing) }
            case let .failure(error):
                choosingFiles = nil
                Self.log("The file chooser failed", error)
                attachFailure = "The file could not be opened."
            }
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
                    onRemove: { id in attachments.removeAll { $0.id == id } },
                    showRemove: true
                )
            }
            HStack(alignment: .bottom, spacing: Spacing.xxs) {
                attachButton
                field
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
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

    /// The + button's width stays put, so larger text leaves the field its
    /// room.
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

    @ViewBuilder
    private var field: some View {
        #if os(macOS)
        ZStack(alignment: .leading) {
            GrowingTextEditor(
                text: $messageText,
                height: $macInputHeight,
                isDisabled: isDisabled,
                autoFocus: autoFocus,
                onSend: send
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

    private var attachButton: some View {
        Button {
            attachFailure = nil
            #if os(macOS)
            chooseFiles()
            #else
            choosingFiles = UUID()
            showFileImporter = true
            #endif
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
        .buttonStyle(.plain)
        .disabled(isBusy || isDisabled || isChoosingOnTheMac)
        .accessibilityLabel("Attach a file")
        .accessibilityIdentifier("composer-attach")
        #if os(macOS)
            .help("Attach a file")
        #endif
    }

    /// Takes the chosen files as attachments. One that cannot be taken is
    /// said above the box; the rest are still taken.
    @MainActor
    private func attach(_ urls: [URL], chosenIn choosing: UUID) async {
        // Checked as the attaching starts, not as the chooser returned: the
        // composer can have moved to another thread in between, and then
        // the files are not this thread's.
        guard choosingFiles == choosing, attachingTask == nil else { return }
        choosingFiles = nil
        let task = UUID()
        attachingTask = task
        defer { if attachingTask == task { attachingTask = nil } }
        for url in urls {
            do {
                let detail = try await UploadService.shared.upload(url: url, threadId: threadId)
                // The composer can have moved to another thread meanwhile.
                guard attachingTask == task else { return }
                attachments.append(detail)
            } catch {
                Self.log("A file could not be attached", error)
                guard attachingTask == task else { return }
                attachFailure = "\(url.lastPathComponent) could not be attached."
            }
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
            Task { await attach(urls, chosenIn: choosing) }
        }
    }
    #endif

    // MARK: - Send | Stop

    @ViewBuilder
    private var actionSlot: some View {
        switch ComposerRules.slot(text: messageText, isAgentRunning: isAgentRunning, canStop: onStop != nil) {
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
        ComposerRules.canSend(text: messageText, isDisabled: isDisabled, isBusy: isBusy)
    }

    private func send() {
        guard canSend else { return }
        let submitted = attachments
        isSubmittingSend = true
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
        messageText = merged.text
        attachments = merged.attachments
        // The field changes without being typed in, wherever focus is.
        AccessibilityNotification.Announcement("Your waiting message is back in the message field").post()
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

    /// Logs what failed and the error's kind, never its description: that
    /// can name the file or where it is.
    private static func log(_ what: String, _ error: Error) {
        let error = error as NSError
        AppErrorReporter.log(message: "\(what) (\(error.domain) \(error.code)).", context: "MessageComposer.attach")
    }

    // MARK: - Recipient

    /// Who the message goes to, at the box's bottom left, with when it can
    /// be sent beside it once there is text while a turn runs.
    private var recipientRow: some View {
        HStack(spacing: Spacing.xs) {
            Text(recipientName)
                .font(.aicovenBodySmall.weight(.semibold))
                .foregroundStyle(Color.aicovenTextSecondary)
                // One line, so a long name shortens before it pushes past
                // the box.
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityLabel("To \(recipientName)")
                .accessibilityIdentifier("composer-recipient")
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
                        Text(role.emoji ?? "🤖")
                            .accessibilityHidden(true)
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
