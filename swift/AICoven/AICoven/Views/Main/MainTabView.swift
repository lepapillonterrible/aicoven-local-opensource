import SwiftUI

/// Main tab view for authenticated users
struct MainTabView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            // Home/Threads tab
            ThreadsView()
                .tabItem {
                    Label("Threads", systemImage: "message")
                }

            // Profile tab
            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person.circle")
                }
        }
        .tint(.purple)
    }
}

/// Threads list view (stub)
struct ThreadsView: View {
    var body: some View {
        NavigationStack {
            VStack {
                Text("Threads")
                    .font(.largeTitle)
                Text("Coming soon...")
                    .foregroundColor(.secondary)
            }
            .navigationTitle("Threads")
            .background(Color.black)
        }
    }
}

#Preview {
    MainTabView()
        .environmentObject(AuthService.shared)
        .environmentObject(AppState.shared)
}
