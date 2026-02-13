import SwiftUI

// Uses shared budget/usage model types defined in UsageModels.swift

/// Budget management view
struct BudgetView: View {
    @State private var budgets: [String: BudgetResponse] = [:] // provider -> budget
    @State private var remaining: [String: RemainingResponse] = [:] // provider -> remaining
    @State private var availableProviders: [String] = []
    @State private var loading = true
    @State private var editingProvider: String?
    @State private var editAmount = ""
    @State private var editHardCap = false
    @State private var saving = false

    var isEmbedded: Bool = false

    let allProviders = ["openai", "anthropic", "google", "mistral", "cohere"]

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                // Header
                if !isEmbedded {
                    VStack(spacing: Spacing.sm) {
                        IconBadge(icon: "dollarsign.circle.fill", size: 60, color: .aicovenPink)

                        Text("Budgets")
                            .font(.aicovenDisplaySmall)
                            .foregroundColor(.aicovenTextPrimary)

                        Text("Set monthly spending limits per provider")
                            .font(.aicovenBody)
                            .foregroundColor(.aicovenTextSecondary)
                    }
                    .padding(.top, Spacing.xl)
                }

                if loading {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.aicovenTeal)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 50)
                } else if availableProviders.isEmpty {
                    // Empty state
                    emptyState
                } else {
                    // Budget cards
                    VStack(spacing: Spacing.md) {
                        ForEach(availableProviders, id: \.self) { provider in
                            BudgetCard(
                                provider: provider,
                                budget: budgets[provider],
                                remaining: remaining[provider],
                                isEditing: editingProvider == provider,
                                editAmount: $editAmount,
                                editHardCap: $editHardCap,
                                onEdit: {
                                    startEditing(provider)
                                },
                                onSave: {
                                    Task {
                                        await saveBudget(provider)
                                    }
                                },
                                onCancel: {
                                    editingProvider = nil
                                }
                            )
                        }
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.bottom, Spacing.xl)
                }
            }
        }
        // Only apply background if not embedded to avoid a separate-looking background
        .background(isEmbedded ? nil : NebulaBackground())
        .task {
            await loadBudgets()
        }
    }

    var emptyState: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "dollarsign.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.aicovenPink.opacity(0.6))

            Text("No Providers Configured")
                .font(.aicovenH2)
                .foregroundColor(.aicovenTextPrimary)

            Text("Add provider keys to set budgets for each AI provider")
                .font(.aicovenBody)
                .foregroundColor(.aicovenTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .padding(Spacing.xxl)
    }

    /// Start editing a budget
    private func startEditing(_ provider: String) {
        editingProvider = provider
        editAmount = budgets[provider].map { String(format: "%.2f", $0.amountUsd) } ?? ""
        editHardCap = budgets[provider]?.hardCap ?? false
    }

    /// Load budgets and available providers
    private func loadBudgets() async {
        loading = true
        defer { loading = false }

        do {
            // Load provider accounts to see which providers are available.
            let accounts = try await ProviderAccountService.shared.loadProviderAccounts()
            let providers = Set(accounts.map { $0.provider.lowercased() })
            availableProviders = allProviders.filter { providers.contains($0) }

            // Load locally stored budgets.
            let budgetList = try await UsageService.shared.getAllBudgets()
            budgets = Dictionary(uniqueKeysWithValues: budgetList.map { ($0.provider, $0) })

            // Load remaining for each provider based on local usage data.
            for provider in availableProviders {
                do {
                    let rem = try await UsageService.shared.getRemainingBudget(provider: provider)
                    remaining[provider] = rem
                } catch {
                    AppErrorReporter.log(error: error, context: "BudgetView.loadBudgets.getRemainingBudget.\(provider)")
                }
            }

        } catch {
            AppErrorReporter.log(error: error, context: "BudgetView.loadBudgets")
        }
    }

    /// Save budget
    private func saveBudget(_ provider: String) async {
        guard let amount = Double(editAmount), amount > 0 else { return }

        saving = true
        defer { saving = false }

        do {
            _ = try await UsageService.shared.setBudget(
                provider: provider,
                amountUsd: amount,
                hardCap: editHardCap
            )

            editingProvider = nil
            await loadBudgets()

        } catch {
            AppErrorReporter.log(error: error, context: "BudgetView.saveBudget")
        }
    }
}

/// Budget card for individual provider
struct BudgetCard: View {
    let provider: String
    let budget: BudgetResponse?
    let remaining: RemainingResponse?
    let isEditing: Bool
    @Binding var editAmount: String
    @Binding var editHardCap: Bool
    let onEdit: () -> Void
    let onSave: () -> Void
    let onCancel: () -> Void

