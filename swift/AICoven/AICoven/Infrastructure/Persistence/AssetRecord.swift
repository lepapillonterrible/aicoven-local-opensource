import CryptoKit
import Foundation
import GRDB

/// Why an asset was not kept, changed or read.
enum AssetError: Error, Equatable {
    /// There is no such asset, or file of one, of the account's.
    case noSuchAsset
    /// An asset has a title.
    case noTitle
    /// What says what it is is longer than it may be.
    case tooLong
    /// The type does not read as a type's name.
    case notAType
    /// A file is larger than a file of an asset may be.
    case fileTooLarge(name: String)
    /// More files than one asset has.
    case tooManyFiles
    /// The coven (or Strix) has as many assets as it may.
    case tooMany
    /// The coven it is to be kept in is not a coven of the account's.
    case noSuchCoven
    /// The thread it is said to come from is not a thread of the account's
    /// in the place the asset is kept in, or the message is not one of
    /// that thread's.
    case noSuchThread
    /// An asset does not go from the status it has to the one asked for.
    case notAllowed
    /// An asset with no file is not proposed.
    case needsAFile
    /// What is kept cannot be opened with the account's key.
    case unreadable
}

/// The account's assets, kept on the device: each in a coven of the
/// account's, or with Strix (an empty coven id), with its files. An
/// asset's title, what says what it is, and each file's name, size and
/// bytes are encrypted with the account's key; its type, status, times
/// and where it came from are kept as they are. The bytes are kept in the
/// database with the asset, so they go with it in the same write (and
/// with its coven and its account). An asset is read, made and changed
/// only as the account signed in, with its own key in memory.
actor AssetRepository {
    static let shared = AssetRepository()

    /// The longest title, and the longest text saying what an asset is,
    /// in characters.
    static let longestTitle = 200
    static let longestDetails = 5000
    /// The largest file, as an attachment's.
    static let largestFile = AttachmentStore.maxBytes
    /// The most files of one asset.
    static let mostFiles = 20
    /// The most assets kept in one coven, or with Strix.
    static let most = 1000

    private static let titlePurpose = "asset_title"
    private static let detailsPurpose = "asset_details"
    private static let filePurpose = "asset_file_meta"
    private static let bodyPurpose = "asset_file"

    /// A file as it is given to be kept.
    struct NewFile {
        let name: String
        let data: Data
    }

    /// What is sealed of a file beside its bytes.
    private struct KeptFile: Codable {
        let name: String
        let size: Int
    }

    private init() {}

    private func getDbQueue() async -> DatabaseQueue? {
        await MainActor.run { DatabaseManager.shared.dbQueue }
    }

    /// A title as it is kept: one line, single spaces, no longer than the
    /// longest.
    static func keptTitle(_ given: String) -> String {
        let oneLine = given.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(oneLine.prefix(longestTitle)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Making

    /// Keeps a new asset in `account`'s coven (Strix for nil), as a draft,
    /// with its files, all in one write, and only in a coven of the
    /// account's. `agentID` is the agent that made
    /// it (nil for one the person added); `threadID` and `messageID` say
    /// where it came from, and are kept only for a thread of the account's
    /// in the same coven (or, for Strix's, in none) and a message of that
    /// thread. Throws unless `account` is the one
    /// signed in with its own key in memory.
    func create(
        type: AssetType,
        title: String,
        details: String = "",
        files: [NewFile],
        inCoven covenID: String?,
        madeBy agentID: String? = nil,
        inThread threadID: String? = nil,
        fromMessage messageID: String? = nil,
        as account: String
    ) async throws -> Asset {
        // Whoever asks is the account signed in, before anything is said
        // of what was given.
        try await AccountSeal.requireKey(of: account, since: DataEncryptionService.shared.keyEpoch)
        guard type.isName else { throw AssetError.notAType }
        let title = Self.keptTitle(title)
        guard !title.isEmpty else { throw AssetError.noTitle }
        let details = details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard details.count <= Self.longestDetails else { throw AssetError.tooLong }
        guard files.count <= Self.mostFiles else { throw AssetError.tooManyFiles }
        if let large = files.first(where: { $0.data.count > Self.largestFile }) {
            throw AssetError.fileTooLarge(name: AssetFile.keptName(large.name))
        }
        // A message is one of a thread.
        guard messageID == nil || threadID != nil else { throw AssetError.noSuchThread }
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        if let threadID {
            // An asset comes from a thread of the place it is kept in. A
            // thread's coven is read from the thread as it is stored.
            let threadsCoven: String?
            do {
                threadsCoven = try await ThreadRepository.shared.covenID(ofThread: threadID, for: account)
            } catch is ThreadLookupError {
                throw AssetError.noSuchThread
            }
            guard threadsCoven == covenID else { throw AssetError.noSuchThread }
        }

        let sealedTitle = try await AccountSeal.seal(title, purpose: Self.titlePurpose, for: account)
        let sealedDetails = try await AccountSeal.seal(details, purpose: Self.detailsPurpose, for: account)
        var kept: [AssetFile] = []
        var sealedFiles: [(id: String, meta: Data, body: Data)] = []
        for file in files {
            let name = AssetFile.keptName(file.name)
            let id = UUID().uuidString
            let meta = try JSONEncoder().encode(KeptFile(name: name, size: file.data.count))
            try await sealedFiles.append((
                id,
                AccountSeal.seal(bytes: meta, purpose: Self.filePurpose, for: account),
                AccountSeal.seal(bytes: file.data, purpose: Self.bodyPurpose, for: account)
            ))
            kept.append(AssetFile(id: id, name: name, mimeType: AttachmentImage.mimeType(forFileNamed: name), sizeBytes: file.data.count))
        }

        let id = UUID().uuidString
        let now = Date()
        let coven = covenID ?? ""
        let holding = AttachmentStore.holdingThreadID(for: account)
        // The sealed files are taken into the write as one value.
        let toWrite = sealedFiles
        try await dbQueue.write { db in
            // Counted in the write that adds it.
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets WHERE user_id = ? AND coven_id = ?", arguments: [account, coven]) ?? 0
            guard count < Self.most else { throw AssetError.tooMany }
            if !coven.isEmpty {
                let isTheirs = try Bool.fetchOne(db, sql: "SELECT 1 FROM covens WHERE id = ? AND user_id = ?", arguments: [coven, account]) ?? false
                guard isTheirs else { throw AssetError.noSuchCoven }
            }
            if let threadID {
                // A thread of the account's: not the row its unsent files wait under.
                let isTheirs = try Bool.fetchOne(
                    db, sql: "SELECT 1 FROM threads WHERE id = ? AND user_id = ? AND id <> ?", arguments: [threadID, account, holding]
                ) ?? false
                guard isTheirs else { throw AssetError.noSuchThread }
                if let messageID {
                    let isOfTheThread = try Bool.fetchOne(
                        db, sql: "SELECT 1 FROM messages WHERE id = ? AND thread_id = ? AND user_id = ?", arguments: [messageID, threadID, account]
                    ) ?? false
                    guard isOfTheThread else { throw AssetError.noSuchThread }
                }
            }
            try db.execute(
                sql: """
                INSERT INTO assets (
                    id, user_id, coven_id, type, status, title_ciphertext, details_ciphertext,
                    made_by_agent_id, thread_id, source_message_id, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    id, account, coven, type.rawValue, AssetStatus.draft.rawValue, sealedTitle, sealedDetails,
                    agentID, threadID, messageID, now, now,
                ]
            )
            for file in toWrite {
                try db.execute(
                    sql: "INSERT INTO asset_files (id, asset_id, meta_ciphertext, created_at, body_ciphertext) VALUES (?, ?, ?, ?, ?)",
                    arguments: [file.id, id, file.meta, now, file.body]
                )
            }
        }
        return Asset(
            id: id, covenID: covenID, type: type, status: .draft, title: title, details: details,
            madeByAgentID: agentID, threadID: threadID, sourceMessageID: messageID, files: kept,
            createdAt: now, updatedAt: now
        )
    }

    // MARK: - Reading

    private func opened(_ sealed: Data, purpose: String) async -> Data? {
        try? await DataEncryptionService.shared.decrypt(sealed, purpose: purpose)
    }

    /// An asset's row as it is stored: what is kept as it is, and what is sealed.
    private struct Stored {
        let id: String
        let type: String
        let status: String
        let title: Data
        let details: Data
        let agentID: String?
        let threadID: String?
        let messageID: String?
        let createdAt: Date
        let updatedAt: Date

        init(_ row: Row) {
            id = row["id"]
            type = row["type"]
            status = row["status"]
            title = row["title_ciphertext"]
            details = row["details_ciphertext"]
            agentID = row["made_by_agent_id"]
            threadID = row["thread_id"]
            messageID = row["source_message_id"]
            createdAt = row["created_at"]
            updatedAt = row["updated_at"]
        }
    }

    /// The assets kept in `account`'s coven (Strix for nil), the one last
    /// changed first (of two changed at once, the one made later), each
    /// with what is known of its files but not their bytes. One of which
    /// anything cannot be opened with the account's key is listed as
    /// unreadable, with no title and no files.
    func assets(inCoven covenID: String?, as account: String) async throws -> [Asset] {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        let coven = covenID ?? ""
        return try await AccountSeal.reading(as: account) {
            // Both in one read, so that an asset is listed with the files it has then.
            let (stored, storedFiles): ([Stored], [(id: String, assetID: String, meta: Data)]) = try await dbQueue.read { db in
                let assets = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, type, status, title_ciphertext, details_ciphertext, made_by_agent_id, thread_id,
                           source_message_id, created_at, updated_at
                    FROM assets WHERE user_id = ? AND coven_id = ? ORDER BY updated_at DESC, rowid DESC
                    """,
                    arguments: [account, coven]
                ).map(Stored.init)
                // Never the bytes: only what says what each file is.
                let files = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT asset_files.id, asset_files.asset_id, asset_files.meta_ciphertext FROM asset_files
                    JOIN assets ON assets.id = asset_files.asset_id
                    WHERE assets.user_id = ? AND assets.coven_id = ? ORDER BY asset_files.rowid
                    """,
                    arguments: [account, coven]
                ).map { (id: $0["id"] as String, assetID: $0["asset_id"] as String, meta: $0["meta_ciphertext"] as Data) }
                return (assets, files)
            }
            // Each asset's files, in the order they were added; nil for an
            // asset of which a file cannot be opened.
            var filesByAsset: [String: [AssetFile]?] = [:]
            for stored in storedFiles {
                guard let meta = await self.opened(stored.meta, purpose: Self.filePurpose),
                      let file = try? JSONDecoder().decode(KeptFile.self, from: meta)
                else {
                    filesByAsset[stored.assetID] = .some(nil)
                    continue
                }
                guard let already = filesByAsset[stored.assetID, default: []] else { continue }
                filesByAsset[stored.assetID] = already + [
                    AssetFile(id: stored.id, name: file.name, mimeType: AttachmentImage.mimeType(forFileNamed: file.name), sizeBytes: file.size),
                ]
            }
            var assets: [Asset] = []
            for stored in stored {
                let title = await self.opened(stored.title, purpose: Self.titlePurpose)
                let details = await self.opened(stored.details, purpose: Self.detailsPurpose)
                let files = filesByAsset[stored.id, default: []]
                let isReadable = title != nil && details != nil && files != nil
                assets.append(Asset(
                    id: stored.id, covenID: covenID, type: AssetType(rawValue: stored.type),
                    // A status this version does not know is read as a
                    // draft: nothing takes a draft for reviewed.
                    status: AssetStatus(rawValue: stored.status) ?? .draft,
                    title: isReadable ? String(decoding: title ?? Data(), as: UTF8.self) : "",
                    details: isReadable ? String(decoding: details ?? Data(), as: UTF8.self) : "",
                    madeByAgentID: stored.agentID, threadID: stored.threadID, sourceMessageID: stored.messageID,
                    files: isReadable ? files ?? [] : [], isUnreadable: !isReadable,
                    createdAt: stored.createdAt, updatedAt: stored.updatedAt
                ))
            }
            return assets
        }
    }

    /// The bytes of a file of one of `account`'s assets.
    func data(ofFile fileID: String, as account: String) async throws -> Data {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        return try await AccountSeal.reading(as: account) {
            let sealed = try await dbQueue.read { db in
                try Data.fetchOne(
                    db,
                    sql: """
                    SELECT asset_files.body_ciphertext FROM asset_files
                    JOIN assets ON assets.id = asset_files.asset_id
                    WHERE asset_files.id = ? AND assets.user_id = ?
                    """,
                    arguments: [fileID, account]
                )
            }
            guard let sealed else { throw AssetError.noSuchAsset }
            do {
                return try await DataEncryptionService.shared.decrypt(sealed, purpose: Self.bodyPurpose)
            } catch is CryptoKitError {
                throw AssetError.unreadable
            }
        }
    }

    // MARK: - Status

    /// Moves one of `account`'s assets to another status, as the person
    /// may (`AssetStatus.canMove(to:)`), and answers with when it was
    /// changed. Whether it may is decided in the write itself, against the
    /// asset as it is then; an asset with no file is not proposed.
    @discardableResult
    func move(_ id: String, to next: AssetStatus, as account: String) async throws -> Date {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        try await AccountSeal.requireKey(of: account, since: DataEncryptionService.shared.keyEpoch)
        let now = Date()
        try await dbQueue.write { db in
            guard let stored = try String.fetchOne(db, sql: "SELECT status FROM assets WHERE id = ? AND user_id = ?", arguments: [id, account]) else {
                throw AssetError.noSuchAsset
            }
            guard (AssetStatus(rawValue: stored) ?? .draft).canMove(to: next) else { throw AssetError.notAllowed }
            if next == .proposed {
                let hasAFile = try Bool.fetchOne(db, sql: "SELECT 1 FROM asset_files WHERE asset_id = ? LIMIT 1", arguments: [id]) ?? false
                guard hasAFile else { throw AssetError.needsAFile }
            }
            try db.execute(
                sql: "UPDATE assets SET status = ?, updated_at = ? WHERE id = ? AND user_id = ?",
                arguments: [next.rawValue, now, id, account]
            )
        }
        return now
    }
}
