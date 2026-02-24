import SwiftUI

/// Enhanced settings view with notifications and preferences
struct EnhancedSettingsView: View {
    @EnvironmentObject var authService: AuthService
    @State private var notificationsEnabled = true
    @State private var emailNotificationsEnabled = true
    @State private var loading = true
    @State private var saving = false
    @State private var animatedBackgrounds = true
    @AppStorage("aicoven_animated_backgrounds") private var storedAnimatedBackgrounds = true
    @State private var showConnectedApps = false

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                // Header
                VStack(spacing: Spacing.sm) {
                    IconBadge(icon: "gear", size: 60, color: .aicovenPurple)

                    Text("Settings")
                        .font(.aicovenDisplaySmall)
                        .foregroundColor(.aicovenTextPrimary)

                    Text("Manage your preferences")
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextSecondary)
                }
                .padding(.top, Spacing.xl)

                if loading {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.aicovenTeal)
                        .padding(.top, 50)
                } else {
                    // Notifications section
                    VStack(spacing: Spacing.md) {
                        HStack {
                            Text("Notifications")
                                .font(.aicovenH3)
                                .foregroundColor(.aicovenTextPrimary)
                            Spacer()
                        }

                        GlassCard {
                            VStack(spacing: Spacing.md) {
                                // Push notifications toggle
                                SettingToggleRow(
                                    icon: "bell.fill",
                                    title: "Push Notifications",
                                    description: "Receive notifications for new messages",
                                    isOn: $notificationsEnabled,
                                    color: .aicovenTeal
                                )
                                .onChange(of: notificationsEnabled) { _, _ in
                                    Task {
                                        await saveSettings()
                                    }
                                }

                                Divider()
                                    .background(Color.aicovenBorder)

                                // Email notifications toggle
                                SettingToggleRow(
                                    icon: "envelope.fill",
                                    title: "Email Notifications",
                                    description: "Receive email updates",
                                    isOn: $emailNotificationsEnabled,
                                    color: .aicovenPurple
                                )
                                .onChange(of: emailNotificationsEnabled) { _, _ in
                                    Task {
                                        await saveSettings()
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.lg)

                    // Appearance section
                    VStack(spacing: Spacing.md) {
                        HStack {
                            Text("Appearance")
                                .font(.aicovenH3)
                                .foregroundColor(.aicovenTextPrimary)
                            Spacer()
                        }

                        GlassCard {
                            VStack(spacing: Spacing.md) {
                                HStack {
                                    Image(systemName: "moon.fill")
                                        .font(.aicovenH3)
                                        .foregroundColor(.aicovenPink)
                                        .frame(width: 32)

                                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                                        Text("Dark Mode")
                                            .font(.aicovenBody)
                                            .foregroundColor(.aicovenTextPrimary)
                                        Text("Always enabled")
                                            .font(.aicovenCaption)
                                            .foregroundColor(.aicovenTextSecondary)
                                    }

                                    Spacer()

                                    Text("ON")
                                        .font(.aicovenCaption)
                                        .foregroundColor(.aicovenTeal)
                                        .padding(.horizontal, Spacing.sm)
                                        .padding(.vertical, Spacing.xxs)
                                        .background(Color.aicovenTeal.opacity(0.2))
                                        .cornerRadius(BorderRadius.circle)
                                }

                                Divider()
                                    .background(Color.aicovenBorder)

                                SettingToggleRow(
                                    icon: "sparkles",
                                    title: "Nebula Animation",
                                    description: "Disable to use a static background everywhere",
                                    isOn: $animatedBackgrounds,
                                    color: .aicovenTeal
                                )
                                .onChange(of: animatedBackgrounds) { _, newValue in
                                    storedAnimatedBackgrounds = newValue
                                    Task {
                                        await saveSettings()
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.lg)

                    #if os(macOS)
                    // File Access section
                    FileAccessSettingsSection()
                    #endif

                    // Integrations section
                    VStack(spacing: Spacing.md) {
                        HStack {
                            Text("Integrations")
                                .font(.aicovenH3)
                                .foregroundColor(.aicovenTextPrimary)
                            Spacer()
                        }

                        Button {
                            showConnectedApps = true
                        } label: {
                            GlassCard {
                                HStack(spacing: Spacing.md) {
                                    Image(systemName: "app.connected.to.app.below.fill")
                                        .font(.aicovenH3)
                                        .foregroundColor(.aicovenPurple)
                                        .frame(width: 32)

                                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                                        Text("Connected Apps")
                                            .font(.aicovenBody)
                                            .foregroundColor(.aicovenTextPrimary)
                                        Text("Connect GitHub, Google Drive, and more")
                                            .font(.aicovenCaption)
                                            .foregroundColor(.aicovenTextSecondary)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.aicovenCaption)
                                        .foregroundColor(.aicovenTextTertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, Spacing.lg)

                    // About section
                    VStack(spacing: Spacing.md) {
                        HStack {
                            Text("About")
                                .font(.aicovenH3)
                                .foregroundColor(.aicovenTextPrimary)
                            Spacer()
                        }

                        GlassCard {
                            VStack(spacing: Spacing.md) {
                                SettingInfoRow(
                                    icon: "info.circle.fill",
                                    title: "Version",
                                    value: "1.0.0",
                                    color: .aicovenTeal
                                )

                                Divider()
                                    .background(Color.aicovenBorder)

                                SettingInfoRow(
                                    icon: "sparkles",
                                    title: "Build",
                                    value: "Beta",
                                    color: .aicovenPurple
                                )
                            }
                        }

                        #if DEBUG
                        // Debug / QA utilities
                        GlassCard {
                            VStack(spacing: Spacing.md) {
                                HStack {
                                    Text("Debug")
                                        .font(.aicovenH3)
                                        .foregroundColor(.aicovenTextPrimary)
                                    Spacer()
                                }

                                Button {
                                    Task {
                                        // Best-effort server-side reset; AuthService will
                                        // update AppState.hasCompletedOnboarding on success.
                                        await authService.markOnboardingCompletedReset()
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: "arrow.counterclockwise")
                                            .foregroundColor(.aicovenPink)
                                        Text("Reset FTUE onboarding for this account")
                                            .font(.aicovenBodySmall)
                                            .foregroundColor(.aicovenTextPrimary)
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        #endif
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.bottom, Spacing.xl)
                }
            }
        }
        .background(NebulaBackground())
        .task {
            await loadSettings()
        }
        .sheet(isPresented: $showConnectedApps) {
            ConnectedAppsView()
                .environmentObject(StoreService.shared)
        }
    }

    /// Load user settings
    private func loadSettings() async {
        loading = true
        defer { loading = false }

        // Start from whatever is persisted locally so we don't
        // accidentally reset the preference if the server doesn't yet
        // send back the new field.
        var effectiveAnimatedBackgrounds = storedAnimatedBackgrounds

        guard let user = authService.currentUser else {
            // No user loaded yet – fall back entirely to local storage.
            animatedBackgrounds = effectiveAnimatedBackgrounds
            return
        }

        // Load from user settings
        notificationsEnabled = user.settings?.notifications ?? true
        emailNotificationsEnabled = user.settings?.emailNotifications ?? true

        // Only override the local value if the backend explicitly
        // returns a setting for animated backgrounds. This prevents the
        // toggle from snapping back to ON when the backend has not yet
        // been updated to persist `animated_backgrounds`.
        if let serverAnimated = user.settings?.animatedBackgrounds {
            effectiveAnimatedBackgrounds = serverAnimated
        }

        animatedBackgrounds = effectiveAnimatedBackgrounds
        storedAnimatedBackgrounds = effectiveAnimatedBackgrounds
    }

    /// Save settings (local-only)
    private func saveSettings() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }

        guard let existing = authService.currentUser else {
            // No user object; persist animated backgrounds only via AppStorage.
            storedAnimatedBackgrounds = animatedBackgrounds
            return
        }

        // Update the in-memory UserSettings and mirror to AuthService. This
        // keeps the UI consistent without talking to any backend.
        let newSettings = UserSettings(
            theme: existing.settings?.theme,
            language: existing.settings?.language,
            notifications: notificationsEnabled,
            emailNotifications: emailNotificationsEnabled,
            hasCompletedOnboarding: existing.settings?.hasCompletedOnboarding,
            animatedBackgrounds: animatedBackgrounds
        )
        let updatedUser = User(
            id: existing.id,
            email: existing.email,
            name: existing.name,
            profile: existing.profile,
            settings: newSettings,
            createdAt: existing.createdAt,
            updatedAt: Date()
        )
        authService.currentUser = updatedUser
        storedAnimatedBackgrounds = animatedBackgrounds
    }
}

/// Setting toggle row with icon
struct SettingToggleRow: View {
    let icon: String
    let title: String
    let description: String
    @Binding var isOn: Bool
    let color: Color

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.aicovenH3)
                .foregroundColor(color)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextPrimary)
                Text(description)
                    .font(.aicovenCaption)
                    .foregroundColor(.aicovenTextSecondary)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.aicovenTeal)
        }
    }
}

/// Setting info row (non-interactive)
struct SettingInfoRow: View {
    let icon: String
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.aicovenH3)
                .foregroundColor(color)
                .frame(width: 32)

            Text(title)
                .font(.aicovenBody)
                .foregroundColor(.aicovenTextPrimary)

            Spacer()

            Text(value)
                .font(.aicovenBody)
                .foregroundColor(.aicovenTextSecondary)
        }
    }
}

#Preview {
    EnhancedSettingsView()
        .environmentObject(AuthService.shared)
}
