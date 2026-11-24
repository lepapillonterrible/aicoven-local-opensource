import CryptoKit
import Foundation
import GRDB

/// A skill: instructions the person added for their agents to follow,
/// from a file of theirs. A skill is followed only while it is on.
nonisolated struct Skill: Identifiable, Equatable {
    let id: String
    /// Its title; empty for a skill that is unreadable (its title, or
    /// its text, could not be opened).
    var title: String
    var isOn: Bool
    /// Whether its title or its text cannot be opened with the account's
    /// key: it is then followed by no agent and cannot be turned on; it
    /// can be turned off and deleted.
    var isUnreadable = false
    let updatedAt: Date
    /// What tells the title and text this skill had when it was listed
    /// from any that take their place: a digest of what is stored of them,
    /// which is sealed, so it says nothing of what they say. A skill is
    /// turned on only as it was listed. Empty for a skill that was not
    /// read from the store, which is none to turn on.
    var version = ""
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
    /// The skill was changed while this was under way: nothing was done.
    case changed
}

/// The account's skills, kept on the device. A skill's title and text are
/// encrypted with the account's key. Nothing they say is kept in the
/// clear: beside them a skill has its id, whose it is, whether it is on,
/// when it was added and last changed, and a digest that tells its source
/// from another. A skill is read, added, changed and deleted only as the
/// account signed in, with its own key in memory.
actor SkillRepository {
    static let shared = SkillRepository()

    /// The longest text of one skill, in characters.
    static let longestText = 100_000
    /// The most skills one account keeps.
    static let most = 200

    private static let titlePurpose = "skill_title"
    private static let textPurpose = "skill_text"

    /// Runs between a skill being looked at and the write that acts on it:
    /// nothing in the app; a test changes the skill there.
    private let betweenLookingAndWriting: (@Sendable () async -> Void)?

    init(betweenLookingAndWriting: (@Sendable () async -> Void)? = nil) {
        self.betweenLookingAndWriting = betweenLookingAndWriting
    }

    private func getDbQueue() async -> DatabaseQueue? {
        await MainActor.run { DatabaseManager.shared.dbQueue }
    }

    /// What tells one source of a skill from another, with nothing of the
    /// source readable in it: the file's address is not kept.
    static func digest(ofSource source: String, for account: String) -> String {
        SHA256.hash(data: Data("\(account)\n\(source)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// What tells a stored title and text from any other (`Skill.version`).
    private static func version(title: Data, text: Data) -> String {
        var digest = SHA256()
        digest.update(data: title)
        digest.update(data: text)
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func opened(_ sealed: Data, purpose: String) async -> String? {
        guard let data = try? await DataEncryptionService.shared.decrypt(sealed, purpose: purpose) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The account's skills, by title. One whose title or text cannot be
    /// opened is listed as unreadable, after the others.
    func skills(as account: String) async throws -> [Skill] {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        return try await AccountSeal.reading(as: account) {
            let rows: [Row] = try await dbQueue.read { db in
                try Row.fetchAll(
                    db, sql: "SELECT id, title_ciphertext, text_ciphertext, is_on, updated_at FROM skills WHERE user_id = ?", arguments: [account]
                )
            }
            var skills: [Skill] = []
            for row in rows {
                let sealedTitle: Data = row["title_ciphertext"], sealedText: Data = row["text_ciphertext"]
                let title = await self.opened(sealedTitle, purpose: Self.titlePurpose)
                let text = await self.opened(sealedText, purpose: Self.textPurpose)
                let isUnreadable = title == nil || text == nil
                skills.append(Skill(
                    id: row["id"], title: isUnreadable ? "" : title ?? "", isOn: row["is_on"], isUnreadable: isUnreadable,
                    updatedAt: row["updated_at"], version: Self.version(title: sealedTitle, text: sealedText)
                ))
            }
            return skills.sorted { one, other in
                if one.isUnreadable != other.isUnreadable { return !one.isUnreadable }
                let order = one.title.localizedCaseInsensitiveCompare(other.title)
                return order == .orderedSame ? one.id < other.id : order == .orderedAscending
            }
        }
    }

    /// What is kept of a skill, as it was read: to tell, in the write that
    /// acts on it, whether it is still what was looked at.
    private struct Kept: Equatable {
        let id: String
        let title: Data
        let text: Data
        let isOn: Bool

        init(_ row: Row) {
            id = row["id"]
            title = row["title_ciphertext"]
            text = row["text_ciphertext"]
            isOn = row["is_on"]
        }

        static let columns = "id, title_ciphertext, text_ciphertext, is_on"
    }

    /// Adds a skill, off: an agent follows it once the person turns it on.
    /// A skill from a source the account already has one from takes that
    /// one's place: its title and text are replaced, and it is turned off
    /// unless its text is the same as before, so that no text is followed
    /// that the person did not turn on. Whether it stays on is decided in
    /// the write itself, against the skill as it is then: one that was
    /// changed, turned off or added since it was looked at ends off.
    @discardableResult
    func add(title: String, text: String, source: String?, as account: String) async throws -> Skill {
        // Whoever asks is the account signed in, before anything is said
        // of what was given.
        try await AccountSeal.requireKey(of: account, since: DataEncryptionService.shared.keyEpoch)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SkillError.empty }
        guard text.count <= Self.longestText else { throw SkillError.tooLong }
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        let title = SkillTitle.kept(title)
        let digest = source.map { Self.digest(ofSource: $0, for: account) }
        // The one it would replace, read as the account with its key in
        // memory, to know whether its text changes.
        let seen: (kept: Kept, hasTheSameText: Bool)? = try await AccountSeal.reading(as: account) {
            guard let digest else { return nil }
            let row: Row? = try await dbQueue.read { db in
                try Row.fetchOne(
                    db, sql: "SELECT \(Kept.columns) FROM skills WHERE user_id = ? AND source_digest = ?", arguments: [account, digest]
                )
            }
            guard let kept = row.map(Kept.init) else { return nil }
            return await (kept, self.opened(kept.text, purpose: Self.textPurpose) == text)
        }
        let sealedTitle = try await AccountSeal.seal(title, purpose: Self.titlePurpose, for: account)
        let sealedText = try await AccountSeal.seal(text, purpose: Self.textPurpose, for: account)
        let now = Date()
        let newID = UUID().uuidString
        await betweenLookingAndWriting?()
        let (id, isOn): (String, Bool) = try await dbQueue.write { db in
            // The skill from this source as it is now, in this write.
            let current = try digest.flatMap { digest in
                try Row.fetchOne(
                    db, sql: "SELECT \(Kept.columns) FROM skills WHERE user_id = ? AND source_digest = ?", arguments: [account, digest]
                )
            }.map(Kept.init)
            if let current {
                // On only if it is on, is still exactly what was looked at,
                // and its text does not change.
                let staysOn = current.isOn && current == seen?.kept && seen?.hasTheSameText == true
                try db.execute(
                    sql: "UPDATE skills SET title_ciphertext = ?, text_ciphertext = ?, is_on = ?, updated_at = ? WHERE id = ? AND user_id = ?",
                    arguments: [sealedTitle, sealedText, staysOn, now, current.id, account]
                )
                return (current.id, staysOn)
            }
            // Counted in the write that adds it.
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM skills WHERE user_id = ?", arguments: [account]) ?? 0 < Self.most else {
                throw SkillError.tooMany
            }
            try db.execute(
                sql: """
                INSERT INTO skills (id, user_id, title_ciphertext, text_ciphertext, is_on, source_digest, created_at, updated_at)
                VALUES (?, ?, ?, ?, 0, ?, ?, ?)
                """,
                arguments: [newID, account, sealedTitle, sealedText, digest, now, now]
            )
            return (newID, false)
        }
        return Skill(id: id, title: title, isOn: isOn, updatedAt: now, version: Self.version(title: sealedTitle, text: sealedText))
    }

    /// Turns a skill on or off. One that cannot be opened is not turned
    /// on: no agent could follow it. A skill is turned on only as it was
    /// listed (`skill.version`): if its title or text was replaced since,
    /// before this was asked or while it is done, nothing is done
    /// (`SkillError.changed`), so that no text is turned on unseen.
    /// Turning one off needs nothing of how it was listed.
    func setOn(_ isOn: Bool, _ skill: Skill, as account: String) async throws {
        let id = skill.id
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        guard isOn else {
            try await AccountSeal.requireKey(of: account, since: DataEncryptionService.shared.keyEpoch)
            try await dbQueue.write { db in
                try db.execute(sql: "UPDATE skills SET is_on = 0, updated_at = ? WHERE id = ? AND user_id = ?", arguments: [Date(), id, account])
                guard db.changesCount == 1 else { throw SkillError.noSuchSkill }
            }
            return
        }
        let seen: Kept = try await AccountSeal.reading(as: account) {
            let row: Row? = try await dbQueue.read { db in
                try Row.fetchOne(db, sql: "SELECT \(Kept.columns) FROM skills WHERE id = ? AND user_id = ?", arguments: [id, account])
            }
            guard let kept = row.map(Kept.init) else { throw SkillError.noSuchSkill }
            guard Self.version(title: kept.title, text: kept.text) == skill.version else { throw SkillError.changed }
            guard await self.opened(kept.title, purpose: Self.titlePurpose) != nil,
                  await self.opened(kept.text, purpose: Self.textPurpose) != nil else { throw SkillError.unreadable }
            return kept
        }
        await betweenLookingAndWriting?()
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE skills SET is_on = 1, updated_at = ?
                WHERE id = ? AND user_id = ? AND title_ciphertext = ? AND text_ciphertext = ?
                """,
                arguments: [Date(), id, account, seen.title, seen.text]
            )
            guard db.changesCount == 1 else {
                let isThere = try Bool.fetchOne(db, sql: "SELECT 1 FROM skills WHERE id = ? AND user_id = ?", arguments: [id, account]) ?? false
                throw isThere ? SkillError.changed : SkillError.noSuchSkill
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
            let rows: [Row] = try await dbQueue.read { db in
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
