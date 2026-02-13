import SwiftUI

/// Forgot password screen
struct ForgotPasswordView: View {
    @Environment(\.dismiss) private var dismiss: DismissAction
    @EnvironmentObject var authService: AuthService

    @State private var email = ""
    @State private var isLoading = false
    @State private var showSuccess = false
    @State private var showError = false
    @State private var errorMessage = ""

    /// Explicit initializer for SwiftUI previews
    init() {}

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    // Header with icon
                    VStack(spacing: Spacing.md) {
                        IconBadge(icon: "envelope.badge", size: 60, color: .aicovenTeal)

                        Text("Reset Password")
                            .font(.aicovenDisplayMedium)
                            .foregroundColor(.aicovenTextPrimary)

                        Text("Enter your email address and we'll send you a link to reset your password.")
                            .font(.aicovenBody)
                            .foregroundColor(.aicovenTextSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                    }
                    .padding(.top, Spacing.xxl)

                    // Email field
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Email")
                            .font(.aicovenH3)
                            .foregroundColor(.aicovenTextPrimary)

                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "envelope")
                                .font(.system(size: 16))
                                .foregroundColor(.aicovenTextTertiary)

                            TextField("", text: $email, prompt: Text("Enter your email").foregroundColor(.aicovenTextTertiary))
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
                    .frame(maxWidth: 400)
                    .padding(.horizontal, Spacing.lg)

                    // Submit button
                    Button(action: handleResetPassword) {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Send Reset Link")
                                    .font(.aicovenBodyMedium)
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
                        .foregroundColor(.white)
                        .cornerRadius(BorderRadius.md)
                        .shadow(
                            color: !email.isEmpty && !isLoading ? Color.aicovenTeal.opacity(0.5) : .clear,
                            radius: 12,
                            x: 0,
                            y: 4
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading || email.isEmpty)
                    .opacity(!email.isEmpty && !isLoading ? 1.0 : 0.5)
                    .frame(maxWidth: 400)
                    .padding(.horizontal, Spacing.lg)

                    Spacer()
                }
            }
            .background(NebulaBackground())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // Track password reset cancellation
                        AnalyticsService.shared.track(
                            event: "password_reset_cancelled",
                            properties: [
                                "email_entered": !email.isEmpty
                            ]
                        )
                        dismiss()
                    }
                    .foregroundColor(.aicovenTeal)
                }
            }
            .alert("Success", isPresented: $showSuccess) {
                Button("OK") {
                    dismiss()
                }
            } message: {
                Text("If this email is associated with an account, a reset password link was sent.")
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
        .onAppear {
            // Track forgot password view appearance
            AnalyticsService.shared.track(
                event: "password_reset_view_opened",
                properties: [:]
            )
        }
    }

    /// Handle password reset action
    private func handleResetPassword() {
        isLoading = true

        // Track password reset attempt (no PII)
        AnalyticsService.shared.track(
            event: "password_reset_attempt",
            properties: [:]
        )

        Task {
            do {
                try await authService.sendPasswordReset(email: email)

                // Track successful password reset request (no PII)
                AnalyticsService.shared.track(
                    event: "password_reset_success",
                    properties: [:]
                )

                showSuccess = true
            } catch {
                errorMessage = error.localizedDescription

                // Track password reset failure (no PII)
                AnalyticsService.shared.track(
                    event: "password_reset_failed",
                    properties: [
                        "error": error.localizedDescription
                    ]
                )

                showError = true
            }
            isLoading = false
        }
    }
}

#Preview {
    NavigationStack {
        ForgotPasswordView()
            .environmentObject(AuthService.shared)
    }
}
