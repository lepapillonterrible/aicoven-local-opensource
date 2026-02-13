import SwiftUI

/// Sheet for creating a new coven
struct CreateCovenSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var storeService: StoreService

    @State private var covenName = ""
    @State private var covenDescription = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    /// Called when a coven is successfully created. Provides the created
    /// Coven so callers can immediately navigate into its workspace.
    let onCreated: (Coven) -> Void

    var body: some View {
        if !storeService.hasCreator {
            FeatureUpsellView(
                feature: .covens,
                featureDescription: "Creating covens with multiple AI agent roles requires the Creator upgrade."
            )
        } else {
            NavigationStack {
                ScrollView {
                    VStack(spacing: Spacing.lg) {
                        // Header
                        VStack(spacing: Spacing.sm) {
                            IconBadge(icon: "person.3", size: 80, color: .aicovenPurple)

                            Text("Create a Coven")
                                .font(.aicovenDisplaySmall)
                                .foregroundColor(.aicovenTextPrimary)

                            Text("Collaborate with multiple AI roles in a shared workspace")
                                .font(.aicovenBody)
                                .foregroundColor(.aicovenTextSecondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 400)
                        }
                        .padding(.top, Spacing.xl)

                        // Form
                        VStack(spacing: Spacing.md) {
                            // Name field
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text("Coven Name")
                                    .font(.aicovenBodyMedium)
                                    .foregroundColor(.aicovenTextPrimary)

                                TextField("", text: $covenName, prompt: Text("My Project").foregroundColor(.aicovenTextTertiary))
                                    .font(.aicovenBody)
                                    .foregroundColor(.aicovenTextPrimary)
                                    .padding(Spacing.sm)
                                    .background(Color.aicovenGlass)
                                    .cornerRadius(BorderRadius.md)
                            }

                            // Description field
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text("Description (Optional)")
                                    .font(.aicovenBodyMedium)
                                    .foregroundColor(.aicovenTextPrimary)

                                TextField("", text: $covenDescription, prompt: Text("What's this coven for?").foregroundColor(.aicovenTextTertiary), axis: .vertical)
                                    .font(.aicovenBody)
                                    .foregroundColor(.aicovenTextPrimary)
                                    .padding(Spacing.sm)
                                    .background(Color.aicovenGlass)
                                    .cornerRadius(BorderRadius.md)
                                    .lineLimit(3 ... 6)
                            }
                        }
                        .padding(.horizontal, Spacing.xl)
                        .glassMorphism()
                        .padding(.horizontal, Spacing.lg)

                        // Error message
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.aicovenBodySmall)
                                .foregroundColor(.aicovenError)
                                .padding(.horizontal, Spacing.lg)
                        }

                        // Actions
                        HStack(spacing: Spacing.md) {
                            // Cancel button with teal text styling
                            Button("Cancel") {
                                dismiss()
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, Spacing.lg)
                            .padding(.vertical, Spacing.sm)
                            .background(Color.aicovenGlass)
                            .foregroundColor(.aicovenTeal)
                            .cornerRadius(BorderRadius.md)

                            Button(action: createCoven) {
                                HStack(spacing: Spacing.xs) {
                                    if isCreating {
                                        ProgressView()
                                            .controlSize(.small)
                                            .tint(.white)
                                    }
                                    Text(isCreating ? "Creating..." : "Create Coven")
                                        .font(.aicovenBodyMedium)
                                }
                                .padding(.horizontal, Spacing.lg)
                                .padding(.vertical, Spacing.sm)
                                .frame(minWidth: 150)
                                .background(
                                    Group {
                                        if covenName.isEmpty {
                                            Color.aicovenGlass
                                        } else {
                                            LinearGradient(
                                                colors: [Color.aicovenTeal, Color.aicovenPurple],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        }
                                    }
                                )
                                .foregroundColor(.white)
                                .cornerRadius(BorderRadius.md)
                            }
                            .buttonStyle(.plain)
                            .disabled(covenName.isEmpty || isCreating)
                        }
                        .padding(.horizontal, Spacing.lg)
                    }
                    .padding(.bottom, Spacing.xl)
                }
                .background(NebulaBackground())
            }
        } // end else (hasCreator)
    }

    private func createCoven() {
        guard !covenName.isEmpty else { return }

        isCreating = true
        errorMessage = nil

        Task {
            do {
                let coven = try await CovenService.shared.createCoven(
                    name: covenName,
                    description: covenDescription.isEmpty ? nil : covenDescription
                )

                await MainActor.run {
                    onCreated(coven)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to create coven: \(error.localizedDescription)"
                    isCreating = false
                }
            }
        }
    }
}

#Preview {
    CreateCovenSheet(onCreated: { _ in })
}
