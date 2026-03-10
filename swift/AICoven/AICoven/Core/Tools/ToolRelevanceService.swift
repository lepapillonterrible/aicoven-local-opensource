import Foundation

/// Central service for relevance-based tool selection.
///
/// Wraps `ToolEmbeddingCache` and provides a unified API for selecting
/// the most relevant tools (both native and MCP) for a given user message.
/// Used by prompt generation (to reduce context consumption) and by
/// forced execution (to score native tools for local models).
@MainActor
final class ToolRelevanceService {
    static let shared = ToolRelevanceService()

    // MARK: - Always-loaded tools

    /// Tools that bypass relevance scoring and are always included with
    /// full schemas. These are the most universally useful tools.
    static let alwaysLoadedTools: Set<String> = [
        "current_time",
        "web_search",
        "shell.execute",
    ]

    // MARK: - Public API

    /// Select the most relevant native (built-in) tools for a user message.
    ///
    /// Returns tools in two tiers:
    ///   1. Always-loaded tools (full schema, bypass scoring)
    ///   2. Top-N relevant tools scored by semantic + keyword hybrid
    ///
    /// - Parameters:
    ///   - userMessage: The user's natural language message.
    ///   - allTools: All available native tool definitions.
    ///   - limit: Maximum total tools to return (including always-loaded).
    /// - Returns: Filtered array of tool definitions, always-loaded first.
    func selectRelevantNativeTools(
        userMessage: String,
        allTools: [ToolDefinition],
        limit: Int = 10
    ) async -> [ToolDefinition] {
        // Always-loaded tools go first.
        let alwaysLoaded = allTools.filter { Self.alwaysLoadedTools.contains($0.name) }
        let candidates = allTools.filter { !Self.alwaysLoadedTools.contains($0.name) }

        // If we have few enough tools, include all.
        let remainingSlots = limit - alwaysLoaded.count
        guard candidates.count > remainingSlots, remainingSlots > 0 else {
            return alwaysLoaded + candidates
        }

        // Try semantic scoring first.
        let embeddingService = EmbeddingService.shared
        if let scored = await embeddingService.searchRelevantTools(
            query: userMessage,
            tools: candidates,
            topK: remainingSlots,
            similarityThreshold: 0.10
        ), !scored.isEmpty {
            return alwaysLoaded + scored.map(\.tool)
        }

        // Fallback: keyword scoring (works without embedding provider).
        let keywordScored = keywordScore(
            userMessage: userMessage,
            tools: candidates,
            limit: remainingSlots
        )
        return alwaysLoaded + keywordScored
    }

    /// Score a single native tool against a user message.
    ///
    /// Returns a normalized 0...1 relevance score. Used by
    /// `forceNativeToolCall` to decide whether to force-execute a tool.
    ///
    /// - Parameters:
    ///   - toolName: Name of the tool to score.
    ///   - userMessage: The user's message.
    ///   - allTools: Full set of native tool definitions.
    /// - Returns: Relevance score (0 = no match, 1 = perfect match).
    func scoreNativeTool(
        toolName: String,
        userMessage: String,
        allTools: [ToolDefinition]
    ) async -> Float {
        guard let tool = allTools.first(where: { $0.name == toolName }) else { return 0 }

        let embeddingService = EmbeddingService.shared
        if let results = await embeddingService.searchRelevantTools(
            query: userMessage,
            tools: [tool],
            topK: 1,
            similarityThreshold: 0.0
        ), let first = results.first {
            return first.score
        }

        // Fallback: simple keyword score.
        return keywordScoreSingle(userMessage: userMessage, tool: tool)
    }

    // MARK: - Compressed native tool catalog

    /// Generate a compact catalog of native tools that were NOT selected
    /// by relevance filtering. Gives the model awareness of what else
    /// exists without full parameter documentation.
    ///
    /// Example:
    ///   OTHER TOOLS: file.read, file.write, file.list, github.listRepos, ...
    static func generateCompressedNativeCatalog(
        excluded: [ToolDefinition]
    ) -> String? {
        guard !excluded.isEmpty else { return nil }
        let names = excluded.map(\.name).joined(separator: ", ")
        return "OTHER AVAILABLE TOOLS (ask to use): \(names)"
    }

    // MARK: - Keyword scoring

    private func keywordScore(
        userMessage: String,
        tools: [ToolDefinition],
        limit: Int
    ) -> [ToolDefinition] {
        let words = userMessage.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }

        guard !words.isEmpty else {
            return Array(tools.prefix(limit))
        }

        var scored: [(tool: ToolDefinition, score: Int)] = []
        for tool in tools {
            let lowerName = tool.name.lowercased()
            let lowerDesc = tool.description.lowercased()
            var score = 0
            for word in words {
                if lowerName.contains(word) { score += 3 }
                if lowerDesc.contains(word) { score += 1 }
            }
            if score > 0 {
                scored.append((tool, score))
            }
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.tool)
    }

    private func keywordScoreSingle(
        userMessage: String,
        tool: ToolDefinition
    ) -> Float {
        let words = userMessage.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }

        guard !words.isEmpty else { return 0 }

        let lowerName = tool.name.lowercased()
        let lowerDesc = tool.description.lowercased()
        var score: Float = 0
        let maxPossible = Float(words.count * 4) // max 3 (name) + 1 (desc) per word

        for word in words {
            if lowerName.contains(word) { score += 3 }
            if lowerDesc.contains(word) { score += 1 }
        }

        return maxPossible > 0 ? min(score / maxPossible, 1.0) : 0
    }
}
