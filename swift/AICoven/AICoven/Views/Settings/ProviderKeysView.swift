import SwiftUI

/// Provider Keys management view
struct ProviderKeysView: View {
    @State private var providerAccounts: [ProviderAccount] = []
    @State private var loading = true
    @State private var showAddSheet = false
    @State private var selectedAccount: ProviderAccount?

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                // Header
                VStack(spacing: Spacing.sm) {
                    IconBadge(icon: "key.fill", size: 60, color: .aicovenTeal)

                    Text("Provider Keys")
                        .font(.aicovenDisplaySmall)
                        .foregroundColor(.aicovenTextPrimary)

                    Text("Manage your AI provider API keys")
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextSecondary)

                    // Data retention policy disclaimer
                    Text("By using a provider API key, you agree to that provider's data retention policy as agreed when the key was obtained.")
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.lg)
                }
                .padding(.top, Spacing.xl)

                if loading {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.aicovenTeal)
                        .padding(.top, 50)
                } else if providerAccounts.isEmpty {
                    // Empty state
                    emptyState
                } else {
                    // Provider list
                    VStack(spacing: Spacing.md) {
                        ForEach(providerAccounts) { account in
                            ProviderAccountCard(account: account) {
                                selectedAccount = account
                            } onDelete: {
                                Task {
                                    await deleteAccount(account)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.lg)

                    // Add button
                    GradientButton("Add Provider Key", icon: "plus.circle.fill", style: .primary) {
                        showAddSheet = true
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.bottom, Spacing.xl)
                }
            }
        }
        .background(NebulaBackground().ignoresSafeArea())
        .sheet(isPresented: $showAddSheet) {
            AddProviderKeySheet {
                showAddSheet = false
                Task {
                    await loadProviderAccounts()
                }
            }
        }
        .sheet(item: $selectedAccount) { account in
            EditProviderKeySheet(account: account) {
                selectedAccount = nil
                Task {
                    await loadProviderAccounts()
                }
            }
        }
        .task {
            await loadProviderAccounts()
        }
    }

    var emptyState: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "key.fill")
                .font(.system(size: 60))
                .foregroundColor(.aicovenTeal.opacity(0.6))

            Text("No Provider Keys")
                .font(.aicovenH2)
                .foregroundColor(.aicovenTextPrimary)

            Text("Add your first API key to start using AI providers with AICoven. All keys are encrypted and stored securely.")
                .font(.aicovenBody)
                .foregroundColor(.aicovenTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            GradientButton("Add Provider Key", icon: "plus.circle.fill", style: .primary) {
                showAddSheet = true
            }
        }
        .padding(Spacing.xxl)
    }

    /// Load provider accounts
    private func loadProviderAccounts() async {
        loading = true
        defer { loading = false }

        do {
            providerAccounts = try await ProviderAccountService.shared.loadProviderAccounts()
        } catch {
            AppErrorReporter.log(error: error, context: "ProviderKeysView.loadProviderAccounts")
            providerAccounts = []
        }
    }

    /// Delete provider account
    private func deleteAccount(_ account: ProviderAccount) async {
        do {
            try await ProviderAccountService.shared.deleteProviderAccount(id: account.id)
            await loadProviderAccounts()
        } catch {
            AppErrorReporter.log(error: error, context: "ProviderKeysView.deleteAccount")
        }
    }
}

/// Provider account card
struct ProviderAccountCard: View {
    let account: ProviderAccount
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var showDeleteConfirmation = false
    @State private var isTesting = false
    @State private var testResult: (success: Bool, message: String)? = nil

    var providerInfo: (icon: String, name: String, color: Color) {
        switch account.provider.lowercased() {
        case "openai": ("🤖", "OpenAI", .aicovenTeal)
        case "google": ("🔵", "Google AI", .blue)
        case "anthropic": ("🟣", "Anthropic", .aicovenPurple)
        case "cohere": ("🧠", "Cohere", .aicovenPink)
        case "mistral": ("🌬️", "Mistral AI", .cyan)
        case "ollama": ("🦙", "Ollama (Local)", .orange)
        case "mlx": ("🧠", "MLX (On-Device)", .purple)
        case "openclaw": ("🦅", "OpenClaw", .orange)
        case "hermes": ("🪽", "Hermes", .aicovenPurple)
        default: ("🔑", account.provider, .aicovenTeal)
        }
    }

