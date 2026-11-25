internal import Combine
import SwiftUI

/// The page of a thread that is not made yet, as the cloud app's: empty
/// but for the composer, and, once something is sent, what was sent while
/// its thread is being made. The thread is made then, and takes this
/// page's place.
struct DraftThreadView: View {
    /// The coven the thread is for; nil for Strix.
    let coven: Coven?
    /// The agent the thread was asked for by name, if any, and which ask
    /// for the page this is (it can be asked for again).
    let askedAgentID: String?
    var request = 0
    /// What the page holds unsent, kept by whoever shows the page so it is
    /// still there when the person comes back to it.
    @ObservedObject var submission: DraftThreadSubmission
    /// Told of the thread once it is made.
    let onThreadCreated: (Thread) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                if let sent = submission.submittedText {
                    VStack(alignment: .trailing, spacing: Spacing.xxs) {
                        Text(sent)
                            .font(.aicovenBody)
                            .foregroundStyle(Color.aicovenTextPrimary)
                            .padding(Spacing.sm)
                            .background(Color.aicovenSurfaceElevated, in: RoundedRectangle(cornerRadius: BorderRadius.md))
                        if !submission.submittedAttachments.isEmpty {
                            // The files going with it, by name.
                            Text(Self.names(of: submission.submittedAttachments))
                                .font(.aicovenCaption)
                                .foregroundStyle(Color.aicovenTextSecondary)
                                .multilineTextAlignment(.trailing)
                        }
                        Text("Sending…")
                            .font(.aicovenCaption)
                            .foregroundStyle(Color.aicovenTextSecondary)
                    }
                    .frame(maxWidth: 800, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(Spacing.md)
                    .accessibilityElement(children: .combine)
                }
            }
            NewThreadComposer(
                coven: coven, askedAgentID: askedAgentID, request: request, submission: submission, autoFocus: true,
                onThreadCreated: onThreadCreated
            )
            .padding(Spacing.md)
        }
    }

    /// The names of the files going with a message, in a line.
    static func names(of files: [FileAttachmentDetail]) -> String {
        files.map(\.name).joined(separator: ", ")
    }
}

/// The composer of a thread that is not made yet. It says who the message
/// goes to (in a coven, one of its agents, to choose from; Strix in Strix
/// and in a coven with no agents), and sending makes the thread, called by
/// the message's first line, and sends the message into it. Files attached
/// here are kept under the account's holding row until then, and go into
/// the thread with the message.
struct NewThreadComposer: View {
    let coven: Coven?
    let askedAgentID: String?
    /// Which ask for the page this is: asked for again, an agent picked
    /// in the menu before gives way to the one asked for.
    var request = 0
    @ObservedObject var submission: DraftThreadSubmission
    var autoFocus = false
    /// Told when a send is taken, before its thread is made.
    var onSend: (() -> Void)?
    let onThreadCreated: (Thread) -> Void

    /// The coven's agents, once read.
    @State private var roles: [Role] = []
    @State private var didLoadRoles = false
    /// The agent the person chose here, over the one the rule gives.
    @State private var chosenAgentID: String?
    /// Counts the readings of the agents, so that only the latest is kept.
    @State private var readings = 0
    private let lastUsed = LastUsedAgentStore()

    /// Who the message goes to: the agent chosen here, else the one the
    /// rule gives; nil is Strix.
    private var recipient: Role? {
        guard coven != nil else { return nil }
        if let chosenAgentID, let chosen = roles.first(where: { $0.id == chosenAgentID }) { return chosen }
        let used = coven.flatMap { lastUsed.agentID(inCoven: $0.id, for: UserScope.currentUserID) }
        return NewThreadRules.recipient(asked: askedAgentID, lastUsed: used, among: roles)
    }

    private var recipientName: String {
        Self.recipientName(inCoven: coven != nil, agentsAreIn: didLoadRoles, recipient: recipient)
    }

