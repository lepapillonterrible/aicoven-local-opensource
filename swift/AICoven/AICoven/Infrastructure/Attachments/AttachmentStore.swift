import CryptoKit
import Foundation
import GRDB

/// The files attached to messages, kept on this device. A file is copied in
/// when it is attached, so it is still there when the message is sent and
/// when the thread is read later, wherever the original has gone. Its bytes
/// are encrypted in the app's own folder, as the account's messages are in
/// the database; its row says whose it is and which thread it belongs to.
/// It goes when it is taken out of the composer unsent, with its thread, and
/// with its account.
actor AttachmentStore {
    static let shared = AttachmentStore()

    /// The largest file that is attached.
    static let maxBytes = 10 * 1024 * 1024

    nonisolated enum Failure: LocalizedError, Equatable {
        case tooLarge(name: String)
        case unreadable(name: String)
        /// Read, but its copy could not be kept (the store could not be
        /// written, or its thread went while it was being attached).
        case notKept(name: String)
        /// Not this account's, or no longer on this device.
        case missing

        var errorDescription: String? {
            switch self {
            case let .tooLarge(name): "\(name) is larger than 10 MB and was not attached."
            case let .unreadable(name): "\(name) could not be read and was not attached."
            case let .notKept(name): "\(name) could not be attached."
            case .missing: "This attachment is no longer on this device."
            }
        }
    }

    /// Where the files are kept; nil until first used, then beside the
    /// database.
    private var directory: URL?
    /// The clearing of what earlier runs of the app left behind, by
    /// account: started once in each run, and waited for by whoever asks.
    private var clearing: [String: Task<Void, Never>] = [:]

    init(directory: URL? = nil) {
        self.directory = directory
    }

    // MARK: - Attaching

    /// Copies a file in as an attachment of the thread. Throws
    /// `Failure.tooLarge`, `.unreadable` or `.notKept` naming the file (the
    /// last also for a thread that is not the current account's, whose row
    /// is refused), or what the store's own checks throw while the data is
    /// locked.
    func add(fileAt url: URL, toThread threadID: String) async throws -> FileAttachmentDetail {
        let name = url.lastPathComponent
        // A file chosen in the system's chooser is readable only between these.
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        // Its size first, so a file far too large is not read at all.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > Self.maxBytes {
            throw Failure.tooLarge(name: name)
        }
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable(name: name) }
        return try await add(data, named: name, mimeType: AttachmentImage.mimeType(forFileNamed: name), toThread: threadID)
    }

    /// Keeps these bytes as an attachment of the thread.
    func add(_ data: Data, named name: String, mimeType: String?, toThread threadID: String) async throws -> FileAttachmentDetail {
        guard data.count <= Self.maxBytes else { throw Failure.tooLarge(name: name) }
        let prepared: AttachmentImage.Prepared
        do {
            prepared = try AttachmentImage.prepared(data, name: name, mimeType: mimeType)
        } catch {
            throw Failure.unreadable(name: name)
        }
        let detail = FileAttachmentDetail(
            id: UUID().uuidString,
            name: prepared.name,
            mimeType: prepared.mimeType,
            sizeBytes: prepared.data.count,
            width: prepared.width,
            height: prepared.height,
            url: nil
        )
        guard let queue = await dbQueue() else { throw RepositoryError.databaseUnavailable }
        let session = try await ThreadRepository.shared.beginWrite()
        let body = try await DataEncryptionService.shared.encrypt(prepared.data, purpose: "attachment")
        let meta = try await DataEncryptionService.shared.encrypt(JSONEncoder().encode(detail), purpose: "attachment_meta")
        try await ThreadRepository.shared.confirm(session)

        // The row first: it is refused for a thread that is not this
        // account's, and then nothing is written.
        do {
            try await queue.write { db in
                try db.execute(
                    sql: "INSERT INTO attachments (id, user_id, thread_id, meta_ciphertext, created_at) VALUES (?, ?, ?, ?, ?)",
                    arguments: [detail.id, session.userID, threadID, meta, Date()]
                )
            }
        } catch {
            Self.log("An attachment's row could not be stored", error)
            throw Failure.notKept(name: name)
        }
        var file: URL?
        do {
            let written = try await fileURL(of: detail.id, for: session.userID, creatingFolder: true)
            file = written
            try body.write(to: written, options: .atomic)
            // Its thread can have been deleted while the file was written,
            // and its row with it: the file is then nobody's, and not kept.
            let isStillThere = try await queue.read { db in
                try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attachments WHERE id = ?)", arguments: [detail.id]) ?? false
            }
            guard isStillThere else { throw Failure.notKept(name: name) }
        } catch {
            if let file { try? FileManager.default.removeItem(at: file) }
            _ = try? await queue.write { db in
                try db.execute(sql: "DELETE FROM attachments WHERE id = ?", arguments: [detail.id])
            }
            throw Failure.notKept(name: name)
        }
        return detail
    }

    // MARK: - Reading

    /// The attachment's bytes. Throws `Failure.missing` unless it is the
    /// current account's and still on this device, and what the store's
    /// readers throw while the data is locked or if the account changes.
    func data(of id: String) async throws -> Data {
        guard let queue = await dbQueue() else { throw RepositoryError.databaseUnavailable }
        let userID = await MainActor.run { UserScope.currentUserID }
        let isOwned = try await queue.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attachments WHERE id = ? AND user_id = ?)", arguments: [id, userID]) ?? false
        }
        guard isOwned else { throw Failure.missing }
        try await ThreadRepository.shared.requireKey(of: userID)
        guard let body = try? await Data(contentsOf: fileURL(of: id, for: userID, creatingFolder: false)) else { throw Failure.missing }
        let data = try await DataEncryptionService.shared.decrypt(body, purpose: "attachment")
        try await ThreadRepository.shared.requireKey(of: userID)
        return data
    }

    // MARK: - Sending and removing

    /// Marks attachments as sent with a message: they are the thread's from
    /// here on, and are no longer cleared as unsent. Throws if they cannot
    /// be marked: a message is not sent with files that would be cleared
    /// from under it.
    func markSent(_ ids: [String], with messageID: String, inThread threadID: String) async throws {
        guard !ids.isEmpty else { return }
        guard let queue = await dbQueue() else { throw RepositoryError.databaseUnavailable }
        let userID = await MainActor.run { UserScope.currentUserID }
        try await queue.write { db in
            for id in ids {
                try db.execute(
                    sql: "UPDATE attachments SET message_id = ? WHERE id = ? AND user_id = ? AND thread_id = ?",
                    arguments: [messageID, id, userID, threadID]
                )
                // One that is no longer there (taken out in another
                // window as this was sent) is not sent as if it were: the
                // whole marking is undone with the write.
                guard db.changesCount == 1 else { throw Failure.missing }
            }
        }
    }

    /// Takes back the mark of a message that was not stored after all:
    /// its attachments are unsent again, in the composer they came from.
    /// Whoever is signed in by now: the message's id is its own, and marks
    /// nobody else's files. If the mark cannot be taken back, the next
    /// launch clears what is marked with a message that does not exist.
    func markUnsent(_ ids: [String], markedWith messageID: String) async {
        guard !ids.isEmpty, let queue = await dbQueue() else { return }
        do {
            try await queue.write { db in
                for id in ids {
                    try db.execute(
                        sql: "UPDATE attachments SET message_id = NULL WHERE id = ? AND message_id = ?",
                        arguments: [id, messageID]
                    )
                }
            }
        } catch {
            Self.log("Attachments could not be marked as unsent again", error)
        }
    }

    /// Removes attachments that were not sent: taken out of the composer,
    /// or dropped with a waiting message. One that was sent stays.
    func removeUnsent(_ ids: [String]) async {
        guard !ids.isEmpty, let queue = await dbQueue() else { return }
        let userID = await MainActor.run { UserScope.currentUserID }
        do {
            let removed = try await queue.write { db in
                var removed: [String] = []
                for id in ids {
                    try db.execute(
                        sql: "DELETE FROM attachments WHERE id = ? AND user_id = ? AND message_id IS NULL",
                        arguments: [id, userID]
                    )
                    if db.changesCount > 0 { removed.append(id) }
                }
                return removed
            }
            await deleteFiles(removed, for: userID)
        } catch {
            Self.log("Unsent attachments could not be removed", error)
        }
    }

    /// Clears what earlier runs of the app left behind for this account:
    /// what was attached and never sent (a composer's files are held only
    /// while the app runs), what is marked with a message that was never
    /// stored, and any file left without a row. Tried once in each run;
    /// whoever asks waits until it has been, so no composer of the
    /// account's is used before. If it fails it is not tried again in that
    /// run, when a composer may hold files it would take: what was left
    /// stays, unused, until the next run.
    func clearLeftovers(for userID: String) async {
        if let underWay = clearing[userID] {
            return await underWay.value
        }
        let task = Task { await self.clearLeftoversNow(for: userID) }
        clearing[userID] = task
        await task.value
    }

    private func clearLeftoversNow(for userID: String) async {
        guard let queue = await dbQueue() else { return }
        do {
            let (unsent, kept) = try await queue.write { db in
                let neverSent = """
                user_id = ? AND (message_id IS NULL
                    OR NOT EXISTS (SELECT 1 FROM messages WHERE messages.id = attachments.message_id))
                """
                let unsent = try String.fetchAll(db, sql: "SELECT id FROM attachments WHERE \(neverSent)", arguments: [userID])
                try db.execute(sql: "DELETE FROM attachments WHERE \(neverSent)", arguments: [userID])
                let kept = try Set(String.fetchAll(db, sql: "SELECT id FROM attachments WHERE user_id = ?", arguments: [userID]))
                return (unsent, kept)
            }
            await deleteFiles(unsent, for: userID)
            // A file with no row is nobody's: one whose thread went while
            // it was being written, or whose deletion was cut short.
            guard let folder = try? await folder(for: userID),
                  let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
            for file in files where !kept.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        } catch {
            Self.log("What earlier runs left attached could not be cleared", error)
        }
    }

    /// Deletes the files of attachments whose rows are gone.
    func deleteFiles(_ ids: [String], for userID: String) async {
        for id in ids {
            guard let file = try? await fileURL(of: id, for: userID, creatingFolder: false) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Deletes every file kept for an account: the account is being deleted.
    func deleteAllFiles(for userID: String) async {
        guard let folder = try? await folder(for: userID) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Where the files are

    /// An account's folder: named by a digest of its id, which says nothing
    /// of the account and is always a plain name.
    private func folder(for userID: String) async throws -> URL {
        let base: URL
        if let directory {
            base = directory
        } else {
            base = await MainActor.run { DatabaseManager.shared.databaseURL.deletingLastPathComponent() }
                .appendingPathComponent("Attachments", isDirectory: true)
            directory = base
        }
        let digest = SHA256.hash(data: Data(userID.utf8)).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent(digest, isDirectory: true)
    }

    /// The file an attachment's bytes are in. An id that is not one of the
    /// store's own is refused: it is used as a file name.
    private func fileURL(of id: String, for userID: String, creatingFolder: Bool) async throws -> URL {
        guard UUID(uuidString: id) != nil else { throw Failure.missing }
        let folder = try await folder(for: userID)
        if creatingFolder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Kept out of backups made of the device's files in the clear.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var marked = folder
            try? marked.setResourceValues(values)
        }
        return folder.appendingPathComponent(id, isDirectory: false)
    }

    private func dbQueue() async -> DatabaseQueue? {
        await MainActor.run { DatabaseManager.shared.dbQueue }
    }

    /// Logs what failed and the error's kind, never its description.
    private nonisolated static func log(_ what: String, _ error: Error) {
        let error = error as NSError
        AppErrorReporter.log(message: "\(what) (\(error.domain) \(error.code)).", context: "AttachmentStore")
    }
}
