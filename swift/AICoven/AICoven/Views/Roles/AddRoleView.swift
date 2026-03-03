import SwiftUI

/// View for creating a new agent role
struct AddRoleView: View {
    let covenId: String
    let roles: [Role] // Existing roles for collaborator selection
    let onComplete: () -> Void

    private let analytics = AnalyticsService.shared

    // Basic fields
    @State private var name = ""
    @State private var emoji = "🤖"
    @State private var description = ""
    @State private var systemPrompt = ""
    @State private var model = "gpt-4o"
    @State private var provider = "openai"
    @State private var providerAccountId: String? = nil
    @State private var temperature: Double = 0.7
    @State private var maxTokens = "2000"
    @State private var saving = false
    @State private var autonomousMode = false
    @State private var autonomousMaxSteps = "5"
    /// Planner configuration (plan_and_execute)
    @State private var plannerMaxTasks = "5"
    @State private var plannerMaxSeconds = "30"
    @State private var showEmojiPicker = false

    // Template state
    @State private var templates: [RoleTemplate] = []
    @State private var selectedTemplateId: String? = nil
    @State private var loadingTemplates = false

    // Provider accounts state
    @State private var providerAccounts: [ProviderAccount] = []
    @State private var loadingAccounts = false

    /// Per-account model options derived from initialization metadata.
    /// Keyed by provider account ID.
    @State private var accountModelOptions: [String: [(String, String)]] = [:]

    /// Dynamically discovered Ollama models (from /api/tags).
    @State private var ollamaModels: [(String, String)] = []

    /// Collaborators state
    @State private var selectedCollaborators: Set<String> = []

    let emojiOptions = ["🤖", "🧠", "💡", "🎨", "📝", "🔍", "⚙️", "📊", "🚀", "💬", "🎯", "🔬", "📚", "✨", "🌟", "🎭"]
    let providerOptions = [
        ("openai", "OpenAI"),
        ("anthropic", "Anthropic"),
        ("google", "Google AI"),
        ("ollama", "Ollama (Local)"),
        ("mlx", "MLX (On-Device)")
    ]

    /// Whether the selected provider is local (no API key needed).
    var isLocalProvider: Bool {
        provider == "mlx" || provider == "ollama"
    }

    var availableModels: [(String, String)] {
        // Local providers: return models from local catalog.
        if provider == "mlx" {
            return MLXModelManager.defaultCatalog.map { ($0.id, $0.displayName) }
        }
        if provider == "ollama" {
            if !ollamaModels.isEmpty {
                return ollamaModels
            }
            // Fallback to the configured default while discovery is in progress
            let ollamaModel = UserDefaults.standard.string(forKey: UserScope.scopedKey("ollama_model")) ?? "llama3.2"
            return [(ollamaModel, ollamaModel)]
        }
        // Cloud providers: use dynamically discovered models.
        if let accountId = providerAccountId,
           let dynamic = accountModelOptions[accountId],
           !dynamic.isEmpty {
            return dynamic
        }
        return []
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                // Header
                VStack(spacing: Spacing.sm) {
                    IconBadge(icon: "person.badge.plus", size: 60, color: .aicovenTeal)

                    Text("Create Agent Role")
                        .font(.aicovenDisplaySmall)
                        .foregroundColor(.aicovenTextPrimary)

                    Text("Configure a new AI agent for this coven")
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextSecondary)
                }
                .padding(.top, Spacing.xl)

