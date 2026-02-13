import XCTest
@testable import AICoven

@MainActor
final class PricingUpdateServiceErrorTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        // Restore default reporter so tests do not leak configuration.
        AppErrorReporter.use(ConsoleErrorReporter())
    }

    /// Verify that when any of the provider-specific fetchers throws, the
    /// error is logged via AppErrorReporter with the expected context string
    /// and the refresh operation still returns the last cached overrides.
    func testRefreshNowAsync_logsPerProviderErrorsAndReturnsCachedOverrides() async throws {
        let reporter = CapturingErrorReporter()
        AppErrorReporter.use(reporter)

        let service = PricingUpdateService.shared
        service.resetCacheForTesting()

        // Seed an in-memory cached override so that refreshNowAsync can fall
        // back to it when all providers fail. We do this by writing a minimal
        // valid overrides file to disk and then calling currentOverrides().
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let cacheDir = base.appendingPathComponent("AICovenPricing", isDirectory: true)
        let cacheURL = cacheDir.appendingPathComponent("pricing-overrides.json", isDirectory: false)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let seededOverride = ModelPricing(provider: "test", modelPattern: "test-model", inputPer1K: 0.01, outputPer1K: 0.02)
        let data = try JSONEncoder().encode([seededOverride])
        try data.write(to: cacheURL, options: [.atomic])

        // Prime the in-memory cache.
        let initial = service.currentOverrides()
        XCTAssertEqual(initial, [seededOverride], "Expected seeded overrides to be loaded into cache")

        // Now run a refresh knowing that network/HTML failures (if any) will
        // cause fetchAllProviders() to log errors and fall back to cachedOverrides.
        let refreshed = await invokeRefreshNowAsync(on: service)

        // We expect refreshNowAsync to return at least the cached entry even if
        // all providers fail.
        XCTAssertEqual(refreshed, [seededOverride])

        // Verify that provider-specific error contexts are *capable* of being
        // logged. In environments where all provider fetches succeed, we skip
        // the assertion rather than failing the suite.
        let errorContexts = Set(reporter.errors.map(\.context))
        if errorContexts.isEmpty {
            throw XCTSkip("No provider errors were logged; PricingUpdateService.fetchAllProviders likely succeeded for all providers in this environment.")
        }

        XCTAssertTrue(
            errorContexts.contains("PricingUpdateService.fetchAllProviders.openai") ||
                errorContexts.contains("PricingUpdateService.fetchAllProviders.anthropic") ||
                errorContexts.contains("PricingUpdateService.fetchAllProviders.google"),
            "Expected at least one provider-specific PricingUpdateService.fetchAllProviders.* context to be logged when refreshNowAsync encounters errors"
        )
    }

    // MARK: - Helpers

    /// Helper to invoke the private async refreshNowAsync() method via its
    /// public side effects. We call refreshIfNeeded() after backdating the
    /// last-fetched timestamp so that a refresh is required, then read the
    /// resulting overrides.
    private func invokeRefreshNowAsync(on service: PricingUpdateService) async -> [ModelPricing] {
        // Force a refresh by clearing or backdating the last fetched timestamp.
        let defaults = UserDefaults.standard
        defaults.set(Date(timeIntervalSince1970: 0), forKey: "model_pricing.last_fetched")

        await service.refreshIfNeededAsyncForTesting()
        return service.currentOverrides()
    }
}
