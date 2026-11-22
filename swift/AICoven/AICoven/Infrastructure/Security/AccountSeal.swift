import Foundation

/// Sealing and opening an account's own content with its own key: what
/// the stores of that content share.
///
/// After a switch from one account to another the first one's data key
/// can stay in memory for a moment. It neither opens nor seals the
/// second's content, so everything here requires that the account asked
/// for is the one signed in and that the key in memory is its own, the
/// same one from before the work until after.
nonisolated enum AccountSeal {
    private static func signedInAccount() async -> String {
        await MainActor.run { UserScope.currentUserID }
    }

    /// Throws unless `account` is the one signed in and the data key in
    /// memory is its own, the same one as when `epoch` was read.
    static func requireKey(of account: String, since epoch: Int) async throws {
        guard await signedInAccount() == account else { throw RepositoryError.accountChanged }
        guard await DataEncryptionService.shared.isUnlocked(for: account) else { throw RepositoryError.dataLocked }
        guard await DataEncryptionService.shared.keyEpoch == epoch else { throw RepositoryError.accountChanged }
    }

    /// `text`, encrypted for `account`, which must be the one signed in
    /// with its own key in memory from before the text is encrypted until
    /// after. A key locked or changed under way is told as that.
    static func seal(_ text: String, purpose: String, for account: String) async throws -> Data {
        try await seal(bytes: Data(text.utf8), purpose: purpose, for: account)
    }

    /// The same, of bytes.
    static func seal(bytes data: Data, purpose: String, for account: String) async throws -> Data {
        let epoch = await DataEncryptionService.shared.keyEpoch
        try await requireKey(of: account, since: epoch)
        let ciphertext: Data
        do {
            ciphertext = try await DataEncryptionService.shared.encrypt(data, purpose: purpose)
        } catch {
            try await requireKey(of: account, since: epoch)
            throw error
        }
        try await requireKey(of: account, since: epoch)
        return ciphertext
    }

    /// Reads something of `account`'s content, with its own key in memory
    /// from before the reading until after. Nothing is read, not even that
    /// there is nothing, while its data is locked; and a key locked or
    /// changed under way is told as that, whatever failed for it.
    static func reading<Read>(as account: String, _ read: () async throws -> Read) async throws -> Read {
        let epoch = await DataEncryptionService.shared.keyEpoch
        try await requireKey(of: account, since: epoch)
        let result: Read
        do {
            result = try await read()
        } catch {
            try await requireKey(of: account, since: epoch)
            throw error
        }
        try await requireKey(of: account, since: epoch)
        return result
    }
}
