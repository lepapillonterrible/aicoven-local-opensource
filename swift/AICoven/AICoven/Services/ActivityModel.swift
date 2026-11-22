internal import Combine
import Foundation

/// The threads Activity is made of: the signed-in account's that are not
/// archived, across Strix and every coven. Only its latest reading is
/// shown, and nothing read for an account that is no longer signed in.
@MainActor
final class ActivityModel: ObservableObject {
    @Published private var threads: [Thread]?
    /// Whether the latest reading failed.
    @Published private(set) var loadFailed = false

    private let loadThreads: () async throws -> [Thread]
    private let signedIn: () -> String
    /// Whose threads are held.
    private var account: String?
    /// Counts the readings, so that only the latest is shown.
    private var readings = 0

    init(
        loadThreads: @escaping () async throws -> [Thread] = { try await ThreadService.shared.threadsNotArchived() },
        signedIn: @escaping () -> String = { UserScope.currentUserID }
    ) {
        self.loadThreads = loadThreads
        self.signedIn = signedIn
    }

    /// The threads as last read, for the account signed in now; nil until
    /// they are read, and for another account's.
    var shown: [Thread]? {
        account == signedIn() ? threads : nil
    }

    /// Reads the threads. A reading that fails leaves what was read
    /// before for the same account as it is, and says it failed.
    func load() async {
        readings += 1
        let reading = readings
        let asked = signedIn()
        if account != asked {
            threads = nil
            account = asked
        }
        do {
            let read = try await loadThreads()
            guard reading == readings, signedIn() == asked else { return }
            threads = read.filter { $0.userId == asked }
            loadFailed = false
        } catch {
            guard reading == readings, signedIn() == asked else { return }
            // The kind of failure only.
            AppErrorReporter.log(message: "Could not read the threads for Activity (\(type(of: error)))", context: "ActivityModel.load")
            loadFailed = true
        }
    }
}
