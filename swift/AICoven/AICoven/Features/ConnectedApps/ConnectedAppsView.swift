import SwiftUI

/// View for managing connected app integrations (GitHub, Google Drive, Figma, Linear).
/// All OAuth tokens are stored locally in Keychain.
struct ConnectedAppsView: View {
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
    /// The sign-in with GitHub that is waiting for its code to be
    /// authorised: closing the code's sheet calls it off.
    @State private var deviceFlowTask: Task<OAuthTokenBundle, Error>?
    /// The code's sheet is on screen, or on its way off it: no other
    /// sign-in begins until it has gone, so what its closing calls off is
    /// the sign-in whose code it showed.
    @State private var codeSheetIsUp = false

    /// The token sheet of an app that connects with one, when it is asked for.
    @State private var tokenRequest: AppTokenRequest?

    // Google Picker state
    @State private var showingGooglePicker = false
    @State private var pickedFiles: [GooglePickerFile] = []

    /// OAuth client IDs: AICoven Local's own, or a fork's from its xcconfig.
    private var githubClientId: String { OAuthClientIDs.github }

    private var googleClientId: String { OAuthClientIDs.google }

    /// A Settings pane, on the stack that shows the pane (which its MCP
    /// servers page is pushed on): a stack of its own inside one pushed by
    /// a path empties that path, and the pane is gone as it arrives.
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {

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
                            waitsForAnotherSignIn: (connectingProvider != nil || codeSheetIsUp) && !provider.connectsWithToken,
                            onConnect: { await connect(provider: provider) },
                            onDisconnect: { await disconnect(provider: provider) },
                            onBrowseDrive: provider == .googleDrive
                                && accounts.contains { $0.provider == .googleDrive && $0.status == .connected }
                                ? { showingGooglePicker = true } : nil,
                            needsToken: provider.accountWaitingForAToken(in: accounts),
                            onReplaceToken: { replaceToken(of: $0) }
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

                mcpServersSection

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
            // The sheet has gone, however it was closed: its sign-in is
            // called off if it still runs.
            deviceFlowTask?.cancel()
            deviceFlowTask = nil
            codeSheetIsUp = false
        } content: {
            GitHubDeviceCodeSheet(
                userCode: deviceUserCode,
                verificationUrl: deviceVerificationUrl,
                onCancel: {
                    // The sign-in is called off. `connect` says it is over
                    // (`connectingProvider`) once it has ended, and not
                    // before: no other begins while this one still runs.
                    deviceFlowTask?.cancel()
                    deviceFlowTask = nil
                    showingDeviceCodeSheet = false
                }
            )
        }
        .sheet(isPresented: $showingGooglePicker) {
            if let account = accounts.first(where: { $0.provider == .googleDrive && $0.status == .connected }) {
                GooglePickerSheet(
                    accountId: account.id,
                    accountName: account.displayName,
                    appId: OAuthClientIDs.googlePickerAppID,
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
        .sheet(item: $tokenRequest) { request in
            AppTokenSheet(request: request) {
                Task { await loadAccounts() }
            }
        }
        .sheet(isPresented: $showUpsell) {
            FeatureUpsellView(
                feature: upsellFeature,
                featureDescription: "Connecting apps needs the \(storeService.name(of: StoreService.toolsPackID)) upgrade. Integrate GitHub, Google Drive, Figma and Linear to give your AI agent access to your files, repositories, designs and issues."
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

                Text("Tokens are stored securely in your device's Keychain")
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

    /// MCP Servers section – navigates to the dedicated management view
    private var mcpServersSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MCP Servers")
                .font(.aicovenH3)
                .foregroundColor(.aicovenTextSecondary)
                .padding(.horizontal, 16)

            // Navigation link to full MCP management view
            NavigationLink(destination: MCPServerManagementView().stoneBackButton().onAppear { AnalyticsService.shared.trackMCPServersOpened() }) {
                GlassCard {
                    HStack(spacing: 16) {
                        // Icon badge for MCP servers
                        IconBadge(icon: "server.rack", size: 40, color: .aicovenPurple)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Remote MCP Servers")
                                .font(.aicovenBodyMedium)
                                .foregroundColor(.aicovenTextPrimary)

                            Text("Connect tools like Zapier, n8n, and custom MCP endpoints")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextSecondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        // Chevron indicator for navigation
                        Image(systemName: "chevron.right")
                            .foregroundColor(.aicovenTextTertiary)
                            .font(.aicovenCaption)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
        }
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
            upsellFeature = switch provider {
            case .github: .githubTool
            case .googleDrive: .googleDriveTool
            case .figma: .figmaTool
            case .linear: .linearTool
            }
            showUpsell = true
            return
        }

        // An app connected with a token asks for it in its own sheet.
        if provider.connectsWithToken {
            tokenRequest = AppTokenRequest(provider: provider, replacing: nil)
            return
        }

        // One sign-in at a time: the code on screen, and what its Cancel
        // calls off, are then the one sign-in's.
        guard connectingProvider == nil, !codeSheetIsUp else { return }
        connectingProvider = provider
        // However it ends, the sign-in is over then, and not before; and
        // its code is off the screen, an error's too.
        defer {
            connectingProvider = nil
            showingDeviceCodeSheet = false
        }
        // Signing in waits for the person and the app: what comes of it
        // is kept only for the account that began it.
        let startedBy = await ConnectedAccountsService.shared.signedInAccount()

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
                        codeSheetIsUp = true
                        showingDeviceCodeSheet = true
                    }
                }

                // The waiting is a task of its own, held so that closing
                // the code's sheet stops it.
                let signIn = Task { try await flow.authenticate() }
                deviceFlowTask = signIn
                tokenBundle = try await signIn.value
                // Called off just as GitHub answered: still called off.
                if signIn.isCancelled { throw CancellationError() }

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

            case .figma, .linear:
                // Connected in its token sheet, above.
                return
            }

            // Create account
            _ = try await ConnectedAccountsService.shared.createAccount(
                provider: provider,
                displayName: displayName,
                tokenBundle: tokenBundle,
                metadata: metadata,
                startedBy: startedBy
            )

            // Reload accounts
            await loadAccounts()

        } catch is CancellationError {
            // User cancelled - not an error
            return
        } catch let error as URLError where error.code == .cancelled {
            // Called off while a request was under way: the same.
            return
        } catch ConnectedAccountError.accountChanged {
            // Another account's by now: nothing was kept, and nothing is
            // said to whoever is signed in.
            return
        } catch {
            if (error as NSError).domain == "com.apple.AuthenticationServices.WebAuthenticationSession",
               (error as NSError).code == 1 {
                // User cancelled - not an error
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    /// Asks for a new token for a connection whose token was refused,
    /// behind the Tools Pack as connecting is.
    private func replaceToken(of account: ConnectedAccount) {
        if !storeService.hasToolsPack {
            upsellFeature = account.provider == .linear ? .linearTool : .figmaTool
            showUpsell = true
            return
        }
        tokenRequest = AppTokenRequest(provider: account.provider, replacing: account)
    }

    /// Disconnect from a provider: the connection its row shows. For an
    /// app connected with a token that is, where none is connected, the
    /// one that waits for a new token.
    private func disconnect(provider: ConnectedAppProvider) async {
        let connected = accounts.first { $0.provider == provider && $0.status == .connected }
        guard let account = connected ?? provider.accountWaitingForAToken(in: accounts) else {
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
    /// Another app's sign-in is under way: this one's waits for it to end.
    var waitsForAnotherSignIn = false
    let onConnect: () async -> Void
    let onDisconnect: () async -> Void
    let onBrowseDrive: (() -> Void)?
    /// A connection whose token was refused and waits for a new one.
    var needsToken: ConnectedAccount?
    var onReplaceToken: (ConnectedAccount) -> Void = { _ in }

    var isConnected: Bool {
        account != nil
    }

    /// What the app calls what it is connected with: a token, or a key.
    private var tokenNoun: String {
        AppTokenSheet.Texts.of(provider).noun
    }

    var body: some View {
        GlassCard {
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
                        if provider.connectsWithToken {
                            Text("Disconnecting deletes this app's copy of the \(tokenNoun). Revoke the \(tokenNoun) in \(provider.displayName) too.")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextTertiary)
                        }
                    } else if let needsToken {
                        Text(needsToken.displayName)
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)
                        Text("\(tokenNoun.capitalized) refused. Needs a new \(tokenNoun).")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenError)
                    } else {
                        Text("Not connected")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextTertiary)
                    }
                }

                Spacer()

                // Action buttons stacked vertically
                VStack(spacing: 8) {
                    if let onBrowseDrive {
                        Button(action: { onBrowseDrive() }) {
                            Label("Browse", systemImage: "folder.badge.plus")
                                .font(.aicovenBodySmall)
                        }
                        .buttonStyle(ConnectButtonStyle())
                    }

                    if isConnecting {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else if isConnected {
                        Button("Disconnect") {
                            Task { await onDisconnect() }
                        }
                        .buttonStyle(DisconnectButtonStyle())
                    } else if let needsToken {
                        Button("Replace \(tokenNoun.capitalized)") {
                            onReplaceToken(needsToken)
                        }
                        .buttonStyle(ConnectButtonStyle())
                        Button("Disconnect") {
                            Task { await onDisconnect() }
                        }
                        .buttonStyle(DisconnectButtonStyle())
                    } else {
                        Button("Connect") {
                            Task { await onConnect() }
                        }
                        .buttonStyle(ConnectButtonStyle())
                        .disabled(waitsForAnotherSignIn)
                    }
                }
            }
        }
    }

