import SwiftUI
import StoreKit

/// Settings screen for configuring the personal default assistant (Strix).
struct StrixSettingsView: View {
    /// Optional close handler; when embedded in a tab we leave this nil so the
    /// tab close button controls lifecycle, mirroring EditRoleView.
    var onClose: (() -> Void)?

    @EnvironmentObject var storeService: StoreService
    @State private var showStore = false
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    @State private var systemPrompt: String = ""
    @State private var autonomousMode: Bool = false
    @State private var maxStepsText: String = "5"
    @State private var plannerMaxTasksText: String = "5"
    @State private var plannerMaxSecondsText: String = "30"
    /// Maximum number of tool-calling steps allowed in a single chat reply.
    /// This controls how many times the assistant can emit a JSON tool call
    /// (web_search/current_time) before it must return a natural-language
    /// answer. Persisted via UserDefaults (chat_max_tool_steps).
    @State private var chatMaxToolStepsText: String = "3"
    /// Model and provider are left empty by default; they will be populated
    /// when settings are loaded or a provider account is selected. This avoids
    /// showing "gpt-4o" in the sidebar when no OpenAI key is configured.
    @State private var model: String = ""
    @State private var provider: String = ""
    @State private var providerAccountId: String? = nil

    // Provider accounts state
    @State private var providerAccounts: [ProviderAccount] = []
    @State private var loadingAccounts = false

    /// Per-account model options derived from initialization metadata.
    /// Keyed by provider account ID.
    @State private var accountModelOptions: [String: [(String, String)]] = [:]

    /// Dynamically discovered Ollama models (from /api/tags).
    @State private var ollamaModels: [(String, String)] = []

    private let providerOptions: [(String, String)] = [
        ("openai", "OpenAI"),
        ("anthropic", "Anthropic"),
        ("google", "Google AI"),
        ("mistral", "Mistral AI"),
        ("ollama", "Ollama (Local)"),
        ("mlx", "MLX (On-Device)"),
    ]

    /// Whether the selected provider is local (no API key needed).
    private var isLocalProvider: Bool {
        provider == "mlx" || provider == "ollama"
    }

    /// Available models for the currently selected provider account. We use
    /// dynamically discovered models from provider_initializations when
    /// possible so the list always matches what the specific key supports.
    private var availableModels: [(String, String)] {
        if provider == "mlx" {
            return MLXModelManager.defaultCatalog.map { ($0.id, $0.displayName) }
        }
        if provider == "ollama" {
            if !ollamaModels.isEmpty {
                return ollamaModels
            }
            let ollamaModel = UserDefaults.standard.string(forKey: UserScope.scopedKey("ollama_model")) ?? "llama3.2"
            return [(ollamaModel, ollamaModel)]
        }
        if let accountId = providerAccountId,
           let dynamic = accountModelOptions[accountId],
           !dynamic.isEmpty {
            return dynamic
        }
        // Without model metadata we intentionally return an empty list and let
        // the UI fall back to a free-form model text field.
        return []
    }

    var body: some View {
        Group {
            if isLoading {
                VStack {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.aicovenTeal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NebulaBackground())
            } else {
                ScrollView {
                    VStack(spacing: Spacing.xl) {
                        header

                        // Main form content
                        form

                        // Primary save CTA at the bottom, like EditRoleView
                        HStack {
                            Spacer()
                            GradientButton("Save Changes", icon: "checkmark.circle.fill", style: .primary) {
                                Task { await save() }
                            }
                            .disabled(isSaving || providerAccounts.isEmpty)
                        }
                        .padding(.horizontal, Spacing.lg)
                        .padding(.bottom, Spacing.xl)
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.top, Spacing.xl)
                }
                .background(NebulaBackground())
            }
        }
        .task {
            await load()
        }
    }

