import SwiftUI

/// The sheet that makes a coven. Covens are behind the Creator upgrade:
/// without it the sheet says so, in place of the form.
struct CreateCovenSheet: View {
    @EnvironmentObject var storeService: StoreService

    /// Called with the coven that was made, before the sheet closes.
    let onCreated: (Coven) -> Void

    var body: some View {
        if storeService.hasCreator {
            NewCovenForm(onCreated: onCreated)
        } else {
            FeatureUpsellView(
                feature: .covens,
                featureDescription: "Creating covens with multiple AI agent roles requires the Creator upgrade."
            )
        }
    }
}

/// The form that makes a coven, as the cloud app's is: its icon, with
/// "Change", beside its name. On the Mac it has a title bar and a bar of
/// buttons; on the iPhone and iPad, Cancel and Create are in the
/// navigation bar.
struct NewCovenForm: View {
    @Environment(\.dismiss) private var dismiss

    @State private var covenName = ""
    /// The icon the coven is made with, once it is the one to make it
    /// with (`NewCovenIcon`).
    @State private var iconSymbol = CovenIcon.defaultSymbol
    @State private var iconTint = IconTint.warm
    @State private var isIconReady = false
    /// The making under way, if one is: what it comes to is acted on only
    /// while it is still this one.
    @State private var creation: UUID?
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    /// Called with the coven that was made, before the sheet closes.
    let onCreated: (Coven) -> Void

    /// The longest name a coven is given (the cloud app's limit).
    static let longestName = 100

    /// The name a coven is made with from what was typed: without the
    /// space around it, and no longer than the longest; nil for none.
    static func name(from typed: String) -> String? {
        let name = String(typed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(longestName))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private var isCreating: Bool {
        creation != nil
    }

    private var canCreate: Bool {
        Self.name(from: covenName) != nil && !isCreating && isIconReady
    }

    var body: some View {
        container
            .onAppear { nameFocused = true }
            // A making under way is not walked away from: what it made
            // would appear with nobody having seen it made.
            .interactiveDismissDisabled(isCreating)
            .onDisappear { creation = nil }
    }

    @ViewBuilder
    private var container: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            Text("New Coven")
                .font(.aicovenH3)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color.aicovenChrome)
            Rectangle().fill(Color.aicovenRule).frame(height: 1)
            form
            Rectangle().fill(Color.aicovenRule).frame(height: 1)
            HStack(spacing: Spacing.xs) {
                Spacer(minLength: Spacing.sm)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreating)
                Button(action: createCoven) { createLabel }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
            .padding(.horizontal, Spacing.sm)
            .frame(height: 52)
            .background(Color.aicovenChrome)
        }
        .frame(width: 440)
        .background(Color.aicovenSurfaceElevated)
        #else
        NavigationStack {
            form
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.aicovenSurface.ignoresSafeArea())
                .navigationTitle("New Coven")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(isCreating)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: createCoven) { createLabel }
                            .disabled(!canCreate)
                    }
                }
        }
        #endif
    }

    private var createLabel: some View {
        HStack(spacing: Spacing.xs) {
            if isCreating {
                ProgressView()
                    .controlSize(.small)
            }
            Text(isCreating ? "Creating…" : "Create")
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .top, spacing: Spacing.md) {
                NewCovenIcon(symbol: $iconSymbol, tint: $iconTint, isReady: $isIconReady)
                    .disabled(isCreating)
                nameField
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenError)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.md)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text("Name")
                .font(.aicovenCaption.weight(.semibold))
                .foregroundStyle(Color.aicovenTextTertiary)
                .accessibilityHidden(true)
            TextField("Name", text: $covenName, prompt: Text("Name"))
                .textFieldStyle(.plain)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit(createCoven)
            #if os(iOS)
                .textInputAutocapitalization(.words)
            #endif
                .disabled(isCreating)
                .padding(.horizontal, Spacing.sm)
                .frame(minHeight: fieldHeight)
                .background(
                    RoundedRectangle(cornerRadius: BorderRadius.sm)
                        .fill(fieldFill)
                        .overlay(RoundedRectangle(cornerRadius: BorderRadius.sm).strokeBorder(Color.aicovenBorder, lineWidth: 1))
                )
                .accessibilityIdentifier("new-coven-name")
        }
    }

    private var fieldHeight: CGFloat {
        #if os(macOS)
        36
        #else
        44
        #endif
    }

    private var fieldFill: Color {
        #if os(macOS)
        Color.aicovenSurface
        #else
        Color.aicovenSurfaceElevated
        #endif
    }

    private func createCoven() {
        guard canCreate, let name = Self.name(from: covenName) else { return }
        let operation = UUID()
        creation = operation
        errorMessage = nil
        // The coven is made for the account that asked. What follows is
        // done only if this making is still the sheet's own and that
        // account is still the one signed in.
        let account = UserScope.currentUserID
        let icon = (iconSymbol, iconTint)

        Task {
            do {
                let coven = try await CovenService.shared.createCoven(name: name, icon: icon)
                guard creation == operation, UserScope.currentUserID == account else { return }
                onCreated(coven)
                dismiss()
            } catch {
                guard creation == operation, UserScope.currentUserID == account else { return }
                errorMessage = "Failed to create coven: \(error.localizedDescription)"
                creation = nil
            }
        }
    }
}

#Preview {
    CreateCovenSheet(onCreated: { _ in })
        .environmentObject(StoreService.shared)
}
