import SwiftUI

/// Root view that handles authentication state and routing.
///
/// On first launch, shows the Firebase login/signup flow. Once authenticated,
/// routes to the onboarding (if not completed) or the main app.
struct ContentView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if authService.isLoading {
                // Show loading state while checking auth
                LoadingView(message: "Loading...")
            } else if authService.isAuthenticated {
                // Authenticated – check onboarding
                if appState.hasCompletedOnboarding {
                    #if os(iOS)
                    MobileRootView()
                    #else
                    HomeView()
                    #endif
                } else {
                    OnboardingFlowView()
                }
            } else {
                // Show login / sign-up flow
                LoginView()
            }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthService.shared)
        .environmentObject(AppState.shared)
}
