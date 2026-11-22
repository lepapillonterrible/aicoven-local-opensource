internal import Combine
import Foundation

/// What the memory pages ask of the store: each as `account`, the one the
/// pages were read for.
protocol MemoryPagesManaging: Sendable {
    func memories(in place: MemoryPlace, limit: Int, offset: Int, as account: String?) async throws -> [Memory]
    func createMemory(in place: MemoryPlace, content: String, tags: [String]?, as account: String?) async throws -> Memory
    func updateMemory(memoryId: String, content: String, tags: [String]?, as account: String?) async throws -> Memory
    func deleteMemory(memoryId: String, as account: String?) async throws
}

extension MemoryService: MemoryPagesManaging {}

/// The memory pages of every place the person has opened in this window,
/// as in the cloud app: each place's entries, read when its Memory opens
/// and kept current by the pages' own edits.
///
/// What it holds is one account's. When another is signed in, what was
/// read for the first is dropped, and nothing that was asked as the first
/// is shown or kept.
@MainActor
final class MemoryPagesModel: ObservableObject {
    @Published private(set) var entriesByPlace: [MemoryPlace: [Memory]] = [:]
    @Published private(set) var loadFailed: Set<MemoryPlace> = []
    /// Entries whose edit is on its way. One can't be edited again until it
    /// lands, wherever the page is opened, so its saves land in order.
    @Published private(set) var savingIds: Set<String> = []
    /// Entries being forgotten; a second Forget waits for the first.
    @Published private(set) var forgettingIds: Set<String> = []
    /// The last failure of an action, by where it happened: an entry's id,
    /// or a section's Add (`addKey`). It is kept here and not by a page,
    /// so an action begun on a page that has since left the screen says
    /// what it came to on the page that shows the place now. The next
    /// action there clears it.
    @Published private(set) var failures: [String: String] = [:]

    static let couldNotAdd = "Couldn't add that. Try again."
    static let couldNotSave = "Couldn't save that change. Try again."
    static let couldNotForget = "Couldn't forget that. Try again."

    /// Where a failed Add to a page of a place is said (`page` is nil for
    /// About me).
    static func addKey(_ page: MemoryPage?, in place: MemoryPlace) -> String {
        "add:\(place):\(page?.rawValue ?? "about-me")"
    }

    static let pageSize = 100

    private let manager: MemoryPagesManaging
    private let signedIn: () -> String
    /// The account whose memory is held.
    private var account: String
    private var loads: [MemoryPlace: Task<Void, Never>] = [:]
    /// Counts each place's edits, so a load that started before an edit
    /// reads again rather than putting back what the edit changed.
    private var revisions: [MemoryPlace: Int] = [:]

    init(manager: MemoryPagesManaging = MemoryService.shared, signedIn: @escaping () -> String = { UserScope.currentUserID }) {
        self.manager = manager
        self.signedIn = signedIn
        account = signedIn()
    }

    /// The account signed in now. If it is another than the one whose
    /// memory is held, that memory is dropped first.
    private func currentAccount() -> String {
        let now = signedIn()
        if now != account {
            account = now
            loads.values.forEach { $0.cancel() }
            loads = [:]
            revisions = [:]
            entriesByPlace = [:]
            loadFailed = []
            savingIds = []
            forgettingIds = []
            failures = [:]
        }
        return now
    }

    /// Whether `asked`, the account something began as, is still the one
    /// signed in. If another is by now, what was held for the first is
    /// dropped here, and what the first began comes to nothing.
    private func isStill(_ asked: String) -> Bool {
        currentAccount() == asked
    }

    /// The place's entries once read; `nil` before the first read lands.
    func entries(in place: MemoryPlace) -> [Memory]? {
        entriesByPlace[place]
    }

    func didLoadFail(in place: MemoryPlace) -> Bool {
        loadFailed.contains(place)
    }

