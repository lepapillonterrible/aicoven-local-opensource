internal import Combine
import Foundation

/// The threads of the scope the shell shows, archived ones among them, as
/// last read from the store. Read again when the scope changes, a message is
/// stored, a thread is made, or one is renamed, archived or deleted.
@MainActor
final class ShellThreads: ObservableObject {
    typealias Load = @Sendable (_ covenID: String?) async throws -> [Thread]

    /// The threads of `scope`, in no particular order.
    @Published private(set) var threads: [Thread] = []
    /// Whose threads `threads` are; nil until a scope is asked for.
    @Published private(set) var scope: ShellScope?
    /// The scope's threads have been read (or the reading failed): until
    /// then an empty list is not yet "no threads".
    @Published private(set) var hasLoaded = false
    /// The scope's threads could not be read, and none are shown.
    @Published private(set) var failed = false

    private let loadThreads: Load
    /// Counts the readings, so that only the latest is shown.
    private var readings = 0

    init(load: @escaping Load = { try await ThreadService.shared.loadThreads(covenId: $0, includeArchived: true) }) {
        loadThreads = load
    }

    /// Reads `scope`'s threads. Another scope's threads go at once: they are
    /// not shown under this one's name while its own are read.
    @discardableResult
    func load(_ scope: ShellScope) -> Task<Void, Never> {
        if scope != self.scope {
            self.scope = scope
            threads = []
            hasLoaded = false
            failed = false
        }
        readings += 1
        let reading = readings
        return Task { [loadThreads] in
            do {
                let stored = try await loadThreads(scope.covenID)
                // Only the latest reading, and only for the scope still shown.
                guard reading == readings, self.scope == scope else { return }
                threads = stored
                failed = false
            } catch {
                guard reading == readings, self.scope == scope else { return }
                // The kind of failure only.
                AppErrorReporter.log(message: "Could not read the scope's threads (\(type(of: error)))", context: "ShellThreads.load")
                // A list already shown stays as it is: it was only being read
                // again. Unless the data is locked or the account another's.
                if !(hasLoaded && !failed && ThreadListRules.keepsShownList(after: error)) {
                    threads = []
                    failed = true
                }
            }
            hasLoaded = true
        }
    }

    /// Reads the shown scope's threads again.
    @discardableResult
    func reload() -> Task<Void, Never>? {
        scope.map { load($0) }
    }

    /// Reads the shown scope's threads again because the person asked, and
    /// says whether that reading failed: true only if it is still the
    /// latest reading when it ends, of the scope still shown, and nothing
    /// could be read. A reading that another has overtaken says nothing of
    /// its own.
    func retry() async -> Bool {
        guard let scope, let reading = reload() else { return false }
        let mine = readings
        await reading.value
        return mine == readings && self.scope == scope && failed
    }
}
