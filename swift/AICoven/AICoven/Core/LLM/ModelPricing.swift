import Foundation

/// Per-model pricing information used to estimate local spend.
///
/// Values are expressed in USD per 1,000 input and output tokens. The initial
/// table is based on public provider pricing as of late 2024; you should update
/// it whenever providers change their prices.
struct ModelPricing: Codable, Equatable {
    let provider: String // e.g. "openai"
    let modelPattern: String // substring match against lowercased model id
    let inputPer1K: Double // USD per 1K input tokens
    let outputPer1K: Double // USD per 1K output tokens
}

struct ModelPricingCatalog {
    static let shared = ModelPricingCatalog()

    /// Static table of common chat models. Matching is case-insensitive and
    /// based on `modelPattern` being contained in the actual model id.
    private let defaults: [ModelPricing] = [
        // OpenAI – GPT-4o family (approximate, per 1K tokens)
        ModelPricing(provider: "openai", modelPattern: "gpt-4o", inputPer1K: 0.005, outputPer1K: 0.015),
        ModelPricing(provider: "openai", modelPattern: "gpt-4o-mini", inputPer1K: 0.00015, outputPer1K: 0.00060),

        // Anthropic – Claude 3.x
        ModelPricing(provider: "anthropic", modelPattern: "claude-3.5-sonnet", inputPer1K: 0.003, outputPer1K: 0.015),
        ModelPricing(provider: "anthropic", modelPattern: "claude-3-sonnet", inputPer1K: 0.003, outputPer1K: 0.015),
        ModelPricing(provider: "anthropic", modelPattern: "claude-3-haiku", inputPer1K: 0.00025, outputPer1K: 0.00125),

        // Google Gemini – rough defaults for 1.5 Pro / Flash families.
        ModelPricing(provider: "google", modelPattern: "gemini-1.5-pro", inputPer1K: 0.0035, outputPer1K: 0.0100),
        ModelPricing(provider: "google", modelPattern: "gemini-1.5-flash", inputPer1K: 0.000075, outputPer1K: 0.0003),
        ModelPricing(provider: "google", modelPattern: "gemini-2.0-flash", inputPer1K: 0.00010, outputPer1K: 0.00040),
        ModelPricing(provider: "google", modelPattern: "gemini-2.5-flash", inputPer1K: 0.00010, outputPer1K: 0.00040),

        // Google Gemini 3 (Preview – pricing estimates based on prior generation trends)
        ModelPricing(provider: "google", modelPattern: "gemini-3-pro", inputPer1K: 0.00125, outputPer1K: 0.01),
        ModelPricing(provider: "google", modelPattern: "gemini-3-flash", inputPer1K: 0.00010, outputPer1K: 0.00040)
    ]

    init() {
        // Fire-and-forget background refresh so future sessions see up-to-date
        // provider pricing. Current session will at least use cached overrides
        // from the last successful fetch.
        PricingUpdateService.shared.refreshIfNeeded()
    }

    /// Lookup pricing for a given provider/model id.
    func pricing(for provider: String, model: String) -> ModelPricing? {
        let p = provider.lowercased()
        let m = model.lowercased()

        // Prefer dynamically fetched overrides from provider docs.
        let overrides = PricingUpdateService.shared.currentOverrides()
        if let entry = overrides.first(where: { $0.provider == p && m.contains($0.modelPattern) }) {
            return entry
        }

        // Fall back to the baked-in defaults.
        return defaults.first { entry in
            entry.provider == p && m.contains(entry.modelPattern)
        }
    }
}