    var providerInfo: (icon: String, name: String, color: Color) {
        switch provider {
        case "openai": ("🤖", "OpenAI", .aicovenTeal)
        case "google": ("🔵", "Google AI", .blue)
        case "anthropic": ("🟣", "Anthropic", .aicovenPurple)
        case "cohere": ("🧠", "Cohere", .aicovenPink)
        case "mistral": ("🌬️", "Mistral AI", .cyan)
        default: ("🔑", provider, .aicovenTeal)
        }
    }

    var usagePercentage: Double {
        guard let remaining, let budgetUsd = remaining.budgetUsd, budgetUsd > 0 else { return 0 }
        return (remaining.usageToDateUsd / budgetUsd) * 100
    }

    var progressColor: Color {
        if usagePercentage >= 90 { return .red }
        if usagePercentage >= 75 { return .orange }
        return .aicovenTeal
    }

    var body: some View {
        GlassCard {
            VStack(spacing: Spacing.md) {
                // Header
                HStack {
                    Text(providerInfo.icon)
                        .font(.system(size: 32))

                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(providerInfo.name)
                            .font(.aicovenH3)
                            .foregroundColor(.aicovenTextPrimary)

                        // Key details exposed directly under key name
                        HStack(spacing: Spacing.sm) {
                            if let remaining {
                                Text("Used: $\(String(format: "%.2f", remaining.usageToDateUsd))")
                                    .font(.aicovenCaption)
                                    .foregroundColor(.aicovenTextSecondary)
                            }

                            if let budget {
                                Text("/")
                                    .font(.aicovenCaption)
                                    .foregroundColor(.aicovenTextTertiary)

                                Text("$\(String(format: "%.0f", budget.amountUsd)) Limit")
                                    .font(.aicovenCaption)
                                    .foregroundColor(.aicovenTextSecondary)

                                Text("•")
                                    .font(.aicovenCaption)
                                    .foregroundColor(.aicovenTextTertiary)

                                if budget.hardCap {
                                    Text("Hard Cap: ON")
                                        .font(.aicovenCaption)
                                        .foregroundColor(.orange)
                                } else {
                                    Text("Hard Cap: OFF")
                                        .font(.aicovenCaption)
                                        .foregroundColor(.aicovenTextTertiary)
                                }
                            } else {
                                Text("• No Limit Set")
                                    .font(.aicovenCaption)
                                    .foregroundColor(.aicovenTextTertiary)
                            }
                        }
                    }

                    Spacer()
                }

                if isEditing {
                    // Edit mode
                    VStack(spacing: Spacing.md) {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Monthly Budget (USD)")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextSecondary)

                            TextField("50.00", text: $editAmount)
                                .font(.aicovenBody)
                                .foregroundColor(.aicovenTextPrimary)
                                .padding(Spacing.sm)
                                .background(Color.aicovenGlass)
                                .cornerRadius(BorderRadius.md)
                        }

                        HStack {
                            Text("Hard Cap")
                                .font(.aicovenBody)
                                .foregroundColor(.aicovenTextPrimary)

                            Spacer()

                            Toggle("", isOn: $editHardCap)
                                .labelsHidden()
                                .tint(.aicovenTeal)
                        }

                        Text("When enabled, requests will be blocked once budget is exceeded")
                            .font(.aicovenCaption)
                            .foregroundColor(.aicovenTextTertiary)

                        HStack(spacing: Spacing.sm) {
                            Button("Cancel") {
                                onCancel()
                            }
                            .buttonStyle(SecondaryButtonStyle())

                            Button("Save") {
                                onSave()
                            }
                            .buttonStyle(PrimaryButtonStyle())
                        }
                    }
                } else {
                    // Display mode (Progress bar)
                    VStack(spacing: Spacing.xs) {
                        if let remaining {
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Rectangle()
                                        .fill(Color.aicovenGlass)
                                        .frame(height: 6)

                                    if budget != nil {
                                        Rectangle()
                                            .fill(progressColor)
                                            .frame(
                                                width: min(geometry.size.width * (usagePercentage / 100), geometry.size.width),
                                                height: 6
                                            )
                                    } else {
                                        // Simple indicator for usage without budget
                                        Rectangle()
                                            .fill(Color.aicovenTeal.opacity(0.3))
                                            .frame(width: 4, height: 6)
                                    }
                                }
                                .cornerRadius(BorderRadius.circle)
                            }
                            .frame(height: 6)
                        } else {
                            // Placeholder for missing usage data
                            Text("Usage data unavailable")
                                .font(.aicovenCaption)
                                .foregroundColor(.aicovenTextTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    // Buttons - Independent of remaining data
                    if budget == nil {
                        Button("Set Budget") {
                            onEdit()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    } else {
                        Button("Edit Budget") {
                            onEdit()
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.aicovenBody)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
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

#Preview {
    BudgetView()
}
