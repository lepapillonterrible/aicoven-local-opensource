internal import Combine
import SwiftUI

/// The page of a thread that is not made yet, as the cloud app's: empty
/// but for the composer, and, once something is sent, what was sent while
/// its thread is being made. The thread is made then, and takes this
/// page's place.
struct DraftThreadView: View {
    /// The coven the thread is for; nil for Strix.
    let coven: Coven?
    /// The agent the thread was asked for by name, if any.
    let askedAgentID: String?
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
                coven: coven, askedAgentID: askedAgentID, submission: submission, autoFocus: true, onThreadCreated: onThreadCreated
            )
            .padding(Spacing.md)
        }
    }
}

/// The composer of a thread that is not made yet. It says who the message
/// goes to (in a coven, one of its agents, to choose from; Strix in Strix
/// and in a coven with no agents), and sending makes the thread, called by
/// the message's first line, and sends the message into it.
struct NewThreadComposer: View {
    let coven: Coven?
    let askedAgentID: String?
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
                attachments: .constant([]),
                onSend: { _ in send() },
                // Not while the coven's agents are on their way (it would go
                // to none of them), nor while a thread is being made.
                isDisabled: submission.isCreatingThread || (coven != nil && !didLoadRoles),
                threadId: WorkspaceTab.draftThread(covenId: coven?.id).id,
                autoFocus: autoFocus,
                recipientName: recipientName,
                recipientChoices: roles,
                recipientID: recipient?.id,
                onChooseRecipient: { chosenAgentID = $0.id },
                allowsAttachments: false,
                notice: submission.errorMessage
            )
        }
        .task(id: coven?.id) { await loadRoles() }
        // Asked for another agent by name while the page is open ("New
        // Thread with Scout"): that is who it goes to, over an earlier pick.
        .onChange(of: askedAgentID) { _, _ in chosenAgentID = nil }
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
        let loaded = try? await RoleService.shared.loadRoles(covenId: covenID)
        // Only the latest reading, for the coven still shown and the account that asked.
        guard reading == readings, coven?.id == covenID, UserScope.currentUserID == account else { return }
        // Agents that could not be read are none: Strix answers, as in a coven that has none.
        roles = loaded ?? []
        didLoadRoles = true
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
            sendFirstMessage: { thread, text in
                if let covenID, let agent { LastUsedAgentStore().set(agent.id, inCoven: covenID, for: thread.userId) }
                try await TurnEngine.shared.start(
                    with: TurnProgress.userMessage(in: thread.id, text: text, attachments: []),
                    context: text,
                    roleID: thread.agentId,
                    agentName: thread.agentName,
                    attachments: nil
                )
            },
            keepUnsent: { thread, text, error in
                // The kind of failure only.
                AppErrorReporter.log(message: "Could not send a new thread's first message (\(type(of: error)))", context: "NewThreadComposer.send")
                // The thread's own composer gives it back, with why.
                TurnEngine.shared.keepUnsent(text, for: thread.id, because: error.localizedDescription)
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

    /// A coven is gone: so is what was being written for it.
    func forget(_ scope: ShellScope) {
        submissions[scope] = nil
    }
}
