import SwiftUI

/// Signup screen aligned with FTUE design (first/last name, email, password)
struct SignupView: View {
    @Environment(\.dismiss) private var dismiss: DismissAction
    @EnvironmentObject var authService: AuthService

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isLoading = false
    @State private var showError = false
    @State private var errorMessage = ""

    /// Explicit initializer for SwiftUI previews
    init() {}

    var body: some View {
        NavigationStack {
            ZStack {
                // Match overall visual style of login/onboarding
                NebulaBackground()

                ScrollView {
                    VStack(spacing: Spacing.xl) {
                        // Brand header
                        VStack(spacing: Spacing.sm) {
                            Text("Create your account")
                                .font(.aicovenDisplayMedium)
                                .foregroundColor(.aicovenTextPrimary)

                            Text("Join the circle of intelligences")
                                .font(.aicovenBody)
                                .foregroundColor(.aicovenTextSecondary)
                        }
                        .padding(.top, Spacing.xl)

                        // Form card
                        VStack(spacing: Spacing.md) {
                            // First / Last name
                            HStack(spacing: Spacing.md) {
                                VStack(alignment: .leading, spacing: Spacing.xs) {
                                    Text("First Name")
                                        .font(.aicovenH3)
                                        .foregroundColor(.aicovenTextPrimary)
                                    TextField("John", text: $firstName)
                                        .textContentType(.givenName)
                                        .foregroundColor(.aicovenTextPrimary)
                                        .padding(Spacing.md)
                                        .background(Color.aicovenGlass)
                                        .cornerRadius(BorderRadius.md)
                                }

                                VStack(alignment: .leading, spacing: Spacing.xs) {
                                    Text("Last Name")
                                        .font(.aicovenH3)
                                        .foregroundColor(.aicovenTextPrimary)
                                    TextField("Doe", text: $lastName)
                                        .textContentType(.familyName)
                                        .foregroundColor(.aicovenTextPrimary)
                                        .padding(Spacing.md)
                                        .background(Color.aicovenGlass)
                                        .cornerRadius(BorderRadius.md)
                                }
                            }

                            // Email
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text("Email address")
                                    .font(.aicovenH3)
                                    .foregroundColor(.aicovenTextPrimary)

                                HStack(spacing: Spacing.sm) {
                                    Image(systemName: "envelope")
                                        .foregroundColor(.aicovenTextTertiary)

                                    TextField("you@example.com", text: $email)
                                        .textContentType(.emailAddress)
                                    #if os(iOS)
                                        .keyboardType(.emailAddress)
                                        .autocapitalization(.none)
                                    #endif
                                        .foregroundColor(.aicovenTextPrimary)
                                }
                                .padding(Spacing.md)
                                .background(Color.aicovenGlass)
                                .cornerRadius(BorderRadius.md)
                            }

                            // Password
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text("Password")
                                    .font(.aicovenH3)
                                    .foregroundColor(.aicovenTextPrimary)

                                HStack(spacing: Spacing.sm) {
                                    Image(systemName: "lock")
                                        .foregroundColor(.aicovenTextTertiary)

                                    SecureField("At least 12 characters", text: $password)
                                        .textContentType(.newPassword)
                                        .foregroundColor(.aicovenTextPrimary)
                                }
                                .padding(Spacing.md)
                                .background(Color.aicovenGlass)
                                .cornerRadius(BorderRadius.md)
                            }

                            // Confirm password
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text("Confirm Password")
                                    .font(.aicovenH3)
                                    .foregroundColor(.aicovenTextPrimary)

                                HStack(spacing: Spacing.sm) {
                                    Image(systemName: "lock.shield")
                                        .foregroundColor(.aicovenTextTertiary)

                                    SecureField("Confirm your password", text: $confirmPassword)
                                        .textContentType(.newPassword)
                                        .foregroundColor(.aicovenTextPrimary)
                                }
                                .padding(Spacing.md)
                                .background(Color.aicovenGlass)
                                .cornerRadius(BorderRadius.md)
                            }

                            // Submit
                            Button(action: handleSignup) {
                                HStack {
                                    if isLoading {
                                        ProgressView()
                                            .tint(.white)
                                    } else {
                                        Text("Continue")
                                            .font(.aicovenBodyMedium)
                                            .foregroundColor(.white)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(Spacing.md)
                                .background(
                                    LinearGradient(
                                        colors: [Color.aicovenTeal, Color.aicovenPurple],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .cornerRadius(BorderRadius.md)
                                .shadow(
                                    color: isFormValid && !isLoading ? Color.aicovenTeal.opacity(0.5) : .clear,
                                    radius: 12,
                                    x: 0,
                                    y: 4
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoading || !isFormValid)
                            .opacity(isFormValid && !isLoading ? 1.0 : 0.5)
                        }
                        .frame(maxWidth: 500)
                        .padding(.horizontal, Spacing.lg)
                        .padding(.bottom, Spacing.xl)

                        // Already have account
                        HStack(spacing: Spacing.xs) {
                            Text("Already have an account?")
                                .font(.aicovenBodySmall)
                                .foregroundColor(.aicovenTextSecondary)
                            Button("Sign in") {
                                // Track navigation to sign in
                                AnalyticsService.shared.track(
                                    event: "signup_navigate_to_signin",
                                    properties: [:]
                                )
                                dismiss()
                            }
                            .font(.aicovenBodySmall)
                            .foregroundColor(.aicovenTeal)
                            .buttonStyle(.plain)
                        }
                        .padding(.bottom, Spacing.xl)
                    }
                }
            }
            .navigationTitle("")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            // Track signup cancellation
                            AnalyticsService.shared.track(
                                event: "signup_cancelled",
                                properties: [
                                    "form_completion": calculateFormCompletion()
                                ]
                            )
                            dismiss()
                        }
                    }
                }
                .alert("Error", isPresented: $showError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(errorMessage)
                }
        }
        .onAppear {
            // Track signup view appearance
            AnalyticsService.shared.track(
                event: "signup_view_opened",
                properties: [:]
            )
        }
    }

    /// Check if form is valid
    private var isFormValid: Bool {
        !firstName.isEmpty && !lastName.isEmpty && !email.isEmpty && !password.isEmpty &&
            password == confirmPassword && password.count >= 6
    }

    /// Calculate form completion percentage for analytics
    private func calculateFormCompletion() -> Double {
        var completedFields = 0
        let totalFields = 5

        if !firstName.isEmpty { completedFields += 1 }
        if !lastName.isEmpty { completedFields += 1 }
        if !email.isEmpty { completedFields += 1 }
        if !password.isEmpty { completedFields += 1 }
        if !confirmPassword.isEmpty { completedFields += 1 }

        return Double(completedFields) / Double(totalFields)
    }

    /// Handle signup action
    private func handleSignup() {
        isLoading = true
        let fullName = firstName + " " + lastName

        // Track signup attempt (no PII)
        AnalyticsService.shared.track(
            event: "signup_attempt",
            properties: [
                "method": "email",
                "has_name": true
            ]
        )

        Task {
            do {
                try await authService.signUp(email: email, password: password, name: fullName)

                // Track successful signup
                AnalyticsService.shared.trackSignUp(method: "email")

                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                showError = true

                // Track signup failure (no PII)
                AnalyticsService.shared.trackAuthError(
                    error: error.localizedDescription,
                    method: "email"
                )
            }
            isLoading = false
        }
    }
}

#Preview {
    NavigationStack {
        SignupView()
            .environmentObject(AuthService.shared)
    }
}
