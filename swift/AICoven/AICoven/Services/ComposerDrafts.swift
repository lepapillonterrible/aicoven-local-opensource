import Foundation

/// What each thread's composer holds unsent: its text and its attachments.
/// The text is kept with the thread, encrypted, so it is there when the
/// thread is opened again, in this run of the app or the next; it is saved a
/// moment after it stops changing, not on every keystroke. Attachments are
/// kept while the app runs.
@MainActor
final class ComposerDrafts {
    static let shared = ComposerDrafts()

    /// Runs `action` after `delay` seconds.
    typealias Schedule = (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Void

    /// How long the text has to stop changing before it is saved.
    static let saveDelay: TimeInterval = 0.8

    /// The drafts read or set since the app started, by thread id.
    private var drafts: [String: ComposerDraft] = [:]
    /// The threads whose text has changed since it was last saved.
    private var unsaved: Set<String> = []
    private var saveIsScheduled = false

    private let load: @Sendable (_ threadID: String) async throws -> String?
    private let save: @Sendable (_ text: String, _ threadID: String) async throws -> Void
    private let schedule: Schedule

    init(
        load: @escaping @Sendable (String) async throws -> String? = { try await ThreadRepository.shared.draft(forThread: $0) },
        save: @escaping @Sendable (String, String) async throws -> Void = { try await ThreadRepository.shared.saveDraft($0, forThread: $1) },
        schedule: @escaping Schedule = { delay, action in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
                action()
            }
        }
    ) {
        self.load = load
        self.save = save
        self.schedule = schedule
    }

    /// The thread's draft: what was set since the app started, or else the
    /// text kept with the thread. Empty when there is none, or it cannot be
    /// read.
    func draft(for threadID: String) async -> ComposerDraft {
        if let known = drafts[threadID] { return known }
        let account = UserScope.currentUserID
        var kept: String?
        do {
            kept = try await load(threadID)
        } catch {
            Self.log("A draft could not be read", error)
        }
        // What was set while the kept text was read is newer than it.
        if let known = drafts[threadID] { return known }
        // Nor is anything of an earlier account's handed on.
        guard UserScope.currentUserID == account else { return ComposerDraft() }
        let draft = ComposerDraft(text: kept ?? "")
        drafts[threadID] = draft
        return draft
    }

    /// Takes what the thread's composer now holds. Its text is saved once
    /// it has stopped changing for a moment.
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
            Task { await self.saveNow() }
        }
    }

    /// Saves every text that has changed since it was last saved, now: the
    /// app is leaving the foreground, or the thread the screen.
    func saveNow() async {
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
