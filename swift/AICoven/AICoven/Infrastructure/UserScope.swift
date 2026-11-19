import Foundation
import FirebaseAuth
import FirebaseCore

/// Centralized helper for scoping local data stores (UserDefaults keys,
/// Keychain service names, file paths) to the current Firebase user.
///
/// Every service that persists user-specific data should use these helpers
/// so that signing in as a different user produces a completely isolated
/// data space. Local/offline mode uses an explicit stable local user scope;
/// it must never fall back to unscoped keys.
enum UserScope {

    // MARK: - Current User

    /// Stable owner ID for local-first/offline use when Firebase is unavailable
    /// or no Firebase user is signed in.
    static let localUserID = "local-user"

    /// The Firebase UID of the currently signed-in user, if Firebase is configured.
    static var firebaseUserID: String? {
        // Guard against accessing Auth before Firebase is configured
        // (crashes in CI/test environments without valid GoogleService-Info.plist)
        guard FirebaseApp.app() != nil else { return nil }
        return Auth.auth().currentUser?.uid
    }

    /// The owner ID that must be used for all local persistence. This always
    /// returns either the authenticated Firebase UID or the explicit local user
    /// scope; returning an unscoped nil would leak data across auth states.
    static var currentUserID: String {
        firebaseUserID ?? localUserID
    }

    // MARK: - Key Scoping

    /// Returns a UserDefaults key scoped to the current user.
    ///
    /// Example: `scopedKey("provider_accounts.v1")` → `"abc123.provider_accounts.v1"`
    static func scopedKey(_ base: String) -> String {
        scopedKey(base, for: currentUserID)
    }

    /// Returns a Keychain service identifier scoped to the current user.
    static func scopedKeychainService(_ base: String) -> String {
        scopedKeychainService(base, for: currentUserID)
    }

    /// `scopedKey` for a named account: for work that waits and must stay
    /// with the account it began for, whoever is signed in by then.
    nonisolated static func scopedKey(_ base: String, for userID: String) -> String {
        "\(userID).\(base)"
    }

    /// `scopedKeychainService` for a named account.
    nonisolated static func scopedKeychainService(_ base: String, for userID: String) -> String {
        "\(base).\(userID)"
    }

    /// Returns a filename scoped to the current user.
    ///
    /// Example: `scopedFilename("personal_threads", extension: "json")` →
    /// `"personal_threads_abc123.json"`
    static func scopedFilename(_ base: String, extension ext: String) -> String {
        "\(base)_\(currentUserID).\(ext)"
    }
}
