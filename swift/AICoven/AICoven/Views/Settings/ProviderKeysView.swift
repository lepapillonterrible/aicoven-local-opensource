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
        .background(NebulaBackground())
        .sheet(isPresented: $showAddSheet) {
            AddProviderKeySheet {
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
    
    // Load provider accounts
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
    
    // Delete provider account
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
    
    var providerInfo: (icon: String, name: String, color: Color) {
        switch account.provider.lowercased() {
        case "openai": return ("🤖", "OpenAI", .aicovenTeal)
        case "google": return ("🔵", "Google AI", .blue)
        case "anthropic": return ("🟣", "Anthropic", .aicovenPurple)
        case "cohere": return ("🧠", "Cohere", .aicovenPink)
        case "mistral": return ("🌬️", "Mistral AI", .cyan)
        case "ollama": return ("🦙", "Ollama (Local)", .orange)
        default: return ("🔑", account.provider, .aicovenTeal)
        }
    }
    
    var statusColor: Color {
        switch account.status {
        case "healthy": return .green
        case "unhealthy": return .red
        case "pending": return .orange
        default: return .gray
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
                
                // Actions
                HStack(spacing: Spacing.sm) {
                    Button("Test") {
                        // Test connection
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    
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
}

/// Add provider key sheet
struct AddProviderKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    let onComplete: () -> Void
    
    @State private var selectedProvider = "openai"
    @State private var displayName = ""
    @State private var apiKey = ""
    @State private var baseURL = "http://localhost:11434"
    @State private var saving = false
    @State private var isLoadingModels = false
    @State private var ollamaModels: [OllamaLLMClient.OllamaModel] = []
    @State private var selectedOllamaModel: String = ""
    @State private var connectionTestResult: (success: Bool, message: String)? = nil
    
    private var isOllama: Bool { selectedProvider == "ollama" }
    
    let providers = [
        ("openai", "OpenAI", "🤖"),
        ("anthropic", "Anthropic Claude", "🟣"),
        ("google", "Google Gemini", "🔵"),
        ("mistral", "Mistral AI", "🌬️"),
        ("cohere", "Cohere", "🧠"),
        ("ollama", "Ollama (Local)", "🦙")
    ]
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    // Provider selection
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("Provider")
                            .font(.aicovenH3)
                            .foregroundColor(.aicovenTextPrimary)
                        
                        ForEach(providers, id: \.0) { provider in
                            Button {
                                selectedProvider = provider.0
                                // Reset Ollama state when switching
                                if provider.0 != "ollama" {
                                    ollamaModels = []
                                    connectionTestResult = nil
                                }
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
                    
                    // Display name
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("Display Name")
                            .font(.aicovenH3)
                            .foregroundColor(.aicovenTextPrimary)
                        
                        TextField(isOllama ? "My Ollama" : "My API Key", text: $displayName)
                            .font(.aicovenBody)
                            .foregroundColor(.aicovenTextPrimary)
                            .padding(Spacing.md)
                            .background(Color.aicovenGlass)
                            .cornerRadius(BorderRadius.md)
                    }
                    
                    if isOllama {
                        ollamaConfigSection
                    } else {
                        // API key (cloud providers)
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
                            
                            Text("🔒 Your API key is encrypted and stored securely")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextSecondary)
                        }
                    }
                    
                    // Save button
                    GradientButton(isOllama ? "Add Ollama" : "Add Provider Key", icon: "checkmark.circle.fill", style: .primary) {
                        Task {
                            await saveProviderKey()
                        }
                    }
                    .disabled(saveDisabled)
                }
                .padding(Spacing.lg)
            }
            .background(Color.aicovenDark)
            .navigationTitle("Add Provider Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private var saveDisabled: Bool {
        if saving { return true }
        if displayName.isEmpty { return true }
        if isOllama {
            return baseURL.isEmpty || selectedOllamaModel.isEmpty
        } else {
            return apiKey.isEmpty
        }
    }
    
    // MARK: - Ollama config section
    
    private var ollamaConfigSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Base URL
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
            
            // Connection test result
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
            
            // Model picker (shown after successful connection)
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
    
    private func testOllamaConnection() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        
        let client = OllamaLLMClient(baseURL: URL(string: baseURL) ?? OllamaLLMClient.defaultBaseURL)
        let connected = await client.testConnection()
        
        if connected {
            do {
                let models = try await client.discoverModels()
                ollamaModels = models
                if let first = models.first {
                    selectedOllamaModel = first.name
                }
                connectionTestResult = (true, "Connected! Found \(models.count) model(s).")
            } catch {
                connectionTestResult = (false, "Connected but failed to list models: \(error.localizedDescription)")
            }
        } else {
            connectionTestResult = (false, "Cannot connect to \(baseURL). Is Ollama running?")
        }
    }
    
    // Save provider key
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

/// Simple callout card used on home views when no provider keys are configured
struct AddProviderKeysCard: View {
    let onOpenProviderKeys: () -> Void
    
    @State private var hasCheckedAccounts = false
    @State private var shouldShow = false
    
    var body: some View {
        Group {
            if hasCheckedAccounts && shouldShow {
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
                
                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += lineHeight + spacing
                    lineHeight = 0
                }
                
                frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
                lineHeight = max(lineHeight, size.height)
                x += size.width + spacing
            }
            
            self.size = CGSize(width: maxWidth, height: y + lineHeight)
        }
    }
}

// Button styles
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
