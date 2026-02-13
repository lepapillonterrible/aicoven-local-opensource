import Foundation
import FirebaseAuth
internal import Combine

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

    /// UserDefaults key for persisting onboarding completion, scoped by user.
    private static func onboardingKey(for uid: String? = nil) -> String {
        let id = uid ?? UserScope.currentUserID
        let base = "hasCompletedOnboarding"
        guard let id else { return base }
        return "\(id).\(base)"
    }

    private init() {
        print("🔧 AuthService initializing...")
        // Listen for auth state changes
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, firebaseUser in
            Task { @MainActor in
                self?.isLoading = true
                if let firebaseUser {
                    print("✅ Firebase user signed in: \(firebaseUser.email ?? "unknown")")
                    // Build user profile from Firebase user data (no backend needed)
                    self?.buildLocalUserProfile(from: firebaseUser)
                    self?.isAuthenticated = true
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
        if let handle = authStateHandle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }

    /// Get current Firebase ID token (available for future API use if needed)
    func getIdToken() async -> String? {
        do {
            return try await Auth.auth().currentUser?.getIDToken()
        } catch {
            print("Error getting ID token: \(error)")
            return nil
        }
    }

    /// Sign in with email and password
    func signIn(email: String, password: String) async throws {
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
        try Auth.auth().signOut()
        currentUser = nil
        isAuthenticated = false
    }

    /// Send password reset email
    func sendPasswordReset(email: String) async throws {
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
        // Rebuild user so settings reflect the change
        if let fbUser = Auth.auth().currentUser {
            buildLocalUserProfile(from: fbUser)
        }
    }

    /// Reset FTUE onboarding flag (debug/QA helper).
    func markOnboardingCompletedReset() async {
        UserDefaults.standard.set(false, forKey: AuthService.onboardingKey())
        AppState.shared.hasCompletedOnboarding = false
        if let fbUser = Auth.auth().currentUser {
            buildLocalUserProfile(from: fbUser)
        }
    }
}
