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
struct LLMConfiguration: Sendable {
    /// Note: ModelDescriptors are now built dynamically per-account using the
    /// provider's ListModels APIs via ProviderAccountService. This struct only
    /// knows how to build clients; it no longer hardcodes any model IDs.
    /// Builds LLMClient instances for providers that have API keys configured.
    /// Keys are expected to be cached in UserDefaults by ProviderAccountService.
    /// This method is nonisolated since UserDefaults.standard is thread-safe.
    nonisolated static func makeDefaultClients() -> [String: LLMClient] {
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

    /// Returns only the configured clients. ModelDescriptors are now provided
    /// by ProviderAccountService based on live ListModels responses.
    /// This method is nonisolated since it only calls nonisolated methods.
    nonisolated static func makeEnvironment() -> (models: [ModelDescriptor], clients: [String: LLMClient]) {
        let clients = makeDefaultClients()
        return ([], clients)
    }
}
