import SwiftUI

struct UsageSettingsView: View {
    @StateObject private var viewModel = UsageViewModel()
    @State private var selectedTab: UsageTab = .usage

    enum UsageTab {
        case usage
        case budgets
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                // Header
                VStack(spacing: Spacing.sm) {
                    IconBadge(icon: "chart.bar.fill", size: 60, color: .aicovenTeal)

                    Text("Budgets & Usage")
                        .font(.aicovenDisplaySmall)
                        .foregroundColor(.aicovenTextPrimary)

                    Text("Track your token usage and manage budgets")
                        .font(.aicovenBody)
                        .foregroundColor(.aicovenTextSecondary)

                    if viewModel.lastUpdated != nil {
                        HStack(spacing: Spacing.md) {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10))
                                Text("Updated \(viewModel.formattedLastUpdated)")
                                    .font(.aicovenCaption)
                            }

                            if viewModel.nextResetDate != nil {
                                Text("•")
                                    .font(.aicovenCaption)

                                HStack(spacing: Spacing.xs) {
                                    Image(systemName: "calendar")
                                        .font(.system(size: 10))
                                    Text("Resets \(viewModel.formattedResetDate)")
                                        .font(.aicovenCaption)
                                }
                            }
                        }
                        .foregroundColor(.aicovenTextTertiary)
                        .padding(.top, Spacing.xs)
                    }
                }
                .padding(.top, Spacing.xl)

                // Tab Picker
                Picker("View", selection: $selectedTab) {
                    Text("Usage").tag(UsageTab.usage)
                    Text("Budgets").tag(UsageTab.budgets)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Spacing.lg)
                .tint(.aicovenTeal)

                if selectedTab == .usage {
                    if viewModel.isLoading {
                        ProgressView()
                            .scaleEffect(1.5)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 50)
                    } else if let error = viewModel.error {
                        Text("Error: \(error)")
                            .foregroundColor(.aicovenPink)
                            .padding()
                    } else {
                        // Summary Cards
                        VStack(spacing: Spacing.md) {
                            HStack(spacing: Spacing.md) {
                                UsageCard(
                                    title: "Total Cost",
                                    value: viewModel.formattedTotalCost,
                                    icon: "dollarsign.circle.fill",
                                    color: .aicovenTeal
                                )

                                UsageCard(
                                    title: "Remaining",
                                    value: viewModel.formattedRemainingBudget,
                                    icon: "chart.pie.fill",
                                    color: .aicovenPurple
                                )
                            }

                            // Budget Progress
                            if let budget = viewModel.budget, budget.budgetUsd != nil {
                                GlassCard {
                                    VStack(alignment: .leading, spacing: Spacing.sm) {
                                        HStack {
                                            Text("Monthly Budget")
                                                .font(.aicovenH3)
                                                .foregroundColor(.aicovenTextPrimary)
                                            Spacer()
                                            Text("\(Int(viewModel.budgetProgress * 100))%")
                                                .font(.aicovenH3)
                                                .foregroundColor(progressColor)
                                        }

                                        GeometryReader { geometry in
                                            ZStack(alignment: .leading) {
                                                Capsule()
                                                    .fill(Color.aicovenBorder)
                                                    .frame(height: 8)

                                                Capsule()
                                                    .fill(progressColor)
                                                    .frame(width: geometry.size.width * viewModel.budgetProgress, height: 8)
                                            }
                                        }
                                        .frame(height: 8)

                                        HStack {
                                            Text("Used: $\(String(format: "%.2f", budget.usageToDateUsd))")
                                                .font(.aicovenCaption)
                                            Spacer()
                                            Text("Limit: $\(String(format: "%.2f", budget.budgetUsd!))")
                                                .font(.aicovenCaption)
                                        }
                                        .foregroundColor(.aicovenTextSecondary)
                                    }
                                    .padding(Spacing.md)
                                }
                            }
                        }
                        .padding(.horizontal, Spacing.lg)

                        // Recent Activity
                        VStack(alignment: .leading, spacing: Spacing.md) {
                            Text("Recent Activity")
                                .font(.aicovenH3)
                                .foregroundColor(.aicovenTextPrimary)
                                .padding(.horizontal, Spacing.lg)

                            GlassCard {
                                VStack(spacing: 0) {
                                    ForEach(viewModel.recentEntries) { entry in
                                        HStack {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(entry.model)
                                                    .font(.system(size: 14, weight: .medium))
                                                    .foregroundColor(.aicovenTextPrimary)
                                                Text(formatDate(entry.createdAt))
                                                    .font(.system(size: 12))
                                                    .foregroundColor(.aicovenTextSecondary)
                                            }

                                            Spacer()

                                            VStack(alignment: .trailing, spacing: 4) {
                                                Text(String(format: "$%.4f", entry.costUsd))
                                                    .font(.system(size: 14, weight: .semibold))
                                                    .foregroundColor(.aicovenTextPrimary)
                                                Text("\(entry.totalTokens) toks")
                                                    .font(.system(size: 12))
                                                    .foregroundColor(.aicovenTextSecondary)
                                            }
                                        }
                                        .padding(.vertical, Spacing.md)
                                        .padding(.horizontal, Spacing.lg)

                                        if entry.id != viewModel.recentEntries.last?.id {
                                            Divider()
                                                .background(Color.aicovenBorder)
                                                .padding(.leading, Spacing.lg)
                                        }
                                    }

                                    if viewModel.recentEntries.isEmpty {
                                        Text("No recent activity")
                                            .font(.aicovenBody)
                                            .foregroundColor(.aicovenTextSecondary)
                                            .padding(Spacing.xl)
                                    }
                                }
                            }
                            .padding(.horizontal, Spacing.lg)
                        }
                    }
                } else {
                    // Budget View
                    BudgetView(isEmbedded: true)
                }
            }
            .padding(.bottom, Spacing.xl)
        }
        .background(NebulaBackground())
        .task {
            await viewModel.loadData()
        }
    }

    var progressColor: Color {
        if viewModel.budgetProgress >= 0.9 { return .aicovenPink }
        if viewModel.budgetProgress >= 0.75 { return .orange }
        return .aicovenTeal
    }

    func formatDate(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = formatter.date(from: isoString) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }

        // Fallback for standard ISO without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: isoString) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }

        return isoString
    }
}

struct UsageCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    Image(systemName: icon)
                        .foregroundColor(color)
                    Text(title)
                        .font(.aicovenCaption)
                        .foregroundColor(.aicovenTextSecondary)
                }

                Text(value)
                    .font(.aicovenH2)
                    .foregroundColor(.aicovenTextPrimary)
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