    var statusColor: Color {
        switch account.status {
        case "healthy": .green
        case "unhealthy": .red
        case "pending": .orange
        default: .gray
        }
    }

    var body: some View {
        GlassCard {
            VStack(spacing: Spacing.md) {
                // Header
                HStack {
                    HStack(spacing: Spacing.sm) {
                        Text(providerInfo.icon)
                            .font(.system(size: 32))

                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(account.displayName)
                                .font(.aicovenH3)
                                .foregroundColor(.aicovenTextPrimary)

                            Text(providerInfo.name)
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextSecondary)

                            if let model = account.defaultModel {
                                Text("Model: \(model)")
                                    .font(.aicovenCaption)
                                    .foregroundColor(.aicovenTextTertiary)
                            }
                        }
                    }

                    Spacer()

                    // Status badge
                    HStack(spacing: Spacing.xxs) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)

                        Text(account.status.capitalized)
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)
                    }
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xxs)
                    .background(Color.aicovenGlass)
                    .cornerRadius(BorderRadius.circle)
                }

                // Scopes
                if !account.scopes.isEmpty {
                    HStack {
                        Text("Capabilities:")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)

                        Spacer()
                    }

                    FlowLayout(spacing: Spacing.xs) {
                        ForEach(account.scopes, id: \.self) { scope in
                            Text(scope)
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextSecondary)
                                .padding(.horizontal, Spacing.sm)
                                .padding(.vertical, Spacing.xxs)
                                .background(Color.aicovenGlass)
                                .cornerRadius(BorderRadius.circle)
                        }
                    }
                }

                // Metadata
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    if let lastCheck = account.lastHealthCheckAt {
                        Text("Last checked: \(lastCheck, style: .date)")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextTertiary)
                    }

                    if let quota = account.quotaHint {
                        Text(quota)
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextTertiary)
                    }
                }

                // Test result
                if let result = testResult {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: result.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(result.success ? .green : .red)
                        Text(result.message)
                            .font(.aicovenCaption)
                            .foregroundColor(result.success ? .green : .red)
                            .lineLimit(2)
                    }
                    .padding(Spacing.sm)
                    .background(Color.aicovenGlass)
                    .cornerRadius(BorderRadius.sm)
                }

                // Actions
                HStack(spacing: Spacing.sm) {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack(spacing: Spacing.xxs) {
                            if isTesting {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .tint(.aicovenTextPrimary)
                            }
                            Text(isTesting ? "Testing..." : "Test")
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(isTesting)

                    Button("Edit") {
                        onEdit()
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    Button("Delete") {
                        showDeleteConfirmation = true
                    }
                    .buttonStyle(DangerButtonStyle())
                }
            }
        }
        .alert("Delete Provider Key", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                onDelete()
            }
        } message: {
            Text("Are you sure you want to delete this provider key? This action cannot be undone.")
        }
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil
        defer { isTesting = false }

        do {
            let status = try await ProviderAccountService.shared.getInitializationStatus(accountId: account.id)
            let modelCount = status.modelMetadata.count
            if modelCount > 0 {
                testResult = (true, "Connected! Found \(modelCount) model(s).")
            } else {
                testResult = (true, "Connected but no models found.")
            }
        } catch {
            // Format error message consistently for all error types
            let errorMessage: String

            // Check if it's an NSError with HTTP status code context
            if let nsError = error as NSError?, nsError.domain == "ProviderAccountService" {
                // HTTP errors from the provider API (e.g., 401, 403, 500)
                let statusCode = nsError.code
                if statusCode > 0 {
                    let description = nsError.localizedDescription
                    // Extract just the HTTP status and brief description
                    if description.contains("HTTP") {
                        errorMessage = description
                    } else {
                        errorMessage = "HTTP \(statusCode): \(description)"
                    }
                } else {
                    // Non-HTTP error (e.g., missing API key)
                    errorMessage = nsError.localizedDescription
                }
            } else {
                // URLError (network issues) or other error types
                errorMessage = error.localizedDescription
            }

            testResult = (false, errorMessage)
        }
    }
}

