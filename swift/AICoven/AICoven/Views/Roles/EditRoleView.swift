import SwiftUI

/// View for editing an existing agent role
struct EditRoleView: View {
    let roleId: String
    let roles: [Role]  // All roles for collaborator selection
    let onComplete: () -> Void
    
    private let analytics = AnalyticsService.shared
    
    @State private var loading = true
    @State private var role: Role?
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
    @State private var showDeleteConfirmation = false
    @State private var deleting = false
    
    // Provider accounts state
    @State private var providerAccounts: [ProviderAccount] = []
    @State private var loadingAccounts = false
    
    /// Per-account model options derived from initialization metadata.
    /// Keyed by provider account ID.
    @State private var accountModelOptions: [String: [(String, String)]] = [:]
    
    // Tools state
    @State private var selectedTools: Set<String> = []
    
    // Collaborators state
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
        Group {
            if loading {
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
                        // Header
                        VStack(spacing: Spacing.sm) {
                            IconBadge(icon: "pencil.circle", size: 60, color: .aicovenPurple)
                            
                            Text("Edit Agent Role")
                                .font(.aicovenDisplaySmall)
                                .foregroundColor(.aicovenTextPrimary)
                            
                            Text("Update role configuration")
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
                                    // Provider
                                    VStack(alignment: .leading, spacing: Spacing.sm) {
                                        Text("Provider")
                                            .font(.aicovenH3)
                                            .foregroundColor(.aicovenTextPrimary)
                                        
                                        ForEach(providerOptions, id: \.0) { option in
                                            Button {
                                                provider = option.0
                                                providerAccountId = nil

                                                if let firstModel = availableModels.first {
                                                    model = firstModel.0
                                                }
                                            } label: {
                                                HStack {
                                                    Text(option.1)
                                                        .font(.aicovenBody)
                                                        .foregroundColor(.aicovenTextPrimary)
                                                    
                                                    Spacer()
                                                    
                                                    if provider == option.0 {
                                                        Image(systemName: "checkmark.circle.fill")
                                                            .foregroundColor(.aicovenTeal)
                                                    }
                                                }
                                                .padding(Spacing.sm)
                                                .background(provider == option.0 ? Color.aicovenGlass : Color.clear)
                                                .cornerRadius(BorderRadius.sm)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    
                                    // Provider Account (API key selection)
                                    VStack(alignment: .leading, spacing: Spacing.sm) {
                                        Text("Provider Account")
                                            .font(.aicovenH3)
                                            .foregroundColor(.aicovenTextPrimary)
                                        
                                        Text("Choose which API key this role should use")
                                            .font(.aicovenCaption)
                                            .foregroundColor(.aicovenTextTertiary)
                                        
                                        if isLocalProvider {
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
                                            let matchingAccounts = providerAccounts.filter { $0.provider.lowercased() == provider.lowercased() }
                                            let accountsToShow = matchingAccounts.isEmpty ? providerAccounts : matchingAccounts

                                            ForEach(accountsToShow) { account in
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
                                        
                                        Slider(value: $temperature, in: 0...2, step: 0.1)
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
                        }
                        .padding(.horizontal, Spacing.lg)
                        
                        // Action buttons
                        VStack(spacing: Spacing.md) {
                            // Save button
                            GradientButton("Save Changes", icon: "checkmark.circle.fill", style: .primary) {
                                Task {
                                    await saveRole()
                                }
                            }
                            .disabled(name.isEmpty || saving)
                            
                            // Delete button
                            Button {
                                showDeleteConfirmation = true
                            } label: {
                                HStack {
                                    Image(systemName: "trash")
                                    Text("Delete Role")
                                }
                                .font(.aicovenBody)
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity)
                                .padding(Spacing.md)
                                .background(Color.aicovenGlass)
                                .cornerRadius(BorderRadius.md)
                            }
                            .buttonStyle(.plain)
                            .disabled(deleting)
                        }
                        .padding(.horizontal, Spacing.lg)
                        .padding(.bottom, Spacing.xl)
                    }
                }
                .background(NebulaBackground())
            }
        }
        // Re-load whenever roleId changes (e.g., multiple edit tabs)
        .task(id: roleId) {
            await loadRole()
            await MainActor.run {
                analytics.trackScreenView(screenName: "EditRoleView", screenClass: "EditRoleView")
                analytics.trackRoleView(roleId: roleId)
            }
        }
        .alert("Delete Role", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    await deleteRole()
                }
            }
        } message: {
            Text("Are you sure you want to delete this role? This action cannot be undone.")
        }
    }
    
