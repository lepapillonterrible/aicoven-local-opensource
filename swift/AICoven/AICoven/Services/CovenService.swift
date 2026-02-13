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

    /// Delete a coven
    /// - Parameter id: Coven ID
    func deleteCoven(id: String) async throws {
        try await CovenRepository.shared.deleteCoven(id: id)
    }
}
