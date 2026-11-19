import Foundation

/// Moves chat history out of the two plain JSON files earlier builds kept it
/// in and into the encrypted database: once for each account, the first time
/// its history is read after its data is unlocked. A file is deleted only
/// after everything in it is stored.
actor LegacyChatHistoryImport {
    static let shared = LegacyChatHistoryImport()

    /// Accounts whose files have been dealt with since launch.
    private var finished: Set<String> = []
    /// The import under way for an account, which later callers wait on.
    private var running: [String: Task<Void, Error>] = [:]

    private init() {}

    /// Returns once the current account's files, if any, are in the
    /// database. Throws, leaving the files where they are, when they cannot
    /// be stored, for example while the account's data is locked.
    func importIfNeeded() async throws {
        #if DEBUG
        // Tests unlock with a key that lasts one test. Run against a
        // developer's own app data, an import under that key would store
        // their history unreadably and then delete the files.
        if DataEncryptionService.isRunningTests { return }
        #endif
        let userID = UserScope.currentUserID
        if finished.contains(userID) { return }
        if let task = running[userID] {
            return try await task.value
        }
        let task = Task {
            try await Self.importFiles(
                for: userID,
                threadsFile: Self.threadsFileURL(for: userID),
                messagesFile: Self.messagesFileURL(for: userID)
            )
        }
        running[userID] = task
        defer { running[userID] = nil }
        try await task.value
        finished.insert(userID)
    }

    /// Imports the two files as the account `userID`'s history.
    static func importFiles(for userID: String, threadsFile: URL, messagesFile: URL) async throws {
        let storedThreads = read([Thread].self, at: threadsFile)
        let storedMessages = read([String: [ChatMessage]].self, at: messagesFile)
        guard storedThreads != nil || storedMessages != nil else { return }

        // The file is the account's own, but earlier builds could leave
        // another account's threads in it; those are not this account's.
        let threads = (storedThreads ?? []).filter { $0.userId == userID }
        try await ThreadRepository.shared.importChatHistory(threads: threads, messages: storedMessages ?? [:], userID: userID)

        // Only a file that was read is stored, so only that is deleted. One
        // that could not be read was set aside, or is still where it was.
        for file in [storedThreads == nil ? nil : threadsFile, storedMessages == nil ? nil : messagesFile].compactMap(\.self) {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                AppErrorReporter.log(error: error, context: "LegacyChatHistoryImport.removeFile")
            }
        }
    }

    /// Decodes one of the files; `nil` when it is absent or cannot be read.
    /// A file that cannot be read is logged and set aside under a name of
    /// its own, as earlier builds started empty from it, so it neither
    /// blocks the import nor is deleted.
    static func read<Value: Decodable>(_ type: Value.Type, at file: URL) -> Value? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: file))
        } catch {
            AppErrorReporter.log(error: error, context: "LegacyChatHistoryImport.read")
            do {
                try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("unreadable-\(UUID().uuidString)"))
            } catch {
                AppErrorReporter.log(error: error, context: "LegacyChatHistoryImport.setAside")
            }
            return nil
        }
    }

    /// Where earlier builds kept an account's threads.
    static func threadsFileURL(for userID: String) -> URL {
        let fileManager = FileManager.default
        #if os(iOS) || os(tvOS) || os(watchOS)
        let directory: FileManager.SearchPathDirectory = .documentDirectory
        #else
        let directory: FileManager.SearchPathDirectory = .applicationSupportDirectory
        #endif
        let base = fileManager.urls(for: directory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("AICoven", isDirectory: true)
            .appendingPathComponent("personal_threads_\(userID).json", isDirectory: false)
    }

    /// Where earlier builds kept an account's messages.
    static func messagesFileURL(for userID: String) -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("AICovenOpen", isDirectory: true)
            .appendingPathComponent("messages_\(userID).json", isDirectory: false)
    }
}