    private var header: some View {
        VStack(spacing: Spacing.sm) {
            IconBadge(icon: "sparkles", size: 60, color: .aicovenTeal)

            Text("Default Assistant (Strix)")
                .font(.aicovenDisplaySmall)
                .foregroundColor(.aicovenTextPrimary)

            Text("Configure Strix for your personal chats. These settings apply to all personal threads.")
                .font(.aicovenBody)
                .foregroundColor(.aicovenTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, Spacing.xl)
    }

    private var form: some View {
        VStack(spacing: Spacing.lg) {
            if let errorMessage {
                ErrorBannerView(message: errorMessage)
            }

            // System prompt
            GlassCard {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("System Prompt")
                        .font(.aicovenH3)
                        .foregroundColor(.aicovenTextPrimary)

                    TextEditor(text: $systemPrompt)
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextPrimary)
                        .frame(minHeight: 160)
                        .padding(Spacing.sm)
                        .background(Color.aicovenGlass)
                        .cornerRadius(BorderRadius.md)
                        .scrollContentBackground(.hidden)

                    Text("Define how Strix should behave, think, and respond in your personal workspace.")
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextTertiary)
                }
            }

            // Model & provider (optional / advanced)
            GlassCard {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HStack {
                        Text("Model & Provider")
                            .font(.aicovenH3)
                            .foregroundColor(.aicovenTextPrimary)
                        Spacer()
                        if !storeService.hasCreator {
                            Image(systemName: "lock.fill")
                                .foregroundColor(.aicovenPurple)
                        }
                    }

                    Text("Choose which model powers Strix in personal chats. Advanced / paid feature.")
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextTertiary)

