import Foundation

/// What each thread's composer holds unsent: its text and its attachments.
/// The text is kept with the thread, encrypted, so it is there when the
/// thread is opened again, in this run of the app or the next; while it
/// changes it is saved at most once every `saveDelay`, not on every
/// keystroke, and at once when asked. Attachments are kept while the app
/// runs.
@MainActor
final class ComposerDrafts {
    static let shared = ComposerDrafts()

    /// Runs `action` after `delay` seconds.
    typealias Schedule = (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Void

    /// How long after a text first changes it is saved, with whatever it
    /// has become by then.
    static let saveDelay: TimeInterval = 0.8

    /// The drafts read or set since the app started, by thread id.
    private var drafts: [String: ComposerDraft] = [:]
    /// The reads of kept text under way, by thread id: a thread opened in
    /// two places at once is read once.
    private var reads: [String: Task<String?, Never>] = [:]
    /// The threads whose text has changed since it was last saved.
    private var unsaved: Set<String> = []
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
    /// read, or the account changed while it was read.
    func draft(for threadID: String) async -> ComposerDraft {
        if let known = drafts[threadID] { return known }
        let account = currentAccount()
        let reading = reads[threadID] ?? Task { [load] in
            do {
                return try await load(threadID)
            } catch {
                Self.log("A draft could not be read", error)
                return nil
            }
        }
        reads[threadID] = reading
        let kept = await reading.value
        if reads[threadID] == reading { reads[threadID] = nil }
        // Nothing of an earlier account's is handed on, read or set.
        guard currentAccount() == account else { return ComposerDraft() }
        // What was set while the kept text was read is newer than it.
        if let known = drafts[threadID] { return known }
        let draft = ComposerDraft(text: kept ?? "")
        drafts[threadID] = draft
        return draft
    }

    /// Takes what the thread's composer now holds. A change of its text is
    /// saved within `saveDelay`.
    func set(_ draft: ComposerDraft, for threadID: String) {
        // An empty composer says nothing of a thread whose kept text has
        // not been read: that text stands.
        guard drafts[threadID] != nil || !draft.isEmpty else { return }
        let textChanged = drafts[threadID]?.text != draft.text
        drafts[threadID] = draft
        guard textChanged else { return }
        unsaved.insert(threadID)
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
        guard !sent.isEmpty, var draft = drafts[threadID] else { return }
        let ids = Set(sent.map(\.id))
        draft.attachments.removeAll { ids.contains($0.id) }
        drafts[threadID] = draft
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
        for threadID in changed {
            do {
                try await save(drafts[threadID]?.text ?? "", threadID)
            } catch {
                // Tried again with the next save, unless it has changed
                // again by then and is waiting already.
                Self.log("A draft could not be saved", error)
                unsaved.insert(threadID)
            }
        }
    }

    /// Logs what failed and the error's kind, never its description.
    private static func log(_ what: String, _ error: Error) {
        let error = error as NSError
        AppErrorReporter.log(message: "\(what) (\(error.domain) \(error.code)).", context: "ComposerDrafts")
    }
}
