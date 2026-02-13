import Foundation
import CryptoKit
import LocalAuthentication
import Security

/// High-level encryption service for protecting local data at rest using
/// a user-provided passphrase.
///
/// This is the **authoritative** encryption layer for the local-first
/// client. Legacy `EncryptionService` from the original cloud app is kept
/// only for backwards compatibility and should not be used in new code.
///
/// Responsibilities:
/// - Deriving a data-encryption key (K_data) from a user passphrase
///   via a wrapping key (K_wrap).
/// - Encrypting/decrypting arbitrary Data payloads for storage in SQLite
///   (threads, messages, memory, settings, provider configs).
actor DataEncryptionService {
    static let shared = DataEncryptionService()

    private struct Metadata: Codable {
        let salt: Data
        let wrappedKey: Data
    }

    /// User-scoped metadata key so each Firebase user has independent encryption.
    private var metadataKey: String {
        UserScope.scopedKey("com.aicoven.local.encryption.metadata")
    }

    private let keychainService = "com.aicoven.local.encryption"
    /// User-scoped Keychain account for device passphrase isolation.
    private var keychainAccount: String {
        guard let uid = UserScope.currentUserID else { return "device_passphrase" }
        return "device_passphrase_\(uid)"
    }

    /// Cached in-memory data-encryption key (K_data) for the current session.
    private var cachedDataKey: SymmetricKey?

    private init() {}

    // MARK: - Public API

    /// Initializes or unlocks the encryption key hierarchy using the
    /// provided passphrase. Must be called before encrypt/decrypt.
    func unlock(withPassphrase passphrase: String) throws {
        if let metadata = try loadMetadata() {
            let kWrap = try deriveWrappingKey(from: passphrase, salt: metadata.salt)
            let sealedBox = try AES.GCM.SealedBox(combined: metadata.wrappedKey)
            let kDataBytes = try AES.GCM.open(sealedBox, using: kWrap)
            cachedDataKey = SymmetricKey(data: kDataBytes)
        } else {
            // First-time setup: generate K_data and metadata.
            let kData = SymmetricKey(size: .bits256)
            let salt = Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) })
            let kWrap = try deriveWrappingKey(from: passphrase, salt: salt)

            let kDataBytes = kData.withUnsafeBytes { Data($0) }
            let sealed = try AES.GCM.seal(kDataBytes, using: kWrap)
            guard let combined = sealed.combined else {
                throw NSError(domain: "DataEncryptionService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to wrap data key"])
            }

            let metadata = Metadata(salt: salt, wrappedKey: combined)
            try storeMetadata(metadata)
            cachedDataKey = kData
        }
    }

    /// Unlocks the encryption key hierarchy using system authentication
    /// (Face ID / Touch ID / device passcode). The underlying passphrase is
    /// generated once and stored in the Keychain, and is never shown to the
    /// user.
    func unlockWithDeviceAuthentication(reason: String = "Unlock local AICoven data") async throws {
        // Use LocalAuthentication to require Face ID / Touch ID / passcode.
        let context = LAContext()
        var laError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &laError) else {
            throw laError ?? NSError(
                domain: "DataEncryptionService",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "Device authentication is not available on this device."]
            )
        }

        // Wrap evaluatePolicy in async/await.
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if success {
                    continuation.resume(returning: true)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "DataEncryptionService",
                        code: -11,
                        userInfo: [NSLocalizedDescriptionKey: "Device authentication failed."]
                    ))
                }
            }
        }

        // After successful device auth, load or create the hidden passphrase
        // from the Keychain, then delegate to the existing unlock method.
        if let existing = try loadDevicePassphraseFromKeychain() {
            try unlock(withPassphrase: existing)
        } else {
            // First-time setup: generate a random passphrase that never leaves
            // the device and is stored only in the Keychain.
            let randomBytes = (0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }
            let passphrase = Data(randomBytes).base64EncodedString()
            try storeDevicePassphraseInKeychain(passphrase)
            try unlock(withPassphrase: passphrase)
        }
    }

    /// Clears the in-memory data key (e.g., on app lock).
    func lock() {
        cachedDataKey = nil
    }

    /// Encrypts arbitrary data for storage.
    func encrypt(_ plaintext: Data, purpose: String) throws -> Data {
        let key = try requireDataKey()
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: Data(purpose.utf8))
        guard let combined = sealed.combined else {
            throw NSError(domain: "DataEncryptionService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to encrypt data"])
        }
        return combined
    }

    /// Decrypts data previously produced by `encrypt`.
    func decrypt(_ ciphertext: Data, purpose: String) throws -> Data {
        let key = try requireDataKey()
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key, authenticating: Data(purpose.utf8))
    }

    // MARK: - Internals

    private func requireDataKey() throws -> SymmetricKey {
        guard let key = cachedDataKey else {
            throw NSError(domain: "DataEncryptionService", code: -3, userInfo: [NSLocalizedDescriptionKey: "Encryption key is locked. Call unlock(withPassphrase:) first."])
        }
        return key
    }

    /// Derives K_wrap from a passphrase and salt.
    /// NOTE: This uses a simple HKDF-based derivation for now. For
    /// production, consider a PBKDF2/Argon2-based KDF tuned per device.
    private func deriveWrappingKey(from passphrase: String, salt: Data) throws -> SymmetricKey {
        let inputKey = SymmetricKey(data: Data(passphrase.utf8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: Data("aicoven-local-wrap".utf8),
            outputByteCount: 32
        )
    }

    private func loadMetadata() throws -> Metadata? {
        guard let data = UserDefaults.standard.data(forKey: metadataKey) else {
            return nil
        }
        return try JSONDecoder().decode(Metadata.self, from: data)
    }

    private func storeMetadata(_ metadata: Metadata) throws {
        let encoded = try JSONEncoder().encode(metadata)
        UserDefaults.standard.set(encoded, forKey: metadataKey)
    }

    // MARK: - Keychain helpers for device-backed passphrase

    private func loadDevicePassphraseFromKeychain() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let passphrase = String(data: data, encoding: .utf8) else {
                return nil
            }
            return passphrase
        case errSecItemNotFound:
            return nil
        default:
            throw NSError(
                domain: "DataEncryptionService",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Keychain error (load): \(status)"]
            )
        }
    }

    private func storeDevicePassphraseInKeychain(_ passphrase: String) throws {
        let data = Data(passphrase.utf8)

        // Remove any existing item first.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            // Rely on the system keychain being protected by device
            // passcode/biometrics; item is only available when unlocked.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(
                domain: "DataEncryptionService",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Keychain error (store): \(status)"]
            )
        }
    }
}

#if DEBUG
extension DataEncryptionService {
    /// Lightweight unlock used only in XCTest so tests never depend on the
    /// user's real passphrase or device authentication. This installs a fresh
    /// in-memory data key without touching persisted metadata or the Keychain.
    nonisolated static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func unlockForTestingEphemeral() {
        guard Self.isRunningTests else { return }
        // Install a random in-memory key; since tests run in a single process
        // this is enough to exercise encryption/decryption paths.
        cachedDataKey = SymmetricKey(size: .bits256)
    }
}
#endif
