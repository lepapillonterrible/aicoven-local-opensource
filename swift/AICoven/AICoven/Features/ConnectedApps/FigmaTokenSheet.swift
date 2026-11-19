import SwiftUI

/// What the Figma token sheet is for: a new connection, or a new token
/// for one whose token Figma has refused.
struct FigmaTokenRequest: Identifiable, Equatable {
    /// The connection the token must belong to, or nil for a new one.
    let replacing: ConnectedAccount?

    var id: String {
        replacing?.id ?? "new"
    }
}

/// Connects Figma with a personal access token, as the cloud app's sheet
/// does. The token is checked with Figma, kept in this device's Keychain,
/// and never shown again. (Signing in with Figma needs a secret a server
/// holds, and this app has no server.)
struct FigmaTokenSheet: View {
    let request: FigmaTokenRequest
    let onConnected: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var saving = false
    @State private var errorMessage: String?
    /// The check of the token that is under way. Closing the sheet calls
    /// it off: a token is not kept after its sheet is gone.
    @State private var checking: Task<Void, Never>?

    /// What the tools ask of Figma, and so what a token needs.
    static let scopes = [
        ("current_user:read", "your name and email"),
        ("file_content:read", "file contents"),
        ("file_comments:read", "comments"),
        ("file_comments:write", "posting comments, if agents may comment"),
    ]

    /// What the person is told when a token was not taken.
    static func message(for error: Error) -> String {
        switch error as? ConnectedAccountsService.FigmaTokenRefusal {
        case .refused, .notAToken:
            "Figma didn't accept this token. Check that it's copied whole and hasn't expired."
        case .otherAccount:
            "This token belongs to a different Figma account. Create one from the account being replaced."
        case .changed:
            "This Figma connection changed while the token was checked. Close this and try again."
        case nil:
            "Figma didn't answer. Try again."
        }
    }

    private var isReplacing: Bool {
        request.replacing != nil
    }

    var body: some View {
        NavigationStack {
            SettingsForm {
                Section {
                    SecureFieldWithPaste(label: "Token", prompt: "figd_…", text: $token)
                        .disabled(saving)
                } footer: {
                    Text(
                        (
                            isReplacing
                                ? "Create a personal access token in Figma under Settings › Security, from this same Figma account."
                                : "Create a personal access token in Figma under Settings › Security."
                        )
                            + " It works until the expiry you set there, and you can revoke it in Figma at any time. AICoven keeps it in this device's Keychain and never shows it again."
                    )
                    .font(.aicovenBodySmall)
                }
                Section {
                    ForEach(Self.scopes, id: \.0) { scope, what in
                        LabeledContent {
                            Text(what)
                        } label: {
                            Text(scope)
                                .font(.aicovenBodySmall.monospaced())
                        }
                    }
                } header: {
                    Text("Give the token these scopes")
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.aicovenError)
                    }
                }
            }
            .navigationTitle(isReplacing ? "Use a New Token" : "Connect Figma")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            checking?.cancel()
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if saving {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Checking the token")
                        } else {
                            Button(isReplacing ? "Save" : "Connect") {
                                check()
                            }
                            .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 420)
        #endif
        .accessibilityIdentifier("figma-token-sheet")
        .onDisappear { checking?.cancel() }
    }

    /// Starts the check of the token, once: pressing again while one is
    /// under way starts no other, so the one under way stays the one that
    /// closing the sheet calls off.
    private func check() {
        guard !saving else { return }
        saving = true
        errorMessage = nil
        checking = Task { await save() }
    }

    private func save() async {
        defer { saving = false }
        do {
            _ = try await ConnectedAccountsService.shared.connectFigma(token: token, replacing: request.replacing?.id)
            token = ""
            // The token was kept: the list is told, whether or not the
            // sheet was closed in that same instant.
            onConnected()
            if !Task.isCancelled { dismiss() }
        } catch {
            // Called off: the sheet is gone, and has nothing to say.
            if Task.isCancelled || error is CancellationError { return }
            let message = Self.message(for: error)
            errorMessage = message
            AccessibilityNotification.Announcement(message).post()
        }
    }
}
