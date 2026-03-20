import SwiftUI
import FirebaseCore

/// Main entry point for the local-first AICoven client.
/// No login, no covens, no backend onboarding – it always shows the
/// personal workspace (Conversations + tabs).
@main
struct AICovenApp: App {
    /// Simple splash state
    @State private var isShowingSplash = true
    /// Whether the local encryption key has been unlocked for this session.
    @State private var isEncryptionUnlocked = false
    /// Observe AuthService to react to sign-out events.
    /// Initialized in init() AFTER Firebase is configured, because
    /// AuthService.shared accesses Auth.auth() which requires Firebase first.
    @ObservedObject private var authService: AuthService

    init() {
        // Initialize Firebase only if a valid configuration is available and not
        // already configured, to avoid fatal errors in local/CI builds without
        // a real GoogleService-Info.plist (or with a placeholder).
        if FirebaseApp.app() == nil {
            if let filePath = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
               let options = FirebaseOptions(contentsOfFile: filePath),
               Self.isValidFirebaseConfig(options) {
                FirebaseApp.configure(options: options)
            }
        }

        // NOW it is safe to access AuthService.shared (requires Auth.auth()).
        _authService = ObservedObject(wrappedValue: AuthService.shared)

        // Local-only version: no remote auth beyond what Firebase Auth provides if used.
        Self.configureAppearance()
        // Initialize local SQLite database and run migrations.
        DatabaseManager.shared.configureIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if isShowingSplash {
                    SplashScreenView()
                        .transition(.opacity)
                } else if !isEncryptionUnlocked {
                    // First check auth, then unlock encryption with user-scoped keys.
                    if !authService.isAuthenticated, !authService.isLoading {
                        PreAuthOnboardingView()
                            .environmentObject(authService)
                            .environmentObject(AppState.shared)
                            .environmentObject(StoreService.shared)
                            .transition(.opacity)
                    } else if authService.isLoading {
                        LoadingView(message: "Loading...")
                    } else {
                        UnlockEncryptionView {
                            withAnimation(.easeInOut(duration: 0.4)) {
                                isEncryptionUnlocked = true
                            }
                        }
                        .transition(.opacity)
                    }
                } else {
                    ContentView()
                        .environmentObject(authService)
                        .environmentObject(AppState.shared)
                        .environmentObject(StoreService.shared)
                        .transition(.opacity)
                }
            }
            .onAppear {
                // Timed splash; no remote initialization.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        isShowingSplash = false
                    }
                }
            }
            .onChange(of: authService.isAuthenticated) { _, authenticated in
                // When user signs out, reset encryption so next user gets a fresh unlock.
                if !authenticated {
                    isEncryptionUnlocked = false
                }
            }
        }
        #if os(macOS)
        .defaultSize(width: 820, height: 620)
        .commands {
            // macOS-specific menu commands can be re-added later if needed.
        }
        #endif
    }

    /// Configure global app appearance
    private static func configureAppearance() {
        #if os(iOS)
        UINavigationBar.appearance().largeTitleTextAttributes = [
            .foregroundColor: UIColor.white
        ]
        #endif
    }

    /// Check if Firebase options contain valid (non-placeholder) configuration.
    /// Returns false for placeholder configs used in CI builds.
    private static func isValidFirebaseConfig(_ options: FirebaseOptions) -> Bool {
        // Check that googleAppID is not a placeholder value.
        // Valid Google App IDs follow the format: 1:PROJECT_NUMBER:PLATFORM:HEX_STRING
        let googleAppID = options.googleAppID
        // Reject obvious placeholder values
        if googleAppID.contains("000000000000") || googleAppID == "placeholder" || googleAppID.isEmpty {
            return false
        }
        // Also check API key isn't a placeholder
        if options.apiKey == "placeholder" {
            return false
        }
        return true
    }
}