/// Add provider key sheet — Step 1: choose a provider
struct AddProviderKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    let onComplete: () -> Void

    @State private var selectedProvider = "openai"
    @State private var showStep2 = false

    let providers = [
        ("openai", "OpenAI", "🤖"),
        ("anthropic", "Anthropic Claude", "🟣"),
        ("google", "Google Gemini", "🔵"),
        ("hermes", "Hermes", "🪽"),
        ("ollama", "Ollama (Local)", "🦙"),
        ("openclaw", "OpenClaw (Local)", "🦅"),
        ("mlx", "MLX (On-Device)", "🧠")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("Choose a Provider")
                            .font(.aicovenH3)
                            .foregroundColor(.aicovenTextPrimary)

                        Text("Select the AI provider whose API key you want to add.")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)

                        ForEach(providers, id: \.0) { provider in
                            Button {
                                selectedProvider = provider.0
                            } label: {
                                HStack {
                                    Text(provider.2)
                                        .font(.system(size: 24))

                                    Text(provider.1)
                                        .font(.aicovenBody)
                                        .foregroundColor(.aicovenTextPrimary)

                                    Spacer()

                                    if selectedProvider == provider.0 {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.aicovenTeal)
                                    }
                                }
                                .padding(Spacing.md)
                                .background(
                                    RoundedRectangle(cornerRadius: BorderRadius.md)
                                        .fill(selectedProvider == provider.0 ? Color.aicovenGlass : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    GradientButton("Continue", icon: "arrow.right.circle.fill", style: .primary) {
                        showStep2 = true
                    }
                }
                .padding(Spacing.lg)
            }
            .background(NebulaBackground().ignoresSafeArea())
            .navigationTitle("Add Provider Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(isPresented: $showStep2) {
                AddProviderKeyStep2View(
                    selectedProvider: selectedProvider,
                    onComplete: onComplete
                )
            }
        }
    }

}

/// Step 2: privacy disclosure (pinned at top) + provider-specific configuration
private struct AddProviderKeyStep2View: View {
    @Environment(\.dismiss) private var dismiss
    let selectedProvider: String
    let onComplete: () -> Void

    @State private var displayName = ""
    @State private var apiKey = ""
    @State private var baseURL = "http://localhost:11434"
    @State private var saving = false
    @State private var isLoadingModels = false
    @State private var ollamaModels: [OllamaLLMClient.OllamaModel] = []
    @State private var selectedOllamaModel: String = ""
    @State private var connectionTestResult: (success: Bool, message: String)? = nil
    @State private var selectedMLXModelID: String = ""
    @State private var acceptedPrivacy = false

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

    private var isLocal: Bool {
        isOllama || isMLX
    }

