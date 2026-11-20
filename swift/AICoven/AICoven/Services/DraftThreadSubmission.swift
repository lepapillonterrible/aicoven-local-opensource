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

    static let couldNotStart = "The thread could not be started. Your message is still available."

    /// The account signed in, by its id.
    private let currentAccount: @MainActor () -> String

    init(currentAccount: @escaping @MainActor () -> String = { UserScope.currentUserID }) {
        self.currentAccount = currentAccount
    }

    /// Makes a thread for what the composer holds and sends that into it
    /// as its first message. Returns nil, and does nothing, with nothing
    /// to send or while a thread is already being made.
    ///
    /// - `createThread` makes the thread for the account that sent (it is
    ///   given the title and that account).
    /// - `sendFirstMessage` starts the reply to the message in the thread.
    /// - `keepUnsent` is told when the thread was made but the message
    ///   could not be sent into it: the thread keeps the text for its own
    ///   composer, and is opened like any thread that was made.
    /// - `onThreadCreated` is told of the thread once it has its message
    ///   (or holds it unsent).
    ///
    /// If the thread cannot be made, the text goes back to the composer,
    /// unless words were typed there meanwhile (blank space alone gives
    /// way to it). If another account is
    /// signed in by the time the thread is made, nothing is sent into it
    /// and nothing is said or given back: the text was the first
    /// account's.
    @discardableResult
    func send(
        createThread: @escaping @MainActor (_ title: String, _ account: String) async throws -> Thread,
        sendFirstMessage: @escaping @MainActor (Thread, String) async throws -> Void,
        keepUnsent: @escaping @MainActor (Thread, String, Error) -> Void,
        onThreadCreated: @escaping @MainActor (Thread) -> Void
    ) -> Task<Void, Never>? {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isCreatingThread else { return nil }
        // Reserved here, in the button's action, before anything waits: a
        // second Send, or newer typing, finds it taken.
        isCreatingThread = true
        errorMessage = nil
        submittedText = text
        messageText = ""
        let account = currentAccount()
        return Task { [currentAccount] in
            defer {
                isCreatingThread = false
                submittedText = nil
            }
            let thread: Thread
            do {
                thread = try await createThread(ThreadTitleGenerator.title(from: text), account)
            } catch {
                // Never into another account's composer, and never over
                // words typed since. A field holding only blank space holds
                // nothing to keep: the message that was not sent matters more.
                guard currentAccount() == account else { return }
                if messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { messageText = text }
                errorMessage = Self.couldNotStart
                return
            }
            // Another account by now: its thread list is not this text's place.
            guard currentAccount() == account else { return }
            do {
                try await sendFirstMessage(thread, text)
            } catch {
                guard currentAccount() == account else { return }
                keepUnsent(thread, text, error)
            }
            guard currentAccount() == account else { return }
            onThreadCreated(thread)
        }
    }
}
