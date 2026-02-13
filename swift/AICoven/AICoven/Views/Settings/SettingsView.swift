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

/// Placeholder for account settings
struct AccountSettingsView: View {
    var body: some View {
        Form {
            Section("Profile") {
                TextField("Display Name", text: .constant(""))
                TextField("Email", text: .constant(""))
                    .textContentType(.emailAddress)
                #if os(iOS)
                    .keyboardType(.emailAddress)
                #endif
            }

            Section("Security") {
                Button("Change Password") {
                    // TODO: Implement
                }

                Button("Delete Account") {
                    // TODO: Implement
                }
                .foregroundColor(.red)
            }
        }
        .navigationTitle("Account")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .onAppear {
                AnalyticsService.shared.trackSettingsView(section: "account")
            }
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
