import SwiftUI

/// View for managing connected app integrations (GitHub, Google Drive).
/// All OAuth tokens are stored locally in Keychain.
struct ConnectedAppsView: View {
    /// Environment to dismiss the view (used on macOS when presented as a sheet)
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var storeService: StoreService

    @State private var accounts: [ConnectedAccount] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isConnecting = false
    @State private var connectingProvider: ConnectedAppProvider?
    @State private var showUpsell = false
    @State private var upsellFeature: PurchasableFeature = .githubTool

    // GitHub Device Flow state
    @State private var showingDeviceCodeSheet = false
    @State private var deviceUserCode: String = ""
    @State private var deviceVerificationUrl: String = ""
    @State private var deviceFlowTask: Task<Void, Never>?

    // Google Picker state
    @State private var showingGooglePicker = false
    @State private var pickedFiles: [GooglePickerFile] = []

    /// OAuth client IDs – pre-configured with AICoven's apps via Info.plist / xcconfig.
    /// Developers who fork the repo can override these in their own xcconfig.
    private var githubClientId: String {
        Bundle.main.infoDictionary?["GITHUB_OAUTH_CLIENT_ID"] as? String ?? "Iv23liJu04XRFISDVMBO"
    }

    private var googleClientId: String {
        Bundle.main.infoDictionary?["GOOGLE_OAUTH_CLIENT_ID"] as? String ?? "870439799161-1c7u8utd0t0kh3ote5kugh8cj9961ugb.apps.googleusercontent.com"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                #if os(macOS)
                // Close button for macOS (sheets don't have a default close button)
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                    .padding(.top, 12)
                }
                #endif

                // Header
                headerSection

                // Info banner
                infoBanner

                // Connected apps list
                VStack(spacing: 16) {
                    ForEach(ConnectedAppProvider.allCases, id: \.rawValue) { provider in
                        ConnectedAppRow(
                            provider: provider,
                            account: accounts.first { $0.provider == provider && $0.status == .connected },
                            isConnecting: connectingProvider == provider,
                            onConnect: { await connect(provider: provider) },
                            onDisconnect: { await disconnect(provider: provider) },
                            onBrowseDrive: provider == .googleDrive ? { showingGooglePicker = true } : nil
                        )
                    }
                }
                .padding(.horizontal)