    private var isSelfHosted: Bool {
        isOpenClaw || isHermes
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                // Privacy disclosure is the very first thing shown — impossible to miss
                privacyView

                // Display name
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Display Name")
                        .font(.aicovenH3)
                        .foregroundColor(.aicovenTextPrimary)

                    TextField(isOllama ? "My Ollama" : isMLX ? "My Local LLM" : "My API Key", text: $displayName)
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextPrimary)
                        .padding(Spacing.md)
                        .background(Color.aicovenGlass)
                        .cornerRadius(BorderRadius.md)
                }

                // Provider-specific configuration
                configurationView

                // Save button
                saveButton
            }
            .padding(Spacing.lg)
        }
        .background(NebulaBackground().ignoresSafeArea())
        .navigationTitle(providerDisplayName)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Privacy disclosure (always first)

    private var privacyView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Privacy & Data Sharing")
                .font(.aicovenH3)
                .foregroundColor(.aicovenTextPrimary)

            if isLocal {
                HStack(alignment: .top, spacing: Spacing.sm) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 20))
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Your data stays on this device")
                            .font(.aicovenBodySmall)
                            .foregroundColor(.aicovenTextPrimary)
                            .fontWeight(.semibold)
                        Text("This provider runs locally. Your message content and conversation context are never sent to any external server.")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)
                    }
                }
                .padding(Spacing.md)
                .background(Color.green.opacity(0.12))
                .cornerRadius(BorderRadius.md)
                .overlay(
                    RoundedRectangle(cornerRadius: BorderRadius.md)
                        .stroke(Color.green.opacity(0.3), lineWidth: 1)
                )

            } else if isSelfHosted {
                HStack(alignment: .top, spacing: Spacing.sm) {
                    Image(systemName: "server.rack")
                        .foregroundColor(.orange)
                        .font(.system(size: 20))
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Self-Hosted / Private Server")
                            .font(.aicovenBodySmall)
                            .foregroundColor(.aicovenTextPrimary)
                            .fontWeight(.semibold)
                        Text("Data is sent to the custom URL you provide. Make sure you trust the destination server. If left blank, it may default to a cloud service (e.g., Together AI).")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)
                    }
                }
                .padding(Spacing.md)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(BorderRadius.md)
                .overlay(
                    RoundedRectangle(cornerRadius: BorderRadius.md)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )

            } else {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Label("What data is sent", systemImage: "paperplane.fill")
                            .font(.aicovenBodySmall)
                            .fontWeight(.semibold)
                            .foregroundColor(.aicovenTextPrimary)

                        Text("Your message content and conversation context will be sent to \(providerDisplayName) for AI processing. No other personal data (account details, contacts, etc.) is shared.")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)

                        Label("Who receives it", systemImage: "person.crop.circle.fill")
                            .font(.aicovenBodySmall)
                            .fontWeight(.semibold)
                            .foregroundColor(.aicovenTextPrimary)

                        Text("\(providerDisplayName) — subject to their privacy policy. AICoven does not store or access your message content on its servers.")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)
                    }
                    .padding(Spacing.md)
                    .background(Color.aicovenGlass)
                    .cornerRadius(BorderRadius.md)

                    Toggle(isOn: $acceptedPrivacy) {
                        Text("I consent to sharing my message content and conversation context with \(providerDisplayName) for AI processing")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextPrimary)
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .aicovenTeal))

                    Link(destination: URL(string: "https://aicoven.ai/privacy")!) {
                        HStack(spacing: Spacing.xs) {
                            Text("Read AICoven's Privacy Policy")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTeal)
                            Image(systemName: "arrow.up.right.square")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTeal)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Configuration

    @ViewBuilder
    private var configurationView: some View {
        if isOllama {
            ollamaConfigSection
        } else if isMLX {
            mlxConfigSection
        } else if isOpenClaw {
            openClawConfigSection
        } else if isHermes {
            hermesConfigSection
        } else {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("API Key")
                    .font(.aicovenH3)
                    .foregroundColor(.aicovenTextPrimary)

                SecureField("sk-...", text: $apiKey)
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextPrimary)
                    .padding(Spacing.md)
                    .background(Color.aicovenGlass)
                    .cornerRadius(BorderRadius.md)

                Text("🔒 Your API key is encrypted and stored securely on this device")
                    .font(.aicovenCaption)
                    .foregroundColor(.aicovenTextSecondary)
            }
        }
    }

    // MARK: - Save

    private var saveButton: some View {
        GradientButton(
            isOllama ? "Add Ollama" : isMLX ? "Add MLX Model" : "Add Provider Key",
            icon: "checkmark.circle.fill",
            style: .primary
        ) {
            Task { await saveProviderKey() }
        }
        .disabled(saveDisabled)
    }

    private var saveDisabled: Bool {
        if saving { return true }
        if displayName.isEmpty { return true }
        if isOllama { return baseURL.isEmpty || selectedOllamaModel.isEmpty }
        if isMLX { return selectedMLXModelID.isEmpty }
        if isOpenClaw { return baseURL.isEmpty || !acceptedPrivacy }
        if isHermes { return (apiKey.isEmpty && baseURL.isEmpty) || !acceptedPrivacy }
        return apiKey.isEmpty || !acceptedPrivacy
    }

    // MARK: - OpenClaw & Hermes config sections

    private var openClawConfigSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Server URL (Required)")
                    .font(.aicovenH3)
                    .foregroundColor(.aicovenTextPrimary)

                TextField("http://localhost:3000", text: $baseURL)
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextPrimary)
                    .padding(Spacing.md)
                    .background(Color.aicovenGlass)
                    .cornerRadius(BorderRadius.md)
                    .autocorrectionDisabled()

                Text("API Key (Optional)")
                    .font(.aicovenH3)
                    .foregroundColor(.aicovenTextPrimary)

                SecureField("sk-...", text: $apiKey)
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextPrimary)
                    .padding(Spacing.md)
                    .background(Color.aicovenGlass)
                    .cornerRadius(BorderRadius.md)
            }
        }
    }

    private var hermesConfigSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("API Key")
                    .font(.aicovenH3)
                    .foregroundColor(.aicovenTextPrimary)

                SecureField("Required for Together AI", text: $apiKey)
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextPrimary)
                    .padding(Spacing.md)
                    .background(Color.aicovenGlass)
                    .cornerRadius(BorderRadius.md)

                Text("Server URL (Optional)")
                    .font(.aicovenH3)
                    .foregroundColor(.aicovenTextPrimary)

                TextField("Custom self-hosted base URL", text: $baseURL)
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextPrimary)
                    .padding(Spacing.md)
                    .background(Color.aicovenGlass)
                    .cornerRadius(BorderRadius.md)
                    .autocorrectionDisabled()
            }
        }
    }

    // MARK: - Ollama config section

    private var ollamaConfigSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Server URL")
                    .font(.aicovenH3)
                    .foregroundColor(.aicovenTextPrimary)

                HStack(spacing: Spacing.sm) {
                    TextField("http://localhost:11434", text: $baseURL)
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextPrimary)
                        .padding(Spacing.md)
                        .background(Color.aicovenGlass)
                        .cornerRadius(BorderRadius.md)
                        .autocorrectionDisabled()

                    Button {
                        Task { await testOllamaConnection() }
                    } label: {
                        HStack(spacing: Spacing.xs) {
                            if isLoadingModels {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .tint(.aicovenTextPrimary)
                            }
                            Text("Connect")
                        }
                        .font(.aicovenBodySmall)
                        .foregroundColor(.aicovenTextPrimary)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)
                        .background(Color.aicovenGlass)
                        .cornerRadius(BorderRadius.md)
                    }
                    .disabled(isLoadingModels || baseURL.isEmpty)
                }

                Text("🏠 Make sure Ollama is running on your machine")
                    .font(.aicovenCaption)
                    .foregroundColor(.aicovenTextSecondary)
            }

            if let result = connectionTestResult {
                HStack {
                    Image(systemName: result.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(result.success ? .green : .red)
                    Text(result.message)
                        .font(.aicovenCaption)
                        .foregroundColor(result.success ? .green : .red)
                }
                .padding(.vertical, Spacing.xs)
            }

            if !ollamaModels.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Model")
                        .font(.aicovenH3)
                        .foregroundColor(.aicovenTextPrimary)

                    Text("Select a model to use as the default")
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextSecondary)

                    ForEach(ollamaModels) { model in
                        Button {
                            selectedOllamaModel = model.name
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.name)
                                        .font(.aicovenBody)
                                        .foregroundColor(.aicovenTextPrimary)

                                    if let size = model.formattedSize {
                                        Text(size)
                                            .font(.aicovenCaption)
                                            .foregroundColor(.aicovenTextTertiary)
                                    }
                                }
                                Spacer()
                                if selectedOllamaModel == model.name {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.aicovenTeal)
                                }
                            }
                            .padding(Spacing.sm)
                            .background(
                                RoundedRectangle(cornerRadius: BorderRadius.sm)
                                    .fill(selectedOllamaModel == model.name ? Color.aicovenGlass : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - MLX config section

    private var mlxConfigSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if !MLXModelManager.isSupported {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("MLX requires Apple Silicon (M1 or newer). This Mac is not supported.")
                        .font(.aicovenCaption)
                        .foregroundColor(.orange)
                }
                .padding(.vertical, Spacing.xs)
            } else {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Select a Model")
                        .font(.aicovenH3)
                        .foregroundColor(.aicovenTextPrimary)

                    Text("Models run entirely on your device. Downloaded from Hugging Face on first use.")
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextSecondary)

                    ForEach(MLXModelManager.defaultCatalog) { model in
                        Button {
                            selectedMLXModelID = model.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.displayName)
                                        .font(.aicovenBody)
                                        .foregroundColor(.aicovenTextPrimary)

                                    Text(model.summary)
                                        .font(.aicovenCaption)
                                        .foregroundColor(.aicovenTextSecondary)
                                        .lineLimit(2)

                                    HStack(spacing: Spacing.sm) {
                                        Label(model.formattedDownloadSize, systemImage: "arrow.down.circle")
                                        Label("\(model.minRAMGB) GB RAM", systemImage: "memorychip")
                                        Label(model.quantization, systemImage: "cube")
                                    }
                                    .font(.aicovenCaption)
                                    .foregroundColor(.aicovenTextTertiary)
                                }
                                Spacer()
                                if selectedMLXModelID == model.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.aicovenTeal)
                                }
                            }
                            .padding(Spacing.sm)
                            .background(
                                RoundedRectangle(cornerRadius: BorderRadius.sm)
                                    .fill(selectedMLXModelID == model.id ? Color.aicovenGlass : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("🧠 No server or API key needed — runs natively on Apple Silicon")
                    .font(.aicovenCaption)
                    .foregroundColor(.aicovenTextSecondary)
            }
        }
    }

    // MARK: - Helpers

    private var providerDisplayName: String {
        switch selectedProvider {
        case "openai": "OpenAI"
        case "anthropic": "Anthropic Claude"
        case "google": "Google Gemini"
        case "ollama": "Ollama (Local)"
        case "mlx": "MLX (On-Device)"
        case "openclaw": "OpenClaw"
        case "hermes": "Hermes"
        default: selectedProvider.capitalized
        }
    }

    func testOllamaConnection() async {
        isLoadingModels = true
        defer { isLoadingModels = false }

        let client = OllamaLLMClient(baseURL: URL(string: baseURL) ?? OllamaLLMClient.defaultBaseURL)
        let connected = await client.testConnection()

        if connected {
            do {
                let models = try await client.discoverModels()
                ollamaModels = models
                if let first = models.first { selectedOllamaModel = first.name }
                connectionTestResult = (true, "Connected! Found \(models.count) model(s).")
            } catch {
                connectionTestResult = (false, "Connected but failed to list models: \(error.localizedDescription)")
            }
        } else {
            connectionTestResult = (false, "Cannot connect to \(baseURL). Is Ollama running?")
        }
    }

    private func saveProviderKey() async {
        saving = true
        defer { saving = false }

        do {
            if isOllama {
                let name = displayName.isEmpty ? "My Ollama" : displayName
                _ = try await ProviderAccountService.shared.createOllamaAccount(
                    displayName: name,
                    baseURL: baseURL,
                    defaultModel: selectedOllamaModel.isEmpty ? nil : selectedOllamaModel
                )
            } else if isMLX {
                let name = displayName.isEmpty ? "My Local LLM" : displayName
                _ = try await ProviderAccountService.shared.createMLXAccount(
                    displayName: name,
                    modelID: selectedMLXModelID
                )
            } else if isOpenClaw {
                let name = displayName.isEmpty ? "OpenClaw Server" : displayName
                _ = try await ProviderAccountService.shared.createOpenClawAccount(
                    displayName: name,
                    baseURL: baseURL,
                    apiKey: apiKey.isEmpty ? nil : apiKey,
                    defaultModel: nil
                )
            } else if isHermes {
                let name = displayName.isEmpty ? "Hermes Server" : displayName
                _ = try await ProviderAccountService.shared.createHermesAccount(
                    displayName: name,
                    apiKey: apiKey.isEmpty ? nil : apiKey,
                    baseURL: baseURL.isEmpty ? nil : baseURL,
                    defaultModel: nil
                )
            } else {
                _ = try await ProviderAccountService.shared.createProviderAccount(
                    provider: selectedProvider,
                    displayName: displayName,
                    apiKey: apiKey,
                    scopes: ["chat"],
                    defaultModel: nil
                )
            }

            onComplete()
            dismiss()

        } catch {
            AppErrorReporter.log(error: error, context: "ProviderKeysView.saveProviderKey")
        }
    }
}

