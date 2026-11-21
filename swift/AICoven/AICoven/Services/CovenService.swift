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
    func createCoven(
        name: String, description: String? = nil, avatar: String? = nil, icon: (symbol: String, tint: IconTint)? = nil,
        as account: String? = nil
    ) async throws -> Coven {
        let coven = try await CovenRepository.shared.createCoven(
            name: name,
            description: description,
            avatar: avatar,
            icon: icon,
            as: account
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

    /// Sets the coven's icon.
    func setIcon(symbol: String, tint: IconTint, forCoven id: String) async throws {
        try await CovenRepository.shared.setIcon(symbol: symbol, tint: tint, forCoven: id)
    }

    /// Sets which connections the coven's agents may use.
    func setConnections(_ connections: CovenConnections?, forCoven id: String) async throws {
        try await CovenRepository.shared.setConnections(connections, forCoven: id)
    }

    /// Which connections may be used in a thread: nil for a thread in no
    /// coven (a personal thread, or an agent run's own thread), or in a
    /// coven that has made no choice yet, where everything connected is
    /// used; the coven's choice otherwise. If the thread, its coven or the
    /// coven's choice cannot be read, or the account changes while they
    /// are, nothing is on: what cannot be checked is not allowed.
    func connections(forThread threadID: String) async -> CovenConnections? {
        let account = await MainActor.run { UserScope.currentUserID }
        let found: CovenConnections?
        do {
            found = try await storedConnections(forThread: threadID, of: account)
        } catch {
            let failure = error as NSError
            AppErrorReporter.log(message: "A thread's connections could not be read (\(failure.domain) \(failure.code)).", context: "CovenService.connections")
            return CovenConnections()
        }
        // What was read is the account's that asked: not another's that
        // signed in while it was read.
        guard await MainActor.run(body: { UserScope.currentUserID }) == account else {
            AppErrorReporter.log(message: "A thread's connections were read for an account no longer signed in.", context: "CovenService.connections")
            return CovenConnections()
        }
        return found
    }

    /// Read from what is stored, the thread and then its coven, and from
    /// nothing kept in memory: looking a thread up changes nothing.
    private func storedConnections(forThread threadID: String, of account: String) async throws -> CovenConnections? {
        guard let covenID = try await ThreadRepository.shared.covenID(ofThread: threadID, for: account) else { return nil }
        return try await CovenRepository.shared.connections(ofCoven: covenID, for: account)
    }

    /// Delete a coven
    /// - Parameter id: Coven ID
    func deleteCoven(id: String) async throws {
        try await CovenRepository.shared.deleteCoven(id: id)
    }
}
