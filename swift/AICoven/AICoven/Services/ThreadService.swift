import Foundation

/// Service for thread-related operations.
///
/// In the open-source, local-first client we do **not** talk to the
/// multi-tenant backend. Personal threads are stored locally and
/// persisted to disk. Coven-based threads are stubbed out and return
/// empty results so legacy code can compile without surfacing coven UI.
actor ThreadService {
    static let shared = ThreadService()

    /// Local store for personal threads (covenId == nil).
    /// Backed by a simple JSON file on disk so that threads persist
    /// across app launches.
    private var personalThreads: [Thread] = []

    /// Location on disk where we persist personal threads.
    private var persistenceURL: URL

    private init() {
        persistenceURL = ThreadService.makePersistenceURL()
        personalThreads = ThreadService.loadThreadsFromDisk(persistenceURL: persistenceURL)
    }

    /// Reload threads for the current user. Call after user switch.
    func reloadForCurrentUser() {
        persistenceURL = ThreadService.makePersistenceURL()
        personalThreads = ThreadService.loadThreadsFromDisk(persistenceURL: persistenceURL)
    }

    // MARK: - Persistence helpers

    /// Compute the URL where the threads JSON file should live.
    private static func makePersistenceURL() -> URL {
        let fileManager = FileManager.default
        let baseDir: URL
        #if os(iOS) || os(tvOS) || os(watchOS)
        baseDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        #else
        // On macOS prefer Application Support, but fall back to Documents if needed.
        baseDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        #endif
        let appDir = baseDir.appendingPathComponent("AICoven", isDirectory: true)
        // Best-effort create with logging so failures are visible during
        // debugging, but do not crash the app.
        do {
            try fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        } catch {
            AppErrorReporter.log(error: error, context: "ThreadService.makePersistenceURL.createDirectory")
        }
        let filename = UserScope.scopedFilename("personal_threads", extension: "json")
        return appDir.appendingPathComponent(filename, isDirectory: false)
    }

    /// Load any previously-saved personal threads from disk.
    ///
    /// Marked as `internal` so tests can exercise the decode-error path and
    /// assert on the corresponding AppErrorReporter logging context.
    static func loadThreadsFromDisk(persistenceURL: URL) -> [Thread] {
        do {
            let data = try Data(contentsOf: persistenceURL)
            let decoder = JSONDecoder()
            let threads = try decoder.decode([Thread].self, from: data)
            AppErrorReporter.log(message: "Loaded \(threads.count) personal threads from disk", context: "ThreadService.loadThreadsFromDisk")
            return threads
        } catch {
            // It's fine if the file does not exist yet or decoding fails;
            // we just start with an empty list.
            if (error as NSError).code != NSFileNoSuchFileError {
                AppErrorReporter.log(error: error, context: "ThreadService.loadThreadsFromDisk")
            }
            return []
        }
    }

    /// Persist the current in-memory personal threads to disk.
    private func persistPersonalThreads() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(personalThreads)
            try data.write(to: persistenceURL, options: [.atomic])
            AppErrorReporter.log(message: "Saved \(personalThreads.count) personal threads to disk", context: "ThreadService.persistPersonalThreads")
        } catch {
            AppErrorReporter.log(error: error, context: "ThreadService.persistPersonalThreads")
        }
    }

    /// Load threads for a coven or personal threads
    /// - Parameters:
    ///   - covenId: The coven ID (nil for personal threads)
    ///   - includeArchived: Whether to include archived threads
    /// - Returns: List of threads
    func loadThreads(covenId: String? = nil, includeArchived: Bool = false) async throws -> [Thread] {
        let filtered: [Thread]
        if let covenId {
            // Return locally persisted threads that belong to this coven.
            filtered = personalThreads.filter { $0.covenId == covenId }
            AppErrorReporter.log(message: "Loading coven threads (covenId: \(covenId)) from local store (\(filtered.count) found)", context: "ThreadService.loadThreads")
        } else {
            // Personal threads have no covenId.
            filtered = personalThreads.filter { $0.covenId == nil }
            AppErrorReporter.log(message: "Loading personal threads from local store (\(filtered.count) total)", context: "ThreadService.loadThreads")
        }
        if includeArchived {
            return filtered
        } else {
            return filtered.filter { !$0.isArchived }
        }
    }

    /// Create a new thread in a coven or personal
    /// - Parameters:
    ///   - title: Thread title (optional)
    ///   - covenId: The coven ID (nil for personal thread)
    ///   - agentId: AI agent/role ID (optional)
    /// - Returns: The created thread
    func createThread(title: String? = nil, covenId: String? = nil, agentId: String? = nil, agentName: String? = nil) async throws -> Thread {
        if let covenId {
            // Coven threads are persisted locally just like personal threads.
            AppErrorReporter.log(message: "Creating coven thread (covenId: \(covenId)) in local store", context: "ThreadService.createThread")
            let now = Date()
            let thread = await Thread(
                id: UUID().uuidString,
                userId: AuthService.shared.currentUser?.id ?? "local-user",
                covenId: covenId,
                title: title ?? "Coven Chat",
                agentId: agentId,
                agentName: agentName,
                agentModel: nil,
                isPinned: false,
                isArchived: false,
                messageCount: 0,
                createdAt: now,
                updatedAt: now,
                lastMessageAt: nil
            )
            personalThreads.append(thread)
            persistPersonalThreads()
            AnalyticsService.shared.trackThreadCreated(covenId: covenId, agentId: agentId)
            return thread
        } else {
            AppErrorReporter.log(message: "Creating personal thread in local store", context: "ThreadService.createThread")
            let now = Date()
            let thread = await Thread(
                id: UUID().uuidString,
                userId: AuthService.shared.currentUser?.id ?? "local-user",
                covenId: nil,
                title: title ?? "New Chat",
                agentId: agentId,
                agentName: agentName,
                agentModel: nil,
                isPinned: false,
                isArchived: false,
                messageCount: 0,
                createdAt: now,
                updatedAt: now,
                lastMessageAt: nil
            )
            personalThreads.append(thread)
            persistPersonalThreads()

            // Track analytics
            AnalyticsService.shared.trackThreadCreated(covenId: nil, agentId: agentId)

            return thread
        }
    }

    /// Get a specific thread
    /// - Parameter threadId: The thread ID
    /// - Returns: The thread
    func getThread(threadId: String) async throws -> Thread {
        if let local = personalThreads.first(where: { $0.id == threadId }) {
            return local
        }
        // For coven threads in the legacy app, just synthesize a placeholder
        // so callers don't crash. In the local-first client these should not
        // be used.
        AppErrorReporter.log(message: "getThread(\(threadId)) called in local-only build – returning placeholder thread.", context: "ThreadService.getThread")
        let now = Date()
        return await Thread(
            id: threadId,
            userId: AuthService.shared.currentUser?.id ?? "local-user",
            covenId: nil,
            title: "Chat",
            agentId: nil,
            agentName: nil,
            agentModel: nil,
            isPinned: false,
            isArchived: false,
            messageCount: 0,
            createdAt: now,
            updatedAt: now,
            lastMessageAt: nil
        )
    }

    /// Update a thread
    /// - Parameters:
    ///   - threadId: The thread ID
    ///   - title: New title (optional)
    ///   - agentId: New agent ID (optional)
    ///   - isPinned: Pin status (optional)
    ///   - isArchived: Archive status (optional)
    /// - Returns: The updated thread
    func updateThread(
        threadId: String,
        title: String? = nil,
        agentId: String? = nil,
        isPinned: Bool? = nil,
        isArchived: Bool? = nil
    ) async throws -> Thread {
        struct UpdateThreadRequest: Encodable {
            let title: String?
            let agentId: String?
            let isPinned: Bool?
            let isArchived: Bool?

            enum CodingKeys: String, CodingKey {
                case title
                case agentId = "agent_id"
                case isPinned = "is_pinned"
                case isArchived = "is_archived"
            }
        }

        // Update in-memory personal thread if present. We ignore coven
        // threads in the local-first client.
        if let index = personalThreads.firstIndex(where: { $0.id == threadId }) {
            let thread = personalThreads[index]
            let newTitle = title ?? thread.title
            let newAgentId = agentId ?? thread.agentId
            let newPinned = isPinned ?? thread.isPinned
            let newArchived = isArchived ?? thread.isArchived
            let updated = Thread(
                id: thread.id,
                userId: thread.userId,
                covenId: thread.covenId,
                title: newTitle,
                agentId: newAgentId,
                agentName: thread.agentName,
                agentModel: thread.agentModel,
                isPinned: newPinned,
                isArchived: newArchived,
                messageCount: thread.messageCount,
                createdAt: thread.createdAt,
                updatedAt: Date(),
                lastMessageAt: thread.lastMessageAt
            )
            personalThreads[index] = updated
            persistPersonalThreads()
            return updated
        }

        // If no local thread found, just return a synthesized placeholder so
        // callers have something to work with.
        print("📝 updateThread(\(threadId)) called for unknown thread in local-only build – returning placeholder.")
        return try await getThread(threadId: threadId)
    }

    /// Delete a thread
    /// - Parameter threadId: The thread ID
    func deleteThread(threadId: String) async throws {
        if let index = personalThreads.firstIndex(where: { $0.id == threadId }) {
            personalThreads.remove(at: index)
            persistPersonalThreads()
            print("🗑️ Deleted personal thread \(threadId) from local store")

            // Track analytics
            AnalyticsService.shared.trackThreadDeleted(threadId: threadId)
        } else {
            print("🗑️ deleteThread(\(threadId)) called for unknown thread in local-only build – ignoring.")
        }
    }
}
