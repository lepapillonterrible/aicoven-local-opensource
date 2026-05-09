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

        // OpenClaw: Self-hosted OpenAI-compatible proxy/gateway
        // Base URL required; API key is optional (many local deployments don't require auth)
        if let openClawURL = defaults.string(forKey: UserScope.scopedKey("openclaw_base_url")),
           !openClawURL.isEmpty,
           let openClawBaseURL = URL(string: openClawURL) {
            result["openclaw"] = OpenClawLLMClient(baseURL: openClawBaseURL)
        }

        // Hermes: Nous Research Hermes models via Together AI or self-hosted
        let hermesKey = defaults.string(forKey: UserScope.scopedKey("hermes_api_key"))
            ?? defaults.string(forKey: UserScope.scopedKey("together_api_key"))
            ?? ProcessInfo.processInfo.environment["HERMES_API_KEY"]
            ?? ProcessInfo.processInfo.environment["TOGETHER_API_KEY"]
        let hermesBaseURL = defaults.string(forKey: UserScope.scopedKey("hermes_base_url"))
            ?? ProcessInfo.processInfo.environment["HERMES_BASE_URL"]

        let hasKey = !(hermesKey?.isEmpty ?? true)
        let hasBaseURL = !(hermesBaseURL?.isEmpty ?? true)

        if hasKey || hasBaseURL {
            result["hermes"] = HermesLLMClient(
                apiKey: hasKey ? hermesKey : nil,
                baseURL: hermesBaseURL.flatMap { URL(string: $0) }
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

        // Register Hermes models if configured
        if clients["hermes"] != nil {
            // Check for custom Hermes base URL (self-hosted) vs Together AI (cloud)
            let hermesBaseURL = UserDefaults.standard.string(forKey: UserScope.scopedKey("hermes_base_url"))
            let isSelfHosted = hermesBaseURL != nil && !hermesBaseURL!.isEmpty

            // Get preferred model alias or full model ID
            let modelAlias = UserDefaults.standard.string(forKey: UserScope.scopedKey("hermes_model")) ?? "hermes-3"

            // Map alias to full Together AI model ID if using cloud
            let modelID: String = if isSelfHosted {
                // For self-hosted, use the raw model identifier
                modelAlias
            } else {
                // Together AI hosted - map aliases to full names
                switch modelAlias.lowercased() {
                case "hermes-3", "hermes-3-405b":
                    "NousResearch/Hermes-3-Llama-3.1-405B-Turbo"
                case "hermes-3-70b":
                    "NousResearch/Hermes-3-Llama-3.1-70B"
                case "hermes-3-8b":
                    "NousResearch/Hermes-3-Llama-3.1-8B"
                case "hermes-2":
                    "NousResearch/Nous-Hermes-2-Mixtral-8x7B-DPO"
                case "hermes-2-mistral":
                    "NousResearch/Nous-Hermes-2-Mistral-7B-DPO"
                case "hermes-2-vision":
                    "NousResearch/Nous-Hermes-2-Vision-Alpha"
                default:
                    modelAlias // Assume user provided full model ID
                }
            }

            // Context window varies by model size
            let contextTokens = HermesLLMClient.contextWindow(for: modelID)

            models.append(ModelDescriptor(
                providerID: "hermes",
                modelID: modelID,
                maxContextTokens: contextTokens,
                supportsTools: true, // Hermes excels at function calling
                supportsEmbeddings: false,
                costClass: isSelfHosted ? .free : .medium
            ))
        }

        return (models, clients)
    }
}
