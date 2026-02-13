import SwiftUI
internal import Combine

/// Enhanced profile view with user information and statistics
struct EnhancedProfileView: View {
    @EnvironmentObject var authService: AuthService
    @State private var userInfo: User?
    @State private var stats: UserStats?
    @State private var covenCount: Int = 0
    @State private var loading = true
    @State private var isEditing = false
    @State private var editedName = ""
    @State private var editedOrganization = ""
    @State private var editedRole = ""
    @State private var saving = false

    var userInitials: String {
        guard let name = userInfo?.name ?? userInfo?.email else { return "?" }
        let components = name.components(separatedBy: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                if loading {
                    // Loading state
                    VStack(spacing: Spacing.lg) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.aicovenTeal)
                        Text("Loading profile...")
                            .font(.aicovenBody)
                            .foregroundColor(.aicovenTextSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 100)
                } else if let user = userInfo {
                    // Avatar section
                    VStack(spacing: Spacing.md) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.aicovenTeal, Color.aicovenPurple],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 100, height: 100)
                                .glowEffect(color: .aicovenTeal, radius: 20, intensity: 0.4)

                            Text(userInitials)
                                .font(.system(size: 36, weight: .bold))
                                .foregroundColor(.white)
                        }

                        Text(user.name ?? user.email)
                            .font(.aicovenH1)
                            .foregroundColor(.aicovenTextPrimary)

                        Text(user.email)
                            .font(.aicovenBody)
                            .foregroundColor(.aicovenTextSecondary)
                    }
                    .padding(.top, Spacing.xl)

                    // Stats section
                    if let stats {
                        VStack(spacing: Spacing.md) {
                            Text("Usage This Month")
                                .font(.aicovenH3)
                                .foregroundColor(.aicovenTextPrimary)

                            HStack(spacing: Spacing.md) {
                                StatCard(
                                    icon: "dollarsign.circle.fill",
                                    value: String(format: "$%.2f", stats.totalCost),
                                    label: "Spent",
                                    color: .aicovenTeal
                                )

                                StatCard(
                                    icon: "message.fill",
                                    value: "\(stats.messagesCount)",
                                    label: "Messages",
                                    color: .aicovenPurple
                                )

                                StatCard(
                                    icon: "brain.fill",
                                    value: "\(covenCount)",
                                    label: "Covens",
                                    color: .aicovenPink
                                )
                            }
                        }
                        .padding(.horizontal, Spacing.lg)
                    }

                    // Profile info section
                    VStack(spacing: Spacing.md) {
                        HStack {
                            Text("Profile Information")
                                .font(.aicovenH3)
                                .foregroundColor(.aicovenTextPrimary)

                            Spacer()

                            Button {
                                if isEditing {
                                    // Cancel editing
                                    isEditing = false
                                    editedName = user.name ?? ""
                                    editedOrganization = user.profile?.organization ?? ""
                                    editedRole = user.profile?.role ?? ""
                                } else {
                                    // Start editing
                                    editedName = user.name ?? ""
                                    editedOrganization = user.profile?.organization ?? ""
                                    editedRole = user.profile?.role ?? ""
                                    isEditing = true
                                }
                            } label: {
                                Image(systemName: isEditing ? "xmark.circle.fill" : "pencil.circle.fill")
                                    .font(.aicovenH3)
                                    .foregroundColor(.aicovenTeal)
                            }
                            .buttonStyle(.plain)
                        }

                        GlassCard {
                            VStack(spacing: Spacing.md) {
                                if isEditing {
                                    // Editing mode
                                    ProfileEditField(label: "Name", text: $editedName)
                                    ProfileEditField(label: "Organization", text: $editedOrganization)
                                    ProfileEditField(label: "Role", text: $editedRole)

                                    GradientButton("Save Changes", icon: "checkmark.circle.fill", style: .primary) {
                                        Task {
                                            await saveProfile()
                                        }
                                    }
                                    .disabled(saving)
                                } else {
                                    // Display mode
                                    ProfileInfoRow(label: "Name", value: user.name ?? "Not set")
                                    ProfileInfoRow(label: "Email", value: user.email)
                                    ProfileInfoRow(label: "Organization", value: user.profile?.organization ?? "Not set")
                                    ProfileInfoRow(label: "Role", value: user.profile?.role ?? "Not set")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.lg)

                    // Sign out button
                    VStack(spacing: Spacing.sm) {
                        Button {
                            Task {
                                do {
                                    try await authService.signOut()
                                } catch {
                                    AppErrorReporter.log(error: error, context: "EnhancedProfileView.signOut")
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.right.square")
                                Text("Sign Out")
                            }
                            .font(.aicovenBody)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                            .padding(Spacing.md)
                            .background(Color.aicovenGlass)
                            .cornerRadius(BorderRadius.md)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.bottom, Spacing.xl)
                } else {
                    // Local-only empty state when no user profile exists
                    VStack(spacing: Spacing.lg) {
                        IconBadge(icon: "person.crop.circle", size: 80, color: .aicovenTeal)

                        VStack(spacing: Spacing.sm) {
                            Text("Local Profile")
                                .font(.aicovenH1)
                                .foregroundColor(.aicovenTextPrimary)
                            Text("This open-source client runs entirely on your device. There is no cloud account, so profile details are optional.")
                                .font(.aicovenBody)
                                .foregroundColor(.aicovenTextSecondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 420)
                        }

                        GlassCard {
                            VStack(spacing: Spacing.sm) {
                                Text("You can still customize your experience from Settings and Provider Keys.")
                                    .font(.aicovenBodySmall)
                                    .foregroundColor(.aicovenTextSecondary)
                                    .multilineTextAlignment(.center)

                                HStack(spacing: Spacing.md) {
                                    NavigationLink(destination: EnhancedSettingsView()) {
                                        Label("Settings", systemImage: "gearshape")
                                    }
                                    .buttonStyle(.bordered)

                                    NavigationLink(destination: ProviderKeysView()) {
                                        Label("Provider Keys", systemImage: "key.fill")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(Spacing.md)
                        }
                        .padding(.horizontal, Spacing.lg)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, Spacing.xl)
                }
            }
        }
        .background(NebulaBackground())
        .task {
            await loadProfile()
        }
        .onReceive(authService.$currentUser) { newValue in
            userInfo = newValue
            if let user = newValue, !isEditing {
                editedName = user.name ?? ""
                editedOrganization = user.profile?.organization ?? ""
                editedRole = user.profile?.role ?? ""
            }
        }
    }

    /// Load user profile and stats (local-only)
    private func loadProfile() async {
        loading = true
        defer { loading = false }

        // In the local-only client there is no backend profile or stats API.
        // We simply show whatever AuthService has in memory and omit stats.
        userInfo = authService.currentUser
        stats = nil
        covenCount = 0
    }

    /// Save profile changes (local-only)
    private func saveProfile() async {
        guard let existing = userInfo ?? authService.currentUser else { return }

        saving = true
        defer { saving = false }

        // Construct a new User value with updated name/profile metadata and
        // store it in AuthService so other views stay in sync. No network call.
        let updatedProfile = UserProfile(
            organization: editedOrganization.isEmpty ? existing.profile?.organization : editedOrganization,
            role: editedRole.isEmpty ? existing.profile?.role : editedRole,
            bio: existing.profile?.bio,
            avatarUrl: existing.profile?.avatarUrl
        )
        let updatedUser = User(
            id: existing.id,
            email: existing.email,
            name: editedName.isEmpty ? existing.name : editedName,
            profile: updatedProfile,
            settings: existing.settings,
            createdAt: existing.createdAt,
            updatedAt: Date()
        )
        userInfo = updatedUser
        authService.currentUser = updatedUser
        isEditing = false
    }
}

/// Stat card component
struct StatCard: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(color)

            Text(value)
                .font(.aicovenH2)
                .foregroundColor(.aicovenTextPrimary)

            Text(label)
                .font(.aicovenCaption)
                .foregroundColor(.aicovenTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.md)
        .glassMorphism(cornerRadius: BorderRadius.lg, padding: 0)
    }
}

/// Profile info row for display mode
struct ProfileInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.aicovenBodySmall)
                .foregroundColor(.aicovenTextSecondary)

            Spacer()

            Text(value)
                .font(.aicovenBody)
                .foregroundColor(.aicovenTextPrimary)
        }
        .padding(.vertical, Spacing.xs)
    }
}

/// Profile edit field for editing mode
struct ProfileEditField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(label)
                .font(.aicovenCaption)
                .foregroundColor(.aicovenTextSecondary)

            TextField("", text: $text)
                .font(.aicovenBody)
                .foregroundColor(.aicovenTextPrimary)
                .padding(Spacing.sm)
                .background(Color.aicovenGlass)
                .cornerRadius(BorderRadius.sm)
        }
    }
}

#Preview {
    EnhancedProfileView()
        .environmentObject(AuthService.shared)
}