    /// What the composer says of who the message goes to: the agent's
    /// name; Strix in Strix and in a coven with no agents; and, while a
    /// coven's agents are on their way, that they are.
    static func recipientName(inCoven: Bool, agentsAreIn: Bool, recipient: Role?) -> String {
        if inCoven, !agentsAreIn { return "Loading agents…" }
        return recipient?.name ?? "Strix"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if submission.isCreatingThread {
                HStack(spacing: Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Starting a thread…")
                        .font(.aicovenBodySmall)
                        .foregroundStyle(Color.aicovenTextSecondary)
                }
                .accessibilityElement(children: .combine)
            }
            MessageComposer(
                messageText: $submission.messageText,
                attachments: $submission.attachments,
                onSend: { _ in send() },
                // Not while the coven's agents are on their way (it would go
                // to none of them), nor while a thread is being made.
                isDisabled: submission.isCreatingThread || (coven != nil && !didLoadRoles),
                threadId: WorkspaceTab.draftThread(covenId: coven?.id).id,
                autoFocus: autoFocus,
                recipientName: recipientName,
                // No choosing while the thread is being made: the message has
                // gone to the agent shown when Send was pressed.
                recipientChoices: submission.isCreatingThread ? [] : roles,
                recipientID: recipient?.id,
                onChooseRecipient: { chosenAgentID = $0.id },
                // There is no thread yet to keep files under.
                fileThread: { try await AttachmentStore.shared.holdingThread() },
                notice: submission.errorMessage
            )
        }
        .task(id: coven?.id) { await loadRoles() }
        // Asked for again while the page is open ("New Thread with Scout"):
        // the agent asked for is who it goes to, over an earlier pick.
        .onChange(of: request) { _, _ in chosenAgentID = nil }
        .onChange(of: submission.isCreatingThread) { _, creating in
            if creating { AccessibilityNotification.Announcement("Starting a thread…").post() }
        }
        // Said to VoiceOver when it comes, and when the person comes back
        // to a page that is still saying it.
        .onChange(of: submission.errorMessage, initial: true) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
    }

    /// Reads the coven's agents; Strix has none to read.
    private func loadRoles() async {
        chosenAgentID = nil
        guard let covenID = coven?.id else {
            roles = []
            didLoadRoles = true
            return
        }
        didLoadRoles = false
        readings += 1
        let reading = readings
        let account = UserScope.currentUserID
        var loaded: [Role]?
        do {
            loaded = try await RoleService.shared.loadRoles(covenId: covenID)
        } catch {
            // The kind of failure only.
            AppErrorReporter.log(message: "Could not read the coven's agents (\(type(of: error)))", context: "NewThreadComposer.loadRoles")
        }
        // Only the latest reading, for the coven still shown and the account that asked.
        guard reading == readings, coven?.id == covenID, UserScope.currentUserID == account else { return }
        // Agents that could not be read are none: Strix answers, as in a coven that has none.
        roles = loaded ?? []
        didLoadRoles = true
    }

    /// A first message that could not be sent into the thread made for it
    /// is handed to that thread's own composer, with why: the text and its
    /// files, the thread's by now. Through the engine, so it goes in front
    /// of anything typed or attached there meanwhile, never over it, and
    /// reaches a composer already showing the thread.
    static func handBack(
        _ text: String, _ files: [FileAttachmentDetail], toThread threadID: String, because error: Error,
        engine: TurnEngine = .shared
    ) {
        // The kind of failure only.
        AppErrorReporter.log(message: "Could not send a new thread's first message (\(type(of: error)))", context: "NewThreadComposer.send")
        engine.handBack(ComposerDraft(text: text, attachments: files), to: threadID, because: error)
    }

    /// Sends what the field holds: makes the thread, then sends the
    /// message into it. The agent is the one shown when Send was pressed.
    private func send() -> Bool {
        let agent = recipient
        let covenID = coven?.id
        let sending = submission.send(
            createThread: { title, account in
                try await ThreadService.shared.createThread(
                    title: title, covenId: covenID, agentId: agent?.id, agentName: agent?.name, as: account
                )
            },
            sendFirstMessage: { thread, text, files in
                if let covenID, let agent { LastUsedAgentStore().set(agent.id, inCoven: covenID, for: thread.userId) }
                try await TurnEngine.shared.start(
                    with: TurnProgress.userMessage(in: thread.id, text: text, attachments: files),
                    context: text,
                    roleID: thread.agentId,
                    agentName: thread.agentName,
                    attachments: files.isEmpty ? nil : files
                )
            },
            keepUnsent: { thread, text, files, error in
                Self.handBack(text, files, toThread: thread.id, because: error)
            },
            onThreadCreated: onThreadCreated
        )
        if sending != nil { onSend?() }
        return sending != nil
    }
}

/// What each scope's new-thread page holds unsent, while the window is
/// open: the text is there again when the person comes back to the page.
/// In memory only; it is one account's (the shell that holds it is).
@MainActor
final class DraftThreads: ObservableObject {
    private var submissions: [ShellScope: DraftThreadSubmission] = [:]

    func submission(for scope: ShellScope) -> DraftThreadSubmission {
        if let held = submissions[scope] { return held }
        let made = DraftThreadSubmission()
        submissions[scope] = made
        return made
    }

    /// A coven is gone: so is what was being written for it, and the
    /// files attached to it.
    func forget(_ scope: ShellScope) {
        let files = submissions[scope]?.attachments.map(\.id) ?? []
        submissions[scope] = nil
        if !files.isEmpty { Task { await AttachmentStore.shared.removeUnsent(files) } }
    }
}