    /// A page's entries, oldest first, so a page reads in the order it was
    /// written. `page` is `nil` for About me, which holds every entry of
    /// the person's own memory.
    func entries(on page: MemoryPage?, in place: MemoryPlace) -> [Memory] {
        (entries(in: place) ?? [])
            .filter { page == nil || $0.page == page }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    /// Reads the place's entries again, sharing a read already under way.
    func load(_ place: MemoryPlace) async {
        let asked = currentAccount()
        if let running = loads[place] {
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            var fetched: [Memory]?
            var revision: Int
            // Read again until no change landed while it was read.
            repeat {
                revision = revisions[place, default: 0]
                fetched = try? await fetchAll(in: place, as: asked)
            } while fetched != nil && account == asked && revision != revisions[place, default: 0]
            // Another account's by now: what was read is nobody's to see.
            guard account == asked, signedIn() == asked else {
                return
            }
            if let fetched {
                entriesByPlace[place] = fetched
                loadFailed.remove(place)
            } else {
                loadFailed.insert(place)
            }
            loads[place] = nil
        }
        loads[place] = task
        await task.value
    }

    /// Every entry, a page at a time. Stops at a short page, or at a page
    /// that brings nothing new.
    private func fetchAll(in place: MemoryPlace, as asked: String) async throws -> [Memory] {
        var all: [Memory] = []
        var seen = Set<String>()
        // Rows read so far, duplicates included: a row added meanwhile moves
        // the rest down a place, so the next page starts after every row read.
        var offset = 0
        while true {
            let page = try await manager.memories(in: place, limit: Self.pageSize, offset: offset, as: asked)
            let fresh = page.filter { seen.insert($0.id).inserted }
            all += fresh
            offset += page.count
            if page.count < Self.pageSize || fresh.isEmpty { return all }
        }
    }

    // MARK: - Edits

    /// Forgets what was last said to have failed at `key`.
    func clearFailure(_ key: String) {
        failures[key] = nil
    }

    /// Adds an entry to a page of a place. True once it is kept; if it
    /// could not be, that is said at the page's Add (`failures`), unless
    /// another account is signed in by then.
    @discardableResult
    func add(_ text: String, on page: MemoryPage?, in place: MemoryPlace) async -> Bool {
        let asked = currentAccount()
        let key = Self.addKey(page, in: place)
        failures[key] = nil
        do {
            let added = try await manager.createMemory(in: place, content: text, tags: page?.tagsForNewEntry, as: asked)
            guard isStill(asked) else { return false }
            apply(in: place) { $0.append(added) }
        } catch {
            if isStill(asked) { failures[key] = Self.couldNotAdd }
            return false
        }
        // A place whose entries have not been read (its first read failed,
        // say) has nothing to add the entry to: it is read now, so that
        // what was kept is shown.
        if entriesByPlace[place] == nil {
            await load(place)
        }
        return isStill(asked)
    }

    /// Saves new text for `memory`. True once it is saved; false, with
    /// nothing said, while an earlier edit of `memory` is on its way; if
    /// it could not be saved, that is said at the entry (`failures`).
    @discardableResult
    func edit(_ memory: Memory, to text: String, in place: MemoryPlace) async -> Bool {
        let asked = currentAccount()
        guard savingIds.insert(memory.id).inserted else { return false }
        defer { if isStill(asked) { savingIds.remove(memory.id) } }
        failures[memory.id] = nil
        do {
            let updated = try await manager.updateMemory(memoryId: memory.id, content: text, tags: nil, as: asked)
            guard isStill(asked) else { return false }
            apply(in: place) { entries in
                if let index = entries.firstIndex(where: { $0.id == updated.id }) {
                    entries[index] = updated
                }
            }
            return true
        } catch {
            if isStill(asked) { failures[memory.id] = Self.couldNotSave }
            return false
        }
    }

    /// Forgets `memory`. True once it is forgotten; false, with nothing
    /// said, while it is already being forgotten; if it could not be,
    /// that is said at the entry (`failures`).
    @discardableResult
    func forget(_ memory: Memory, in place: MemoryPlace) async -> Bool {
        let asked = currentAccount()
        guard forgettingIds.insert(memory.id).inserted else { return false }
        defer { if isStill(asked) { forgettingIds.remove(memory.id) } }
        failures[memory.id] = nil
        do {
            try await manager.deleteMemory(memoryId: memory.id, as: asked)
            guard isStill(asked) else { return false }
            apply(in: place) { $0.removeAll { $0.id == memory.id } }
            return true
        } catch {
            if isStill(asked) { failures[memory.id] = Self.couldNotForget }
            return false
        }
    }

    /// Applies an edit the store confirmed. Before the first read there is
    /// nothing to change; the read under way, if any, reads again.
    private func apply(in place: MemoryPlace, _ change: (inout [Memory]) -> Void) {
        revisions[place, default: 0] += 1
        guard var entries = entriesByPlace[place] else { return }
        change(&entries)
        entriesByPlace[place] = entries
    }
}

/// The rules for the page's typing fields (an edit's and an Add's).
nonisolated enum MemoryDraft {
    /// Whether an open field holds text that isn't saved: an Add with text, or
    /// an edit whose text differs from the entry's (`original`, `nil` when no
    /// edit is open). While one does, no other Edit, Add or Forget starts, so
    /// nothing the person typed is closed without Save or Cancel.
    static func holdsText(editing original: String?, editDraft: String, adding: Bool, addDraft: String) -> Bool {
        if let original, !isUnchanged(editDraft, from: original) { return true }
        return adding && !trimmed(addDraft).isEmpty
    }

    /// Whether saving `draft` would change nothing: it is `original`, the text
    /// the edit started from, apart from whitespace at either end.
    static func isUnchanged(_ draft: String, from original: String) -> Bool {
        trimmed(draft) == trimmed(original)
    }

    /// Whether an entry with this stored text is edited in a multi-line field.
    /// A single-line field turns line breaks into spaces on the first change,
    /// so an entry that has some can't be edited in one.
    static func editsInMultilineField(_ storedText: String) -> Bool {
        storedText.contains(where: \.isNewline)
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
