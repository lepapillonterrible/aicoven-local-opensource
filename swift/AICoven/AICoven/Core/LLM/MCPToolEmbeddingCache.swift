import Foundation

/// In-memory cache for MCP tool description embeddings.
///
/// Embeddings are computed lazily via `EmbeddingService` the first time a
/// semantic tool search is requested. The cache is invalidated whenever the
/// set of cached tools changes (detected by comparing tool names + count).
///
/// Storage is trivial (~600 KB for 200 tools × 768-dim × 4 bytes) so we
/// keep everything in memory and recompute on app relaunch.
actor MCPToolEmbeddingCache {
    static let shared = MCPToolEmbeddingCache()

    // MARK: - State

    /// Cached embeddings keyed by the full tool name (e.g. "mcp.zapier.send_email").
    private var embeddings: [String: [Float]] = [:]

    /// Fingerprint of the tool set that was last embedded, used to detect
    /// when the cache needs to be rebuilt (e.g. server reconnect, tool list change).
    private var toolSetFingerprint: String = ""

    /// Whether an embedding computation is already in progress.
    /// Prevents redundant concurrent computations.
    private var isComputing = false

    // MARK: - Public API

    /// Returns cached embeddings for the given tools, computing them if
    /// necessary. Returns nil if no embedding provider is configured.
    ///
    /// - Parameters:
    ///   - tools: The full set of MCP tool definitions (from `PromptTemplates.mcpToolDefinitions`).
    /// - Returns: Dictionary of tool name → embedding vector, or nil if embeddings unavailable.
    func getEmbeddings(for tools: [ToolDefinition]) async -> [String: [Float]]? {
        let fingerprint = computeFingerprint(for: tools)

        // Cache is valid — return immediately.
        if fingerprint == toolSetFingerprint, !embeddings.isEmpty {
            return embeddings
        }

        // Avoid redundant concurrent computation.
        guard !isComputing else { return embeddings.isEmpty ? nil : embeddings }
        isComputing = true
        defer { isComputing = false }

        // Compute embeddings for all tool descriptions.
        // We batch the descriptions and embed them together for efficiency.
        let descriptions = tools.map { buildSearchableDescription(for: $0) }
        let names = tools.map(\.name)

        // Use the shared EmbeddingService which routes to whatever
        // embedding-capable provider the user has configured.
        let vectors: [[Float]]
        do {
            let embeddingService = await EmbeddingService.shared
            // Embed all descriptions. embedText only handles one at a time,
            // so we batch manually. For 200 tools this takes ~1-2 seconds
            // on a typical API provider (batched internally by the SDK).
            var results: [[Float]] = []
            for desc in descriptions {
                if let vec = try await embeddingService.embedText(desc) {
                    results.append(vec)
                } else {
                    // No embedding provider configured — abort.
                    return nil
                }
            }
            vectors = results
        } catch {
            AppErrorReporter.log(error: error, context: "MCPToolEmbeddingCache.getEmbeddings")
            return nil
        }

        // Store in cache.
        var newCache: [String: [Float]] = [:]
        for (i, name) in names.enumerated() where i < vectors.count {
            newCache[name] = vectors[i]
        }
        embeddings = newCache
        toolSetFingerprint = fingerprint

        return embeddings
    }

    /// Clear the cache, forcing recomputation on next access.
    func invalidate() {
        embeddings = [:]
        toolSetFingerprint = ""
    }

    // MARK: - Helpers

    /// Build a rich, searchable text description for a tool that captures
    /// its name, purpose, and parameter semantics. This is what gets
    /// embedded, so more context here = better semantic matching.
    private func buildSearchableDescription(for tool: ToolDefinition) -> String {
        // Split the tool name into words for better embedding coverage.
        // "mcp.zapier.gmail_send_email" → "gmail send email"
        let nameWords = tool.name
            .replacingOccurrences(of: "mcp.", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let paramNames = tool.parameters.map(\.name).joined(separator: ", ")
        let paramDesc = paramNames.isEmpty ? "" : " Parameters: \(paramNames)."

        return "\(nameWords): \(tool.description)\(paramDesc)"
    }

    /// Compute a lightweight fingerprint of the tool set so we can detect
    /// when it changes without comparing every embedding.
    private func computeFingerprint(for tools: [ToolDefinition]) -> String {
        // Sort names for stability, then hash count + joined names.
        let sorted = tools.map(\.name).sorted()
        let joined = "\(sorted.count)|\(sorted.joined(separator: ","))"
        var hasher = Hasher()
        hasher.combine(joined)
        return String(format: "%08x", abs(hasher.finalize()))
    }
}
