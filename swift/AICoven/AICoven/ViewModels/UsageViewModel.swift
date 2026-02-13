import Foundation
import SwiftUI
internal import Combine

@MainActor
class UsageViewModel: ObservableObject {
    @Published var summary: UsageSummaryResponse?
    @Published var budget: RemainingResponse? // Aggregate
    @Published var recentEntries: [UsageEntryResponse] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var lastUpdated: Date?
    @Published var nextResetDate: Date?

    private let service = UsageService.shared
    private let allProviders = ["openai", "anthropic", "google", "mistral", "cohere"]

    func loadData() async {
        isLoading = true
        error = nil

        do {
            // Load summary (last 30 days)
            async let summaryTask = service.getUsageSummary()

            // Load recent entries
            async let entriesTask = service.getUsageEntries(limit: 10)

            // Fetch remaining for ALL providers to aggregate
            var totalUsage: Double = 0
            var totalBudget: Double? = nil
            var totalRemaining: Double? = nil

            var hasAnyBudget = false

            // We need to fetch sequentially or grouped since we don't have a 'get all' endpoint yet
            // For now, simple loop (could be parallelized)
            for provider in allProviders {
                do {
                    let rem = try await service.getRemainingBudget(provider: provider)
                    totalUsage += rem.usageToDateUsd
                    if let busd = rem.budgetUsd {
                        hasAnyBudget = true
                        totalBudget = (totalBudget ?? 0) + busd
                        totalRemaining = (totalRemaining ?? 0) + (rem.remainingUsd ?? 0)
                    }
                } catch {
                    AppErrorReporter.log(error: error, context: "UsageViewModel.loadData.getRemainingBudget.\(provider)")
                }
            }

            var aggregatedBudget = RemainingResponse(
                provider: "Total",
                budgetUsd: totalBudget,
                usageToDateUsd: totalUsage,
                remainingUsd: totalRemaining,
                hardCap: false,
                thresholdHit: nil
            )

            let (summaryResult, entriesResult) = try await (summaryTask, entriesTask)

            summary = summaryResult
            budget = aggregatedBudget
            recentEntries = entriesResult
            lastUpdated = Date()

            // Calculate next reset date (1st of next month)
            let calendar = Calendar.current
            if let nextMonth = calendar.date(byAdding: .month, value: 1, to: Date()) {
                let components = calendar.dateComponents([.year, .month], from: nextMonth)
                nextResetDate = calendar.date(from: components)
            }

        } catch {
            AppErrorReporter.log(error: error, context: "UsageViewModel.loadData")
            if let apiError = error as? APIError, case .backendUnavailable = apiError {
                // In the local-only client we don't have backend usage data.
                // Treat this as "no data" rather than surfacing an error.
                summary = nil
                budget = nil
                recentEntries = []
                self.error = nil
            } else {
                self.error = error.localizedDescription
            }
        }

        isLoading = false
    }

    var formattedTotalCost: String {
        guard let cost = summary?.totalCostUsd else { return "$0.00" }
        return formatCurrency(cost)
    }

    var formattedRemainingBudget: String {
        guard let remaining = budget?.remainingUsd else { return "Unlimited" }
        return formatCurrency(remaining)
    }

    var budgetProgress: Double {
        guard let budget,
              let total = budget.budgetUsd,
              total > 0 else { return 0 }
        return min(budget.usageToDateUsd / total, 1.0)
    }

    var formattedLastUpdated: String {
        guard let date = lastUpdated else { return "-" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var formattedResetDate: String {
        guard let date = nextResetDate else { return "-" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }
}
