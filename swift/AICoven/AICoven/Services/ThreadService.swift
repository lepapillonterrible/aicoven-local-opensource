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
    /// The last change to the threads, which the next one waits for.
    private var lastChange: Task<Void, Never>?

    private init() {}

    /// Forget the loaded threads. Call after a user switch or sign-out; the
    /// next read loads the current account's.
    func reloadForCurrentUser() {
        personalThreads = []
        loadedUserID = nil
    }

    /// Loads the current account's threads from the database. While the
    /// account's data is locked it throws and holds nothing, and loads on a
    /// later call.
    private func ensureLoaded() async throws {
        let userID = UserScope.currentUserID
        guard await DataEncryptionService.shared.isUnlocked else {
            personalThreads = []
            loadedUserID = nil
            throw RepositoryError.dataLocked
        }
        guard loadedUserID != userID else { return }
        let threads = try await ThreadRepository.shared.loadChatThreads()
        // The account can change while the database answers.
        guard UserScope.currentUserID == userID, loadedUserID != userID else { return }
        personalThreads = threads.sorted { $0.createdAt < $1.createdAt }
        loadedUserID = userID
        await cleanupTestThreads()
    }

    /// Whether `userID` is still the account whose threads are loaded. A
    /// change that waited on the database checks it before touching the
    /// list, so one account's thread never lands in another's.
    private func isShowing(_ userID: String) -> Bool {
        UserScope.currentUserID == userID && loadedUserID == userID
    }

    /// Runs one change to the threads at a time, in the order asked. Each
    /// reads the list when its turn comes, so a rename and a pin started
    /// together both land, and a change queued behind a delete finds the
    /// thread gone.
    private func oneAtATime<Value: Sendable>(
        _ change: @escaping @Sendable (isolated ThreadService) async throws -> Value
    ) async throws -> Value {
        let previous = lastChange
        let task = Task {
            await previous?.value
            return try await change(self)
        }
        lastChange = Task { _ = await task.result }
        return try await task.value
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
        let filtered = personalThreads.filter { $0.covenId == covenId }
        return includeArchived ? filtered : filtered.filter { !$0.isArchived }
    }

    /// Create a new thread in a coven or personal
    /// - Parameters:
    ///   - title: Thread title (optional)
    ///   - covenId: The coven ID (nil for personal thread)
    ///   - agentId: AI agent/role ID (optional)
    /// - Returns: The created thread
    func createThread(title: String? = nil, covenId: String? = nil, agentId: String? = nil, agentName: String? = nil) async throws -> Thread {
        try await oneAtATime { service in
            try await service.create(title: title, covenId: covenId, agentId: agentId, agentName: agentName)
        }
    }

    private func create(title: String?, covenId: String?, agentId: String?, agentName: String?) async throws -> Thread {
        try await ensureLoaded()
        let userID = UserScope.currentUserID
        let now = Date()
        let thread = await Thread(
            id: UUID().uuidString,
            userId: userID,
            covenId: covenId,
            title: ThreadInputValidator.normalizedTitle(title, defaultTitle: covenId == nil ? "New Chat" : "Coven Chat"),
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
        // Stored for its own account; shown and announced only there.
        guard isShowing(userID) else { return thread }
        personalThreads.append(thread)

        await AnalyticsService.shared.trackThreadCreated(covenId: covenId, agentId: agentId)
        await MainActor.run {
            NotificationCenter.default.post(name: .didCreateThread, object: nil, userInfo: ["thread": thread])
        }
        return thread
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
        try await oneAtATime { service in
            try await service.update(threadId: threadId, title: title, agentId: agentId, isPinned: isPinned, isArchived: isArchived)
        }
    }

    private func update(threadId: String, title: String?, agentId: String?, isPinned: Bool?, isArchived: Bool?) async throws -> Thread {
        // Throws the same sanitized not-found error as a lookup does, rather
        // than logging opaque IDs.
        let thread = try await getThread(threadId: threadId)
        let userID = UserScope.currentUserID
        let updated = Thread(
            id: thread.id,
            userId: thread.userId,
            covenId: thread.covenId,
            title: title.map { ThreadInputValidator.normalizedTitle($0, defaultTitle: thread.title ?? "New Chat") } ?? thread.title,
            agentId: agentId ?? thread.agentId,
            agentName: thread.agentName,
            agentModel: thread.agentModel,
            isPinned: isPinned ?? thread.isPinned,
            isArchived: isArchived ?? thread.isArchived,
            messageCount: thread.messageCount,
            createdAt: thread.createdAt,
            updatedAt: Date(),
            lastMessageAt: thread.lastMessageAt
        )
        try await ThreadRepository.shared.saveThread(updated)
        if isShowing(userID), let index = personalThreads.firstIndex(where: { $0.id == threadId }) {
            personalThreads[index] = updated
        }
        return updated
    }

    /// Delete a thread, and with it its messages.
    /// - Parameter threadId: The thread ID
    func deleteThread(threadId: String) async throws {
        try await oneAtATime { service in
            try await service.delete(threadId: threadId)
        }
    }

    private func delete(threadId: String) async throws {
        try await ensureLoaded()
        guard personalThreads.contains(where: { $0.id == threadId }) else {
            AppErrorReporter.log(message: "Ignoring delete for unknown thread", context: "ThreadService.deleteThread")
            return
        }
        let userID = UserScope.currentUserID
        try await ThreadRepository.shared.deleteThread(id: threadId)
        if isShowing(userID) {
            personalThreads.removeAll { $0.id == threadId }
        }
        AppErrorReporter.log(message: "Deleted thread from local store", context: "ThreadService.deleteThread")
        await AnalyticsService.shared.trackThreadDeleted(threadId: threadId)
    }
}

extension Notification.Name {
    static let didCreateThread = Notification.Name("didCreateThread")
}
