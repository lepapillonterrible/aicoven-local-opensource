import Foundation

/// Service for thread-related operations.
///
/// In the open-source, local-first client we do **not** talk to the
/// multi-tenant backend. Threads are stored in the encrypted local database
/// and cached here once read.
actor ThreadService {
    static let shared = ThreadService()

    /// The current account's threads, personal and coven, once loaded.
    private var personalThreads: [Thread] = []
    /// The account `personalThreads` was loaded for; `nil` until it is.
    private var loadedUserID: String?

    private init() {}

    /// Forget the loaded threads. Call after a user switch or sign-out; the
    /// next read loads the current account's.
    func reloadForCurrentUser() {
        personalThreads = []
        loadedUserID = nil
    }

    /// Loads the current account's threads from the database. It throws
    /// while the account's data is locked, and loads on a later call.
    private func ensureLoaded() async throws {
        let userID = UserScope.currentUserID
        guard loadedUserID != userID else { return }
        let threads = try await ThreadRepository.shared.loadChatThreads()
        // The account can change while the database answers.
        guard UserScope.currentUserID == userID, loadedUserID != userID else { return }
        personalThreads = threads.sorted { $0.createdAt < $1.createdAt }
        loadedUserID = userID
        await cleanupTestThreads()
    }

    /// Remove threads created by automated tests (identified by "Test Thread" prefix).
    /// Call this to clean up after running tests with a real Firebase account.
    func cleanupTestThreads() async {
        let testThreads = personalThreads.filter { $0.title?.hasPrefix("Test Thread") == true }
        guard !testThreads.isEmpty else { return }
        AppErrorReporter.log(message: "Removing \(testThreads.count) automated test threads", context: "ThreadService.cleanupTestThreads")
        for thread in testThreads {
            do {
                try await ThreadRepository.shared.deleteThread(id: thread.id)
                personalThreads.removeAll { $0.id == thread.id }
            } catch {
                AppErrorReporter.log(error: error, context: "ThreadService.cleanupTestThreads")
            }
        }
    }

    /// Load threads for a coven or personal threads
    /// - Parameters:
    ///   - covenId: The coven ID (nil for personal threads)
    ///   - includeArchived: Whether to include archived threads
    /// - Returns: List of threads
    func loadThreads(covenId: String? = nil, includeArchived: Bool = false) async throws -> [Thread] {
        try await ensureLoaded()
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
        try await ensureLoaded()
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
            try await ThreadRepository.shared.saveThread(thread)
            personalThreads.append(thread)
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
            try await ThreadRepository.shared.saveThread(thread)
            personalThreads.append(thread)

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
        try await ensureLoaded()
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

        try await ensureLoaded()
        if let thread = personalThreads.first(where: { $0.id == threadId }) {
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
            try await ThreadRepository.shared.saveThread(updated)
            // The list can change while the database writes.
            if let index = personalThreads.firstIndex(where: { $0.id == threadId }) {
                personalThreads[index] = updated
            }
            return updated
        }

        // If no local thread is found, throw the same sanitized not-found
        // error as getThread(threadId:) rather than logging opaque IDs.
        return try await getThread(threadId: threadId)
    }

    /// Delete a thread
    /// - Parameter threadId: The thread ID
    func deleteThread(threadId: String) async throws {
        try await ensureLoaded()
        if personalThreads.contains(where: { $0.id == threadId }) {
            // The thread's messages go with it.
            try await ThreadRepository.shared.deleteThread(id: threadId)
            personalThreads.removeAll { $0.id == threadId }
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
