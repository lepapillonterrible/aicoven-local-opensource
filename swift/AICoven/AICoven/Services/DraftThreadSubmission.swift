internal import Combine
import Foundation

/// Owns a new thread's first message from Send until the thread that was
/// made for it has taken it. The thread is made only then: a page with
/// nothing sent leaves no empty thread behind.
@MainActor
final class DraftThreadSubmission: ObservableObject {
    /// What the composer holds.
    @Published var messageText = ""
    /// A thread is being made for what was sent: nothing else is sent
    /// meanwhile.
    @Published private(set) var isCreatingThread = false
    /// Why the thread could not be started, until the next send.
    @Published private(set) var errorMessage: String?
    /// What was sent, while its thread is being made: the page shows it.
    @Published private(set) var submittedText: String?
    /// The files the composer holds attached: kept in the store under the
    /// account's holding row until the thread they go to is made.
    @Published var attachments: [FileAttachmentDetail] = []
    /// The files that went with what was sent, while its thread is made.
    @Published private(set) var submittedAttachments: [FileAttachmentDetail] = []

    /// Said when the message came back to the field; and when it did not,
    /// because the field holds words typed since.
    static let couldNotStart = "The thread could not be started. Your message is still available."
    static let couldNotStartNotGivenBack = "The thread could not be started."

    /// What is done with a new thread's files: they were attached before
    /// there was a thread to keep them under.
    struct Files {
        /// Takes the files into the thread that was made for them.
        var take: @MainActor (_ files: [FileAttachmentDetail], _ thread: Thread, _ account: String) async throws -> Void
        /// Undoes a thread whose message's files could not be taken into it.
        var discardThread: @MainActor (_ thread: Thread, _ account: String) async -> Void
        /// Removes files that go with no message after all.
        var drop: @MainActor (_ files: [FileAttachmentDetail]) async -> Void

        /// As the app keeps them: in `AttachmentStore`, the thread in
        /// `ThreadService`.
        static let stored = Files(
            take: { files, thread, account in
                try await AttachmentStore.shared.moveUnsent(files.map(\.id), toThread: thread.id, for: account)
            },
            discardThread: { thread, account in
                // Only as the account it was made for; a thread that cannot
                // be deleted is left, empty.
                guard UserScope.currentUserID == account else { return }
                do {
                    try await ThreadService.shared.deleteThread(threadId: thread.id)
                } catch {
                    // The kind of failure only.
                    AppErrorReporter.log(
                        message: "Could not discard a thread whose files could not be taken (\(type(of: error)))",
                        context: "DraftThreadSubmission.discardThread"
                    )
                }
            },
            drop: { files in await AttachmentStore.shared.removeUnsent(files.map(\.id)) }
        )
    }

    /// The account signed in, by its id.
    private let currentAccount: @MainActor () -> String

    init(currentAccount: @escaping @MainActor () -> String = { UserScope.currentUserID }) {
        self.currentAccount = currentAccount
    }

    /// Makes a thread for what the composer holds and sends that into it
    /// as its first message, with the files attached. Returns nil, and
    /// does nothing, with no text to send or while a thread is already
    /// being made.
    ///
    /// - `createThread` makes the thread for the account that sent (it is
    ///   given the title and that account).
    /// - `files` takes the attached files into that thread. If they cannot
    ///   be taken, the thread is discarded and the send is one whose
    ///   thread could not be made.
    /// - `sendFirstMessage` starts the reply to the message in the thread.
    /// - `keepUnsent` is told when the thread was made but the message
    ///   could not be sent into it: the thread keeps the text and the
    ///   files for its own composer, and is opened like any thread that
    ///   was made.
    /// - `onThreadCreated` is told of the thread once it has its message
    ///   (or holds it unsent).
    ///
    /// If the thread cannot be made, the text and its files go back to the
    /// composer, unless words were typed there meanwhile (blank space
    /// alone gives way to it): then neither comes back, and the files are
    /// dropped, not sent with other words. If another account is signed in
    /// by the time the thread is made, nothing is sent into it and nothing
    /// is said or given back: the message was the first account's.
    @discardableResult
    func send(
        createThread: @escaping @MainActor (_ title: String, _ account: String) async throws -> Thread,
        files: Files = .stored,
        sendFirstMessage: @escaping @MainActor (Thread, String, [FileAttachmentDetail]) async throws -> Void,
        keepUnsent: @escaping @MainActor (Thread, String, [FileAttachmentDetail], Error) -> Void,
        onThreadCreated: @escaping @MainActor (Thread) -> Void
    ) -> Task<Void, Never>? {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isCreatingThread else { return nil }
        // Reserved here, in the button's action, before anything waits: a
        // second Send finds it taken; newer typing waits in the field.
        isCreatingThread = true
        errorMessage = nil
        let attached = attachments
        submittedText = text
        submittedAttachments = attached
        messageText = ""
        attachments = []
        let account = currentAccount()
        return Task { [currentAccount] in
            defer {
                isCreatingThread = false
                submittedText = nil
                submittedAttachments = []
            }
            let thread: Thread
            do {
                thread = try await createThread(ThreadTitleGenerator.title(from: text), account)
            } catch {
                await giveBack(text, attached, to: account, dropping: files.drop)
                return
            }
            // Another account by now: its thread list is not this text's place.
            guard currentAccount() == account else { return }
            if !attached.isEmpty {
                do {
                    try await files.take(attached, thread, account)
                } catch {
                    // A thread made for a message that cannot go into it
                    // whole is not kept: nothing was sent.
                    await files.discardThread(thread, account)
                    await giveBack(text, attached, to: account, dropping: files.drop)
                    return
                }
                guard currentAccount() == account else { return }
            }
            do {
                try await sendFirstMessage(thread, text, attached)
            } catch {
                guard currentAccount() == account else { return }
                keepUnsent(thread, text, attached, error)
            }
            guard currentAccount() == account else { return }
            onThreadCreated(thread)
        }
    }

    /// Gives a message whose thread could not be started back to the
    /// composer. Never into another account's composer, and never over
    /// words typed since: then its files go with no message, and are
    /// dropped. A field holding only blank space holds nothing to keep:
    /// the message that was not sent matters more.
    private func giveBack(
        _ text: String, _ attached: [FileAttachmentDetail], to account: String,
        dropping drop: @MainActor ([FileAttachmentDetail]) async -> Void
    ) async {
        guard currentAccount() == account else { return }
        if messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messageText = text
            // In front of any attached since: they were attached first.
            attachments = attached + attachments
            errorMessage = Self.couldNotStart
        } else {
            errorMessage = Self.couldNotStartNotGivenBack
            if !attached.isEmpty { await drop(attached) }
        }
    }
}
