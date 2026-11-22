import CryptoKit
import Foundation
import GRDB

/// Why what every agent of a scope is told could not be read.
enum CovenContextError: Error {
    /// What is stored cannot be opened with the account's key.
    case unreadable
}

/// What every agent of a scope is told ("Every agent here knows…"): a
/// short text added to the instructions of each of its agents, as the
/// cloud app's coven context is. An account has one for each of its
/// covens and one for Strix, which is no stored coven here and is kept
/// under an empty coven id. The text is encrypted with the account's key.
actor CovenContextRepository {
    static let shared = CovenContextRepository()

    /// The longest text kept (the cloud app's limit).
    static let longest = 2000
    private static let purpose = "coven_context"

    private init() {}

    private func getDbQueue() async -> DatabaseQueue? {
        await MainActor.run { DatabaseManager.shared.dbQueue }
    }

    /// The text as it is kept: without the space around it, and no longer
    /// than the longest.
    static func kept(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(longest))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What every agent of `account`'s coven (Strix for nil) is told;
    /// empty where nothing is kept. Throws unless `account` is the one
    /// signed in with its own key in memory, and where what is kept
    /// cannot be opened.
    func context(ofCoven covenID: String?, as account: String) async throws -> String {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        return try await AccountSeal.reading(as: account) {
            let sealed: Data? = try await dbQueue.read { db in
                try Data.fetchOne(
                    db,
                    sql: "SELECT text_ciphertext FROM coven_context WHERE user_id = ? AND coven_id = ?",
                    arguments: [account, covenID ?? ""]
                )
            }
            guard let sealed else { return "" }
            do {
                return try await String(decoding: DataEncryptionService.shared.decrypt(sealed, purpose: Self.purpose), as: UTF8.self)
            } catch is CryptoKitError {
                throw CovenContextError.unreadable
            }
        }
    }

    /// Keeps `text` as what every agent of `account`'s coven (Strix for
    /// nil) is told, and answers with what was kept (`kept(_:)`); an
    /// empty text keeps nothing. Throws unless `account` is the one
    /// signed in with its own key in memory, whether a text is kept or
    /// what was kept is removed; a coven's text is kept only for a coven
    /// of that account.
    @discardableResult
    func setContext(_ text: String, forCoven covenID: String?, as account: String) async throws -> String {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        let text = Self.kept(text)
        let coven = covenID ?? ""
        guard !text.isEmpty else {
            // As any change of it: only as the account signed in, with its
            // own key in memory.
            try await AccountSeal.requireKey(of: account, since: DataEncryptionService.shared.keyEpoch)
            try await dbQueue.write { db in
                try db.execute(sql: "DELETE FROM coven_context WHERE user_id = ? AND coven_id = ?", arguments: [account, coven])
            }
            return text
        }
        let sealed = try await AccountSeal.seal(text, purpose: Self.purpose, for: account)
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO coven_context (user_id, coven_id, text_ciphertext, updated_at) VALUES (?, ?, ?, ?)
                ON CONFLICT (user_id, coven_id) DO UPDATE SET text_ciphertext = excluded.text_ciphertext, updated_at = excluded.updated_at
                """,
                arguments: [account, coven, sealed, Date()]
            )
        }
        return text
    }
}