    /// Load role data
    private func loadRole() async {
        print("🔍 EditRoleView loading role with ID: \(roleId)")
        loading = true
        
        // Load provider accounts
        do {
            providerAccounts = try await ProviderAccountService.shared.loadProviderAccounts()
        } catch {
            print("❌ Failed to load provider accounts: \(error.localizedDescription)")
        }
        
        // Load role
        do {
            role = try await RoleService.shared.getRole(roleId: roleId)
            print("✅ Loaded role: \(role?.name ?? "unknown") with ID: \(role?.id ?? "unknown")")
            
            // Populate form fields
            if let role = role {
                name = role.name
                emoji = role.emoji ?? "🤖"
                description = role.description ?? ""
                systemPrompt = role.systemPrompt ?? ""
                model = role.model ?? "gpt-4o"
                provider = role.provider ?? "openai"
                providerAccountId = role.providerAccountId
                temperature = role.temperature ?? 0.7
                maxTokens = String(role.maxTokens ?? 2000)
                
                // Populate tools, collaborators, and autonomous config from settings
                if let settings = role.settings {
                    if let tools = settings.allowedTools {
                        selectedTools = Set(tools)
                    }
                    if let collaborators = settings.collaboratorRoleIds {
                        selectedCollaborators = Set(collaborators)
                    }
                    if let mode = settings.autonomousMode {
                        autonomousMode = mode
                    }
                    if let steps = settings.autonomousMaxSteps {
                        autonomousMaxSteps = String(steps)
                    }
                    if let plannerTasks = settings.plannerMaxTasks {
                        plannerMaxTasks = String(plannerTasks)
                    }
                    if let plannerSeconds = settings.plannerMaxSeconds {
                        plannerMaxSeconds = String(format: "%.0f", plannerSeconds)
                    }
                }
                
                // Hydrate dynamic model options for the linked provider account
                if let accountId = providerAccountId,
                   let account = providerAccounts.first(where: { $0.id == accountId }) {
                    await loadModelsForAccount(account)
                }
            }
        } catch {
            print("❌ Failed to load role: \(error.localizedDescription)")
        }
        
        loading = false
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
    
    /// Save role changes
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
            _ = try await RoleService.shared.updateRole(
                roleId: roleId,
                name: name,
                emoji: emoji,
                description: description.isEmpty ? nil : description,
                systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
                model: model,
                provider: provider,
                providerAccountId: providerAccountId,
                temperature: temperature,
                maxTokens: maxTokensInt,
                allowedTools: Array(selectedTools),
                collaboratorRoleIds: Array(selectedCollaborators),
                autonomousMode: autonomousMode,
                autonomousMaxSteps: stepsInt,
                plannerMaxTasks: plannerTasksInt,
                plannerMaxSeconds: plannerSecondsDouble
            )
            
            analytics.trackRoleUpdate(roleId: roleId, field: "all")
            onComplete()
        } catch {
            print("❌ Failed to update role: \(error.localizedDescription)")
            analytics.trackError(errorType: "role_update", errorMessage: error.localizedDescription, context: "EditRoleView")
        }
    }
    
    /// Delete role
    private func deleteRole() async {
        deleting = true
        defer { deleting = false }
        
        do {
            try await RoleService.shared.deleteRole(roleId: roleId)
            analytics.trackRoleDelete(roleId: roleId)
            onComplete()
        } catch {
            print("❌ Failed to delete role: \(error.localizedDescription)")
            analytics.trackError(errorType: "role_delete", errorMessage: error.localizedDescription, context: "EditRoleView")
        }
    }
}
