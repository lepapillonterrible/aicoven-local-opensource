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
        // IMPORTANT: Do NOT load threads here. The active user scope may change
        // after authentication, so threads are loaded in reloadForCurrentUser()
        // using the scoped persistence path for the current owner.
        persistenceURL = ThreadService.makePersistenceURL()
        // Start with empty array - will be populated after auth via reloadForCurrentUser()
        personalThreads = []
    }

    /// Reload threads for the current user. Call after user switch.
    func reloadForCurrentUser() {
        persistenceURL = ThreadService.makePersistenceURL()
        AppErrorReporter.log(message: "Reloading scoped personal threads", context: "ThreadService.reloadForCurrentUser")

        personalThreads = ThreadService.loadThreadsFromDisk(persistenceURL: persistenceURL)

        // Clean up any orphaned threads without a valid user ID.
        // These may exist from before authentication was required.
        cleanupOrphanedThreads()

        // Clean up threads created by automated tests
        cleanupTestThreads()
    }

    /// Remove threads created by automated tests (identified by "Test Thread" prefix).
    /// Call this to clean up after running tests with a real Firebase account.
    func cleanupTestThreads() {
        let testThreads = personalThreads.filter { thread in
            thread.title?.hasPrefix("Test Thread") == true
        }

        if !testThreads.isEmpty {
            AppErrorReporter.log(message: "Removing \(testThreads.count) automated test threads", context: "ThreadService.cleanupTestThreads")
            personalThreads.removeAll { thread in
                thread.title?.hasPrefix("Test Thread") == true
            }
            persistPersonalThreads()
        }
    }

    /// Remove threads that don't belong to the current user.
    /// This handles legacy threads created before auth was required.
    private func cleanupOrphanedThreads() {
        let currentUserID = UserScope.currentUserID

        // Remove threads with missing or mismatched user IDs
        let validUserIDs = [currentUserID] // Only current user's threads are valid
        let orphanedThreads = personalThreads.filter { thread in
            thread.userId.isEmpty ||
                !validUserIDs.contains(thread.userId)
        }

        if !orphanedThreads.isEmpty {
            AppErrorReporter.log(message: "Removing \(orphanedThreads.count) orphaned threads (invalid user ID)", context: "ThreadService.cleanupOrphanedThreads")
            personalThreads.removeAll { thread in
                thread.userId.isEmpty ||
                    thread.userId == "local-user" ||
                    !validUserIDs.contains(thread.userId)
            }
            persistPersonalThreads()
        }
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
        let currentUserID = UserScope.currentUserID

        if let covenId {
            // Coven threads are persisted locally just like personal threads.
            AppErrorReporter.log(message: "Creating coven thread (covenId: \(covenId)) in local store", context: "ThreadService.createThread")
            let now = Date()
            let normalizedTitle = ThreadInputValidator.normalizedTitle(title, defaultTitle: "Coven Chat")
            let thread = await Thread(
                id: UUID().uuidString,
                userId: currentUserID,
                covenId: covenId,
                title: normalizedTitle,
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
            await AnalyticsService.shared.trackThreadCreated(covenId: covenId, agentId: agentId)
            await MainActor.run {
                NotificationCenter.default.post(name: .didCreateThread, object: nil, userInfo: ["thread": thread])
            }
            return thread
        } else {
            AppErrorReporter.log(message: "Creating personal thread in local store", context: "ThreadService.createThread")
            let now = Date()
            let normalizedTitle = ThreadInputValidator.normalizedTitle(title, defaultTitle: "New Chat")
            let thread = await Thread(
                id: UUID().uuidString,
                userId: currentUserID,
                covenId: nil,
                title: normalizedTitle,
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
            await AnalyticsService.shared.trackThreadCreated(covenId: nil, agentId: agentId)

            // Notify listeners
            await MainActor.run {
                NotificationCenter.default.post(name: .didCreateThread, object: nil, userInfo: ["thread": thread])
            }

            return thread
        }
    }

    /// Get a specific thread
    /// - Parameter threadId: The thread ID
    /// - Returns: The thread
    /// - Throws: Error if thread not found or no authenticated user
    func getThread(threadId: String) async throws -> Thread {
        if let local = personalThreads.first(where: { $0.id == threadId }) {
            return local
        }
        // Thread not found - throw error instead of returning placeholder
        throw NSError(
            domain: "ThreadService",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Thread not found"]
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
            let newTitle = title.map { ThreadInputValidator.normalizedTitle($0, defaultTitle: thread.title ?? "New Chat") } ?? thread.title
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

        // If no local thread is found, throw the same sanitized not-found
        // error as getThread(threadId:) rather than logging opaque IDs.
        return try await getThread(threadId: threadId)
    }

    /// Delete a thread
    /// - Parameter threadId: The thread ID
    func deleteThread(threadId: String) async throws {
        if let index = personalThreads.firstIndex(where: { $0.id == threadId }) {
            personalThreads.remove(at: index)
            persistPersonalThreads()
            AppErrorReporter.log(message: "Deleted personal thread from local store", context: "ThreadService.deleteThread")

            // Track analytics
            await AnalyticsService.shared.trackThreadDeleted(threadId: threadId)
        } else {
            AppErrorReporter.log(message: "Ignoring delete for unknown thread", context: "ThreadService.deleteThread")
        }
    }
}

extension Notification.Name {
    static let didCreateThread = Notification.Name("didCreateThread")
}
