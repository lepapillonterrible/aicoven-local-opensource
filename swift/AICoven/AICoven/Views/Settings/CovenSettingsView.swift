import SwiftUI

/// Settings screen for editing a coven's identity in the local-first client.
///
/// Adapted from the cloud `CovenSettingsView`: the local `Coven` model only
/// stores name + description (no server-hosted avatar or injected model
/// context), so this surface edits those fields and offers a danger-zone
/// delete. Persistence goes through the local `CovenService`/`CovenRepository`.
struct CovenSettingsView: View {
    /// The coven being edited — fields are pre-populated from this snapshot.
    let coven: Coven
    /// Invoked after a successful save so the parent can refresh its list.
    var onSaved: (() -> Void)?
    /// Invoked after deletion so the parent can clear stale navigation state.
    var onDeleted: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var descriptionText: String = ""

    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @State private var showSavedToast = false
    @State private var showDeleteConfirmation = false

    private let descriptionMaxLength = 500

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                header

                if let errorMessage {
                    Text(errorMessage)
                        .font(.aicovenCaption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.lg)
                }

                identitySection
                dangerZoneSection

                HStack {
                    Spacer()
                    GradientButton(
                        "Save Changes",
                        icon: "checkmark.circle.fill",
                        style: .primary
                    ) {
                        Task { await save() }
                    }
                    .disabled(isSaving || isDeleting || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.xl)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.xl)
        }
        .background(NebulaBackground())
        .navigationTitle("Coven Settings")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .onAppear {
                name = coven.name
                descriptionText = coven.description ?? ""
            }
            .overlay(alignment: .top) {
                if showSavedToast {
                    Text("Settings saved")
                        .font(.aicovenBodyMedium)
                        .foregroundColor(.black)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)
                        .background(Color.aicovenTeal)
                        .cornerRadius(BorderRadius.md)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, Spacing.lg)
                }
            }
            .alert("Delete \(coven.name)?", isPresented: $showDeleteConfirmation) {
                Button("Delete Coven", role: .destructive) {
                    Task { await deleteCoven() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes the coven and its workspace. This cannot be undone.")
            }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Spacing.sm) {
            IconBadge(icon: "gearshape", size: 60, color: .aicovenTeal)
            Text("Configure identity for \(coven.name).")
                .font(.aicovenBody)
                .foregroundColor(.aicovenTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, Spacing.md)
    }

    // MARK: - Identity Section

    private var identitySection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Identity")
                    .font(.aicovenH2)
                    .foregroundColor(.aicovenTextPrimary)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Name")
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextSecondary)

                    TextField("Coven name", text: $name)
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextPrimary)
                        .padding(Spacing.sm)
                        .background(Color.aicovenGlass)
                        .cornerRadius(BorderRadius.md)
                    #if os(iOS)
                        .textInputAutocapitalization(.words)
                    #endif
                }

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Description")
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextSecondary)

                    TextEditor(text: $descriptionText)
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextPrimary)
                        .frame(minHeight: 80)
                        .padding(Spacing.sm)
                        .background(Color.aicovenGlass)
                        .cornerRadius(BorderRadius.md)
                        .scrollContentBackground(.hidden)
                        .onChange(of: descriptionText) { _, newValue in
                            if newValue.count > descriptionMaxLength {
                                descriptionText = String(newValue.prefix(descriptionMaxLength))
                            }
                        }

                    HStack {
                        Spacer()
                        Text("\(descriptionText.count)/\(descriptionMaxLength)")
                            .font(.aicovenCaption)
                            .foregroundColor(
                                descriptionText.count > descriptionMaxLength - 50
                                    ? .orange
                                    : .aicovenTextTertiary
                            )
                    }
                }

                Text("A short description shown in the coven list.")
                    .font(.aicovenCaption)
                    .foregroundColor(.aicovenTextTertiary)
            }
        }
    }

    // MARK: - Danger Zone

    private var dangerZoneSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Danger Zone")
                    .font(.aicovenH2)
                    .foregroundColor(.red)

                Text("Delete this coven and remove it from your workspace list.")
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label(isDeleting ? "Deleting..." : "Delete Coven", systemImage: "trash")
                        .font(.aicovenBodyMedium)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.sm)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isSaving || isDeleting)

                Text("Deleting a coven is permanent. Only continue if you no longer need this workspace.")
                    .font(.aicovenCaption)
                    .foregroundColor(.aicovenTextTertiary)
            }
        }
    }

    // MARK: - Persistence

    private func save() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Coven name cannot be empty."
            return
        }

        isSaving = true
        errorMessage = nil

        do {
            let descValue = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await CovenService.shared.updateCoven(
                id: coven.id,
                name: trimmedName,
                description: descValue
            )

            await MainActor.run {
                isSaving = false
                withAnimation(.easeInOut(duration: 0.3)) { showSavedToast = true }
            }

            try? await Task.sleep(nanoseconds: 800_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) { showSavedToast = false }
                onSaved?()
                dismiss()
            }
        } catch {
            await MainActor.run {
                isSaving = false
                errorMessage = "Failed to save: \(error.localizedDescription)"
            }
        }
    }

    private func deleteCoven() async {
        isDeleting = true
        errorMessage = nil

        do {
            try await CovenService.shared.deleteCoven(id: coven.id)
            await MainActor.run {
                isDeleting = false
                onDeleted?(coven.id)
                dismiss()
            }
        } catch {
            await MainActor.run {
                isDeleting = false
                errorMessage = "Failed to delete coven: \(error.localizedDescription)"
            }
        }
    }
}
