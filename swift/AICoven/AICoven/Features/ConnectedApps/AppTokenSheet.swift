import SwiftUI

/// What the token sheet is for: a new connection of an app, or a new
/// token for one whose token the app has refused.
struct AppTokenRequest: Identifiable, Equatable {
    let provider: ConnectedAppProvider
    /// The connection the token must belong to, or nil for a new one.
    let replacing: ConnectedAccount?

    var id: String {
        "\(provider.rawValue):\(replacing?.id ?? "new")"
    }
}

/// Connects an app with a token the person makes in the app and pastes
/// here: a Figma personal access token (as the cloud app's sheet does) or
/// a Linear personal API key. The token is checked with the app, kept in
/// this device's Keychain, and never shown again. (Signing in to these
/// apps needs a secret a server holds, and this app has no server.)
struct AppTokenSheet: View {
    let request: AppTokenRequest
    let onConnected: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var saving = false
    @State private var errorMessage: String?
    /// The check of the token that is under way. Closing the sheet calls
    /// it off: a token is not kept after its sheet is gone.
    @State private var checking: Task<Void, Never>?

    /// What the sheet says for an app.
    struct Texts {
        /// "token" or "key", as the app calls it.
        let noun: String
        let fieldLabel: String
        let prompt: String
        /// Where one is made, said once for a new connection and once for
        /// a replacement, and then what holds for both.
        let whereMade: String
        let whereMadeAgain: String
        let lasts: String
        /// What the token must be allowed, each with what it is for; empty
        /// where the app has nothing to choose.
        let scopes: [(String, String)]
        /// What is said in place of scopes, where there are none.
        let reach: String?

        static let figma = Texts(
            noun: "token",
            fieldLabel: "Token",
            prompt: "figd_…",
            whereMade: "Create a personal access token in Figma under Settings › Security.",
            whereMadeAgain: "Create a personal access token in Figma under Settings › Security, from this same Figma account.",
            lasts: "It works until the expiry you set there, and you can revoke it in Figma at any time.",
            scopes: [
                ("current_user:read", "your name and email"),
                ("file_content:read", "file contents"),
                ("file_comments:read", "comments"),
                ("file_comments:write", "posting comments, if agents may comment"),
            ],
            reach: nil
        )

        static let linear = Texts(
            noun: "key",
            fieldLabel: "API key",
            prompt: "lin_api_…",
            whereMade: "Create a personal API key in Linear under Settings › Security & access.",
            whereMadeAgain: "Create a personal API key in Linear under Settings › Security & access, from this same Linear account.",
            lasts: "You can revoke it in Linear at any time.",
            scopes: [],
            reach: "The key acts as you in Linear: agents can see the issues you can see. They ask before they comment on an issue or change one."
        )

        /// An app's texts. (Only apps that connect with a token have a
        /// sheet; the others are never asked for.)
        static func of(_ provider: ConnectedAppProvider) -> Texts {
            switch provider {
            case .linear: .linear
            case .figma, .github, .googleDrive: .figma
            }
        }
    }

    /// What the person is told when a token was not taken.
    static func message(for error: Error, in provider: ConnectedAppProvider) -> String {
        let app = provider.displayName
        let noun = Texts.of(provider).noun
        switch error as? ConnectedAccountsService.TokenRefusal {
        case .refused, .notAToken:
            return provider == .linear
                ? "Linear didn't accept this key. Check that it's copied whole and hasn't been revoked."
                : "Figma didn't accept this token. Check that it's copied whole and hasn't expired."
        case .otherAccount:
            return "This \(noun) belongs to a different \(app) account. Create one from the account being replaced."
        case .changed:
            return "This \(app) connection changed while the \(noun) was checked. Close this and try again."
        case nil:
            return "\(app) didn't answer. Try again."
        }
    }

    private var isReplacing: Bool {
        request.replacing != nil
    }

    private var texts: Texts {
        .of(request.provider)
    }

    var body: some View {
        NavigationStack {
            SettingsForm {
                Section {
                    SecureFieldWithPaste(label: texts.fieldLabel, prompt: texts.prompt, text: $token)
                        .disabled(saving)
                } footer: {
                    Text("\(isReplacing ? texts.whereMadeAgain : texts.whereMade) \(texts.lasts) AICoven keeps it in this device's Keychain and never shows it again.")
                        .font(.aicovenBodySmall)
                }
                if !texts.scopes.isEmpty {
                    Section {
                        ForEach(texts.scopes, id: \.0) { scope, what in
                            LabeledContent {
                                Text(what)
                            } label: {
                                Text(scope)
                                    .font(.aicovenBodySmall.monospaced())
                            }
                        }
                    } header: {
                        Text("Give the \(texts.noun) these scopes")
                    }
                }
                if let reach = texts.reach {
                    Section {
                        Text(reach)
                            .font(.aicovenBodySmall)
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.aicovenError)
                    }
                }
            }
            .navigationTitle(isReplacing ? "Use a New \(texts.noun.capitalized)" : "Connect \(request.provider.displayName)")
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
                                .accessibilityLabel("Checking the \(texts.noun)")
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
        .accessibilityIdentifier("app-token-sheet-\(request.provider.rawValue)")
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
            _ = try await ConnectedAccountsService.shared.connect(request.provider, token: token, replacing: request.replacing?.id)
            token = ""
            // The token was kept: the list is told, whether or not the
            // sheet was closed in that same instant.
            onConnected()
            if !Task.isCancelled { dismiss() }
        } catch {
            // Called off: the sheet is gone, and has nothing to say.
            if Task.isCancelled || error is CancellationError { return }
            let message = Self.message(for: error, in: request.provider)
            errorMessage = message
            AccessibilityNotification.Announcement(message).post()
        }
    }
}