/// Edit an existing provider key
struct EditProviderKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    let account: ProviderAccount
    let onComplete: () -> Void

    @State private var displayName: String = ""
    @State private var apiKey: String = ""
    @State private var baseURL: String = ""
    @State private var saving = false
    @State private var errorMessage: String?

    private var isOllama: Bool {
        account.provider.lowercased() == "ollama"
    }

    private var isMLX: Bool {
        account.provider.lowercased() == "mlx"
    }

    private var isOpenClaw: Bool {
        account.provider.lowercased() == "openclaw"
    }

    private var isHermes: Bool {
        account.provider.lowercased() == "hermes"
    }

    private var isLocal: Bool {
        isOllama || isMLX
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    // Display name
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("Display Name")
                            .font(.aicovenH3)
                            .foregroundColor(.aicovenTextPrimary)

                        TextField("My API Key", text: $displayName)
                            .font(.aicovenBody)
                            .foregroundColor(.aicovenTextPrimary)
                            .padding(Spacing.md)
                            .background(Color.aicovenGlass)
                            .cornerRadius(BorderRadius.md)
                    }

                    // API key or Base URL
                    if isOllama {
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            Text("Server URL")
                                .font(.aicovenH3)
                                .foregroundColor(.aicovenTextPrimary)

                            TextField("http://localhost:11434", text: $baseURL)
                                .font(.aicovenBody)
                                .foregroundColor(.aicovenTextPrimary)
                                .padding(Spacing.md)
                                .background(Color.aicovenGlass)
                                .cornerRadius(BorderRadius.md)
                                .autocorrectionDisabled()
                        }
                    } else if isOpenClaw || isHermes {
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            Text("API Key")
                                .font(.aicovenH3)
                                .foregroundColor(.aicovenTextPrimary)

                            SecureField("Leave blank to keep current key", text: $apiKey)
                                .font(.aicovenBody)
                                .foregroundColor(.aicovenTextPrimary)
                                .padding(Spacing.md)
                                .background(Color.aicovenGlass)
                                .cornerRadius(BorderRadius.md)

                            Text("🔒 Leave blank to keep your existing key")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextSecondary)

                            Text("Server URL")
                                .font(.aicovenH3)
                                .foregroundColor(.aicovenTextPrimary)

                            TextField(isOpenClaw ? "http://localhost:3000" : "Custom self-hosted base URL", text: $baseURL)
                                .font(.aicovenBody)
                                .foregroundColor(.aicovenTextPrimary)
                                .padding(Spacing.md)
                                .background(Color.aicovenGlass)
                                .cornerRadius(BorderRadius.md)
                                .autocorrectionDisabled()
                        }
                    } else if !isMLX {
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            Text("API Key")
                                .font(.aicovenH3)
                                .foregroundColor(.aicovenTextPrimary)

                            SecureField("Leave blank to keep current key", text: $apiKey)
                                .font(.aicovenBody)
                                .foregroundColor(.aicovenTextPrimary)
                                .padding(Spacing.md)
                                .background(Color.aicovenGlass)
                                .cornerRadius(BorderRadius.md)

                            Text("🔒 Leave blank to keep your existing key")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextSecondary)
                        }
                    }

                    if let error = errorMessage {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(error)
                                .font(.aicovenCaption)
                                .foregroundColor(.red)
                        }
                    }

                    // Save button
                    GradientButton(saving ? "Saving..." : "Save Changes", icon: "checkmark.circle.fill", style: .primary) {
                        Task { await saveChanges() }
                    }
                    .disabled(saving || displayName.isEmpty)
                }
                .padding(Spacing.lg)
            }
            .background(NebulaBackground().ignoresSafeArea())
            .navigationTitle("Edit Provider Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear {
            displayName = account.displayName
            baseURL = account.baseURL ?? (isOpenClaw ? "http://localhost:3000" : "")
        }
    }

    private func saveChanges() async {
        saving = true
        errorMessage = nil
        defer { saving = false }

        do {
            try await ProviderAccountService.shared.updateProviderAccount(
                id: account.id,
                displayName: displayName,
                apiKey: apiKey.isEmpty ? nil : apiKey,
                baseURL: (isOllama || isOpenClaw || isHermes) ? baseURL : nil
            )
            onComplete()
            dismiss()
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
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

struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.aicovenBodySmall)
            .foregroundColor(.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm)
            .background(Color.aicovenGlass)
            .cornerRadius(BorderRadius.md)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}