                // Show recently picked files if any
                if !pickedFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recently Picked Files")
                            .font(.aicovenH3)
                            .foregroundColor(.aicovenTextSecondary)
                        ForEach(pickedFiles) { file in
                            HStack {
                                Image(systemName: "doc.fill")
                                    .foregroundColor(.aicovenTeal)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name)
                                        .font(.aicovenBodySmall)
                                        .foregroundColor(.aicovenTextPrimary)
                                    Text(file.id)
                                        .font(.aicovenCaption)
                                        .foregroundColor(.aicovenTextTertiary)
                                }
                                Spacer()
                            }
                            .padding(8)
                            .background(Color.aicovenGlass)
                            .cornerRadius(8)
                        }
                    }
                    .padding(.horizontal)
                }

                Spacer(minLength: 40)
            }
        }
        .background(NebulaBackground())
        .task { await loadAccounts() }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let errorMessage { Text(errorMessage) }
        }
        .sheet(isPresented: $showingDeviceCodeSheet) {
            // Called when sheet is dismissed (user cancelled)
            deviceFlowTask?.cancel()
            deviceFlowTask = nil
        } content: {
            GitHubDeviceCodeSheet(
                userCode: deviceUserCode,
                verificationUrl: deviceVerificationUrl,
                onCancel: {
                    deviceFlowTask?.cancel()
                    deviceFlowTask = nil
                    showingDeviceCodeSheet = false
                    connectingProvider = nil
                }
            )
        }
        .sheet(isPresented: $showingGooglePicker) {
            if let account = accounts.first(where: { $0.provider == .googleDrive && $0.status == .connected }) {
                GooglePickerSheet(
                    accountId: account.id,
                    apiKey: Bundle.main.infoDictionary?["GOOGLE_PICKER_API_KEY"] as? String ?? "",
                    appId: Bundle.main.infoDictionary?["GOOGLE_PICKER_APP_ID"] as? String ?? "",
                    onFilesPicked: { files in
                        pickedFiles = files
                        showingGooglePicker = false
                    },
                    onCancel: {
                        showingGooglePicker = false
                    }
                )
            }
        }
        .sheet(isPresented: $showUpsell) {
            FeatureUpsellView(
                feature: upsellFeature,
                featureDescription: "Connected Apps require the Tools Pack upgrade. Integrate GitHub and Google Drive to give your AI agent access to your files and repositories."
            )
            .environmentObject(storeService)
        }

    }

    // MARK: - View Components

    /// Header section
    private var headerSection: some View {
        VStack(spacing: Spacing.sm) {
            IconBadge(icon: "app.connected.to.app.below.fill", size: 60, color: .aicovenPurple)

            Text("Connected Apps")
                .font(.aicovenDisplaySmall)
                .foregroundColor(.aicovenTextPrimary)

            Text("Connect external services to enhance agent capabilities")
                .font(.aicovenBody)
                .foregroundColor(.aicovenTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, Spacing.xl)
    }

    /// Info banner about local-first architecture
    private var infoBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .foregroundColor(.aicovenTeal)

            VStack(alignment: .leading, spacing: 2) {
                Text("Local-First Security")
                    .font(.aicovenBodySmall)
                    .fontWeight(.semibold)
                    .foregroundColor(.aicovenTextPrimary)

                Text("OAuth tokens are stored securely in your device's Keychain")
                    .font(.aicovenCaption)
                    .foregroundColor(.aicovenTextSecondary)
            }

            Spacer()
        }
        .padding()
        .background(Color.aicovenGlass)
        .cornerRadius(12)
        .padding(.horizontal)
    }

    // MARK: - Actions

    /// Load accounts from ConnectedAccountsService
    private func loadAccounts() async {
        isLoading = true
        accounts = await ConnectedAccountsService.shared.getAllAccounts()
        isLoading = false
    }

    /// Connect to a provider
    private func connect(provider: ConnectedAppProvider) async {
        // Gate connected apps behind the Tools Pack entitlement
        if !storeService.hasToolsPack {
            upsellFeature = provider == .github ? .githubTool : .googleDriveTool
            showUpsell = true
            return
        }

        connectingProvider = provider

        do {
            let tokenBundle: OAuthTokenBundle
            let displayName: String
            var metadata: [String: String] = [:]

            switch provider {
            case .github:

                // Use Device Flow for GitHub (no client secret needed)
                let flow = GitHubDeviceFlow(clientId: githubClientId)

                // Set up callback to show user code
                flow.onUserCodeReceived = { [self] userCode, verificationUrl in
                    // Set values first, then show sheet on next run loop
                    // to ensure SwiftUI state is committed
                    deviceUserCode = userCode
                    deviceVerificationUrl = verificationUrl
                    DispatchQueue.main.async {
                        showingDeviceCodeSheet = true
                    }
                }

                // Start flow in a task so we can cancel it
                tokenBundle = try await withTaskCancellationHandler {
                    try await flow.authenticate()
                } onCancel: {
                    // Task was cancelled (user dismissed sheet)
                }

                // Hide device code sheet
                showingDeviceCodeSheet = false

                // Fetch user info
                displayName = try await fetchGitHubUsername(token: tokenBundle.accessToken)
                metadata["login"] = displayName

            case .googleDrive:

                let flow = await GoogleOAuthFlow(clientId: googleClientId)
                tokenBundle = try await flow.authenticate()

                // Fetch user info
                displayName = try await fetchGoogleEmail(token: tokenBundle.accessToken)
                metadata["email"] = displayName
            }

            // Create account
            _ = try await ConnectedAccountsService.shared.createAccount(
                provider: provider,
                displayName: displayName,
                tokenBundle: tokenBundle,
                metadata: metadata
            )

            // Reload accounts
            await loadAccounts()
            connectingProvider = nil

        } catch is CancellationError {
            // User cancelled - not an error
            connectingProvider = nil
            return
        } catch {
            connectingProvider = nil
            if (error as NSError).domain == "com.apple.AuthenticationServices.WebAuthenticationSession",
               (error as NSError).code == 1 {
                // User cancelled - not an error
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    /// Disconnect from a provider
    private func disconnect(provider: ConnectedAppProvider) async {
        guard let account = accounts.first(where: { $0.provider == provider && $0.status == .connected }) else {
            return
        }

        await ConnectedAccountsService.shared.disconnectAccount(id: account.id)
        await loadAccounts()
    }

    // MARK: - Helpers

    /// Fetch GitHub username from API
    private func fetchGitHubUsername(token: String) async throws -> String {
        let url = URL(string: "https://api.github.com/user")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = json["login"] as? String else {
            return "GitHub User"
        }

        return login
    }

    /// Fetch Google email from API
    private func fetchGoogleEmail(token: String) async throws -> String {
        let url = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String else {
            return "Google User"
        }

        return email
    }
}

// MARK: - Connected App Row

/// A single row displaying a connected app's status
struct ConnectedAppRow: View {
    let provider: ConnectedAppProvider
    let account: ConnectedAccount?
    let isConnecting: Bool
    let onConnect: () async -> Void
    let onDisconnect: () async -> Void
    let onBrowseDrive: (() -> Void)?

    var isConnected: Bool {
        account != nil
    }

    var body: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                Circle()
                    .fill(providerColor.opacity(0.15))
                    .frame(width: 48, height: 48)

                Image(systemName: provider.iconName)
                    .font(.system(size: 24))
                    .foregroundColor(providerColor)
            }

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(provider.displayName)
                    .font(.aicovenH3)
                    .foregroundColor(.aicovenTextPrimary)

                if let account {
                    Text(account.displayName)
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextSecondary)
                } else {
                    Text("Not connected")
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextTertiary)
                }
            }

            Spacer()

            // Action buttons
            if isConnecting {
                ProgressView()
                    .scaleEffect(0.8)
            } else if isConnected {
                HStack(spacing: 8) {
                    if let onBrowseDrive {
                        Button("Browse Files") {
                            onBrowseDrive()
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                    }
                    Button("Disconnect") {
                        Task { await onDisconnect() }
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            } else {
                Button("Connect") {
                    Task { await onConnect() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color.aicovenGlass)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.aicovenBorder, lineWidth: 1)
        )
        .cornerRadius(12)
    }

    /// Color for each provider
    private var providerColor: Color {
        switch provider {
        case .github: .purple
        case .googleDrive: .blue
        }
    }
}

// MARK: - Google Picker Sheet

/// Wrapper that fetches the access token from Keychain and
/// presents the GooglePickerView with it.
struct GooglePickerSheet: View {
    let accountId: String
    let apiKey: String
    let appId: String
    let onFilesPicked: ([GooglePickerFile]) -> Void
    let onCancel: () -> Void

    @State private var accessToken: String?
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(.aicovenTeal)
                    Text("Preparing Drive access…")
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NebulaBackground())
            } else if let error {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextSecondary)
                        .multilineTextAlignment(.center)
                    Button("Cancel") { onCancel() }
                        .buttonStyle(.bordered)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NebulaBackground())
            } else if let token = accessToken {
                GooglePickerView(
                    accessToken: token,
                    apiKey: apiKey,
                    appId: appId,
                    onFilesPicked: onFilesPicked,
                    onCancel: onCancel
                )
            }
        }
        .task {
            do {
                let token = try await ConnectedAccountsService.shared.getAccessToken(forAccountId: accountId)
                accessToken = token
                isLoading = false
            } catch {
                self.error = "Failed to get access token: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }
}

// MARK: - GitHub Device Code Sheet

/// Sheet displayed during GitHub Device Flow showing the user code
struct GitHubDeviceCodeSheet: View {
    let userCode: String
    let verificationUrl: String
    let onCancel: () -> Void

    @State private var codeCopied = false

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: Spacing.sm) {
                IconBadge(icon: "link.circle.fill", size: 60, color: .aicovenPurple)

                Text("Connect to GitHub")
                    .font(.aicovenH1)
                    .foregroundColor(.aicovenTextPrimary)
            }

            // Instructions
            Text("Enter this code on GitHub to authorize AICoven:")
                .font(.aicovenBody)
                .foregroundColor(.aicovenTextSecondary)
                .multilineTextAlignment(.center)

            // User code display
            HStack(spacing: 12) {
                if userCode.isEmpty {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Loading code...")
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextSecondary)
                } else {
                    Text(userCode)
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .tracking(4)

                    Button {
                        copyToClipboard(userCode)
                        codeCopied = true
                        // Reset after 2 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            codeCopied = false
                        }
                    } label: {
                        Image(systemName: codeCopied ? "checkmark" : "doc.on.doc")
                            .foregroundColor(codeCopied ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            .background(Color.aicovenGlass)
            .cornerRadius(12)

            // Open GitHub button
            if let url = URL(string: verificationUrl) {
                Link(destination: url) {
                    HStack {
                        Text("Open GitHub")
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        LinearGradient(
                            colors: [Color.aicovenTeal, Color.aicovenPurple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
            }

            // Waiting indicator
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                    .tint(.aicovenTeal)
                Text("Waiting for authorization...")
                    .font(.aicovenCaption)
                    .foregroundColor(.aicovenTextTertiary)
            }

            Spacer()

            // Cancel button
            Button("Cancel") {
                onCancel()
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(minWidth: 320, minHeight: 400)
        .background(NebulaBackground())
    }

    /// Copy text to clipboard
    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

// MARK: - Preview

#if DEBUG
struct ConnectedAppsView_Previews: PreviewProvider {
    static var previews: some View {
        ConnectedAppsView()
    }
}

struct GitHubDeviceCodeSheet_Previews: PreviewProvider {
    static var previews: some View {
        GitHubDeviceCodeSheet(
            userCode: "ABCD-1234",
            verificationUrl: "https://github.com/login/device",
            onCancel: {}
        )
    }
}
#endif
