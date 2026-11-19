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
            .accessibilityLabel("Test")
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

    private static let providers = ["openai", "anthropic", "google", "openrouter", "hermes", "ollama", "openclaw", "mlx"]

    var body: some View {
        NavigationStack {
            SettingsForm {
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
        }
        .aiConnectionSheet()
    }
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
    @State private var ollamaConnectionFailure: String?
    @State private var selectedMLXModelID = ""
    @State private var acceptedPrivacy = false

    init(selectedProvider: String, onComplete: @escaping () -> Void, dismissSheet: @escaping () -> Void) {
        self.selectedProvider = selectedProvider
        self.onComplete = onComplete
        self.dismissSheet = dismissSheet
        // Named after the provider; the person can rename it here.
        _displayName = State(initialValue: providerDisplayName(slug: selectedProvider))
        _baseURL = State(initialValue: selectedProvider == "ollama" ? "http://localhost:11434" : "")
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

    private var isHermes: Bool {
        selectedProvider == "hermes"
    }

    private var providerName: String {
        providerDisplayName(slug: selectedProvider)
    }

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
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
                Toggle(isOpenClaw || isHermes ? "Share my messages with this server" : "Share my messages with \(providerName)", isOn: $acceptedPrivacy)
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
        case "openclaw":
            return "Messages and their context go to the server address you enter. Use a server you trust. \(policy)"
        case "hermes":
            return "Messages and their context go to the server address you enter, or to Together AI when you enter none. \(policy)"
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
        } else if isOpenClaw {
            Section("Server") {
                FormAddressField(label: "Address", text: $baseURL, prompt: "http://localhost:3000")
            }
        } else if isHermes {
            Section {
                FormAddressField(label: "Address", text: $baseURL, prompt: "Together AI")
            } header: {
                Text("Server")
            } footer: {
                Text("Leave the address empty to use Together AI, which needs an API key.")
                    .font(.aicovenBodySmall)
            }
        }
    }

    @ViewBuilder
    private var ollamaSections: some View {
        Section {
            FormAddressField(label: "Address", text: $baseURL, prompt: "http://localhost:11434")
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
            if let ollamaConnectionFailure {
                FormErrorRow(message: ollamaConnectionFailure)
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
    private var mlxSection: some View {
        if MLXModelManager.isSupported {
            Section {
                ForEach(MLXModelManager.defaultCatalog) { model in
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
                FormErrorRow(message: "MLX needs Apple silicon (M1 or newer). This device can't run it.")
            }
        }
    }

    // MARK: - Save

    private var keyPrompt: String {
        if isOpenClaw { return "Optional" }
        if isHermes { return "Needed for Together AI" }
        return "Required"
    }

    private var saveDisabled: Bool {
        if trimmedName.isEmpty { return true }
        if isOllama { return baseURL.isEmpty || selectedOllamaModel.isEmpty }
        if isMLX { return selectedMLXModelID.isEmpty }
        if isOpenClaw { return baseURL.isEmpty || !acceptedPrivacy }
        if isHermes { return (apiKey.isEmpty && baseURL.isEmpty) || !acceptedPrivacy }
        return apiKey.isEmpty || !acceptedPrivacy
    }

    private func connectToOllama() async {
        isLoadingModels = true
        ollamaConnectionFailure = nil
        defer { isLoadingModels = false }

        let client = OllamaLLMClient(baseURL: URL(string: baseURL) ?? OllamaLLMClient.defaultBaseURL)
        guard await client.testConnection() else {
            ollamaModels = []
            ollamaConnectionFailure = "Can't reach \(baseURL). Is Ollama running?"
            return
        }
        do {
            ollamaModels = try await client.discoverModels()
            if !ollamaModels.contains(where: { $0.name == selectedOllamaModel }) {
                selectedOllamaModel = ollamaModels.first?.name ?? ""
            }
            if ollamaModels.isEmpty {
                ollamaConnectionFailure = "Connected, but this server has no models. Pull one with Ollama first."
            }
        } catch {
            ollamaModels = []
            ollamaConnectionFailure = "Connected, but couldn't list models: \(error.localizedDescription)"
        }
    }

    private func saveProviderKey() async {
        saving = true
        errorMessage = nil
        defer { saving = false }

        let service = ProviderAccountService.shared
        do {
            if isOllama {
                _ = try await service.createOllamaAccount(displayName: trimmedName, baseURL: baseURL, defaultModel: selectedOllamaModel)
            } else if isMLX {
                _ = try await service.createMLXAccount(displayName: trimmedName, modelID: selectedMLXModelID)
            } else if isOpenClaw {
                _ = try await service.createOpenClawAccount(
                    displayName: trimmedName,
                    baseURL: baseURL,
                    apiKey: apiKey.isEmpty ? nil : apiKey,
                    defaultModel: nil
                )
            } else if isHermes {
                _ = try await service.createHermesAccount(
                    displayName: trimmedName,
                    apiKey: apiKey.isEmpty ? nil : apiKey,
                    baseURL: baseURL.isEmpty ? nil : baseURL,
                    defaultModel: nil
                )
            } else {
                _ = try await service.createProviderAccount(
                    provider: selectedProvider,
                    displayName: trimmedName,
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
        ["ollama", "openclaw", "hermes"].contains(slug)
    }

    private var hasKey: Bool {
        !account.isLocalProvider
    }

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var addressPrompt: String {
        switch slug {
        case "ollama": "http://localhost:11434"
        case "openclaw": "http://localhost:3000"
        default: "Together AI"
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
                    .disabled(saving || trimmedName.isEmpty)
                }
            }
        }
        .aiConnectionSheet()
    }

    private func saveChanges() async {
        saving = true
        errorMessage = nil
        defer { saving = false }

        do {
            try await ProviderAccountService.shared.updateProviderAccount(
                id: account.id,
                displayName: trimmedName,
                apiKey: apiKey.isEmpty ? nil : apiKey,
                baseURL: hasAddress ? baseURL : nil
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
