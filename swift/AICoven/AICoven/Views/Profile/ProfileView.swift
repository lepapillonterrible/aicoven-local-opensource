import SwiftUI

/// User profile view
struct ProfileView: View {
    @EnvironmentObject var authService: AuthService
    @State private var user: User?

    private let analytics = AnalyticsService.shared

    var body: some View {
        NavigationStack {
            List {
                // User info section
                Section {
                    HStack(spacing: 16) {
                        // Avatar
                        ZStack {
                            Circle()
                                .fill(Color(hex: "#8B5CF6").opacity(0.2))
                                .frame(width: 60, height: 60)

                            Image(systemName: "person.fill")
                                .font(.title)
                                .foregroundColor(Color(hex: "#8B5CF6"))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(user?.name ?? "User")
                                .font(.headline)

                            Text(user?.email ?? "")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }

                // Stats section
                Section("Activity") {
                    HStack {
                        Label("Covens", systemImage: "sparkles")
                        Spacer()
                        Text("0")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Label("Threads", systemImage: "message")
                        Spacer()
                        Text("0")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Label("Messages", systemImage: "bubble.left")
                        Spacer()
                        Text("0")
                            .foregroundColor(.secondary)
                    }
                }

                // Budgets & Usage
                Section("Settings") {
                    NavigationLink(destination: UsageSettingsView()) {
                        Label("Budgets & Usage", systemImage: "chart.bar")
                    }
                }

                // Actions section
                Section {
                    Button(action: signOut) {
                        Label("Sign Out", systemImage: "arrow.right.square")
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Profile")
            .scrollContentBackground(.hidden)
            .background(NebulaBackground())
        }
        .task {
            await loadUserProfile()
            await MainActor.run {
                analytics.trackScreenView(screenName: "ProfileView", screenClass: "ProfileView")
                analytics.trackProfileOpened()
            }
        }
    }

    /// Load user profile from API
    private func loadUserProfile() async {
        user = authService.currentUser
    }

    /// Sign out
    private func signOut() {
        analytics.trackScreenView(screenName: "Logout", screenClass: "ProfileView")
        Task {
            do {
                try await authService.signOut()
            } catch {
                AppErrorReporter.log(error: error, context: "ProfileView.signOut")
            }
        }
    }
}

#Preview {
    ProfileView()
        .environmentObject(AuthService.shared)
}
