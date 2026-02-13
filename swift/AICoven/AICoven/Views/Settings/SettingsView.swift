import SwiftUI

/// Settings view
struct SettingsView: View {
    @AppStorage("notifications_enabled") private var notificationsEnabled = true
    @AppStorage("dark_mode_enabled") private var darkModeEnabled = true
    @AppStorage("compact_mode") private var compactMode = false

    private let analytics = AnalyticsService.shared

    var body: some View {
        NavigationStack {
            Form {
                // Account section
                Section("Account") {
                    NavigationLink(destination: AccountSettingsView()) {
                        Label("Account Details", systemImage: "person.circle")
                    }

                    NavigationLink(destination: LegacyProviderKeysView()) {
                        Label("Provider Keys", systemImage: "key")
                    }
                }

                // Appearance section
                Section("Appearance") {
                    Toggle(isOn: $darkModeEnabled) {
                        Label("Dark Mode", systemImage: "moon")
                    }
                    .onChange(of: darkModeEnabled) { _, newValue in
                        analytics.trackThemeChange(theme: newValue ? "dark" : "light")
                    }

                    Toggle(isOn: $compactMode) {
                        Label("Compact Mode", systemImage: "rectangle.compress.vertical")
                    }
                    .onChange(of: compactMode) { _, newValue in
                        analytics.trackSettingChange(setting: "compact_mode", value: newValue ? "enabled" : "disabled")
                    }
                }

                // Notifications section
                Section("Notifications") {
                    Toggle(isOn: $notificationsEnabled) {
                        Label("Enable Notifications", systemImage: "bell")
                    }
                    .onChange(of: notificationsEnabled) { _, newValue in
                        analytics.trackNotificationSettingChange(type: "all", enabled: newValue)
                    }
                }

                // Memory section
                Section("Memory & Data") {
                    NavigationLink(destination: MemorySettingsView()) {
                        Label("Memory Settings", systemImage: "brain")
                    }

                    Button(action: clearCache) {
                        Label("Clear Cache", systemImage: "trash")
                            .foregroundColor(.red)
                    }
                }

                // About section
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundColor(.secondary)
                    }

                    Link(destination: URL(string: "https://aicoven.com/privacy")!) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }

                    Link(destination: URL(string: "https://aicoven.com/terms")!) {
                        Label("Terms of Service", systemImage: "doc.text")
                    }
                }

                // Help section
                Section("Help") {
                    NavigationLink(destination: CovenTutorialView()) {
                        Label("Tutorial", systemImage: "questionmark.circle")
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                analytics.trackScreenView(screenName: "SettingsView", screenClass: "SettingsView")
            }
        }
    }

    /// Clear cached data
    private func clearCache() {
        // TODO: Implement cache clearing
        print("Clearing cache...")
    }
}

/// Account settings view with profile info and account management
struct AccountSettingsView: View {
    @EnvironmentObject var authService: AuthService
    @State private var showDeleteConfirmation = false
    @State private var showFinalDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var deleteError: String?
    @State private var showPasswordReset = false
    @State private var passwordResetSent = false

    var body: some View {
        Form {
            // Profile section showing current user info
            Section("Profile") {
                HStack {
                    Text("Display Name")
                    Spacer()
                    Text(authService.currentUser?.name ?? "Not set")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Email")
                    Spacer()
                    Text(authService.currentUser?.email ?? "Unknown")
                        .foregroundColor(.secondary)
                }
            }

            // Security section with password reset and account deletion
            Section("Security") {
                Button("Reset Password") {
                    showPasswordReset = true
                }

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    HStack {
                        Text("Delete Account")
                        if isDeleting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isDeleting)
            }

            // Show error if deletion failed
            if let error = deleteError {
                Section {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Account")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .onAppear {
                AnalyticsService.shared.trackSettingsView(section: "account")
            }
            // Password reset confirmation
            .alert("Reset Password", isPresented: $showPasswordReset) {
                Button("Cancel", role: .cancel) {}
                Button("Send Reset Email") {
                    Task {
                        if let email = authService.currentUser?.email {
                            do {
                                try await authService.sendPasswordReset(email: email)
                                passwordResetSent = true
                            } catch {
                                print("❌ Failed to send password reset: \(error)")
                            }
                        }
                    }
                }
            } message: {
                Text("We'll send a password reset link to \(authService.currentUser?.email ?? "your email").")
            }
            // Password reset sent confirmation
            .alert("Email Sent", isPresented: $passwordResetSent) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Check your email for the password reset link.")
            }
            // First delete confirmation
            .alert("Delete Account?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Continue", role: .destructive) {
                    showFinalDeleteConfirmation = true
                }
            } message: {
                Text("This will permanently delete your account and all your local data including conversations, memories, and settings. This action cannot be undone.")
            }
            // Final delete confirmation
            .alert("Are you absolutely sure?", isPresented: $showFinalDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete My Account", role: .destructive) {
                    Task {
                        await deleteAccount()
                    }
                }
            } message: {
                Text("Your account will be permanently deleted. You will be signed out immediately.")
            }
    }

    /// Deletes the user's account and local data, then signs out
    private func deleteAccount() async {
        isDeleting = true
        deleteError = nil

        do {
            try await authService.deleteAccount()
            // User is now signed out; the auth state listener will handle UI transition
        } catch {
            deleteError = "Failed to delete account. Please try again."
            print("❌ Account deletion failed: \(error)")
        }

        isDeleting = false
    }
}

/// Placeholder for provider keys (legacy - use Settings/ProviderKeysView.swift instead)
struct LegacyProviderKeysView: View {
    var body: some View {
        List {
            Section("API Keys") {
                Text("Manage your AI provider API keys")
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Provider Keys")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .onAppear {
                AnalyticsService.shared.trackSettingsView(section: "provider_keys")
            }
    }
}

/// Placeholder for memory settings
struct MemorySettingsView: View {
    @State private var autoCapture = true
    @State private var similarityThreshold = 0.7

    var body: some View {
        Form {
            Section("Memory Capture") {
                Toggle("Auto-capture Conversations", isOn: $autoCapture)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Similarity Threshold")
                        .font(.subheadline)
                    Slider(value: $similarityThreshold, in: 0 ... 1, step: 0.1)
                    Text(String(format: "%.1f", similarityThreshold))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Policies") {
                Text("Memory retention and sharing policies")
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Memory Settings")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#Preview {
    SettingsView()
}
