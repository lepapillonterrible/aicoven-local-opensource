import Foundation

/// Service for coven-related operations.
///
/// Copied from the cloud AICoven app and adapted for local-first:
/// all API calls replaced with local SQLite operations via CovenRepository.
actor CovenService {
    static let shared = CovenService()

    private init() {}

    /// Load all covens for the current user
    func loadCovens() async throws -> [Coven] {
        print("🏰 Loading covens...")
        let covens = try await CovenRepository.shared.loadCovens()
        print("✅ Loaded \(covens.count) covens")
        return covens
    }

    /// Create a new coven
    /// - Parameters:
    ///   - name: Name of the coven
    ///   - description: Optional description
    ///   - avatar: Optional avatar URL
    /// - Returns: The created coven
    func createCoven(name: String, description: String? = nil, avatar: String? = nil) async throws -> Coven {
        print("🏰 Creating coven: \(name)")
        let coven = try await CovenRepository.shared.createCoven(
            name: name,
            description: description,
            avatar: avatar
        )
        print("✅ Created coven: \(coven.id)")
        return coven
    }

    /// Update an existing coven
    /// - Parameters:
    ///   - id: Coven ID
    ///   - name: New name (optional)
    ///   - description: New description (optional)
    ///   - avatar: New avatar URL (optional)
    /// - Returns: The updated coven
    func updateCoven(id: String, name: String? = nil, description: String? = nil, avatar: String? = nil) async throws -> Coven {
        try await CovenRepository.shared.updateCoven(
            id: id,
            name: name,
            description: description,
            avatar: avatar
        )
    }

    /// Sets which connections the coven's agents may use.
    func setConnections(_ connections: CovenConnections?, forCoven id: String) async throws {
        try await CovenRepository.shared.setConnections(connections, forCoven: id)
    }

    /// Which connections may be used in a thread: nil for a thread in no
    /// coven (a personal thread), or in a coven that has made no choice
    /// yet, where everything connected is used; the coven's choice
    /// otherwise. If the thread or its coven cannot be read, nothing is
    /// on: what cannot be checked is not allowed.
    func connections(forThread threadID: String) async -> CovenConnections? {
        do {
            let thread = try await ThreadService.shared.getThread(threadId: threadID)
            guard let covenID = thread.covenId else { return nil }
            guard let coven = try await CovenRepository.shared.loadCovens().first(where: { $0.id == covenID }) else {
                AppErrorReporter.log(message: "A thread's coven was not found", context: "CovenService.connections")
                return CovenConnections()
            }
            return coven.settings?.connections
        } catch {
            let failure = error as NSError
            AppErrorReporter.log(message: "A thread's connections could not be read (\(failure.domain) \(failure.code)).", context: "CovenService.connections")
            return CovenConnections()
        }
    }

    /// Delete a coven
    /// - Parameter id: Coven ID
    func deleteCoven(id: String) async throws {
        try await CovenRepository.shared.deleteCoven(id: id)
    }
}
