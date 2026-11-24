import Foundation
import FirebaseAuth
import FirebaseCore
internal import Combine
import GRDB

/// Authentication service using Firebase Auth.
///
/// Copied from the cloud AICoven app and adapted for local-first:
/// - Firebase Auth handles sign-in/sign-up/sign-out/password-reset (gives persistent user ID)
/// - User profile is built from Firebase user data (no backend API calls)
/// - Onboarding flag persisted locally via UserDefaults
@MainActor
class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published var currentUser: User?
    @Published var isAuthenticated = false
    @Published var isLoading = true
    @Published var error: Error?

    private var authStateHandle: AuthStateDidChangeListenerHandle?

    /// Whether Firebase Auth is available (i.e., FirebaseApp was configured).
    /// When false, all auth operations are no-ops.
    private let isFirebaseAvailable: Bool

    /// UserDefaults key for persisting onboarding completion, scoped by user.
    private static func onboardingKey(for uid: String? = nil) -> String {
        let id = uid ?? UserScope.currentUserID
        let base = "hasCompletedOnboarding"
        return "\(id).\(base)"
    }

    /// UserDefaults key to detect fresh install. This is NOT user-scoped because
    /// we need to detect reinstall before knowing who the user is.
    private static let hasLaunchedBeforeKey = "AuthService.hasLaunchedBefore"

    private init() {
        print("🔧 AuthService initializing...")

        // Check if Firebase is configured before accessing Auth.auth().
        // In CI builds or when GoogleService-Info.plist is missing/invalid,
        // FirebaseApp won't be configured and Auth.auth() would crash.
        guard FirebaseApp.app() != nil else {
            print("⚠️ Firebase not configured - AuthService running in offline mode")
            isFirebaseAvailable = false
            isLoading = false
            return
        }
        isFirebaseAvailable = true

        // Detect fresh install: Firebase persists auth in Keychain (survives app deletion),
        // but UserDefaults is cleared on uninstall. If we have a Firebase user but no
        // UserDefaults marker, this is a reinstall - sign out for a clean slate.
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: Self.hasLaunchedBeforeKey)
        if !hasLaunchedBefore {
            UserDefaults.standard.set(true, forKey: Self.hasLaunchedBeforeKey)
            if Auth.auth().currentUser != nil {
                print("🔄 Fresh install detected with stale Firebase auth - signing out")
                try? Auth.auth().signOut()
            }
        }

        // Listen for auth state changes
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, firebaseUser in
            Task { @MainActor in
                self?.isLoading = true
                // Who is signed in now, for a link that is waiting.
                AppState.shared.accountReported(firebaseUser?.uid)
                // Whoever is signed in now, nothing the rows said of the
                // account before stays said: on signing in, switching,
                // signing out, and when an account is deleted.
                ThreadActivities.shared.accountChanged()
                MemoryProposalQuestions.shared.accountReported(UserScope.currentUserID)
                // What is asked of the account before leaves; the same
                // account reported again keeps it.
                ToolApprovals.shared.accountReported(UserScope.currentUserID)
                // A turn still running for the account before is stopped there.
                TurnEngine.shared.accountChanged()
                LocalNotifications.shared.accountReported(firebaseUser?.uid)
                // The pictures drawn of the account's assets are held in
                // memory only, and not for whoever is signed in next.
                AssetThumbnails.shared.forgetAll()
                if let firebaseUser {
                    print("✅ Firebase user signed in")
                    // Clear any previous user's data first
                    AppState.shared.clearUserData()
                    // Build user profile from Firebase user data (no backend needed)
                    self?.buildLocalUserProfile(from: firebaseUser)
                    self?.isAuthenticated = true
                    // Reload all services for the newly signed-in user to ensure
                    // user-scoped data isolation (prevents seeing other users' data)
                    await ThreadService.shared.reloadForCurrentUser()
                    // Read again now that the threads are this account's.
                    ThreadActivities.shared.accountChanged()
                    MemoryProposalQuestions.shared.accountReported(UserScope.currentUserID)

                    // One-time cleanup: clear stale test purchases that were cached
                    // during automated testing. This runs once per user.
                    let cleanupKey = "StoreService.didCleanupStalePurchases.\(firebaseUser.uid)"
                    if !UserDefaults.standard.bool(forKey: cleanupKey) {
                        await MainActor.run {
                            StoreService.shared.clearStalePurchasesForCurrentUser()
                            UserDefaults.standard.set(true, forKey: cleanupKey)
                        }
                    }

                    await StoreService.shared.reloadForCurrentUser()
                } else {
                    print("❌ No Firebase user - signed out")
                    self?.currentUser = nil
                    self?.isAuthenticated = false
                }
                self?.isLoading = false
            }
        }
    }

    deinit {
        // Only remove listener if Firebase was available
        if isFirebaseAvailable, let handle = authStateHandle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }

    /// Get current Firebase ID token (available for future API use if needed)
    func getIdToken() async -> String? {
        guard isFirebaseAvailable else { return nil }
        do {
            return try await Auth.auth().currentUser?.getIDToken()
        } catch {
            print("Error getting ID token (\(type(of: error)))")
            return nil
        }
    }

    /// Sign in with email and password
    func signIn(email: String, password: String) async throws {
        guard isFirebaseAvailable else {
            throw NSError(
                domain: "AuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Firebase not configured"]
            )
        }
        print("🔐 Attempting sign in")
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await Auth.auth().signIn(withEmail: email, password: password)
            print("✅ Firebase sign in successful")
            // User profile will be built by auth state listener
        } catch {
            print("❌ Firebase sign in failed (\(type(of: error)))")
            self.error = error
            throw error
        }
    }

    /// Sign up with email and password
    func signUp(email: String, password: String, name: String?) async throws {
        guard isFirebaseAvailable else {
            throw NSError(
                domain: "AuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Firebase not configured"]
            )
        }
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)

            // Update display name if provided
            if let name {
                let changeRequest = result.user.createProfileChangeRequest()
                changeRequest.displayName = name
                try await changeRequest.commitChanges()
                // The auth state listener fires immediately on createUser,
                // before commitChanges completes, so the initial profile has
                // nil displayName. Rebuild now that the name is committed.
                buildLocalUserProfile(from: result.user)
            }

            // Auth state listener will also fire, but we've already set up
            // the profile with the correct name above.
        } catch {
            self.error = error
            throw error
        }
    }

    /// Sign out and clean up user-scoped state.
    func signOut() throws {
        // Lock encryption so the next user must re-authenticate.
        Task {
            await DataEncryptionService.shared.lock()
            // Reload threads for the (now nil) user context.
            await ThreadService.shared.reloadForCurrentUser()
        }
        // Only call Firebase signOut if available
        if isFirebaseAvailable {
            try Auth.auth().signOut()
        }
        // At once, before this returns: nothing the rows said of the
        // account stays said.
        ThreadActivities.shared.accountChanged()
        AssetThumbnails.shared.forgetAll()
        MemoryProposalQuestions.shared.accountChanged()
        ToolApprovals.shared.accountChanged()
        // A turn still running for the account before is stopped there.
        TurnEngine.shared.accountChanged()
        LocalNotifications.shared.accountReported(nil)
        currentUser = nil
        isAuthenticated = false
    }

    /// Send password reset email
    func sendPasswordReset(email: String) async throws {
        guard isFirebaseAvailable else {
            throw NSError(
                domain: "AuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Firebase not configured"]
            )
        }
        try await Auth.auth().sendPasswordReset(withEmail: email)
    }

    /// Build a local User object from the Firebase user (no backend API call)
    private func buildLocalUserProfile(from firebaseUser: FirebaseAuth.User) {
        let user = User(
            id: firebaseUser.uid,
            email: firebaseUser.email ?? "",
            name: firebaseUser.displayName,
            profile: nil,
            settings: UserSettings(
                theme: nil,
                language: nil,
                notifications: nil,
                emailNotifications: nil,
                hasCompletedOnboarding: UserDefaults.standard.bool(forKey: AuthService.onboardingKey(for: firebaseUser.uid)),
                animatedBackgrounds: nil
            ),
            createdAt: firebaseUser.metadata.creationDate,
            updatedAt: firebaseUser.metadata.lastSignInDate
        )
        currentUser = user
        // Sync onboarding flag to AppState
        AppState.shared.hasCompletedOnboarding = user.settings?.hasCompletedOnboarding ?? false
    }

    /// Update user profile (local-only: updates Firebase display name and in-memory user)
    func updateProfile(name: String?, profile: UserProfile?) async throws {
        guard isFirebaseAvailable else { return }
        if let name, let fbUser = Auth.auth().currentUser {
            let changeRequest = fbUser.createProfileChangeRequest()
            changeRequest.displayName = name
            try await changeRequest.commitChanges()
        }
        // Rebuild local user from (now-updated) Firebase user
        if let fbUser = Auth.auth().currentUser {
            buildLocalUserProfile(from: fbUser)
        }
    }

    /// Mark the current user as having completed FTUE onboarding.
    /// Persisted locally via UserDefaults (no backend needed).
    func markOnboardingCompleted() async {
        UserDefaults.standard.set(true, forKey: AuthService.onboardingKey())
        AppState.shared.hasCompletedOnboarding = true
        // Rebuild user so settings reflect the change (only if Firebase is available)
        if isFirebaseAvailable, let fbUser = Auth.auth().currentUser {
            buildLocalUserProfile(from: fbUser)
        }
    }

    /// Reset FTUE onboarding flag (debug/QA helper).
    func markOnboardingCompletedReset() async {
        UserDefaults.standard.set(false, forKey: AuthService.onboardingKey())
        AppState.shared.hasCompletedOnboarding = false
        // Rebuild user so settings reflect the change (only if Firebase is available)
        if isFirebaseAvailable, let fbUser = Auth.auth().currentUser {
            buildLocalUserProfile(from: fbUser)
        }
    }

    /// Re-authenticate the user with their password.
    /// Required before sensitive operations like account deletion.
    /// - Parameter password: The user's current password
    /// - Throws: An error if re-authentication fails
    func reauthenticate(password: String) async throws {
        guard isFirebaseAvailable else {
            throw NSError(
                domain: "AuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Firebase not configured"]
            )
        }

        guard let firebaseUser = Auth.auth().currentUser,
              let email = firebaseUser.email else {
            throw NSError(
                domain: "AuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No user is currently signed in."]
            )
        }

        // Create credential and re-authenticate
        let credential = EmailAuthProvider.credential(withEmail: email, password: password)
        try await firebaseUser.reauthenticate(with: credential)
        print("✅ Re-authentication successful")
    }

    /// Permanently delete the current user's account and all associated local data.
    /// This deletes all user data from the local SQLite database and the Firebase Auth user.
    /// - Parameter password: The user's current password for re-authentication
    /// - Throws: An error if the deletion fails
    func deleteAccount(password: String) async throws {
        print("🗑️ Starting account deletion...")

        guard isFirebaseAvailable else {
            throw NSError(
                domain: "AuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Firebase not configured"]
            )
        }

        guard let firebaseUser = Auth.auth().currentUser else {
            throw NSError(
                domain: "AuthService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No user is currently signed in."]
            )
        }

        // Re-authenticate before deletion (Firebase requires recent auth for sensitive ops)
        try await reauthenticate(password: password)

        let userId = firebaseUser.uid

        // Delete all user data from local SQLite database
        await deleteLocalUserData(userId: userId)
        // And the files attached to the account's messages.
        await AttachmentStore.shared.deleteAllFiles(for: userId)

        // Clear user-specific UserDefaults
        UserDefaults.standard.removeObject(forKey: AuthService.onboardingKey(for: userId))
        CovenOrderStore().remove(for: userId)
        LastUsedAgentStore().remove(for: userId)
        ScopeVisitStore().remove(for: userId)
        LocalNotifications.shared.forget(userId)

        // Delete the Firebase Auth user
        do {
            try await firebaseUser.delete()
            print("✅ Firebase user deleted")
        } catch {
            print("❌ Failed to delete Firebase user (\(type(of: error)))")
            // Re-throw the error since the user expects account to be fully deleted
            throw error
        }

        // Its threads are gone: so is what their rows said.
        ThreadActivities.shared.accountChanged()
        AssetThumbnails.shared.forgetAll()
        MemoryProposalQuestions.shared.accountChanged()
        ToolApprovals.shared.accountChanged()
        // A turn still running for the account before is stopped there.
        TurnEngine.shared.accountChanged()
        LocalNotifications.shared.accountReported(nil)

        print("✅ Account deleted successfully")

        // Clear local state
        await DataEncryptionService.shared.lock()
        currentUser = nil
        isAuthenticated = false
        AppState.shared.hasCompletedOnboarding = false
    }

    /// Deletes all local data for a specific user from the SQLite database.
    /// - Parameter userId: The Firebase UID of the user whose data should be deleted
    private func deleteLocalUserData(userId: String) async {
        print("🗑️ Deleting local data for the account")

        guard let dbQueue = await DatabaseManager.shared.dbQueue else {
            print("⚠️ Database not available, skipping local data deletion")
            return
        }

        do {
            try await dbQueue.write { db in
                // Delete user's threads and messages (messages cascade delete with threads)
                try db.execute(
                    sql: "DELETE FROM threads WHERE user_id = ?",
                    arguments: [userId]
                )

                // Delete user's memory chunks
                try db.execute(
                    sql: "DELETE FROM memory_chunks WHERE user_id = ?",
                    arguments: [userId]
                )

                // What every agent of the user's covens, and of Strix, is told
                try db.execute(
                    sql: "DELETE FROM coven_context WHERE user_id = ?",
                    arguments: [userId]
                )

                // Delete user's memory proposals
                try db.execute(
                    sql: "DELETE FROM memory_proposals WHERE user_id = ?",
                    arguments: [userId]
                )

                // Delete user's skills
                try db.execute(
                    sql: "DELETE FROM skills WHERE user_id = ?",
                    arguments: [userId]
                )

                // Delete user's assets (their files go with them)
                try db.execute(
                    sql: "DELETE FROM assets WHERE user_id = ?",
                    arguments: [userId]
                )

                // Delete user's tasks
                try db.execute(
                    sql: "DELETE FROM tasks WHERE user_id = ?",
                    arguments: [userId]
                )

                // Delete user's roles (cascade from covens may handle some)
                try db.execute(
                    sql: "DELETE FROM roles WHERE user_id = ?",
                    arguments: [userId]
                )

                // Delete user's covens (will cascade delete roles)
                try db.execute(
                    sql: "DELETE FROM covens WHERE user_id = ?",
                    arguments: [userId]
                )

                // Delete user's provider accounts
                try db.execute(
                    sql: "DELETE FROM provider_accounts WHERE id IN (SELECT id FROM provider_accounts)",
                    arguments: []
                )

                // Delete user settings
                try db.execute(
                    sql: "DELETE FROM user_settings WHERE id = ?",
                    arguments: [userId]
                )

                print("✅ Local user data deleted from SQLite")
            }
        } catch {
            print("❌ Failed to delete local user data (\(type(of: error)))")
            // Don't throw here - we still want to proceed with Firebase deletion
        }
    }
}