                    if !storeService.hasCreator {
                        // Locked overlay for model customization
                        VStack(spacing: Spacing.sm) {
                            Text("Unlock model customization with the Creator upgrade.")
                                .font(.aicovenBodySmall)
                                .foregroundColor(.aicovenTextSecondary)
                                .multilineTextAlignment(.center)
                            Button("View Upgrade Options") {
                                showStore = true
                            }
                            .font(.aicovenBodySmall)
                            .foregroundColor(.aicovenTeal)
                        }
                        .padding(.vertical, Spacing.md)
                    } else {

                        if loadingAccounts {
                            ProgressView()
                                .padding(Spacing.md)
                        } else if providerAccounts.isEmpty {
                            VStack(spacing: Spacing.sm) {
                                Image(systemName: "key.fill")
                                    .font(.system(size: 32))
                                    .foregroundColor(.aicovenTextSecondary)
                                Text("No Provider Keys Added")
                                    .font(.aicovenH3)
                                    .foregroundColor(.aicovenTextPrimary)
                                Text("You must add at least one Provider Key before you can configure Strix.")
                                    .font(.aicovenBodySmall)
                                    .foregroundColor(.aicovenTextSecondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.vertical, Spacing.lg)
                            .frame(maxWidth: .infinity)
                            .background(Color.aicovenGlass)
                            .cornerRadius(BorderRadius.md)
                        } else {
                            // Provider selection grouped by provider type
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text("Provider")
                                    .font(.aicovenCaption)
                                    .foregroundColor(.aicovenTextSecondary)

                                let accountsByProvider = Dictionary(grouping: providerAccounts) { $0.provider.lowercased() }

                                ForEach(providerOptions, id: \.0) { option in
                                    let accountsForProvider = accountsByProvider[option.0] ?? []
                                    let isLocal = option.0 == "mlx" || option.0 == "ollama"

                                    if isLocal {
                                        // Local provider – one tap selects provider and model
                                        let isSelected = provider == option.0
                                        Button {
                                            provider = option.0
                                            providerAccountId = nil
                                            if option.0 == "mlx" {
                                                model = MLXModelManager.shared.activeModelID
                                                    ?? MLXModelManager.defaultCatalog.first?.id ?? ""
                                            } else {
                                                model = ollamaModels.first?.0
                                                    ?? UserDefaults.standard.string(forKey: UserScope.scopedKey("ollama_model"))
                                                    ?? "llama3.2"
                                            }
                                        } label: {
                                            HStack {
                                                Image(systemName: "desktopcomputer")
                                                    .foregroundColor(.aicovenTeal)
                                                VStack(alignment: .leading, spacing: Spacing.xxs) {
                                                    Text(option.1)
                                                        .font(.aicovenBody)
                                                        .foregroundColor(.aicovenTextPrimary)
                                                    if isSelected {
                                                        let modelLabel = availableModels.first(where: { $0.0 == model })?.1 ?? model
                                                        Text(modelLabel)
                                                            .font(.aicovenCaption)
                                                            .foregroundColor(.aicovenTextSecondary)
                                                    } else {
                                                        Text(option.0 == "mlx" ? "On-device via Apple Silicon" : "Running locally")
                                                            .font(.aicovenCaption)
                                                            .foregroundColor(.aicovenTextSecondary)
                                                    }
                                                }
                                                Spacer()
                                                if isSelected {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .foregroundColor(.aicovenTeal)
                                                }
                                            }
                                            .padding(Spacing.sm)
                                            .background(isSelected ? Color.aicovenGlass : Color.clear)
                                            .cornerRadius(BorderRadius.sm)
                                        }
                                        .buttonStyle(.plain)
                                    } else if accountsForProvider.count == 1, let account = accountsForProvider.first {
                                        // Single key – one tap selects provider + key
                                        let isSelected = providerAccountId == account.id
                                        Button {
                                            providerAccountId = account.id
                                            provider = account.provider
                                            Task { await loadModelsForAccount(account) }
                                        } label: {
                                            HStack {
                                                VStack(alignment: .leading, spacing: Spacing.xxs) {
                                                    Text(option.1)
                                                        .font(.aicovenBody)
                                                        .foregroundColor(.aicovenTextPrimary)
                                                    Text(account.displayName)
                                                        .font(.aicovenCaption)
                                                        .foregroundColor(.aicovenTextSecondary)
                                                }
                                                Spacer()
                                                if isSelected {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .foregroundColor(.aicovenTeal)
                                                }
                                            }
                                            .padding(Spacing.sm)
                                            .background(isSelected ? Color.aicovenGlass : Color.clear)
                                            .cornerRadius(BorderRadius.sm)
                                        }
                                        .buttonStyle(.plain)
                                    } else if accountsForProvider.count > 1 {
                                        // Multiple keys – show provider header + each key
                                        VStack(alignment: .leading, spacing: Spacing.xs) {
                                            Text(option.1)
                                                .font(.aicovenH3)
                                                .foregroundColor(.aicovenTextSecondary)
                                                .padding(.top, Spacing.sm)
                                            ForEach(accountsForProvider) { account in
                                                Button {
                                                    providerAccountId = account.id
                                                    provider = account.provider
                                                    Task { await loadModelsForAccount(account) }
                                                } label: {
                                                    HStack {
                                                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                                                            Text(account.displayName)
                                                                .font(.aicovenBody)
                                                                .foregroundColor(.aicovenTextPrimary)
                                                            if let modelLabel = accountModelOptions[account.id]?.first(where: { $0.0 == account.defaultModel })?.1 ?? account.defaultModel {
                                                                Text("Model: \(modelLabel)")
                                                                    .font(.aicovenCaption)
                                                                    .foregroundColor(.aicovenTextTertiary)
                                                            }
                                                        }
                                                        Spacer()
                                                        if providerAccountId == account.id {
                                                            Image(systemName: "checkmark.circle.fill")
                                                                .foregroundColor(.aicovenTeal)
                                                        }
                                                    }
                                                    .padding(Spacing.sm)
                                                    .background(providerAccountId == account.id ? Color.aicovenGlass : Color.clear)
                                                    .cornerRadius(BorderRadius.sm)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    }
                                }
                            }

                            // Model picker – only for cloud providers
                            if !isLocalProvider {
                                if !availableModels.isEmpty {
                                    VStack(alignment: .leading, spacing: Spacing.xs) {
                                        Text("Model")
                                            .font(.aicovenCaption)
                                            .foregroundColor(.aicovenTextSecondary)

                                        Menu {
                                            ForEach(availableModels, id: \.0) { option in
                                                Button(option.1) {
                                                    model = option.0
                                                }
                                            }
                                        } label: {
                                            HStack {
                                                let current = availableModels.first(where: { $0.0 == model })
                                                Text(current?.1 ?? model)
                                                    .font(.aicovenBody)
                                                    .foregroundColor(.aicovenTextPrimary)
                                                Spacer()
                                                Image(systemName: "chevron.down")
                                                    .foregroundColor(.aicovenTextSecondary)
                                            }
                                            .padding(Spacing.sm)
                                            .background(Color.aicovenGlass)
                                            .cornerRadius(BorderRadius.sm)
                                        }
                                    }
                                } else if !provider.isEmpty {
                                    VStack(alignment: .leading, spacing: Spacing.xs) {
                                        Text("Model ID")
                                            .font(.aicovenCaption)
                                            .foregroundColor(.aicovenTextSecondary)

                                        TextField("gpt-4o", text: $model)
                                            .font(.aicovenBody)
                                            .foregroundColor(.aicovenTextPrimary)
                                            .padding(Spacing.sm)
                                            .background(Color.aicovenGlass)
                                            .cornerRadius(BorderRadius.sm)
                                            .disableAutocorrection(true)
                                    }
                                }
                            }
                        }
                    } // end else (hasCreator)
                }
            }
            .sheet(isPresented: $showStore) {
                StoreView()
                    .environmentObject(storeService)
            }

