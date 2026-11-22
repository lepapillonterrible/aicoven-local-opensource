import CryptoKit
import Foundation
import GRDB

/// A skill: instructions the person added for their agents to follow,
/// from a file of theirs. A skill is followed only while it is on.
nonisolated struct Skill: Identifiable, Equatable {
    let id: String
    /// Its title; empty where it could not be opened.
    var title: String
    var isOn: Bool
    /// Whether what is kept of it cannot be opened with the account's key:
    /// it is then followed by no agent, and can only be deleted.
    var isUnreadable = false
    let updatedAt: Date
}

/// Why a skill was not kept, changed or read.
enum SkillError: Error, Equatable {
    /// There is no such skill of the account's.
    case noSuchSkill
    /// A skill has no text.
    case empty
    /// The text is longer than a skill may be.
    case tooLong
    /// The account has as many skills as it may.
    case tooMany
    /// What is kept of the skill cannot be opened with the account's key.
    case unreadable
}

/// The account's skills, kept on the device. A skill's title and text are
/// encrypted with the account's key; nothing of a skill is kept in the
/// clear but whether it is on and when it was last changed. A skill is
/// read, added, changed and deleted only as the account signed in, with
/// its own key in memory.
actor SkillRepository {
    static let shared = SkillRepository()

    /// The longest text of one skill, in characters.
    static let longestText = 100_000
    /// The most skills one account keeps.
    static let most = 200

    private static let titlePurpose = "skill_title"
    private static let textPurpose = "skill_text"

    private init() {}

    private func getDbQueue() async -> DatabaseQueue? {
        await MainActor.run { DatabaseManager.shared.dbQueue }
    }

    /// What tells one source of a skill from another, with nothing of the
    /// source readable in it: the file's address is not kept.
    static func digest(ofSource source: String, for account: String) -> String {
        SHA256.hash(data: Data("\(account)\n\(source)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func opened(_ sealed: Data, purpose: String) async -> String? {
        guard let data = try? await DataEncryptionService.shared.decrypt(sealed, purpose: purpose) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The account's skills, by title. One that cannot be opened is
    /// listed as unreadable, after the others.
    func skills(as account: String) async throws -> [Skill] {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        return try await AccountSeal.reading(as: account) {
            let rows = try await dbQueue.read { db in
                try Row.fetchAll(db, sql: "SELECT id, title_ciphertext, is_on, updated_at FROM skills WHERE user_id = ?", arguments: [account])
            }
            var skills: [Skill] = []
            for row in rows {
                let title = await self.opened(row["title_ciphertext"], purpose: Self.titlePurpose)
                skills.append(Skill(id: row["id"], title: title ?? "", isOn: row["is_on"], isUnreadable: title == nil, updatedAt: row["updated_at"]))
            }
            return skills.sorted { one, other in
                if one.isUnreadable != other.isUnreadable { return !one.isUnreadable }
                let order = one.title.localizedCaseInsensitiveCompare(other.title)
                return order == .orderedSame ? one.id < other.id : order == .orderedAscending
            }
        }
    }

    /// Adds a skill, off: an agent follows it once the person turns it on.
    /// A skill from a source the account already has one from takes that
    /// one's place: its title and text are replaced, and it is turned off
    /// unless its text is the same as before, so that no text is followed
    /// that the person did not turn on.
    @discardableResult
    func add(title: String, text: String, source: String?, as account: String) async throws -> Skill {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SkillError.empty }
        guard text.count <= Self.longestText else { throw SkillError.tooLong }
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        let title = SkillTitle.kept(title)
        let digest = source.map { Self.digest(ofSource: $0, for: account) }
        // The one it would replace, read as the account with its key in
        // memory, to know whether its text changes.
        let existing: (id: String, text: String?, isOn: Bool)? = try await AccountSeal.reading(as: account) {
            guard let digest else { return nil }
            let row = try await dbQueue.read { db in
                try Row.fetchOne(
                    db, sql: "SELECT id, text_ciphertext, is_on FROM skills WHERE user_id = ? AND source_digest = ?", arguments: [account, digest]
                )
            }
            guard let row else { return nil }
            return await (row["id"], self.opened(row["text_ciphertext"], purpose: Self.textPurpose), row["is_on"])
        }
        let sealedTitle = try await AccountSeal.seal(title, purpose: Self.titlePurpose, for: account)
        let sealedText = try await AccountSeal.seal(text, purpose: Self.textPurpose, for: account)
        let now = Date()
        if let existing {
            let isOn = existing.isOn && existing.text == text
            try await dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE skills SET title_ciphertext = ?, text_ciphertext = ?, is_on = ?, updated_at = ? WHERE id = ? AND user_id = ?",
                    arguments: [sealedTitle, sealedText, isOn, now, existing.id, account]
                )
                guard db.changesCount == 1 else { throw SkillError.noSuchSkill }
            }
            return Skill(id: existing.id, title: title, isOn: isOn, updatedAt: now)
        }
        let id = UUID().uuidString
        try await dbQueue.write { db in
            // Counted in the write that adds it.
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM skills WHERE user_id = ?", arguments: [account]) ?? 0 < Self.most else {
                throw SkillError.tooMany
            }
            try db.execute(
                sql: """
                INSERT INTO skills (id, user_id, title_ciphertext, text_ciphertext, is_on, source_digest, created_at, updated_at)
                VALUES (?, ?, ?, ?, 0, ?, ?, ?)
                """,
                arguments: [id, account, sealedTitle, sealedText, digest, now, now]
            )
        }
        return Skill(id: id, title: title, isOn: false, updatedAt: now)
    }

    /// Turns a skill on or off. One that cannot be opened is not turned
    /// on: no agent could follow it.
    func setOn(_ isOn: Bool, id: String, as account: String) async throws {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        try await AccountSeal.reading(as: account) {
            if isOn {
                let sealed = try await dbQueue.read { db in
                    try Data.fetchOne(db, sql: "SELECT text_ciphertext FROM skills WHERE id = ? AND user_id = ?", arguments: [id, account])
                }
                guard let sealed else { throw SkillError.noSuchSkill }
                guard await self.opened(sealed, purpose: Self.textPurpose) != nil else { throw SkillError.unreadable }
            }
            try await dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE skills SET is_on = ?, updated_at = ? WHERE id = ? AND user_id = ?", arguments: [isOn, Date(), id, account]
                )
                guard db.changesCount == 1 else { throw SkillError.noSuchSkill }
            }
        }
    }

    /// Deletes a skill of the account's, readable or not.
    func delete(id: String, as account: String) async throws {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        try await AccountSeal.requireKey(of: account, since: DataEncryptionService.shared.keyEpoch)
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM skills WHERE id = ? AND user_id = ?", arguments: [id, account])
            guard db.changesCount == 1 else { throw SkillError.noSuchSkill }
        }
    }

    /// The skills an agent of the account's follows: those that are on and
    /// can be opened, by title, each with its text.
    func followed(as account: String) async throws -> [(title: String, text: String)] {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        return try await AccountSeal.reading(as: account) {
            let rows = try await dbQueue.read { db in
                try Row.fetchAll(db, sql: "SELECT id, title_ciphertext, text_ciphertext FROM skills WHERE user_id = ? AND is_on = 1", arguments: [account])
            }
            var followed: [(id: String, title: String, text: String)] = []
            for row in rows {
                guard let title = await self.opened(row["title_ciphertext"], purpose: Self.titlePurpose),
                      let text = await self.opened(row["text_ciphertext"], purpose: Self.textPurpose) else { continue }
                followed.append((row["id"], title, text))
            }
            return followed
                .sorted { one, other in
                    let order = one.title.localizedCaseInsensitiveCompare(other.title)
                    return order == .orderedSame ? one.id < other.id : order == .orderedAscending
                }
                .map { ($0.title, $0.text) }
        }
    }
}