    /// Color for each provider
    private var providerColor: Color {
        switch provider {
        case .github: .purple
        case .googleDrive: .blue
        case .figma: .orange
        case .linear: .indigo
        }
    }
}

// MARK: - Google Picker Sheet

/// Opens Google's Picker in the system's browser (`GooglePickerPage`) with
/// the connection's token, and waits for the files chosen. The sheet says
/// what is happening meanwhile, and closes when the browser does.
struct GooglePickerSheet: View {
    let accountId: String
    /// The Google account connected, which the person chooses files as.
    let accountName: String
    let appId: String
    let onFilesPicked: ([GooglePickerFile]) -> Void
    let onCancel: () -> Void

    @State private var browser = GooglePickerBrowser()
    @State private var problem: String?
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 16) {
            if let problem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.orange)
                    .accessibilityHidden(true)
                Text(problem)
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextSecondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    self.problem = nil
                    attempt += 1
                }
                .buttonStyle(.borderedProminent)
            } else {
                ProgressView()
                    .tint(.aicovenTeal)
                Text("Choose files in your browser")
                    .font(.aicovenH3)
                    .foregroundColor(.aicovenTextPrimary)
                Text("Google Drive opens there. Choose files as \(accountName): the Google tools can open only the files you choose, and those AICoven made.")
                    .font(.aicovenBodySmall)
                    .foregroundColor(.aicovenTextSecondary)
                    .multilineTextAlignment(.center)
            }
            Button("Cancel") {
                browser.cancel()
                onCancel()
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: 420)
        #if os(macOS)
            .frame(minWidth: 380, minHeight: 240)
        #endif
            .task(id: attempt) { await choose() }
            .onDisappear { browser.cancel() }
    }

    private func choose() async {
        let service = ConnectedAccountsService.shared
        let signedIn = await service.signedInAccount()
        func stillAsked() async -> Bool {
            guard !Task.isCancelled else { return false }
            return await service.signedInAccount() == signedIn
        }
        do {
            let token = try await service.getAccessToken(forAccountId: accountId)
            guard await stillAsked() else { return }
            guard let state = GooglePickerPage.newState(),
                  let url = GooglePickerPage.url(token: token, appID: appId, state: state) else {
                show("Google Drive couldn't be opened. Try again.")
                return
            }
            let answered = try await browser.open(url)
            guard await stillAsked() else {
                onCancel()
                return
            }
            switch GooglePickerPage.answer(of: answered, state: state) {
            case let .picked(files):
                onFilesPicked(files)
            case .cancelled:
                onCancel()
            case .failed, nil:
                show("Google Drive couldn't be opened. Try again.")
            }
        } catch is CancellationError {
            if !Task.isCancelled { onCancel() }
        } catch {
            guard await stillAsked() else { return }
            show("Google Drive couldn't be opened. Check that Google is still connected, then try again.")
        }
    }

    private func show(_ words: String) {
        problem = words
        AccessibilityNotification.Announcement(words).post()
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

// MARK: - Button Styles

struct ConnectButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.aicovenBodySmall)
            .foregroundColor(.white)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(
                LinearGradient(
                    colors: [Color.aicovenTeal, Color.aicovenPurple],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(BorderRadius.md)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

struct DisconnectButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.aicovenBodySmall)
            .foregroundColor(.aicovenTextSecondary)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(Color.aicovenGlass)
            .cornerRadius(BorderRadius.md)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}
