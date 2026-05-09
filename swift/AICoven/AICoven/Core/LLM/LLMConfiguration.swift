import Foundation

/// Central configuration for built-in LLM providers (OpenAI, Anthropic, Gemini).
///
/// This wires together:
/// - ModelDescriptors used by ModelRouter.
/// - Concrete LLMClient implementations, keyed by provider ID.
///
/// API keys are read from UserDefaults via ProviderAccountService's
/// global cache keys (openai_api_key, anthropic_api_key, gemini_api_key).
/// Configuration for building LLM clients from user-provided API keys.
/// All methods are nonisolated since they only read from thread-safe UserDefaults.
enum LLMConfiguration {
    /// Note: ModelDescriptors are now built dynamically per-account using the
    /// provider's ListModels APIs via ProviderAccountService. This struct only
    /// knows how to build clients; it no longer hardcodes any model IDs.
    /// Builds LLMClient instances for providers that have API keys configured.
    /// Keys are expected to be cached in UserDefaults by ProviderAccountService.
    /// This method is implicitly MainActor since it accesses UserScope.
    static func makeDefaultClients() -> [String: LLMClient] {
        var result: [String: LLMClient] = [:]
        let defaults = UserDefaults.standard

        if let openAIKey = defaults.string(forKey: UserScope.scopedKey("openai_api_key")), !openAIKey.isEmpty {
            result["openai"] = OpenAILLMClient(apiKey: openAIKey)
        }

        if let anthropicKey = defaults.string(forKey: UserScope.scopedKey("anthropic_api_key")), !anthropicKey.isEmpty {
            result["anthropic"] = AnthropicLLMClient(apiKey: anthropicKey)
        }

        if let geminiKey = defaults.string(forKey: UserScope.scopedKey("gemini_api_key")), !geminiKey.isEmpty {
            result["google"] = GeminiLLMClient(apiKey: geminiKey)
        }

        // Ollama: no API key needed, just a base URL (defaults to localhost:11434).
        if let ollamaURL = defaults.string(forKey: UserScope.scopedKey("ollama_base_url")), !ollamaURL.isEmpty {
            result["ollama"] = OllamaLLMClient(baseURL: URL(string: ollamaURL) ?? OllamaLLMClient.defaultBaseURL)
        }

        // MLX: on-device Apple Silicon inference, no API key or server needed.
        if MLXModelManager.isSupported,
           let mlxModelID = defaults.string(forKey: "MLXModelManager.activeModelID"), !mlxModelID.isEmpty {
            result["mlx"] = MLXLLMClient(modelID: mlxModelID)
        }

        return result
    }

    /// Returns configured clients plus any locally-available model descriptors.
    /// Cloud provider descriptors are provided dynamically by
    /// ProviderAccountService; MLX on-device models are registered here
    /// so the router can include them in routing decisions.
    static func makeEnvironment() -> (models: [ModelDescriptor], clients: [String: LLMClient]) {
        let clients = makeDefaultClients()
        var models: [ModelDescriptor] = []

        // Register the active MLX model so it participates in routing.
        if let mlxModelID = UserDefaults.standard.string(forKey: "MLXModelManager.activeModelID"),
           !mlxModelID.isEmpty, clients["mlx"] != nil {
            // Look up catalog metadata for context-window heuristic.
            let catalogEntry = MLXModelManager.defaultCatalog.first { $0.id == mlxModelID }
            // Small local models typically support ~4K context; 7B+ can do ~8K.
            let contextTokens = (catalogEntry?.minRAMGB ?? 4) >= 8 ? 8_192 : 4_096
            models.append(ModelDescriptor(
                providerID: "mlx",
                modelID: mlxModelID,
                maxContextTokens: contextTokens,
                supportsTools: true,
                supportsEmbeddings: false,
                costClass: .free
            ))
        }

        return (models, clients)
    }
}
