import Foundation

/// Fetches pricing information from official provider documentation pages and
/// caches it locally as overrides for `ModelPricingCatalog`.
///
/// This is deliberately best-effort: if fetching or parsing fails, we keep the
/// last known good values and fall back to the built-in defaults.
final class PricingUpdateService {
    static let shared = PricingUpdateService()

    private let cacheFileName = "pricing-overrides.json"
    private let lastFetchedKey = "model_pricing.last_fetched"
    private let refreshInterval: TimeInterval = 60 * 60 * 24 // 24 hours

    private var cachedOverrides: [ModelPricing] = []

    private init() {}

    #if DEBUG
    /// Testing-only helper to clear in-memory overrides so tests can exercise
    /// specific code paths (e.g., decode failures) deterministically.
    func resetCacheForTesting() {
        cachedOverrides = []
    }
    #endif

    // MARK: - Public API

    /// Return the currently cached overrides (in-memory or from disk).
    func currentOverrides() -> [ModelPricing] {
        if !cachedOverrides.isEmpty { return cachedOverrides }

        let url = cacheURL()
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            let overrides = try JSONDecoder().decode([ModelPricing].self, from: data)
            cachedOverrides = overrides
            return overrides
        } catch {
            AppErrorReporter.log(error: error, context: "PricingUpdateService.currentOverrides.decodeOverrides")
            return []
        }
    }

    /// Kick off a background refresh if our cached data is older than the
    /// configured refresh interval.
    func refreshIfNeeded() {
        Task {
            await refreshIfNeededAsync()
        }
    }

    /// Clear locally cached provider pricing overrides without touching user
    /// data, provider credentials, memories, or threads.
    @discardableResult
    func clearCachedOverrides() -> Int {
        var removedItems = 0

        if !cachedOverrides.isEmpty {
            cachedOverrides = []
            removedItems += 1
        }

        let defaults = UserDefaults.standard
        if defaults.object(forKey: lastFetchedKey) != nil {
            defaults.removeObject(forKey: lastFetchedKey)
            removedItems += 1
        }

        let url = cacheURL()
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
                removedItems += 1
            } catch {
                AppErrorReporter.log(error: error, context: "PricingUpdateService.clearCachedOverrides.removeFile")
            }
        }

        return removedItems
    }

    #if DEBUG
    /// Testing-only entry point that directly invokes the async refresh logic
    /// without spawning a detached Task. This allows XCTest to await the
    /// refresh in a controlled way.
    func refreshIfNeededAsyncForTesting() async {
        await refreshIfNeededAsync()
    }
    #endif

    // MARK: - Internal async implementation

    private func refreshIfNeededAsync() async {
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: lastFetchedKey) as? Date {
            let age = Date().timeIntervalSince(last)
            if age < refreshInterval { return }
        }
        _ = await refreshNowAsync()
    }

    @discardableResult
    private func refreshNowAsync() async -> [ModelPricing] {
        do {
            let overrides = try await fetchAllProviders()
            guard !overrides.isEmpty else { return cachedOverrides }

            let data = try JSONEncoder().encode(overrides)
            let url = cacheURL()
            try ensureDirectoryExists(for: url)
            try data.write(to: url, options: [.atomic])

            cachedOverrides = overrides
            UserDefaults.standard.set(Date(), forKey: lastFetchedKey)
            return overrides
        } catch {
            AppErrorReporter.log(error: error, context: "PricingUpdateService.refreshNowAsync")
            return cachedOverrides
        }
    }

    private func fetchAllProviders() async throws -> [ModelPricing] {
        var all: [ModelPricing] = []

        do {
            let openAI = try await fetchOpenAIPrices()
            all.append(contentsOf: openAI)
        } catch {
            AppErrorReporter.log(error: error, context: "PricingUpdateService.fetchAllProviders.openai")
        }

        do {
            let anthropic = try await fetchAnthropicPrices()
            all.append(contentsOf: anthropic)
        } catch {
            AppErrorReporter.log(error: error, context: "PricingUpdateService.fetchAllProviders.anthropic")
        }

        do {
            let google = try await fetchGooglePrices()
            all.append(contentsOf: google)
        } catch {
            AppErrorReporter.log(error: error, context: "PricingUpdateService.fetchAllProviders.google")
        }

        return all
    }

    // MARK: - Provider-specific fetchers

    /// OpenAI pricing: https://openai.com/api/pricing
    private func fetchOpenAIPrices() async throws -> [ModelPricing] {
        guard let url = URL(string: "https://openai.com/api/pricing") else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let html = String(data: data, encoding: .utf8) else { return [] }

        var result: [ModelPricing] = []

        if let (input, output) = extractPricePair(html: html, anchor: "gpt-4o-mini") {
            result.append(ModelPricing(provider: "openai", modelPattern: "gpt-4o-mini", inputPer1K: input, outputPer1K: output))
        }
        if let (input, output) = extractPricePair(html: html, anchor: "gpt-4o") {
            result.append(ModelPricing(provider: "openai", modelPattern: "gpt-4o", inputPer1K: input, outputPer1K: output))
        }

        return result
    }

    /// Anthropic pricing: https://platform.claude.com/docs/en/about-claude/pricing
    private func fetchAnthropicPrices() async throws -> [ModelPricing] {
        guard let url = URL(string: "https://platform.claude.com/docs/en/about-claude/pricing") else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let html = String(data: data, encoding: .utf8) else { return [] }

        var result: [ModelPricing] = []

        if let (input, output) = extractPricePair(html: html, anchor: "claude 3.5 sonnet") {
            result.append(ModelPricing(provider: "anthropic", modelPattern: "claude-3.5-sonnet", inputPer1K: input, outputPer1K: output))
        }
        if let (input, output) = extractPricePair(html: html, anchor: "claude 3 haiku") {
            result.append(ModelPricing(provider: "anthropic", modelPattern: "claude-3-haiku", inputPer1K: input, outputPer1K: output))
        }

        return result
    }

    /// Google Gemini pricing: https://ai.google.dev/pricing
    private func fetchGooglePrices() async throws -> [ModelPricing] {
        guard let url = URL(string: "https://ai.google.dev/pricing") else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let html = String(data: data, encoding: .utf8) else { return [] }

        var result: [ModelPricing] = []

        if let (input, output) = extractPricePair(html: html, anchor: "gemini 1.5 pro") {
            result.append(ModelPricing(provider: "google", modelPattern: "gemini-1.5-pro", inputPer1K: input, outputPer1K: output))
        }
        if let (input, output) = extractPricePair(html: html, anchor: "gemini 1.5 flash") {
            result.append(ModelPricing(provider: "google", modelPattern: "gemini-1.5-flash", inputPer1K: input, outputPer1K: output))
        }

        return result
    }

    // MARK: - HTML helpers

    /// Extract the first two `$X` amounts that appear near a given anchor string
    /// and interpret them as input and output price per 1M tokens. Values are
    /// converted to per-1K tokens for our internal representation.
    private func extractPricePair(html: String, anchor: String, searchRadius: Int = 2000) -> (Double, Double)? {
        let lowerHTML = html.lowercased()
        guard let anchorRange = lowerHTML.range(of: anchor.lowercased()) else { return nil }

        let startOffset = lowerHTML.distance(from: lowerHTML.startIndex, to: anchorRange.lowerBound)
        let startIndex = html.index(html.startIndex, offsetBy: startOffset)
        let endIndex = html.index(startIndex, offsetBy: searchRadius, limitedBy: html.endIndex) ?? html.endIndex
        let snippet = String(html[startIndex ..< endIndex])

        guard let regex = try? NSRegularExpression(pattern: "\\$(\\d+(?:\\.\\d+)?)") else { return nil }
        let range = NSRange(location: 0, length: (snippet as NSString).length)
        let matches = regex.matches(in: snippet, options: [], range: range)
        guard matches.count >= 2 else { return nil }

        func amount(at index: Int) -> Double? {
            let m = matches[index]
            guard m.numberOfRanges >= 2 else { return nil }
            let r = m.range(at: 1)
            guard let swiftRange = Range(r, in: snippet) else { return nil }
            return Double(snippet[swiftRange])
        }

        guard let inputPer1M = amount(at: 0), let outputPer1M = amount(at: 1) else { return nil }

        let inputPer1K = inputPer1M / 1000.0
        let outputPer1K = outputPer1M / 1000.0
        return (inputPer1K, outputPer1K)
    }

    // MARK: - File helpers

    private func cacheURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        return base.appendingPathComponent("AICovenPricing", isDirectory: true)
            .appendingPathComponent(cacheFileName, isDirectory: false)
    }

    private func ensureDirectoryExists(for fileURL: URL) throws {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
