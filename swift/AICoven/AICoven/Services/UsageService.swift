import Foundation

actor UsageService {
    static let shared = UsageService()

    /// User-scoped local storage keys
    private var entriesKey: String {
        UserScope.scopedKey("local_usage.entries.v1")
    }

    private var budgetsKey: String {
        UserScope.scopedKey("local_usage.budgets.v1")
    }

    private let isoFormatter: ISO8601DateFormatter

    private init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoFormatter = formatter
    }

    // MARK: - Public API

    /// Record a local usage entry for the given provider/model.
    func recordLocalUsage(provider: String, model: String?, usage: TokenUsage?, threadId: String?) async {
        guard let usage, let model else { return }

        var entries = loadEntries()
        let now = Date()
        let id = UUID().uuidString

        let cost = estimateCostUsd(provider: provider, usage: usage, model: model)

        let entry = UsageEntryResponse(
            id: id,
            userId: "local-user",
            covenId: nil,
            threadId: threadId,
            provider: provider,
            model: model,
            // TokenUsage fields are optional coming from the LLM provider; default
            // missing values to 0 so local usage tracking is always consistent.
            promptTokens: usage.promptTokens ?? 0,
            completionTokens: usage.completionTokens ?? 0,
            totalTokens: usage.totalTokens ?? 0,
            costUsd: cost,
            createdAt: isoFormatter.string(from: now)
        )

        entries.append(entry)
        // Keep only the most recent 500 entries to cap storage.
        if entries.count > 500 {
            entries = Array(entries.suffix(500))
        }
        saveEntries(entries)
    }

    /// Get usage summary for the current user over a date range.
    func getUsageSummary(startDate: Date? = nil, endDate: Date? = nil, covenId: String? = nil) async throws -> UsageSummaryResponse {
        // covenId is ignored in the local-only client; all usage is personal.
        let entries = loadEntries()

        let now = Date()
        let effectiveEnd = endDate ?? now
        let effectiveStart: Date = if let startDate {
            startDate
        } else {
            // Default window: last 30 days
            Calendar.current.date(byAdding: .day, value: -30, to: effectiveEnd) ?? now
        }

        var totalTokens = 0
        var promptTokens = 0
        var completionTokens = 0
        var totalCost: Double = 0
        var messageCount = 0

        for entry in entries {
            guard let createdAtDate = isoFormatter.date(from: entry.createdAt) else { continue }
            guard createdAtDate >= effectiveStart, createdAtDate <= effectiveEnd else { continue }

            totalTokens += entry.totalTokens
            promptTokens += entry.promptTokens
            completionTokens += entry.completionTokens
            totalCost += entry.costUsd
            messageCount += 1
        }

        return UsageSummaryResponse(
            totalTokens: totalTokens,
            totalCostUsd: totalCost,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            messageCount: messageCount,
            startDate: isoFormatter.string(from: effectiveStart),
            endDate: isoFormatter.string(from: effectiveEnd)
        )
    }

    /// Get detailed usage entries (newest first).
    func getUsageEntries(limit: Int = 50, offset: Int = 0) async throws -> [UsageEntryResponse] {
        let entries = loadEntries()
            .sorted { lhs, rhs in
                // Sort descending by timestamp
                guard let ld = isoFormatter.date(from: lhs.createdAt),
                      let rd = isoFormatter.date(from: rhs.createdAt) else {
                    return lhs.createdAt > rhs.createdAt
                }
                return ld > rd
            }

        let start = min(max(0, offset), entries.count)
        let end = min(entries.count, start + limit)
        return Array(entries[start ..< end])
    }

    /// Get remaining budget for a provider for the current calendar month.
    func getRemainingBudget(provider: String) async throws -> RemainingResponse {
        let budgets = loadBudgets()
        let matchingBudget = budgets.first { $0.provider.lowercased() == provider.lowercased() }

        // Aggregate usage for this provider for the current month.
        let calendar = Calendar.current
        let now = Date()
        let monthInterval = calendar.dateInterval(of: .month, for: now)

        var usageThisMonth: Double = 0
        let entries = loadEntries()
        if let monthInterval {
            for entry in entries where entry.provider.lowercased() == provider.lowercased() {
                guard let createdAtDate = isoFormatter.date(from: entry.createdAt) else { continue }
                if monthInterval.contains(createdAtDate) {
                    usageThisMonth += entry.costUsd
                }
            }
        }

        let budgetUsd = matchingBudget?.amountUsd
        let remainingUsd: Double? = if let budgetUsd {
            max(0, budgetUsd - usageThisMonth)
        } else {
            nil
        }

        // Simple threshold: notify at 75% and 90% if a budget exists.
        let thresholdHit: Int?
        if let budgetUsd, budgetUsd > 0 {
            let ratio = usageThisMonth / budgetUsd
            if ratio >= 0.9 {
                thresholdHit = 90
            } else if ratio >= 0.75 {
                thresholdHit = 75
            } else {
                thresholdHit = nil
            }
        } else {
            thresholdHit = nil
        }

        return RemainingResponse(
            provider: provider,
            budgetUsd: budgetUsd,
            usageToDateUsd: usageThisMonth,
            remainingUsd: remainingUsd,
            hardCap: matchingBudget?.hardCap ?? false,
            thresholdHit: thresholdHit
        )
    }

    /// Return all configured budgets.
    func getAllBudgets() async throws -> [BudgetResponse] {
        loadBudgets()
    }

    /// Create or update a budget for the given provider.
    @discardableResult
    func setBudget(provider: String, amountUsd: Double, hardCap: Bool) async throws -> BudgetResponse {
        var budgets = loadBudgets()
        let now = Date()

        if let index = budgets.firstIndex(where: { $0.provider.lowercased() == provider.lowercased() }) {
            var existing = budgets[index]
            existing = BudgetResponse(
                id: existing.id,
                ownerId: existing.ownerId,
                provider: provider,
                amountUsd: amountUsd,
                hardCap: hardCap,
                alerts: existing.alerts,
                active: existing.active,
                createdAt: existing.createdAt,
                updatedAt: isoFormatter.string(from: now)
            )
            budgets[index] = existing
        } else {
            let newBudget = BudgetResponse(
                id: UUID().uuidString,
                ownerId: "local-user",
                provider: provider,
                amountUsd: amountUsd,
                hardCap: hardCap,
                alerts: [75, 90],
                active: true,
                createdAt: isoFormatter.string(from: now),
                updatedAt: nil
            )
            budgets.append(newBudget)
        }

        saveBudgets(budgets)

        // Return the updated budget
        return budgets.first { $0.provider.lowercased() == provider.lowercased() }!
    }

    // MARK: - Private helpers

    private func loadEntries() -> [UsageEntryResponse] {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: entriesKey) else { return [] }
        do {
            return try JSONDecoder().decode([UsageEntryResponse].self, from: data)
        } catch {
            AppErrorReporter.log(error: error, context: "UsageService.loadEntries.decodeEntries")
            return []
        }
    }

    private func saveEntries(_ entries: [UsageEntryResponse]) {
        do {
            let data = try JSONEncoder().encode(entries)
            UserDefaults.standard.set(data, forKey: entriesKey)
        } catch {
            AppErrorReporter.log(error: error, context: "UsageService.saveEntries.encodeEntries")
        }
    }

    private func loadBudgets() -> [BudgetResponse] {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: budgetsKey) else { return [] }
        do {
            return try JSONDecoder().decode([BudgetResponse].self, from: data)
        } catch {
            AppErrorReporter.log(error: error, context: "UsageService.loadBudgets.decodeBudgets")
            return []
        }
    }

    private func saveBudgets(_ budgets: [BudgetResponse]) {
        do {
            let data = try JSONEncoder().encode(budgets)
            UserDefaults.standard.set(data, forKey: budgetsKey)
        } catch {
            AppErrorReporter.log(error: error, context: "UsageService.saveBudgets.encodeBudgets")
        }
    }

    /// Estimate cost in USD using provider/model-specific pricing. We prefer
    /// exact per-model pricing from `ModelPricingCatalog` when available and
    /// fall back to a coarse per-provider rate otherwise.
    private func estimateCostUsd(provider: String, usage: TokenUsage, model: String) -> Double {
        let prompt = Double(usage.promptTokens ?? 0)
        let completion = Double(usage.completionTokens ?? 0)

        if let pricing = ModelPricingCatalog.shared.pricing(for: provider, model: model) {
            let inputCost = (prompt / 1000.0) * pricing.inputPer1K
            let outputCost = (completion / 1000.0) * pricing.outputPer1K
            return inputCost + outputCost
        }

        // Fallback: simple per-provider flat rate using total tokens.
        let totalTokens = Double(usage.totalTokens ?? 0)
        let perThousand = switch provider.lowercased() {
        case "openai":
            0.01
        case "anthropic":
            0.012
        case "google", "gemini":
            0.008
        default:
            0.0
        }
        return (totalTokens / 1000.0) * perThousand
    }
}
