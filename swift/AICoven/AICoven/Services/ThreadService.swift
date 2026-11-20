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
    /// Counts resets of the list, so a load that began before one is not
    /// kept after it.
    private var resets = 0
    /// How many loads of the threads are under way, and the messages
    /// stored meanwhile, by thread id: the threads read may not have them.
    private var loadsUnderWay = 0
    private var notedWhileLoading: [String: Date] = [:]

    private init() {}

    /// Posted when a thread was used (a message was stored in it): lists
    /// of threads read theirs again, since their order follows it.
    static let threadUsed = Notification.Name("ThreadService.threadUsed")

    /// A message was stored in a thread at `date`: the thread, if it is
    /// among those loaded, is as lately used as that.
    func noteMessage(in threadID: String, at date: Date) {
        if let index = personalThreads.firstIndex(where: { $0.id == threadID }) {
            personalThreads[index] = personalThreads[index].lastUsed(at: date)
        }
        // The threads can be on their way from the database, read before
        // this message was stored: it is kept, and counted when they are in.
        if loadsUnderWay > 0 {
            notedWhileLoading[threadID] = max(date, notedWhileLoading[threadID] ?? date)
        }
        // Told whether or not the thread is among those held.
        // Posted on the main actor: the lists that hear it are views.
        Task { @MainActor in
            NotificationCenter.default.post(name: Self.threadUsed, object: nil)
        }
    }

    /// Forget the loaded threads. Call after a user switch or sign-out; the
    /// next read loads the current account's.
    func reloadForCurrentUser() {
        personalThreads = []
        loadedUserID = nil
        resets += 1
    }

    /// Loads the current account's threads from the database. While the
    /// account's data is locked it throws and holds nothing, and loads on a
    /// later call.
    private func ensureLoaded() async throws {
        let userID = UserScope.currentUserID
        guard await DataEncryptionService.shared.isUnlocked(for: userID) else {
            reloadForCurrentUser()
            throw RepositoryError.dataLocked
        }
        guard loadedUserID != userID else { return }
        // What a composer held attached and unsent when the app last
        // closed is not kept. Cleared once in each run, and waited for
        // here before the threads are handed to anyone, so no composer is
        // used before it is done.
        await AttachmentStore.shared.clearLeftovers(for: userID)
        let resetsAtStart = resets
        loadsUnderWay += 1
        defer {
            loadsUnderWay -= 1
            if loadsUnderWay == 0 { notedWhileLoading = [:] }
        }
        let threads = try await ThreadRepository.shared.loadChatThreads()
        // The data can be locked, the list reset, or the account changed
        // while the database answers; what was read is then not kept.
        guard await DataEncryptionService.shared.isUnlocked(for: userID) else { throw RepositoryError.dataLocked }
        guard UserScope.currentUserID == userID, resets == resetsAtStart else { throw RepositoryError.accountChanged }
        guard loadedUserID != userID else { return }
        personalThreads = threads.sorted { $0.createdAt < $1.createdAt }.map { $0.lastUsed(at: notedWhileLoading[$0.id]) }
        loadedUserID = userID
        await cleanupTestThreads()
    }

    /// Whether `userID` is still the account whose threads are loaded. A
    /// change that waited on the database checks it before touching the
    /// list, so one account's thread never lands in another's.
    private func isShowing(_ userID: String) -> Bool {
        UserScope.currentUserID == userID && loadedUserID == userID
    }

    /// Throws unless `userID`, the account a change was asked under, is
    /// still the current one. A change can wait its turn behind another,
    /// and must not then be made for whoever signed in meanwhile.
    private func requireCurrent(_ userID: String) throws {
        guard UserScope.currentUserID == userID else { throw RepositoryError.accountChanged }
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
                let attached = try await ThreadRepository.shared.deleteThread(id: thread.id, for: thread.userId)
                await AttachmentStore.shared.deleteFiles(attached, for: thread.userId)
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

    /// Where each of the account's threads that is not archived belongs
    /// (Strix, or its coven), by thread id.
    func scopesOfThreads() async throws -> [String: ShellScope] {
        try await ensureLoaded()
        var scopes: [String: ShellScope] = [:]
        for thread in personalThreads where !thread.isArchived {
            scopes[thread.id] = ShellScope(covenID: thread.covenId)
        }
        return scopes
    }

    /// Create a new thread in a coven or personal
    /// - Parameters:
    ///   - title: Thread title (optional)
    ///   - covenId: The coven ID (nil for personal thread)
    ///   - agentId: AI agent/role ID (optional)
    /// - Returns: The created thread
    ///   - account: Whoever asked, where the caller read it before waiting:
    ///     if another account is signed in by now, nothing is made.
    func createThread(
        title: String? = nil, covenId: String? = nil, agentId: String? = nil, agentName: String? = nil, as account: String? = nil
    ) async throws -> Thread {
        let userID = UserScope.currentUserID
        if let account, account != userID { throw RepositoryError.accountChanged }
        return try await oneAtATime { service in
            try await service.create(title: title, covenId: covenId, agentId: agentId, agentName: agentName, for: userID)
        }
    }

    private func create(title: String?, covenId: String?, agentId: String?, agentName: String?, for userID: String) async throws -> Thread {
        try requireCurrent(userID)
        try await ensureLoaded()
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

        await MainActor.run {
            // Checked where it is posted, with no wait in between.
            guard UserScope.currentUserID == userID else { return }
            NotificationCenter.default.post(name: .didCreateThread, object: nil, userInfo: ["thread": thread])
        }
        await AnalyticsService.shared.trackThreadCreated(covenId: covenId, agentId: agentId)
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
        let userID = UserScope.currentUserID
        return try await oneAtATime { service in
            try await service.update(
                threadId: threadId, title: title, agentId: agentId, isPinned: isPinned, isArchived: isArchived, for: userID
            )
        }
    }

    private func update(
        threadId: String,
        title: String?,
        agentId: String?,
        isPinned: Bool?,
        isArchived: Bool?,
        for userID: String
    ) async throws -> Thread {
        try requireCurrent(userID)
        // Throws the same sanitized not-found error as a lookup does, rather
        // than logging opaque IDs.
        let thread = try await getThread(threadId: threadId)
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
        guard isShowing(userID), let index = personalThreads.firstIndex(where: { $0.id == threadId }) else { return updated }
        // A message can have been stored in it while it was saved: it is
        // as lately used as the service holds it to be by now.
        let kept = updated.lastUsed(at: personalThreads[index].lastMessageAt)
        personalThreads[index] = kept
        return kept
    }

    /// Delete a thread, and with it its messages.
    /// - Parameter threadId: The thread ID
    func deleteThread(threadId: String) async throws {
        let userID = UserScope.currentUserID
        try await oneAtATime { service in
            try await service.delete(threadId: threadId, for: userID)
        }
    }

    private func delete(threadId: String, for userID: String) async throws {
        try requireCurrent(userID)
        try await ensureLoaded()
        guard personalThreads.contains(where: { $0.id == threadId }) else {
            AppErrorReporter.log(message: "Ignoring delete for unknown thread", context: "ThreadService.deleteThread")
            return
        }
        // The thread's attachments go with it: their rows with its row,
        // their files once that is gone.
        let attached = try await ThreadRepository.shared.deleteThread(id: threadId, for: userID)
        await AttachmentStore.shared.deleteFiles(attached, for: userID)
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
