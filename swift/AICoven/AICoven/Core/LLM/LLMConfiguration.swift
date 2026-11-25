import Foundation

/// Central configuration for built-in LLM providers (OpenAI, Anthropic, Gemini).
///
/// This wires together:
/// - ModelDescriptors used by ModelRouter.
/// - Concrete LLMClient implementations, keyed by provider ID.
///
/// API keys are resolved from Keychain via ProviderAccountService account
/// metadata. UserDefaults is only used for non-secret provider configuration
/// such as base URLs and model preferences.
enum LLMConfiguration {
    /// Note: ModelDescriptors are now built dynamically per-account using the
    /// provider's ListModels APIs via ProviderAccountService. This struct only
    /// knows how to build clients; it no longer hardcodes any model IDs.
    /// Builds LLMClient instances for providers that have API keys configured.
    /// Secret keys are read from Keychain using provider account metadata.
    /// This method is implicitly MainActor since it accesses UserScope.
    static func makeDefaultClients() -> [String: LLMClient] {
        var result: [String: LLMClient] = [:]
        let defaults = UserDefaults.standard

        if let openAIKey = ProviderAccountService.apiKeyFromKeychain(forProvider: "openai"), !openAIKey.isEmpty {
            result["openai"] = OpenAILLMClient(apiKey: openAIKey)
        }

        if let anthropicKey = ProviderAccountService.apiKeyFromKeychain(forProvider: "anthropic"), !anthropicKey.isEmpty {
            result["anthropic"] = AnthropicLLMClient(apiKey: anthropicKey)
        }

        if let geminiKey = ProviderAccountService.apiKeyFromKeychain(forProvider: "gemini"), !geminiKey.isEmpty {
            result["google"] = GeminiLLMClient(apiKey: geminiKey)
        }

        if let openRouterKey = ProviderAccountService.apiKeyFromKeychain(forProvider: "openrouter"), !openRouterKey.isEmpty {
            result["openrouter"] = OpenAILLMClient(
                apiKey: openRouterKey,
                baseURL: OpenAILLMClient.openRouterBaseURL,
                providerID: "openrouter",
                providerName: "OpenRouter"
            )
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

        // OpenClaw: Self-hosted OpenAI-compatible proxy/gateway
        // Base URL required; API key is optional (many local deployments don't require auth)
        if let openClawURL = defaults.string(forKey: UserScope.scopedKey("openclaw_base_url")),
           !openClawURL.isEmpty,
           let openClawBaseURL = URL(string: openClawURL) {
            let openClawKey = ProviderAccountService.apiKeyFromKeychain(forProvider: "openclaw")
                ?? ProcessInfo.processInfo.environment["OPENCLAW_API_KEY"]
            result["openclaw"] = OpenClawLLMClient(baseURL: openClawBaseURL, apiKey: openClawKey)
        }

        // Any other server that speaks the OpenAI chat API (LM Studio, vLLM,
        // llama.cpp): an address, and a key only if the server asks for one.
        if let server = ProviderAccountService.openAICompatibleServer() {
            result["openai_compatible"] = OpenClawLLMClient(
                baseURL: server.baseURL,
                apiKey: server.apiKey,
                providerID: "openai_compatible",
                providerName: "OpenAI-compatible server"
            )
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

        // Register OpenClaw models/descriptors if configured.
        // OpenClaw can host any OpenAI-compatible model, so we provide
        // a flexible mechanism that supports user-defined model IDs.
        if clients["openclaw"] != nil {
            // Check if user has specified a custom model in settings
            let openClawModel = UserDefaults.standard.string(forKey: UserScope.scopedKey("openclaw_model"))
                ?? "openai/gpt-3.5-turbo" // Sensible default

            // Context size varies by model - use a conservative 4K default
            // User can override via openclaw_context_tokens if needed
            let contextTokens = UserDefaults.standard.integer(forKey: UserScope.scopedKey("openclaw_context_tokens"))
            let effectiveContext = contextTokens > 0 ? contextTokens : 4_096

            models.append(ModelDescriptor(
                providerID: "openclaw",
                modelID: openClawModel,
                maxContextTokens: effectiveContext,
                supportsTools: true, // OpenClaw can support tools depending on backend
                supportsEmbeddings: false,
                costClass: .free // Self-hosted = no cost
            ))
        }

        return (models, clients)
    }
}
