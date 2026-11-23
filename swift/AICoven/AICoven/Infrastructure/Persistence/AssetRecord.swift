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
    /// An asset does not go from the status it has to the one asked for;
    /// or it is changed, and is no draft.
    case notAllowed
    /// The asset is not what it was when it was listed: it is not approved
    /// unseen.
    case changed
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

    /// Where a test may step in: nothing in the app does.
    enum Step {
        /// A change to a stored asset was asked for, before it waits its turn.
        case asked
        /// Just before a write, after everything it writes was looked at
        /// and sealed.
        case beforeWriting
    }

    private let at: (@Sendable (Step) async -> Void)?

    init(at: (@Sendable (Step) async -> Void)? = nil) {
        self.at = at
    }

    /// Takes back what a rejected write wrote, whatever became of whoever
    /// asked: one that was called off still has its write taken back. If
    /// it cannot be, that is logged, by its kind only.
    private func takeBack(in dbQueue: DatabaseQueue, _ undo: @escaping @Sendable (Database) throws -> Void) async {
        await Task {
            do {
                try await dbQueue.write(undo)
            } catch {
                AppErrorReporter.log(message: "A rejected asset write could not be taken back (\(type(of: error)))", context: "AssetRepository")
            }
        }.value
    }

    private func getDbQueue() async -> DatabaseQueue? {
        await MainActor.run { DatabaseManager.shared.dbQueue }
    }

    /// What tells an asset as it is stored from the same asset changed
    /// (`Asset.version`): its files in the order they were added.
    static func version(title: Data, details: Data, files: [(id: String, meta: Data)]) -> String {
        var digest = SHA256()
        digest.update(data: title)
        digest.update(data: details)
        for file in files {
            digest.update(data: Data(file.id.utf8))
            digest.update(data: file.meta)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
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
        // of what was given; and with the same key in memory from here
        // until the asset has been written.
        let epoch = await DataEncryptionService.shared.keyEpoch
        try await AccountSeal.requireKey(of: account, since: epoch)
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
        await at?(.beforeWriting)
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
        do {
            try await AccountSeal.requireKey(of: account, since: epoch)
        } catch {
            // The account's data was locked, or changed hands, while the
            // write waited its turn: what it wrote is taken back.
            await takeBack(in: dbQueue) { db in
                try db.execute(sql: "DELETE FROM assets WHERE id = ? AND user_id = ?", arguments: [id, account])
            }
            throw error
        }
        return Asset(
            id: id, covenID: covenID, type: type, status: .draft, title: title, details: details,
            madeByAgentID: agentID, threadID: threadID, sourceMessageID: messageID, files: kept,
            version: Self.version(title: sealedTitle, details: sealedDetails, files: sealedFiles.map { ($0.id, $0.meta) }),
            createdAt: now, updatedAt: now
        )
    }

    // MARK: - Changing a draft

    /// Whether the asset is `account`'s and a draft, in the write that
    /// would change it: what is proposed is frozen for the person's
    /// review, and what is approved or archived is not changed either.
    private nonisolated static func requireDraft(_ id: String, of account: String, in db: Database) throws {
        guard let status = try String.fetchOne(db, sql: "SELECT status FROM assets WHERE id = ? AND user_id = ?", arguments: [id, account]) else {
            throw AssetError.noSuchAsset
        }
        guard status == AssetStatus.draft.rawValue else { throw AssetError.notAllowed }
    }

    /// One change to a stored asset at a time (a draft changed, a file
    /// added, a status moved): each waits for the one before it to be
    /// written and, if it must be, put back. Two that overlapped while the
    /// data was being locked could otherwise put back each other's
    /// rejected write in place of how the asset stood.
    ///
    /// A change is `account`'s as its data stood when the change was asked
    /// for: the key's epoch is read then, before the change waits, and the
    /// change is made only if the same key is still in memory when its
    /// turn comes (and until it has been written). One asked for before
    /// the data was locked is not made after it was unlocked again.
    private func inTurn<Done: Sendable>(
        as account: String, _ change: @escaping @Sendable (_ epoch: Int) async throws -> Done
    ) async throws -> Done {
        let epoch = await DataEncryptionService.shared.keyEpoch
        try await AccountSeal.requireKey(of: account, since: epoch)
        let before = lastChange
        let changing = Task { () throws -> Done in
            await self.at?(.asked)
            await before?.value
            try await AccountSeal.requireKey(of: account, since: epoch)
            return try await change(epoch)
        }
        lastChange = Task { _ = try? await changing.value }
        return try await changing.value
    }

    /// The change last asked for, done or not.
    private var lastChange: Task<Void, Never>?

    /// Changes a draft's title, or what says what it is, or both (nil
    /// leaves one as it is). Only a draft is changed.
    func update(_ id: String, title newTitle: String? = nil, details newDetails: String? = nil, as account: String) async throws {
        try await inTurn(as: account) { epoch in
            try await self.updateInTurn(id, title: newTitle, details: newDetails, as: account, since: epoch)
        }
    }

    private func updateInTurn(_ id: String, title newTitle: String?, details newDetails: String?, as account: String, since epoch: Int) async throws {
        let title = newTitle.map(Self.keptTitle)
        if let title, title.isEmpty { throw AssetError.noTitle }
        let details = newDetails?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let details, details.count > Self.longestDetails { throw AssetError.tooLong }
        guard title != nil || details != nil else { return }
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        var sealedTitle: Data?
        if let title { sealedTitle = try await AccountSeal.seal(title, purpose: Self.titlePurpose, for: account) }
        var sealedDetails: Data?
        if let details { sealedDetails = try await AccountSeal.seal(details, purpose: Self.detailsPurpose, for: account) }
        let (newTitleData, newDetailsData) = (sealedTitle, sealedDetails)
        let now = Date()
        await at?(.beforeWriting)
        // What it held before, as it is stored, to put it back by.
        let before: (title: Data, details: Data, changed: String) = try await dbQueue.write { db in
            try Self.requireDraft(id, of: account, in: db)
            let stored = try Row.fetchOne(
                db, sql: "SELECT title_ciphertext, details_ciphertext, updated_at FROM assets WHERE id = ? AND user_id = ?", arguments: [id, account]
            )
            guard let stored else { throw AssetError.noSuchAsset }
            let (oldTitle, oldDetails): (Data, Data) = (stored["title_ciphertext"], stored["details_ciphertext"])
            try db.execute(
                sql: "UPDATE assets SET title_ciphertext = ?, details_ciphertext = ?, updated_at = ? WHERE id = ? AND user_id = ?",
                arguments: [newTitleData ?? oldTitle, newDetailsData ?? oldDetails, now, id, account]
            )
            return (oldTitle, oldDetails, stored["updated_at"])
        }
        do {
            try await AccountSeal.requireKey(of: account, since: epoch)
        } catch {
            // Locked, or another account's, while the write waited its
            // turn: put back as it was, unless something changed it since.
            let stood = before
            await takeBack(in: dbQueue) { db in
                try db.execute(
                    sql: """
                    UPDATE assets SET title_ciphertext = ?, details_ciphertext = ?, updated_at = ?
                    WHERE id = ? AND user_id = ? AND title_ciphertext = ? AND details_ciphertext = ? AND updated_at = ?
                    """,
                    arguments: [stood.title, stood.details, stood.changed, id, account, newTitleData ?? stood.title, newDetailsData ?? stood.details, now]
                )
            }
            throw error
        }
    }

    /// Adds a file to a draft, after those it has. Only a draft is
    /// changed, and an asset has only so many files (counted in the write).
    @discardableResult
    func addFile(_ file: NewFile, to id: String, as account: String) async throws -> AssetFile {
        try await inTurn(as: account) { epoch in try await self.addFileInTurn(file, to: id, as: account, since: epoch) }
    }

    private func addFileInTurn(_ file: NewFile, to id: String, as account: String, since epoch: Int) async throws -> AssetFile {
        let name = AssetFile.keptName(file.name)
        guard file.data.count <= Self.largestFile else { throw AssetError.fileTooLarge(name: name) }
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        let meta = try await AccountSeal.seal(
            bytes: JSONEncoder().encode(KeptFile(name: name, size: file.data.count)), purpose: Self.filePurpose, for: account
        )
        let body = try await AccountSeal.seal(bytes: file.data, purpose: Self.bodyPurpose, for: account)
        let fileID = UUID().uuidString
        let now = Date()
        await at?(.beforeWriting)
        let changedBefore: String = try await dbQueue.write { db in
            try Self.requireDraft(id, of: account, in: db)
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_files WHERE asset_id = ?", arguments: [id]) ?? 0
            guard count < Self.mostFiles else { throw AssetError.tooManyFiles }
            let changed = try String.fetchOne(db, sql: "SELECT updated_at FROM assets WHERE id = ? AND user_id = ?", arguments: [id, account]) ?? ""
            try db.execute(
                sql: "INSERT INTO asset_files (id, asset_id, meta_ciphertext, created_at, body_ciphertext) VALUES (?, ?, ?, ?, ?)",
                arguments: [fileID, id, meta, now, body]
            )
            try db.execute(sql: "UPDATE assets SET updated_at = ? WHERE id = ? AND user_id = ?", arguments: [now, id, account])
            return changed
        }
        do {
            try await AccountSeal.requireKey(of: account, since: epoch)
        } catch {
            // Locked, or another account's, while the write waited its
            // turn: the file is taken out again.
            await takeBack(in: dbQueue) { db in
                try db.execute(sql: "DELETE FROM asset_files WHERE id = ? AND asset_id = ?", arguments: [fileID, id])
                try db.execute(
                    sql: "UPDATE assets SET updated_at = ? WHERE id = ? AND user_id = ? AND updated_at = ?", arguments: [changedBefore, id, account, now]
                )
            }
            throw error
        }
        return AssetFile(id: fileID, name: name, mimeType: AttachmentImage.mimeType(forFileNamed: name), sizeBytes: file.data.count)
    }

    // MARK: - Reading

    private func opened(_ sealed: Data, purpose: String) async -> Data? {
        try? await DataEncryptionService.shared.decrypt(sealed, purpose: purpose)
    }

    /// What is kept of a file beside its bytes; nil if it cannot be opened.
    private func file(from sealedMeta: Data) async -> KeptFile? {
        guard let meta = await opened(sealedMeta, purpose: Self.filePurpose) else { return nil }
        return try? JSONDecoder().decode(KeptFile.self, from: meta)
    }

    /// An asset's row as it is stored: what is kept as it is, and what is sealed.
    private struct Stored {
        let id: String
        let covenID: String
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
            covenID = row["coven_id"]
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
        try await assets(where: "assets.coven_id = ?", [covenID ?? ""], as: account)
    }

    /// Those of `account`'s assets that have these ids, wherever each is
    /// kept, in the order of the ids; an id that is no asset of the
    /// account's is left out. Every id is looked up, some at a time.
    func assets(withIDs ids: [String], as account: String) async throws -> [Asset] {
        var found: [String: Asset] = [:]
        var rest = ids[...]
        while !rest.isEmpty {
            let some = Array(rest.prefix(Self.idsInOneRead))
            rest = rest.dropFirst(some.count)
            let marks = Array(repeating: "?", count: some.count).joined(separator: ", ")
            for asset in try await assets(where: "assets.id IN (\(marks))", some, as: account) {
                found[asset.id] = asset
            }
        }
        var told = Set<String>()
        return ids.compactMap { id in told.insert(id).inserted ? found[id] : nil }
    }

    /// The most ids one read names: well under what a statement takes.
    static let idsInOneRead = 200

    /// The account's assets that `condition` holds for (it speaks of the
    /// `assets` table), as a listing gives them.
    private func assets(where condition: String, _ values: [String], as account: String) async throws -> [Asset] {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        return try await AccountSeal.reading(as: account) {
            // Both in one read, so that an asset is listed with the files it has then.
            let (stored, storedFiles): ([Stored], [(id: String, assetID: String, meta: Data)]) = try await dbQueue.read { db in
                let arguments = StatementArguments([account] + values)
                let assets = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, coven_id, type, status, title_ciphertext, details_ciphertext, made_by_agent_id, thread_id,
                           source_message_id, created_at, updated_at
                    FROM assets WHERE assets.user_id = ? AND \(condition) ORDER BY updated_at DESC, rowid DESC
                    """,
                    arguments: arguments
                ).map(Stored.init)
                // Never the bytes: only what says what each file is.
                let files = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT asset_files.id, asset_files.asset_id, asset_files.meta_ciphertext FROM asset_files
                    JOIN assets ON assets.id = asset_files.asset_id
                    WHERE assets.user_id = ? AND \(condition) ORDER BY asset_files.rowid
                    """,
                    arguments: arguments
                ).map { (id: $0["id"] as String, assetID: $0["asset_id"] as String, meta: $0["meta_ciphertext"] as Data) }
                return (assets, files)
            }
            // Each asset's files, in the order they were added; nil for an
            // asset of which a file cannot be opened.
            var filesByAsset: [String: [AssetFile]?] = [:]
            for stored in storedFiles {
                guard let file = await self.file(from: stored.meta) else {
                    filesByAsset[stored.assetID] = .some(nil)
                    continue
                }
                guard let already = filesByAsset[stored.assetID, default: []] else { continue }
                filesByAsset[stored.assetID] = already + [
                    AssetFile(id: stored.id, name: file.name, mimeType: AttachmentImage.mimeType(forFileNamed: file.name), sizeBytes: file.size),
                ]
            }
            // What is stored of each asset's files, grouped once, in order.
            var sealedFiles: [String: [(id: String, meta: Data)]] = [:]
            for file in storedFiles {
                sealedFiles[file.assetID, default: []].append((file.id, file.meta))
            }
            var assets: [Asset] = []
            for stored in stored {
                let title = await self.opened(stored.title, purpose: Self.titlePurpose)
                let details = await self.opened(stored.details, purpose: Self.detailsPurpose)
                let files = filesByAsset[stored.id, default: []]
                let isReadable = title != nil && details != nil && files != nil
                assets.append(Asset(
                    id: stored.id, covenID: stored.covenID.isEmpty ? nil : stored.covenID, type: AssetType(rawValue: stored.type),
                    // A status this version does not know is read as a
                    // draft: nothing takes a draft for reviewed.
                    status: AssetStatus(rawValue: stored.status) ?? .draft,
                    title: isReadable ? String(decoding: title ?? Data(), as: UTF8.self) : "",
                    details: isReadable ? String(decoding: details ?? Data(), as: UTF8.self) : "",
                    madeByAgentID: stored.agentID, threadID: stored.threadID, sourceMessageID: stored.messageID,
                    files: isReadable ? files ?? [] : [], isUnreadable: !isReadable,
                    version: Self.version(title: stored.title, details: stored.details, files: sealedFiles[stored.id] ?? []),
                    createdAt: stored.createdAt, updatedAt: stored.updatedAt
                ))
            }
            return assets
        }
    }

    /// The bytes of a file of one of `account`'s assets. Not those of an
    /// asset that is listed as unreadable: every part of the asset must
    /// open with the account's key, as for a listing.
    func data(ofFile fileID: String, as account: String) async throws -> Data {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        return try await AccountSeal.reading(as: account) {
            let stored: (title: Data, details: Data, metas: [Data], body: Data)? = try await dbQueue.read { db in
                let asset = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT assets.id, assets.title_ciphertext, assets.details_ciphertext, asset_files.body_ciphertext
                    FROM asset_files JOIN assets ON assets.id = asset_files.asset_id
                    WHERE asset_files.id = ? AND assets.user_id = ?
                    """,
                    arguments: [fileID, account]
                )
                guard let asset else { return nil }
                let assetID: String = asset["id"]
                let metas = try Data.fetchAll(db, sql: "SELECT meta_ciphertext FROM asset_files WHERE asset_id = ?", arguments: [assetID])
                return (asset["title_ciphertext"], asset["details_ciphertext"], metas, asset["body_ciphertext"])
            }
            guard let stored else { throw AssetError.noSuchAsset }
            guard await self.opened(stored.title, purpose: Self.titlePurpose) != nil,
                  await self.opened(stored.details, purpose: Self.detailsPurpose) != nil
            else { throw AssetError.unreadable }
            for meta in stored.metas {
                guard await self.file(from: meta) != nil else { throw AssetError.unreadable }
            }
            guard let body = await self.opened(stored.body, purpose: Self.bodyPurpose) else { throw AssetError.unreadable }
            return body
        }
    }

    // MARK: - Status

    /// Moves one of `account`'s assets to another status, as the person
    /// may (`AssetStatus.canMove(to:)`), and answers with when it was
    /// changed. Whether it may is decided in the write itself, against the
    /// asset as it is then; an asset with no file is not proposed. An
    /// asset is approved only as it was listed (`version`, the listed
    /// asset's): one whose title, text or files were changed since is not
    /// approved unseen (`AssetError.changed`).
    /// It takes its turn among the changes to stored assets (`inTurn`).
    @discardableResult
    func move(_ id: String, to next: AssetStatus, listedAs version: String? = nil, as account: String) async throws -> Date {
        try await inTurn(as: account) { epoch in try await self.moveInTurn(id, to: next, listedAs: version, as: account, since: epoch) }
    }

    private func moveInTurn(_ id: String, to next: AssetStatus, listedAs version: String?, as account: String, since epoch: Int) async throws -> Date {
        guard let dbQueue = await getDbQueue() else { throw RepositoryError.databaseUnavailable }
        let now = Date()
        await at?(.beforeWriting)
        // How it stood before, as it is stored, to put it back by.
        let before: (status: String, changed: String) = try await dbQueue.write { db in
            let stored = try Row.fetchOne(
                db, sql: "SELECT status, updated_at, title_ciphertext, details_ciphertext FROM assets WHERE id = ? AND user_id = ?",
                arguments: [id, account]
            )
            guard let stored else { throw AssetError.noSuchAsset }
            let status: String = stored["status"]
            guard (AssetStatus(rawValue: status) ?? .draft).canMove(to: next) else { throw AssetError.notAllowed }
            if next == .approved {
                // Approved as it was listed, or not at all.
                let files = try Row.fetchAll(db, sql: "SELECT id, meta_ciphertext FROM asset_files WHERE asset_id = ? ORDER BY rowid", arguments: [id])
                    .map { (id: $0["id"] as String, meta: $0["meta_ciphertext"] as Data) }
                let asItIs = Self.version(title: stored["title_ciphertext"], details: stored["details_ciphertext"], files: files)
                guard asItIs == version else { throw AssetError.changed }
            }
            if next == .proposed {
                let hasAFile = try Bool.fetchOne(db, sql: "SELECT 1 FROM asset_files WHERE asset_id = ? LIMIT 1", arguments: [id]) ?? false
                guard hasAFile else { throw AssetError.needsAFile }
            }
            try db.execute(
                sql: "UPDATE assets SET status = ?, updated_at = ? WHERE id = ? AND user_id = ?",
                arguments: [next.rawValue, now, id, account]
            )
            return (status, stored["updated_at"])
        }
        do {
            try await AccountSeal.requireKey(of: account, since: epoch)
        } catch {
            // The account's data was locked, or changed hands, while the
            // write waited its turn: the asset is put back as it stood,
            // unless something has changed it since.
            let stood = before
            await takeBack(in: dbQueue) { db in
                try db.execute(
                    sql: "UPDATE assets SET status = ?, updated_at = ? WHERE id = ? AND user_id = ? AND status = ? AND updated_at = ?",
                    arguments: [stood.status, stood.changed, id, account, next.rawValue, now]
                )
            }
            throw error
        }
        return now
    }
}
