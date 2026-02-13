import Foundation

/// Describes a specific model available through a given provider.
/// Conforms to Sendable since all properties are value types.
public struct ModelDescriptor: Hashable, Sendable {
    public enum CostClass {
        case free
        case cheap
        case medium
        case expensive
    }

    public let providerID: String
    public let modelID: String
    public let maxContextTokens: Int
    public let supportsTools: Bool
    /// Whether this model can be used for embeddings.
    public let supportsEmbeddings: Bool
    public let costClass: CostClass

    public init(
        providerID: String,
        modelID: String,
        maxContextTokens: Int,
        supportsTools: Bool,
        supportsEmbeddings: Bool,
        costClass: CostClass
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.maxContextTokens = maxContextTokens
        self.supportsTools = supportsTools
        self.supportsEmbeddings = supportsEmbeddings
        self.costClass = costClass
    }
}

/// Context for routing decisions, all properties are value types.
public struct RoutingContext: Sendable {
    public enum TaskType: Sendable {
        case chat
        case summarize
        case embed
        case judge
        case agentStep
    }

    public let task: TaskType
    public let requireLocalOnly: Bool
    public let requireLongContext: Bool
    public let preferHighQuality: Bool

    public init(
        task: TaskType,
        requireLocalOnly: Bool = false,
        requireLongContext: Bool = false,
        preferHighQuality: Bool = true
    ) {
        self.task = task
        self.requireLocalOnly = requireLocalOnly
        self.requireLongContext = requireLongContext
        self.preferHighQuality = preferHighQuality
    }
}

/// Decides which provider + model to use for a given task.
public protocol ModelRouter: Sendable {
    func route(for context: RoutingContext) -> ModelDescriptor?
    /// Look up a specific model by provider and model ID.
    func findExact(providerID: String, modelID: String) -> ModelDescriptor?
}

public extension ModelRouter {
    /// Default implementation returns nil (no match).
    func findExact(providerID: String, modelID: String) -> ModelDescriptor? {
        nil
    }
}

/// Minimal heuristic router implementation. In a real app this would read
/// user preferences and a dynamic model registry from local storage.
/// Conforms to Sendable since it only holds immutable data after init.
public final class HeuristicModelRouter: ModelRouter, @unchecked Sendable {
    private let availableModels: [ModelDescriptor]

    public init(availableModels: [ModelDescriptor]) {
        self.availableModels = availableModels
    }

    public func findExact(providerID: String, modelID: String) -> ModelDescriptor? {
        // Exact match first.
        if let exact = availableModels.first(where: { $0.providerID == providerID && $0.modelID == modelID }) {
            return exact
        }
        // If the provider exists but the exact model isn't in the dynamic list,
        // synthesize a descriptor so newly released models still work.
        if availableModels.contains(where: { $0.providerID == providerID }) {
            return ModelDescriptor(
                providerID: providerID,
                modelID: modelID,
                maxContextTokens: 128_000,
                supportsTools: true,
                supportsEmbeddings: false,
                costClass: .expensive
            )
        }
        return nil
    }

    public func route(for context: RoutingContext) -> ModelDescriptor? {
        let candidates: [ModelDescriptor] = if context.requireLocalOnly {
            availableModels.filter { $0.providerID == "local" }
        } else {
            availableModels
        }

        guard !candidates.isEmpty else { return nil }

        switch context.task {
        case .embed:
            // Prefer the cheapest model that explicitly supports embeddings.
            let embedders = candidates.filter(\.supportsEmbeddings)
            return embedders.min(by: { $0.costClassWeight < $1.costClassWeight })
        case .judge, .agentStep:
            // Prefer cheaper / smaller models for control tasks.
            return candidates.min(by: { $0.costClassWeight < $1.costClassWeight })
        case .chat, .summarize:
            if context.preferHighQuality {
                return candidates.max(by: { $0.costClassWeight < $1.costClassWeight })
            } else {
                return candidates.min(by: { $0.costClassWeight < $1.costClassWeight })
            }
        }
    }
}

private extension ModelDescriptor {
    var costClassWeight: Int {
        switch costClass {
        case .free: -1
        case .cheap: 0
        case .medium: 1
        case .expensive: 2
        }
    }
}
