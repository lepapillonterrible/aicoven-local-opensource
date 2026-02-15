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
        guard let id else { return base }
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
                if let firebaseUser {
                    print("✅ Firebase user signed in: \(firebaseUser.email ?? "unknown")")
                    // Clear any previous user's data first
                    AppState.shared.clearUserData()
                    // Build user profile from Firebase user data (no backend needed)
                    self?.buildLocalUserProfile(from: firebaseUser)
                    self?.isAuthenticated = true
                    // Reload all services for the newly signed-in user to ensure
                    // user-scoped data isolation (prevents seeing other users' data)
                    await ThreadService.shared.reloadForCurrentUser()
                    await StoreService.shared.reloadForCurrentUser()
                    await ChatService.shared.reloadForCurrentUser()
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
            print("Error getting ID token: \(error)")
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
        print("🔐 Attempting sign in for: \(email)")
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await Auth.auth().signIn(withEmail: email, password: password)
            print("✅ Firebase sign in successful: \(result.user.uid)")
            // User profile will be built by auth state listener
        } catch {
            print("❌ Firebase sign in failed: \(error.localizedDescription)")
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

    /// Permanently delete the current user's account and all associated local data.
    /// This deletes all user data from the local SQLite database and the Firebase Auth user.
    /// - Throws: An error if the deletion fails
    func deleteAccount() async throws {
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

        let userId = firebaseUser.uid

        // Delete all user data from local SQLite database
        await deleteLocalUserData(userId: userId)

        // Clear user-specific UserDefaults
        UserDefaults.standard.removeObject(forKey: AuthService.onboardingKey(for: userId))

        // Delete the Firebase Auth user
        do {
            try await firebaseUser.delete()
            print("✅ Firebase user deleted")
        } catch {
            print("❌ Failed to delete Firebase user: \(error)")
            // Re-throw the error since the user expects account to be fully deleted
            throw error
        }

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
        print("🗑️ Deleting local data for user: \(userId)")

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

                // Delete user's memory proposals
                try db.execute(
                    sql: "DELETE FROM memory_proposals WHERE user_id = ?",
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
            print("❌ Failed to delete local user data: \(error)")
            // Don't throw here - we still want to proceed with Firebase deletion
        }
    }
}
