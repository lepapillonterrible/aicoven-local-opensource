import Foundation

/// Describes the concrete capabilities available for a given configured
/// provider key. This is derived from the model catalog plus any
/// provider-specific knowledge (e.g. which models support images).
/// Conforms to Sendable since all properties are value types.
struct ProviderCapabilities {
    let providerID: String // e.g. "openai", "anthropic", "google"
    let chatModel: String? // default chat model for this provider
    let visionModel: String? // model that can accept images/files as input
    let imageModel: String? // model or endpoint for image generation
    let webModel: String? // model capable of built-in web browsing, if any
    let supportsFilesAPI: Bool // whether the provider has a first-class files API
}

/// Aggregated environment for tools and capabilities. This wraps the lower
/// level LLMConfiguration environment and adds a provider capability matrix
/// that higher-level services (tools, agents) can consult.
/// Conforms to Sendable since all properties are Sendable.
struct ToolEnvironment {
    let clients: [String: LLMClient] // keyed by providerID
    let models: [ModelDescriptor]
    let capabilities: [ProviderCapabilities]

    /// Build a ToolEnvironment from the current LLMConfiguration. This only
    /// inspects providers for which we actually have API keys configured.
    static func make() -> ToolEnvironment {
        let env = LLMConfiguration.makeEnvironment()
        let clients = env.clients
        let models = env.models

        var caps: [ProviderCapabilities] = []

        // Group models per provider for easier inspection.
        let modelsByProvider = Dictionary(grouping: models, by: { $0.providerID })

        for (providerID, providerModels) in modelsByProvider {
            // Pick a default chat model: prefer the highest cost class (quality)
            // for chat/summarize style tasks.
            let chatModel = providerModels
                .sorted { $0.costClassWeight < $1.costClassWeight }
                .last?
                .modelID

            // Heuristic: treat any model that mentions "vision" or accepts
            // images in its known ID as vision-capable. This is intentionally
            // conservative; we can refine over time.
            let visionModel = providerModels
                .first { descriptor in
                    let id = descriptor.modelID.lowercased()
                    return id.contains("vision") || id.contains("gpt-4o") || id.contains("gemini-1.5-pro")
                }?.modelID

            // For now we assume the same provider that does chat can also do
            // image generation via a separate endpoint keyed by provider.
            // The ToolService will pick sensible defaults per provider.
            let imageModel: String? = chatModel

            // Web browsing: reserved for providers/models that support it; we
            // start with nil and can wire this up later when such models are
            // added to the catalog.
            let webModel: String? = nil

            let supportsFilesAPI = switch providerID {
            case "openai":
                true
            default:
                false
            }

            let providerCaps = ProviderCapabilities(
                providerID: providerID,
                chatModel: chatModel,
                visionModel: visionModel,
                imageModel: imageModel,
                webModel: webModel,
                supportsFilesAPI: supportsFilesAPI
            )
            caps.append(providerCaps)
        }

        return ToolEnvironment(clients: clients, models: models, capabilities: caps)
    }
}

private extension ModelDescriptor {
    /// Reuse the same weight heuristic as the router so that higher-level
    /// components can make similar quality/cost tradeoffs.
    var costClassWeight: Int {
        switch costClass {
        case .free: -1
        case .cheap: 0
        case .medium: 1
        case .expensive: 2
        }
    }
}
