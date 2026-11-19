import SwiftUI

/// The AI connections pane: the person's provider accounts, and adding,
/// editing, testing, and deleting them.
struct ProviderKeysView: View {
    @StateObject private var viewModel = ProviderKeysViewModel()

    var body: some View {
        SettingsForm {
            Section {
                Button {
                    viewModel.showAddSheet = true
                } label: {
                    Label("Add AI Connection…", systemImage: "plus.circle.fill")
                }
                .accessibilityIdentifier("add-provider-key")
            } footer: {
                Text("Each provider's data retention policy applies to its key.")
                    .font(.aicovenBodySmall)
            }

            if let error = viewModel.lastErrorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.aicovenError)
                }
            }

            // The spinner shows only while there are no accounts to list; a
            // reload (after a test, an edit, or a delete) keeps the list in
            // place.
            if viewModel.loading, viewModel.providerAccounts.isEmpty {
                ProgressView()
            } else if viewModel.providerAccounts.isEmpty {
                Section {
                    Text("Add your first AI connection to start chatting. Keys are kept in this device's Keychain.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(viewModel.providerAccounts) { account in
                        ProviderAccountRow(
                            account: account,
                            testActionState: viewModel.testActionState(for: account),
                            onEdit: { viewModel.selectedAccount = account },
                            onDelete: { viewModel.pendingDelete = account },
                            onTest: { Task { await viewModel.testConnection(for: account) } }
                        )
                    }
                } footer: {
                    Text("Choose a connection to edit it.")
                        .font(.aicovenBodySmall)
                }
            }
        }
        .alert(
            "Delete \(viewModel.pendingDelete?.displayName ?? "")?",
            isPresented: Binding(
                get: { viewModel.pendingDelete != nil },
                set: { if !$0 { viewModel.pendingDelete = nil } }
            ),
            presenting: viewModel.pendingDelete
        ) { account in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await viewModel.deleteAccount(account) }
            }
        } message: { account in
            Text(ProviderKeysViewModel.deleteMessage(for: account))
        }
        .sheet(isPresented: $viewModel.showAddSheet) {
            AddProviderKeySheet {
                Task { await viewModel.loadProviderAccounts() }
            }
        }
        .sheet(item: $viewModel.selectedAccount) { account in
            EditProviderKeySheet(account: account) {
                Task { await viewModel.loadProviderAccounts() }
            }
        }
        // Onboarding and other screens add accounts too.
        .onReceive(NotificationCenter.default.publisher(for: .providerKeysUpdated)) { _ in
            Task { await viewModel.loadProviderAccounts() }
        }
        .task {
            await viewModel.loadProviderAccounts()
        }
    }
}

/// One provider account as a single row: its logo, name, provider and
/// model, a status dot, and Test. A failed test's reason shows under the
/// name while its cross does. Choosing the row edits the account; Delete is
/// in the swipe actions and the context menu, and asks first.
struct ProviderAccountRow: View {
    let account: ProviderAccount
    let testActionState: ProviderAccountTestActionState
    let onEdit: () -> Void
    /// Asks to delete the account; the screen shows the confirmation.
    let onDelete: () -> Void
    let onTest: () -> Void

    private var subtitle: String {
        let provider = providerDisplayName(slug: account.provider)
        return account.defaultModel.map { "\(provider) · \($0)" } ?? provider
    }