                // Form
                VStack(spacing: Spacing.lg) {
                    // Basic info
                    GlassCard {
                        VStack(spacing: Spacing.md) {
                            // Emoji picker
                            VStack(alignment: .leading, spacing: Spacing.sm) {
                                Text("Icon")
                                    .font(.aicovenH3)
                                    .foregroundColor(.aicovenTextPrimary)

                                Button {
                                    showEmojiPicker.toggle()
                                } label: {
                                    Text(emoji)
                                        .font(.system(size: 48))
                                        .frame(width: 80, height: 80)
                                        .background(Color.aicovenGlass)
                                        .cornerRadius(BorderRadius.md)
                                }
                                .buttonStyle(.plain)

                                if showEmojiPicker {
                                    FlowLayout(spacing: Spacing.sm) {
                                        ForEach(emojiOptions, id: \.self) { option in
                                            Button {
                                                emoji = option
                                                showEmojiPicker = false
                                            } label: {
                                                Text(option)
                                                    .font(.system(size: 32))
                                                    .frame(width: 50, height: 50)
                                                    .background(emoji == option ? Color.aicovenGlass : Color.clear)
                                                    .cornerRadius(BorderRadius.sm)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }

                            // Name
                            FormField(label: "Name", text: $name, placeholder: "Code Assistant")

                            // Description
                            FormField(label: "Description", text: $description, placeholder: "Helps with coding tasks and reviews", multiline: true)
                        }
                    }

                    // Template selector
                    GlassCard {
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            Text("Role Template (Optional)")
                                .font(.aicovenH3)
                                .foregroundColor(.aicovenTextPrimary)

                            Text("Start from a pre-made template or build from scratch")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextTertiary)

                            if loadingTemplates {
                                ProgressView()
                                    .padding(Spacing.md)
                            } else if templates.isEmpty {
                                Text("No templates available")
                                    .font(.aicovenBody)
                                    .foregroundColor(.aicovenTextTertiary)
                                    .padding(Spacing.md)
                            } else {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: Spacing.sm) {
                                        // None option
                                        Button {
                                            selectedTemplateId = nil
                                        } label: {
                                            VStack {
                                                Text("✨")
                                                    .font(.system(size: 32))
                                                Text("From Scratch")
                                                    .font(.aicovenCaption)
                                                    .foregroundColor(.aicovenTextSecondary)
                                            }
                                            .frame(width: 100, height: 80)
                                            .background(selectedTemplateId == nil ? Color.aicovenGlass : Color.clear)
                                            .cornerRadius(BorderRadius.md)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: BorderRadius.md)
                                                    .stroke(selectedTemplateId == nil ? Color.aicovenTeal : Color.clear, lineWidth: 2)
                                            )
                                        }
                                        .buttonStyle(.plain)

                                        ForEach(templates) { template in
                                            Button {
                                                selectedTemplateId = template.id
                                                Task {
                                                    await loadTemplate(template.id)
                                                }
                                            } label: {
                                                VStack {
                                                    Text(template.emoji ?? "📝")
                                                        .font(.system(size: 32))
                                                    Text(template.name)
                                                        .font(.aicovenCaption)
                                                        .foregroundColor(.aicovenTextSecondary)
                                                        .lineLimit(2)
                                                        .multilineTextAlignment(.center)
                                                }
                                                .frame(width: 100, height: 80)
                                                .background(selectedTemplateId == template.id ? Color.aicovenGlass : Color.clear)
                                                .cornerRadius(BorderRadius.md)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: BorderRadius.md)
                                                        .stroke(selectedTemplateId == template.id ? Color.aicovenTeal : Color.clear, lineWidth: 2)
                                                )
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.vertical, Spacing.sm)
                                }
                            }
                        }
                    }

                    // System prompt
                    GlassCard {
                        VStack(spacing: Spacing.sm) {
                            Text("System Prompt")
                                .font(.aicovenH3)
                                .foregroundColor(.aicovenTextPrimary)

                            TextEditor(text: $systemPrompt)
                                .font(.aicovenBody)
                                .foregroundColor(.aicovenTextPrimary)
                                .frame(minHeight: 150)
                                .padding(Spacing.sm)
                                .background(Color.aicovenGlass)
                                .cornerRadius(BorderRadius.md)
                                .scrollContentBackground(.hidden)

                            Text("Define the role's behavior, personality, and capabilities")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextTertiary)
                        }
                    }

                    // Model configuration
                    GlassCard {
                        VStack(spacing: Spacing.md) {
                            // Provider Account
                            VStack(alignment: .leading, spacing: Spacing.sm) {
                                Text("Provider Account")
                                    .font(.aicovenH3)
                                    .foregroundColor(.aicovenTextPrimary)

                                Text("Select which API key to use for this role")
                                    .font(.aicovenCaption)
                                    .foregroundColor(.aicovenTextTertiary)

                                if isLocalProvider {
                                    // Local providers don't need account selection.
                                    HStack(spacing: Spacing.sm) {
                                        Image(systemName: "desktopcomputer")
                                            .foregroundColor(.aicovenTeal)
                                        Text(provider == "mlx" ? "Running on-device via Apple Silicon" : "Running locally via Ollama")
                                            .font(.aicovenBody)
                                            .foregroundColor(.aicovenTextSecondary)
                                    }
                                    .padding(Spacing.sm)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.aicovenGlass)
                                    .cornerRadius(BorderRadius.sm)
                                } else if loadingAccounts {
                                    ProgressView()
                                        .padding(Spacing.md)
                                } else if providerAccounts.isEmpty {
                                    Text("No provider accounts found. Add one in Settings.")
                                        .font(.aicovenBody)
                                        .foregroundColor(.aicovenTextTertiary)
                                        .padding(Spacing.md)
                                } else {
                                    let accountsByProvider = Dictionary(grouping: providerAccounts) { $0.provider.lowercased() }
                                    ForEach(providerOptions, id: \.0) { option in
                                        let accountsForProvider = accountsByProvider[option.0] ?? []
                                        if !accountsForProvider.isEmpty {
                                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                                Text(option.1)
                                                    .font(.aicovenH3)
                                                    .foregroundColor(.aicovenTextSecondary)
                                                    .padding(.top, Spacing.sm)
                                                ForEach(accountsForProvider) { account in
                                                    Button {
                                                        providerAccountId = account.id
                                                        provider = account.provider
                                                        Task {
                                                            await loadModelsForAccount(account)
                                                        }
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
                            }

                            // Model
                            VStack(alignment: .leading, spacing: Spacing.sm) {
                                Text("Model")
                                    .font(.aicovenH3)
                                    .foregroundColor(.aicovenTextPrimary)

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

                            // Temperature
                            VStack(alignment: .leading, spacing: Spacing.sm) {
                                HStack {
                                    Text("Temperature")
                                        .font(.aicovenH3)
                                        .foregroundColor(.aicovenTextPrimary)

                                    Spacer()

                                    Text(String(format: "%.1f", temperature))
                                        .font(.aicovenBody)
                                        .foregroundColor(.aicovenTextSecondary)
                                }

                                Slider(value: $temperature, in: 0 ... 2, step: 0.1)
                                    .tint(.aicovenTeal)

                                Text("Lower = more focused, Higher = more creative")
                                    .font(.aicovenCaption)
                                    .foregroundColor(.aicovenTextTertiary)
                            }

                            // Max tokens
                            FormField(label: "Max Tokens", text: $maxTokens, placeholder: "2000")

                            // Autonomous & planner behavior
                            VStack(alignment: .leading, spacing: Spacing.sm) {
                                HStack {
                                    Text("Autonomous Mode")
                                        .font(.aicovenH3)
                                        .foregroundColor(.aicovenTextPrimary)

                                    Spacer()

                                    Toggle("", isOn: $autonomousMode)
                                        .toggleStyle(SwitchToggleStyle(tint: .aicovenTeal))
                                        .labelsHidden()
                                }

                                if autonomousMode {
                                    FormField(
                                        label: "Max autonomous steps",
                                        text: $autonomousMaxSteps,
                                        placeholder: "5"
                                    )
                                }

                                // Planner settings apply to plan_and_execute flows
                                VStack(alignment: .leading, spacing: Spacing.xs) {
                                    Text("Planner – max tasks per run")
                                        .font(.aicovenCaption)
                                        .foregroundColor(.aicovenTextSecondary)
                                    TextField("5", text: $plannerMaxTasks)
                                        .font(.aicovenBody)
                                        .foregroundColor(.aicovenTextPrimary)
                                        .padding(Spacing.sm)
                                        .background(Color.aicovenGlass)
                                        .cornerRadius(BorderRadius.sm)

                                    Text("Planner – time budget (seconds)")
                                        .font(.aicovenCaption)
                                        .foregroundColor(.aicovenTextSecondary)
                                    TextField("30", text: $plannerMaxSeconds)
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

                    // Collaborators
                    if !roles.isEmpty {
                        GlassCard {
                            VStack(alignment: .leading, spacing: Spacing.sm) {
                                Text("Collaborator Roles")
                                    .font(.aicovenH3)
                                    .foregroundColor(.aicovenTextPrimary)

                                Text("Select which other roles this agent can coordinate with")
                                    .font(.aicovenCaption)
                                    .foregroundColor(.aicovenTextTertiary)

                                ForEach(roles) { role in
                                    Button {
                                        if selectedCollaborators.contains(role.id) {
                                            selectedCollaborators.remove(role.id)
                                        } else {
                                            selectedCollaborators.insert(role.id)
                                        }
                                    } label: {
                                        HStack(spacing: Spacing.sm) {
                                            Image(systemName: selectedCollaborators.contains(role.id) ? "checkmark.square.fill" : "square")
                                                .foregroundColor(selectedCollaborators.contains(role.id) ? .aicovenTeal : .aicovenTextTertiary)

                                            if let emoji = role.emoji {
                                                Text(emoji)
                                                    .font(.system(size: 16))
                                            }

                                            Text(role.name)
                                                .font(.aicovenBody)
                                                .foregroundColor(.aicovenTextPrimary)

                                            Spacer()
                                        }
                                        .padding(.vertical, Spacing.xs)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Spacing.lg)

                // Save button
                GradientButton("Create Agent Role", icon: "checkmark.circle.fill", style: .primary) {
                    Task {
                        await saveRole()
                    }
                }
                .disabled(name.isEmpty || saving)
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.xl)
            }
        }
        .background(NebulaBackground())
        .onAppear {
            analytics.trackScreenView(screenName: "AddRoleView", screenClass: "AddRoleView")
            Task {
                await loadData()
                await discoverOllamaModels()
            }
        }
    }

    /// Load templates and provider accounts
    private func loadData() async {
        // Load templates
        loadingTemplates = true
        do {
            templates = try await RoleTemplateService.shared.loadTemplates()
        } catch {
            print("❌ Failed to load templates: \(error.localizedDescription)")
        }
        loadingTemplates = false

        // Load provider accounts
        loadingAccounts = true
        do {
            providerAccounts = try await ProviderAccountService.shared.loadProviderAccounts()
            // Set first healthy account as default
            if let firstAccount = providerAccounts.first(where: { $0.status == "healthy" }) ?? providerAccounts.first {
                providerAccountId = firstAccount.id
                provider = firstAccount.provider
                await loadModelsForAccount(firstAccount)
            }
        } catch {
            print("❌ Failed to load provider accounts: \(error.localizedDescription)")
        }
        loadingAccounts = false
    }

    /// Discover locally available Ollama models via /api/tags.
    private func discoverOllamaModels() async {
        let client = OllamaLLMClient()
        do {
            let models = try await client.discoverModels()
            if !models.isEmpty {
                ollamaModels = models.map { m in (m.name, m.formattedSize.map { s in "\(m.name) (\(s))" } ?? m.name) }
                // If current model isn't in the discovered list, default to first
                if provider == "ollama", !ollamaModels.contains(where: { $0.0 == model }) {
                    model = ollamaModels.first?.0 ?? model
                }
            }
        } catch {
            // Ollama not running or unreachable — keep fallback
            print("⚠️ Could not discover Ollama models: \(error.localizedDescription)")
        }
    }

    /// Load initialization metadata for a provider account
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
            print("⚠️ Failed to load initialization status for account \(account.id): \(error.localizedDescription)")
        }
    }

    /// Load template and populate form
    private func loadTemplate(_ templateId: String) async {
        do {
            let template = try await RoleTemplateService.shared.getTemplate(templateId)
            name = template.role.name
            emoji = template.role.emoji ?? "🤖"
            description = template.purpose.joined(separator: "\n")
            systemPrompt = template.systemPrompt ?? ""

            // Tool policy from templates is no longer used;
            // all tools are enabled by default.
        } catch {
            print("❌ Failed to load template: \(error.localizedDescription)")
        }
    }

    /// Save the new role
    private func saveRole() async {
        guard let maxTokensInt = Int(maxTokens) else { return }

        saving = true
        defer { saving = false }

        do {
            let stepsInt = Int(autonomousMaxSteps) ?? 5
            let rawPlannerTasks = Int(plannerMaxTasks) ?? 5
            let plannerTasksInt = max(1, min(10, rawPlannerTasks))
            let rawPlannerSeconds = Double(plannerMaxSeconds) ?? 30.0
            let plannerSecondsDouble = max(5.0, min(120.0, rawPlannerSeconds))
            let createdRole = try await RoleService.shared.createRole(
                covenId: covenId,
                name: name,
                emoji: emoji,
                description: description.isEmpty ? nil : description,
                systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
                model: model,
                provider: provider,
                providerAccountId: providerAccountId,
                temperature: temperature,
                maxTokens: maxTokensInt,
                allowedTools: nil,
                collaboratorRoleIds: Array(selectedCollaborators),
                autonomousMode: autonomousMode,
                autonomousMaxSteps: stepsInt,
                plannerMaxTasks: plannerTasksInt,
                plannerMaxSeconds: plannerSecondsDouble
            )

            analytics.trackRoleCreate(roleId: createdRole.id, templateId: selectedTemplateId, isCustom: selectedTemplateId == nil)
            onComplete()
        } catch {
            print("❌ Failed to create role: \(error.localizedDescription)")
            analytics.trackError(errorType: "role_create", errorMessage: error.localizedDescription, context: "AddRoleView")
        }
    }
}

/// Reusable form field component
struct FormField: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    var multiline: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(label)
                .font(.aicovenH3)
                .foregroundColor(.aicovenTextPrimary)

            if multiline {
                TextEditor(text: $text)
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextPrimary)
                    .frame(minHeight: 80)
                    .padding(Spacing.sm)
                    .background(Color.aicovenGlass)
                    .cornerRadius(BorderRadius.md)
                    .scrollContentBackground(.hidden)
            } else {
                TextField(placeholder, text: $text)
                    .font(.aicovenBody)
                    .foregroundColor(.aicovenTextPrimary)
                    .padding(Spacing.md)
                    .background(Color.aicovenGlass)
                    .cornerRadius(BorderRadius.md)
            }
        }
    }
}