            // Autonomous & planner behavior
            GlassCard {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HStack {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text("Autonomous Mode")
                                .font(.aicovenH3)
                                .foregroundColor(.aicovenTextPrimary)

                            Text("Allow Strix to take multiple tool actions in a row when needed.")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextTertiary)
                        }

                        Spacer()

                        Toggle("", isOn: $autonomousMode)
                            .toggleStyle(SwitchToggleStyle(tint: .aicovenTeal))
                            .labelsHidden()
                    }

                    if autonomousMode {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Max autonomous steps")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextSecondary)

                            TextField("5", text: $maxStepsText)
                                .font(.aicovenBody)
                                .foregroundColor(.aicovenTextPrimary)
                                .padding(Spacing.sm)
                                .background(Color.aicovenGlass)
                                .cornerRadius(BorderRadius.sm)
                        }
                    }

                    // Chat tool-calling behavior
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Chat – max tool steps per reply")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)

                        TextField("3", text: $chatMaxToolStepsText)
                            .font(.aicovenBody)
                            .foregroundColor(.aicovenTextPrimary)
                        #if os(iOS)
                            .keyboardType(.numberPad)
                        #endif
                            .padding(Spacing.sm)
                            .background(Color.aicovenGlass)
                            .cornerRadius(BorderRadius.sm)

                        Text("Controls how many times Strix may call tools (web search, current time) in a single reply before answering. Set to 0 or leave blank to use the default (3).")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextTertiary)
                    }

                    // Planner configuration for plan_and_execute
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Planner – max tasks per run")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)

                        TextField("5", text: $plannerMaxTasksText)
                            .font(.aicovenBody)
                            .foregroundColor(.aicovenTextPrimary)
                            .padding(Spacing.sm)
                            .background(Color.aicovenGlass)
                            .cornerRadius(BorderRadius.sm)

                        Text("Planner – time budget (seconds)")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextSecondary)

                        TextField("30", text: $plannerMaxSecondsText)
                            .font(.aicovenBody)
                            .foregroundColor(.aicovenTextPrimary)
                            .padding(Spacing.sm)
                            .background(Color.aicovenGlass)
                            .cornerRadius(BorderRadius.sm)

                        Text("Planner settings only affect plan-and-execute flows; normal single-step replies are unchanged.")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextTertiary)
                            .padding(.top, Spacing.xs)
                    }
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let settings = try await StrixSettingsService.shared.loadPersonalStrix()
            await MainActor.run {
                systemPrompt = settings.systemPrompt ?? "You are Strix, a helpful AI assistant."
                autonomousMode = settings.autonomousMode ?? false
                let steps = settings.autonomousMaxSteps ?? 5
                maxStepsText = String(steps)
                // Hydrate chat tool-step configuration from UserDefaults so the
                // UI matches the current behavior.
                let currentChatSteps = ChatService.currentMaxToolSteps()
                chatMaxToolStepsText = String(currentChatSteps)
                if let plannerTasks = settings.plannerMaxTasks {
                    plannerMaxTasksText = String(plannerTasks)
                }
                if let plannerSeconds = settings.plannerMaxSeconds {
                    plannerMaxSecondsText = String(format: "%.0f", plannerSeconds)
                }
                // Only use persisted model/provider if they exist; otherwise leave
                // as placeholders that will be populated when a provider account is selected.
                // This prevents showing "gpt-4o" in the sidebar when no OpenAI key is configured.
                model = settings.model ?? ""
                provider = settings.provider ?? ""
                providerAccountId = settings.providerAccountId
            }

            // After loading Strix, hydrate available provider accounts so the
            // UI can reflect the bound key and its models.
            await loadProviderAccounts()
        } catch {
            AppErrorReporter.log(error: error, context: "StrixSettingsView.load")
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Load provider accounts and, when possible, align Strix with a real
    /// provider account so that provider/model choices map to an actual key.
    private func loadProviderAccounts() async {
        loadingAccounts = true
        defer { loadingAccounts = false }

        do {
            let accounts = try await ProviderAccountService.shared.loadProviderAccounts()
            providerAccounts = accounts

            // Discover Ollama models in the background regardless of current provider.
            await discoverOllamaModels()

            // If the saved provider is local, keep it — don't override with a cloud account.
            if isLocalProvider {
                return
            }

            // Prefer the account already bound to Strix, if it still exists.
            if let id = providerAccountId,
               let account = accounts.first(where: { $0.id == id }) {
                provider = account.provider
                await loadModelsForAccount(account)
                return
            }

            // Otherwise, fall back to the first healthy account, or the first
            // available one.
            if providerAccountId == nil,
               let account = accounts.first(where: { $0.status == "healthy" }) ?? accounts.first {
                providerAccountId = account.id
                provider = account.provider
                await loadModelsForAccount(account)
            }
        } catch {
            AppErrorReporter.log(error: error, context: "StrixSettingsView.loadProviderAccounts")
        }
    }

    /// Load initialization metadata for a provider account and derive the
    /// list of supported models for use in the model picker.
    private func loadModelsForAccount(_ account: ProviderAccount) async {
        do {
            let status = try await ProviderAccountService.shared.getInitializationStatus(
                accountId: account.id
            )
            let models = status.modelMetadata.map { metadata in
                let label = metadata.name ?? metadata.id
                return (metadata.id, label)
            }
            if !models.isEmpty {
                accountModelOptions[account.id] = models
                if providerAccountId == account.id,
                   !models.contains(where: { $0.0 == model }) {
                    model = models.first?.0 ?? model
                }
            }
        } catch {
            AppErrorReporter.log(error: error, context: "StrixSettingsView.loadModelsForAccount.\(account.id)")
        }
    }

    /// Discover locally available Ollama models via /api/tags.
    private func discoverOllamaModels() async {
        let client = OllamaLLMClient()
        do {
            let models = try await client.discoverModels()
            if !models.isEmpty {
                ollamaModels = models.map { m in
                    (m.name, m.formattedSize.map { s in "\(m.name) (\(s))" } ?? m.name)
                }
                if provider == "ollama", !ollamaModels.contains(where: { $0.0 == model }) {
                    model = ollamaModels.first?.0 ?? model
                }
            }
        } catch {
            // Ollama not running or unreachable — keep fallback
        }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let trimmedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let steps = Int(maxStepsText) ?? 5
        let rawPlannerTasks = Int(plannerMaxTasksText) ?? 5

        // Normalize chat tool step configuration into a small bounded range.
        let rawChatSteps = Int(chatMaxToolStepsText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let chatSteps = max(0, min(10, rawChatSteps))
        let plannerTasks = max(1, min(10, rawPlannerTasks))
        let rawPlannerSeconds = Double(plannerMaxSecondsText) ?? 30.0
        let plannerSeconds = max(5.0, min(120.0, rawPlannerSeconds))

        // Only persist model/provider if they are non-empty; otherwise pass nil
        // so that the sidebar doesn't show a hardcoded default like "gpt-4o".
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            _ = try await StrixSettingsService.shared.updatePersonalStrix(
                systemPrompt: trimmedPrompt.isEmpty ? nil : trimmedPrompt,
                model: trimmedModel.isEmpty ? nil : trimmedModel,
                provider: trimmedProvider.isEmpty ? nil : trimmedProvider,
                providerAccountId: providerAccountId,
                autonomousMode: autonomousMode,
                autonomousMaxSteps: steps,
                plannerMaxTasks: plannerTasks,
                plannerMaxSeconds: plannerSeconds
            )

            // Persist chat tool-step budget so ChatService.streamMessage picks
            // it up on the next turn.
            UserDefaults.standard.set(chatSteps, forKey: "chat_max_tool_steps")

            await MainActor.run {
                onClose?()
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    StrixSettingsView()
}
