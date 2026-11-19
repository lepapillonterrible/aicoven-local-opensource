internal import Combine
import Foundation

/// What each thread's composer holds unsent: its text and its attachments.
/// The text is kept with the thread, encrypted, so it is there when the
/// thread is opened again, in this run of the app or the next; while it
/// changes it is saved at most once every `saveDelay`, not on every
/// keystroke, and at once when asked. Attachments are kept while the app
/// runs. Everything held here is held for the account it was read or typed
/// under, and is not handed to another.
@MainActor
final class ComposerDrafts {
    static let shared = ComposerDrafts()

    /// Runs `action` after `delay` seconds.
    typealias Schedule = (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Void

    /// How long after a text first changes it is saved, with whatever it
    /// has become by then.
    static let saveDelay: TimeInterval = 0.8

    /// A thread, as one account's.
    private struct Key: Hashable {
        let account: String
        let threadID: String
    }

    /// The drafts read or set since the app started, by account and
    /// thread.
    private var drafts: [Key: ComposerDraft] = [:]
    /// The reads of kept text under way: a thread opened in two places at
    /// once is read once.
    private var reads: [Key: Task<Read, Never>] = [:]

    /// What a read of a thread's kept text came to.
    private enum Read {
        case text(String?)
        case failed
    }

    /// The threads whose text has changed since it was last saved.
    private var unsaved: Set<Key> = []
    /// Sent files taken out of a thread's draft: a composer showing that
    /// thread takes them out of what it holds too.
    let attachmentsRemoved = PassthroughSubject<(threadID: String, ids: Set<String>), Never>()
    private var saveIsScheduled = false
    /// The last save started. Each waits for the one before, so a text
    /// saved later is stored later.
    private(set) var lastSave: Task<Void, Never>?

    private let load: @Sendable (_ threadID: String) async throws -> String?
    private let save: @Sendable (_ text: String, _ threadID: String) async throws -> Void
    private let schedule: Schedule
    /// The account signed in, by its id.
    private let currentAccount: @MainActor () -> String

    init(
        load: @escaping @Sendable (String) async throws -> String? = { try await ThreadRepository.shared.draft(forThread: $0) },
        save: @escaping @Sendable (String, String) async throws -> Void = { try await ThreadRepository.shared.saveDraft($0, forThread: $1) },
        schedule: @escaping Schedule = { delay, action in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
                action()
            }
        },
        currentAccount: @escaping @MainActor () -> String = { UserScope.currentUserID }
    ) {
        self.load = load
        self.save = save
        self.schedule = schedule
        self.currentAccount = currentAccount
    }

    /// The thread's draft: what was set since the app started, or else the
    /// text kept with the thread. Empty when there is none, it cannot be
    /// read for now, or the account changed while it was read.
    func draft(for threadID: String) async -> ComposerDraft {
        let key = Key(account: currentAccount(), threadID: threadID)
        if let known = drafts[key] { return known }
        let reading = reads[key] ?? Task { [load] in
            do {
                return try await Read.text(load(threadID))
            } catch {
                Self.log("A draft could not be read", error)
                return Read.failed
            }
        }
        reads[key] = reading
        let read = await reading.value
        if reads[key] == reading { reads[key] = nil }
        // Nothing of an earlier account's is handed on, read or set: what
        // was read was read as the account that asked.
        guard currentAccount() == key.account else { return ComposerDraft() }
        // What was set while the kept text was read is newer than it.
        if let known = drafts[key] { return known }
        // A read that failed says nothing of what is kept: it is read
        // again the next time the thread is asked for.
        guard case let .text(kept) = read else { return ComposerDraft() }
        let draft = ComposerDraft(text: kept ?? "")
        drafts[key] = draft
        return draft
    }

    /// Takes what the thread's composer now holds. A change of its text is
    /// saved within `saveDelay`.
    func set(_ draft: ComposerDraft, for threadID: String) {
        let key = Key(account: currentAccount(), threadID: threadID)
        // An empty composer says nothing of a thread whose kept text has
        // not been read: that text stands.
        guard drafts[key] != nil || !draft.isEmpty else { return }
        let textChanged = drafts[key]?.text != draft.text
        drafts[key] = draft
        guard textChanged else { return }
        unsaved.insert(key)
        guard !saveIsScheduled else { return }
        saveIsScheduled = true
        schedule(Self.saveDelay) { [weak self] in
            guard let self else { return }
            saveIsScheduled = false
            startSave()
        }
    }

    /// Takes sent attachments out of the thread's draft, wherever its
    /// composer is by now: a message can be accepted after its thread has
    /// left the screen, and its files are not to go with another.
    func removeAttachments(_ sent: [FileAttachmentDetail], from threadID: String) {
        guard !sent.isEmpty else { return }
        let ids = Set(sent.map(\.id))
        let key = Key(account: currentAccount(), threadID: threadID)
        if var draft = drafts[key] {
            draft.attachments.removeAll { ids.contains($0.id) }
            drafts[key] = draft
        }
        // A composer opened on the thread since the message was sent holds
        // them too.
        attachmentsRemoved.send((threadID, ids))
    }

    /// Saves every text that has changed since it was last saved, now: the
    /// app is leaving the foreground, or the thread the screen.
    func saveNow() async {
        await startSave().value
    }

    /// Starts a save of what has changed, after the saves started before.
    @discardableResult
    private func startSave() -> Task<Void, Never> {
        let previous = lastSave
        let saving = Task { [weak self] in
            await previous?.value
            await self?.saveChanged()
        }
        lastSave = saving
        return saving
    }

    private func saveChanged() async {
        let changed = unsaved
        unsaved = []
        // Only what the account signed in typed: another's waits for it.
        for key in changed where key.account != currentAccount() {
            unsaved.insert(key)
        }
        for key in changed where key.account == currentAccount() {
            do {
                try await save(drafts[key]?.text ?? "", key.threadID)
            } catch {
                // Tried again with the next save, unless it has changed
                // again by then and is waiting already.
                Self.log("A draft could not be saved", error)
                unsaved.insert(key)
            }
        }
    }

    /// Logs what failed and the error's kind, never its description.
    private static func log(_ what: String, _ error: Error) {
        let error = error as NSError
        AppErrorReporter.log(message: "\(what) (\(error.domain) \(error.code)).", context: "ComposerDrafts")
    }
}