    private var failureMessage: String? {
        if case let .failure(message) = testActionState { return message }
        return nil
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            // A button, not a tap gesture, so the keyboard reaches Edit too.
            Button(action: onEdit) {
                HStack(spacing: Spacing.sm) {
                    ProviderLogoBadge(assetName: providerLogoAssetName(slug: account.provider), size: 28)
                    VStack(alignment: .leading, spacing: Spacing.xxxs) {
                        Text(account.displayName)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.aicovenBodySmall)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let failureMessage {
                            Text(failureMessage)
                                .font(.aicovenBodySmall)
                                .foregroundStyle(Color.aicovenError)
                                .lineLimit(3)
                        }
                    }
                    Spacer(minLength: 0)
                    ProviderAccountStatus(account: account, compact: true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit")
            Button(action: onTest) {
                testButtonLabel
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(testActionState == .testing)
            .accessibilityLabel("Test \(account.displayName)")
            .accessibilityValue(testAccessibilityValue)
            .help(testActionState.resultMessage ?? "Test the connection")
        }
        .accessibilityAction(named: "Delete", onDelete)
        .contextMenu {
            Button("Edit…", action: onEdit)
            Button("Delete…", role: .destructive, action: onDelete)
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Edit", action: onEdit)
        }
    }

    /// The Test button shows the test: a spinner while it runs, then a tick
    /// or a cross, then "Test" again. The word stays in place, hidden, so
    /// the button keeps its size.
    private var testButtonLabel: some View {
        ZStack {
            Text("Test")
                .opacity(testActionState == .idle ? 1 : 0)
            switch testActionState {
            case .idle:
                EmptyView()
            case .testing:
                ProgressView()
                    .controlSize(.small)
            case .success:
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.aicovenTextSecondary)
            case .failure:
                Image(systemName: "xmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.aicovenError)
            }
        }
    }

    private var testAccessibilityValue: String {
        switch testActionState {
        case .idle: ""
        case .testing: "Testing"
        case let .success(message), let .failure(message): message
        }
    }
}

/// A provider account's stored status, which the last Test set. Compact is
/// the dot alone, for the account row; otherwise the dot and the status
/// word, for the edit form.
struct ProviderAccountStatus: View {
    let account: ProviderAccount
    let compact: Bool

    private var color: Color {
        switch account.status {
        case "healthy", "pending": .aicovenTextSecondary
        case "unhealthy": .aicovenError
        default: .aicovenTextTertiary
        }
    }

    var body: some View {
        if compact {
            StatusDot(color: color, label: account.status.capitalized)
        } else {
            HStack(spacing: Spacing.xxs) {
                StatusDot(color: color, label: account.status.capitalized)
                Text(account.status.capitalized)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(account.status.capitalized)
        }
    }
}

/// Add an AI connection, step 1: choose a provider. Each opens its form.
struct AddProviderKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    let onComplete: () -> Void

    private static let providers = [
        "openai", "anthropic", "google", "openrouter", "openai_compatible", "ollama", "openclaw", "mlx",
    ]

    #if os(macOS)
    @State private var detectedServers: [DetectedLocalProvider] = []
    @State private var isDetecting = false
    @State private var hasDetected = false
    /// Servers found at an address the person typed.
    @State private var namedServers: [DetectedLocalProvider] = []
    @State private var typedAddress = ""
    @State private var typedAddressFailure: String?
    @State private var isCheckingAddress = false
    /// The found server whose form is open.
    @State private var chosenServer: DetectedLocalProvider?
    /// False once the list is covered by a form or the sheet has closed, so
    /// a check that finishes then says nothing over another screen.
    @State private var listIsShowing = false
    #endif

    var body: some View {
        NavigationStack {
            SettingsForm {
                #if os(macOS)
                detectSection
                #endif

                Section("Provider") {
                    ForEach(Self.providers, id: \.self) { provider in
                        NavigationLink {
                            AddProviderKeyStep2View(
                                selectedProvider: provider,
                                onComplete: onComplete,
                                // The form's own `dismiss` only pops back to
                                // this list; a saved connection closes the
                                // sheet.
                                dismissSheet: { dismiss() }
                            )
                        } label: {
                            Label {
                                Text(providerDisplayName(slug: provider))
                            } icon: {
                                ProviderLogoBadge(assetName: providerLogoAssetName(slug: provider), size: 24)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add AI Connection")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            #if os(macOS)
            .onAppear { listIsShowing = true }
            .onDisappear { listIsShowing = false }
            .navigationDestination(item: $chosenServer) { server in
                AddProviderKeyStep2View(
                    selectedProvider: server.provider,
                    detected: server,
                    onComplete: onComplete,
                    dismissSheet: { dismiss() }
                )
            }
            #endif
        }
        .aiConnectionSheet()
    }

    #if os(macOS)
    /// Servers on this Mac: Detect asks the usual ports, and Check asks an
    /// address the person types. Choosing one opens its form filled in.
    private var detectSection: some View {
        Section {
            Button {
                Task { await detect() }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Text("Detect Servers")
                    if isDetecting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(isDetecting)

            ForEach(foundServers) { server in
                Button {
                    chosenServer = server
                } label: {
                    HStack(spacing: Spacing.sm) {
                        ProviderLogoBadge(assetName: providerLogoAssetName(slug: server.provider), size: 24)
                        VStack(alignment: .leading, spacing: Spacing.xxxs) {
                            Text(server.displayName)
                            Text(Self.subtitle(for: server))
                                .font(.aicovenBodySmall)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.aicovenBodySmall)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Connect")
            }
            if hasDetected, !isDetecting, detectedServers.isEmpty {
                Text("No server answered on the usual ports.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: Spacing.sm) {
                TextField(
                    "Port or address",
                    text: $typedAddress,
                    prompt: Text(LocalProviderDiscoveryService.ManualEntryCopy.placeholder)
                )
                .autocorrectionDisabled()
                .onSubmit { Task { await checkTypedAddress() } }
                Button {
                    Task { await checkTypedAddress() }
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Text("Check")
                        if isCheckingAddress {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(isCheckingAddress || typedAddress.isEmpty)
            }
            if let typedAddressFailure {
                FormErrorRow(message: typedAddressFailure)
            }
        } header: {
            Text("On this Mac")
        } footer: {
            Text("Detect asks the usual ports of LM Studio and Ollama on this Mac. For a server on another port, or another machine, enter its port or address.")
                .font(.aicovenBodySmall)
        }
    }

    /// Detected servers, then the ones at typed addresses that Detect did
    /// not also find.
    private var foundServers: [DetectedLocalProvider] {
        detectedServers + namedServers.filter { named in !detectedServers.contains { $0.id == named.id } }
    }

    private static func subtitle(for server: DetectedLocalProvider) -> String {
        let address = server.baseURL.replacingOccurrences(of: "http://", with: "")
        if server.requiresKey { return "\(address) · asks for an API key" }
        if server.provider == "ollama" { return address }
        return "\(address) · \(server.models.count == 1 ? "1 model" : "\(server.models.count) models")"
    }

    private func detect() async {
        isDetecting = true
        defer { isDetecting = false }
        detectedServers = await LocalProviderDiscoveryService().discover()
        hasDetected = true
        guard listIsShowing else { return }
        announce(
            detectedServers.isEmpty
                ? "No server answered on the usual ports."
                : "Found \(detectedServers.map(\.displayName).formatted(.list(type: .and)))."
        )
    }

    private func checkTypedAddress() async {
        // Return in the field reaches here while a check runs; one at a time.
        guard !isCheckingAddress else { return }
        let typed = typedAddress
        typedAddressFailure = nil
        guard let address = LocalProviderDiscoveryService.serverBaseURL(from: typed) else {
            typedAddressFailure = LocalProviderDiscoveryService.ManualEntryCopy.invalidInput
            announce(LocalProviderDiscoveryService.ManualEntryCopy.invalidInput)
            return
        }
        isCheckingAddress = true
        defer { isCheckingAddress = false }

        let discovery = LocalProviderDiscoveryService()
        // A known tool's usual port names the server; anything else is an
        // OpenAI-compatible server at its address.
        let known = discovery.knownEndpoint(at: address)
        let shownAddress = address.absoluteString.replacingOccurrences(of: "http://", with: "")
        let found = await discovery.probe(
            address,
            provider: known?.provider ?? "openai_compatible",
            displayName: known?.displayName ?? shownAddress
        )
        // The answer is for the address that was checked.
        guard typed == typedAddress else { return }
        guard let found else {
            let failure = LocalProviderDiscoveryService.ManualEntryCopy.noResponse(at: shownAddress)
            typedAddressFailure = failure
            if listIsShowing { announce(failure) }
            return
        }
        namedServers.removeAll { $0.id == found.id }
        namedServers.append(found)
        typedAddress = ""
        if listIsShowing { announce("Found \(found.displayName).") }
    }
    #endif
}

private extension View {
    /// One size on the Mac for the provider list and every form, which
    /// scroll inside it, and the app's light or dark choice.
    func aiConnectionSheet() -> some View {
        themedColorScheme()
        #if os(macOS)
            .frame(minWidth: 480, idealWidth: 520, minHeight: 360, idealHeight: 520)
        #endif
    }

    /// Says a finished check's result to VoiceOver, whose focus stays on
    /// the control that started it.
    func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }

    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

/// A line of a connection form that says what went wrong.
private struct FormErrorRow: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(Color.aicovenError)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Add an AI connection, step 2: where messages go (always first), then the
/// provider's own settings, the connection's name, and its key.
private struct AddProviderKeyStep2View: View {
    let selectedProvider: String
    let onComplete: () -> Void
    /// Dismisses the whole Add sheet.
    let dismissSheet: () -> Void

    @State private var displayName: String
    @State private var apiKey = ""
    @State private var baseURL: String
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var isLoadingModels = false
    @State private var ollamaModels: [OllamaLLMClient.OllamaModel] = []
    @State private var selectedOllamaModel = ""
    /// The models an OpenAI-compatible server listed, and the one chosen.
    @State private var serverModels: [String]
    @State private var selectedServerModel: String
    /// Why Connect found no models to choose from.
    @State private var connectionFailure: String?
    @State private var selectedMLXModelID = ""
    @State private var acceptedPrivacy = false
    /// False once the form is left, so a Connect that finishes then says
    /// nothing over another screen.
    @State private var formIsShowing = false
    /// True when the form opened on a detected Ollama server, whose models
    /// it lists at once.
    private let connectsOnOpen: Bool

    private static let serverAsksForKey = "This server asks for an API key. Enter it below, then Connect."

    /// `detected` fills the form from a server Detect found, so connecting
    /// it needs nothing typed unless the server asks for a key.
    init(
        selectedProvider: String,
        detected: DetectedLocalProvider? = nil,
        onComplete: @escaping () -> Void,
        dismissSheet: @escaping () -> Void
    ) {
        self.selectedProvider = selectedProvider
        self.onComplete = onComplete
        self.dismissSheet = dismissSheet
        // Named after the provider, or the detected server; the person can
        // rename it here.
        _displayName = State(initialValue: detected?.displayName ?? providerDisplayName(slug: selectedProvider))
        _baseURL = State(initialValue: detected?.baseURL ?? (selectedProvider == "ollama" ? "http://localhost:11434" : ""))
        _serverModels = State(initialValue: detected?.models ?? [])
        _selectedServerModel = State(initialValue: detected?.models.first ?? "")
        _connectionFailure = State(initialValue: detected?.requiresKey == true ? Self.serverAsksForKey : nil)
        connectsOnOpen = detected != nil && selectedProvider == "ollama"
    }

    private var isOllama: Bool {
        selectedProvider == "ollama"
    }

    private var isMLX: Bool {
        selectedProvider == "mlx"
    }

    private var isOpenClaw: Bool {
        selectedProvider == "openclaw"
    }

    private var isCompatibleServer: Bool {
        selectedProvider == "openai_compatible"
    }

    private var providerName: String {
        providerDisplayName(slug: selectedProvider)
    }

    var body: some View {
        SettingsForm {
            privacySection
            configurationSections

            Section {
                FormTextField(label: "Name", text: $displayName, prompt: providerName)
                if !isOllama, !isMLX {
                    SecureFieldWithPaste(label: "API key", prompt: keyPrompt, text: $apiKey)
                }
            } footer: {
                if !isOllama, !isMLX {
                    Text("The key is kept in this device's Keychain.")
                        .font(.aicovenBodySmall)
                }
            }

            // Last in the form, directly under the fields it is about: a
            // failed save must not look like nothing happened.
            if let errorMessage {
                Section { FormErrorRow(message: errorMessage) }
            }
        }
        .navigationTitle(providerName)
        .inlineNavigationTitle()
        .onAppear { formIsShowing = true }
        .onDisappear { formIsShowing = false }
        .task {
            if connectsOnOpen { await connectToOllama() }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Adding")
                } else {
                    Button("Add") {
                        Task { await saveProviderKey() }
                    }
                    .disabled(saveDisabled)
                }
            }
        }
    }

    // MARK: - Where messages go (always first)

    @ViewBuilder
    private var privacySection: some View {
        if isMLX {
            Section {
                Label("Messages stay on this device", systemImage: "lock.shield")
            } footer: {
                Text("The model runs on this device. Messages and their context are not sent anywhere.")
                    .font(.aicovenBodySmall)
            }
        } else if isOllama {
            Section {
                Label("Messages go only to your Ollama server", systemImage: "lock.shield")
            } footer: {
                Text("Messages and their context go to the Ollama server at the address below, and nowhere else.")
                    .font(.aicovenBodySmall)
            }
        } else {
            Section {
                Toggle(
                    isOpenClaw || isCompatibleServer ? "Share my messages with this server" : "Share my messages with \(providerName)",
                    isOn: $acceptedPrivacy
                )
            } footer: {
                // Built as a key so the policy link is a link.
                Text(LocalizedStringKey(privacyFooter))
                    .font(.aicovenBodySmall)
            }
        }
    }

    private var privacyFooter: String {
        let policy = "AICoven does not store or read them on its servers. [Privacy Policy](https://aicoven.ai/privacy)"
        switch selectedProvider {
        case "openclaw", "openai_compatible":
            return "Messages and their context go to the server address you enter. Use a server you trust. \(policy)"
        case "openrouter":
            return "Messages and their context go to OpenRouter, and to the provider of the model you choose, to generate replies. Each has its own privacy policy. \(policy)"
        default:
            return "Messages and their context go to \(providerName) to generate replies, under its privacy policy. \(policy)"
        }
    }

    // MARK: - The provider's own settings

    @ViewBuilder
    private var configurationSections: some View {
        if isOllama {
            ollamaSections
        } else if isMLX {
            mlxSection
        } else if isCompatibleServer {
            compatibleServerSections
        } else if isOpenClaw {
            Section("Server") {
                FormAddressField(label: "Address", text: $baseURL, prompt: "http://localhost:3000")
            }
        }
    }

    @ViewBuilder
    private var ollamaSections: some View {
        Section {
            FormAddressField(label: "Address", text: $baseURL, prompt: "http://localhost:11434")
                // The listed models belong to the address they came from.
                .onChange(of: baseURL) { _, _ in
                    ollamaModels = []
                    selectedOllamaModel = ""
                    connectionFailure = nil
                }
            Button {
                Task { await connectToOllama() }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Text("Connect")
                    if isLoadingModels {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(isLoadingModels || baseURL.isEmpty)
            if let connectionFailure {
                FormErrorRow(message: connectionFailure)
            }
        } header: {
            Text("Server")
        } footer: {
            Text("Ollama must be running at this address. Connect lists its models.")
                .font(.aicovenBodySmall)
        }

        if !ollamaModels.isEmpty {
            Section {
                Picker("Model", selection: $selectedOllamaModel) {
                    ForEach(ollamaModels) { model in
                        Text(model.formattedSize.map { "\(model.name) (\($0))" } ?? model.name)
                            .tag(model.name)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var compatibleServerSections: some View {
        Section {
            FormAddressField(label: "Address", text: $baseURL, prompt: "http://127.0.0.1:1234")
                // The listed models belong to the address they came from.
                .onChange(of: baseURL) { _, _ in
                    serverModels = []
                    selectedServerModel = ""
                    connectionFailure = nil
                }
            Button {
                Task { await connectToServer() }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Text("Connect")
                    if isLoadingModels {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(isLoadingModels || baseURL.isEmpty)
            if let connectionFailure {
                FormErrorRow(message: connectionFailure)
            }
        } header: {
            Text("Server")
        } footer: {
            Text("Any server that speaks the OpenAI chat API, such as LM Studio, vLLM or llama.cpp. Connect lists its models; a server that asks for a key needs it entered below first.")
                .font(.aicovenBodySmall)
        }

        if !serverModels.isEmpty {
            Section {
                Picker("Model", selection: $selectedServerModel) {
                    ForEach(serverModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var mlxSection: some View {
        if MLXModelManager.isSupported {
            Section {
                ForEach(MLXModelManager.shared.deviceFilteredCatalog) { model in
                    Button {
                        selectedMLXModelID = model.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                                Text(model.displayName)
                                Text(model.summary)
                                    .font(.aicovenBodySmall)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Text("\(model.formattedDownloadSize) download · \(model.minRAMGB) GB memory · \(model.quantization)")
                                    .font(.aicovenBodySmall)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if selectedMLXModelID == model.id {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Color.aicovenTeal)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedMLXModelID == model.id ? .isSelected : [])
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Downloaded from Hugging Face the first time it is used. No server or API key is needed.")
                    .font(.aicovenBodySmall)
            }
        } else {
            Section {
                FormErrorRow(message: "This device can't run MLX models.")
            }
        }
    }

    // MARK: - Save

    private var keyPrompt: String {
        if isOpenClaw || isCompatibleServer { return "Optional" }
        return "Required"
    }

    private var saveDisabled: Bool {
        if displayName.isEmpty { return true }
        if isOllama { return baseURL.isEmpty || selectedOllamaModel.isEmpty }
        if isMLX { return selectedMLXModelID.isEmpty }
        if isCompatibleServer { return selectedServerModel.isEmpty || !acceptedPrivacy }
        if isOpenClaw { return baseURL.isEmpty || !acceptedPrivacy }
        return apiKey.isEmpty || !acceptedPrivacy
    }

    /// Lists the models at the address in the field. An answer for an
    /// address the field no longer holds is dropped.
    private func connectToOllama() async {
        let address = baseURL
        isLoadingModels = true
        connectionFailure = nil
        defer { isLoadingModels = false }

        var models: [OllamaLLMClient.OllamaModel] = []
        var failure: String?
        if let url = URL(string: address), url.host != nil {
            let client = OllamaLLMClient(baseURL: url)
            if await client.testConnection() {
                do {
                    models = try await client.discoverModels()
                    if models.isEmpty {
                        failure = "Connected, but this server has no models. Pull one with Ollama first."
                    }
                } catch {
                    failure = "Connected, but couldn't list models: \(error.localizedDescription)"
                }
            } else {
                failure = "Can't reach \(address). Is Ollama running?"
            }
        } else {
            failure = "Enter the server's address, such as http://localhost:11434."
        }

        guard address == baseURL else { return }
        ollamaModels = models
        connectionFailure = failure
        if !models.contains(where: { $0.name == selectedOllamaModel }) {
            selectedOllamaModel = models.first?.name ?? ""
        }
        if formIsShowing {
            announce(failure ?? (models.count == 1 ? "1 model listed." : "\(models.count) models listed."))
        }
    }

    /// Lists the models of the server at the address in the field, with the
    /// key in the form if there is one. An answer for an address or a key
    /// the form no longer holds is dropped.
    private func connectToServer() async {
        let address = baseURL
        let key = apiKey
        isLoadingModels = true
        connectionFailure = nil
        defer { isLoadingModels = false }

        var models: [String] = []
        var failure: String?
        if let server = LocalProviderDiscoveryService.serverBaseURL(from: address) {
            switch await LocalProviderDiscoveryService().models(at: server, apiKey: key) {
            case let .success(data):
                models = LocalProviderDiscoveryService.parseModelIds(from: data)
                if models.isEmpty {
                    failure = "Connected, but the server listed no models. Load one in the server first."
                }
            case .unauthorized:
                failure = key.isEmpty ? Self.serverAsksForKey : "The server refused this API key."
            case .unavailable:
                failure = "Nothing answered at \(address). Check the server is running and serves the OpenAI API."
            }
        } else {
            failure = "Enter the server's address, such as http://127.0.0.1:1234."
        }

        guard address == baseURL, key == apiKey else { return }
        serverModels = models
        connectionFailure = failure
        if !models.contains(selectedServerModel) {
            selectedServerModel = models.first ?? ""
        }
        if formIsShowing {
            announce(failure ?? (models.count == 1 ? "1 model listed." : "\(models.count) models listed."))
        }
    }

    private func saveProviderKey() async {
        saving = true
        errorMessage = nil
        defer { saving = false }

        let service = ProviderAccountService.shared
        do {
            if isOllama {
                _ = try await service.createOllamaAccount(displayName: displayName, baseURL: baseURL, defaultModel: selectedOllamaModel)
            } else if isMLX {
                _ = try await service.createMLXAccount(displayName: displayName, modelID: selectedMLXModelID)
            } else if isCompatibleServer {
                // Saved as the address requests go to, whatever form it was
                // typed in. Connect listed models from it, so it is one.
                guard let server = LocalProviderDiscoveryService.serverBaseURL(from: baseURL) else {
                    errorMessage = "Enter the server's address, such as http://127.0.0.1:1234."
                    return
                }
                _ = try await service.createOpenAICompatibleAccount(
                    displayName: displayName,
                    baseURL: server.absoluteString,
                    apiKey: apiKey.isEmpty ? nil : apiKey,
                    defaultModel: selectedServerModel
                )
            } else if isOpenClaw {
                _ = try await service.createOpenClawAccount(
                    displayName: displayName,
                    baseURL: baseURL,
                    apiKey: apiKey.isEmpty ? nil : apiKey,
                    defaultModel: nil
                )
            } else {
                _ = try await service.createProviderAccount(
                    provider: selectedProvider,
                    displayName: displayName,
                    apiKey: apiKey,
                    scopes: ["chat"],
                    defaultModel: nil
                )
            }
            onComplete()
            dismissSheet()
        } catch {
            AppErrorReporter.log(error: error, context: "ProviderKeysView.saveProviderKey")
            errorMessage = "Couldn't add the connection: \(error.localizedDescription)"
        }
    }
}

/// Edit an AI connection: its name, its server address where it has one,
/// and its key, which stays as it is when the field is left empty.
struct EditProviderKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    let account: ProviderAccount
    let onComplete: () -> Void

    @State private var displayName: String
    @State private var apiKey = ""
    @State private var baseURL: String
    @State private var saving = false
    @State private var errorMessage: String?

    init(account: ProviderAccount, onComplete: @escaping () -> Void) {
        self.account = account
        self.onComplete = onComplete
        _displayName = State(initialValue: account.displayName)
        _baseURL = State(initialValue: account.baseURL ?? "")
    }

    private var slug: String {
        account.provider.lowercased()
    }

    private var hasAddress: Bool {
        ["ollama", "openclaw", "openai_compatible"].contains(slug)
    }

    private var hasKey: Bool {
        !account.isLocalProvider
    }

    private var addressPrompt: String {
        switch slug {
        case "ollama": "http://localhost:11434"
        case "openclaw": "http://localhost:3000"
        default: "http://127.0.0.1:1234"
        }
    }

    var body: some View {
        NavigationStack {
            SettingsForm {
                Section {
                    HStack(spacing: Spacing.sm) {
                        ProviderLogoBadge(assetName: providerLogoAssetName(slug: slug), size: 28)
                        FormTextField(label: "Name", text: $displayName, prompt: "My AI connection")
                    }
                    LabeledContent("Status") {
                        ProviderAccountStatus(account: account, compact: false)
                    }
                    if let model = account.defaultModel {
                        LabeledContent("Model", value: model)
                    }
                } footer: {
                    Text("Test, in the list, checks the connection and sets its status.")
                        .font(.aicovenBodySmall)
                }

                if hasAddress {
                    Section("Server") {
                        FormAddressField(label: "Address", text: $baseURL, prompt: addressPrompt)
                    }
                }

                if hasKey {
                    Section {
                        SecureFieldWithPaste(label: "API key", prompt: "Unchanged", text: $apiKey)
                    } footer: {
                        Text("Leave it empty to keep the current key.")
                            .font(.aicovenBodySmall)
                    }
                }

                if let errorMessage {
                    Section { FormErrorRow(message: errorMessage) }
                }
            }
            .navigationTitle(providerDisplayName(slug: slug))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await saveChanges() }
                    }
                    .disabled(saving || displayName.isEmpty)
                }
            }
        }
        .aiConnectionSheet()
    }

    private func saveChanges() async {
        saving = true
        errorMessage = nil
        defer { saving = false }

        var address = baseURL
        if slug == "openai_compatible" {
            // Saved as the address requests go to, as Add saves it.
            guard let server = LocalProviderDiscoveryService.serverBaseURL(from: baseURL) else {
                errorMessage = "Enter the server's address, such as http://127.0.0.1:1234."
                return
            }
            address = server.absoluteString
        }

        do {
            try await ProviderAccountService.shared.updateProviderAccount(
                id: account.id,
                displayName: displayName,
                apiKey: apiKey.isEmpty ? nil : apiKey,
                baseURL: hasAddress ? address : nil
            )
            onComplete()
            dismiss()
        } catch {
            AppErrorReporter.log(error: error, context: "ProviderKeysView.saveChanges")
            errorMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

/// Simple callout card used on home views when no provider keys are configured
struct AddProviderKeysCard: View {
    let onOpenProviderKeys: () -> Void

    @State private var hasCheckedAccounts = false
    @State private var shouldShow = false

    var body: some View {
        Group {
            if hasCheckedAccounts, shouldShow {
                GlassCard {
                    HStack(spacing: Spacing.md) {
                        IconBadge(icon: "key.fill", size: 40, color: .aicovenTeal)

                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Add your provider keys")
                                .font(.aicovenH2)
                                .foregroundColor(.aicovenTextPrimary)
                            Text("To start chatting with AICoven, add your API keys for your preferred AI providers.")
                                .font(.aicovenBodySmall)
                                .foregroundColor(.aicovenTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        Button(action: onOpenProviderKeys) {
                            Text("Add Keys")
                                .font(.aicovenBodySmall)
                                .padding(.horizontal, Spacing.md)
                                .padding(.vertical, Spacing.xs)
                                .background(Color.aicovenTeal)
                                .foregroundColor(.black)
                                .cornerRadius(BorderRadius.md)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task {
            await checkProviderAccounts()
        }
    }

    private func checkProviderAccounts() async {
        guard !hasCheckedAccounts else { return }
        defer { hasCheckedAccounts = true }

        do {
            let accounts = try await ProviderAccountService.shared.loadProviderAccounts()
            shouldShow = accounts.isEmpty
        } catch {
            AppErrorReporter.log(error: error, context: "AddProviderKeysCard.checkProviderAccounts")
            shouldShow = false
        }
    }
}

/// Flow layout for wrapping chips
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.replacingUnspecifiedDimensions().width, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.frames[index].minX, y: bounds.minY + result.frames[index].minY), proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var frames: [CGRect] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var lineHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if x + size.width > maxWidth, x > 0 {
                    x = 0
                    y += lineHeight + spacing
                    lineHeight = 0
                }

                frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
                lineHeight = max(lineHeight, size.height)
                x += size.width + spacing
            }

            size = CGSize(width: maxWidth, height: y + lineHeight)
        }
    }
}

/// Button styles
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.aicovenBodySmall)
            .foregroundColor(.aicovenTextPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm)
            .background(Color.aicovenGlass)
            .cornerRadius(BorderRadius.md)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}
