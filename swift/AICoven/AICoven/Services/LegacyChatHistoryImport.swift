import Foundation

/// Moves chat history out of the two plain JSON files earlier builds kept it
/// in and into the encrypted database: once for each account, the first time
/// its history is read after its data is unlocked. The files are deleted
/// only after everything in them is stored.
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
        let userID = UserScope.currentUserID
        if finished.contains(userID) { return }
        if let task = running[userID] {
            return try await task.value
        }
        let task = Task { try await Self.importFiles(for: userID) }
        running[userID] = task
        defer { running[userID] = nil }
        try await task.value
        finished.insert(userID)
    }

    static func importFiles(for userID: String) async throws {
        let threadsFile = threadsFileURL(for: userID)
        let messagesFile = messagesFileURL(for: userID)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: threadsFile.path) || fileManager.fileExists(atPath: messagesFile.path) else { return }

        // The file is the account's own, but earlier builds could leave
        // another account's threads in it; those are not this account's.
        let threads = (read([Thread].self, at: threadsFile) ?? []).filter { $0.userId == userID }
        let messages = read([String: [ChatMessage]].self, at: messagesFile) ?? [:]
        try await ThreadRepository.shared.importChatHistory(threads: threads, messages: messages)

        for file in [threadsFile, messagesFile] where fileManager.fileExists(atPath: file.path) {
            do {
                try fileManager.removeItem(at: file)
            } catch {
                AppErrorReporter.log(error: error, context: "LegacyChatHistoryImport.removeFile")
            }
        }
    }

    /// Decodes one of the files; `nil` when it is absent. A file that cannot
    /// be read is set aside under another name, as earlier builds started
    /// empty from it, so it neither blocks the import nor is lost.
    static func read<Value: Decodable>(_ type: Value.Type, at file: URL) -> Value? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: file))
        } catch {
            AppErrorReporter.log(error: error, context: "LegacyChatHistoryImport.read")
            do {
                try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("unreadable"))
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
