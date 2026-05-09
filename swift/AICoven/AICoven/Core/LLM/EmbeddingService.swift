import Foundation

/// Errors for embedding-related operations.
enum EmbeddingServiceError: Error {
    case noEmbeddingProviderConfigured
    case embeddingFailed
}

/// Service responsible for computing embeddings via the configured LLM
/// providers and wiring them into the local memory store.
@MainActor
final class EmbeddingService {
    static let shared = EmbeddingService()

    private let memoryRepository: MemoryRepository
    private let modelRouter: ModelRouter
    private let llmClients: [String: LLMClient]

    init(memoryRepository: MemoryRepository = .shared) {
        self.memoryRepository = memoryRepository
        let env = LLMConfiguration.makeEnvironment()
        modelRouter = HeuristicModelRouter(availableModels: env.models)
        llmClients = env.clients
    }

    /// Indexes a new memory chunk:
    /// - Picks an embedding-capable model via the router.
    /// - Computes an embedding for the given text.
    /// - Stores the memory+embedding via MemoryRepository.
    func indexMemory(
        scope: String,
        text: String,
        tags: [String],
        pii: Bool,
        createdBy: String?,
        source: String?
    ) async throws -> LocalMemoryChunk {
        let embedding = try await embedText(text)
        return try await memoryRepository.storeMemory(
            scope: scope,
            text: text,
            tags: tags,
            pii: pii,
            createdBy: createdBy,
            source: source,
            embedding: embedding
        )
    }

    /// Computes an embedding for ad-hoc queries (e.g., search prompts).
    func embedText(_ text: String) async throws -> [Float]? {
        guard !llmClients.isEmpty else { return nil }

        let ctx = RoutingContext(
            task: .embed,
            requireLocalOnly: false,
            requireLongContext: false,
            preferHighQuality: false
        )
        guard let descriptor = modelRouter.route(for: ctx),
              descriptor.supportsEmbeddings,
              let client = llmClients[descriptor.providerID] else {
            // No embedding-capable provider configured; fall back to nil.
            return nil
        }

        let vectors = try await client.embed(texts: [text], model: descriptor.modelID)
        return vectors.first
    }

    /// Retrieves memories relevant to the given query using a hybrid of
    /// semantic (embedding) similarity and lexical overlap. Results are
    /// filtered by a minimum combined similarity threshold and then
    /// deduplicated using a Jaccard similarity check on token sets so that
    /// highly-overlapping chunks do not crowd out the top-k.
    ///
    /// If no provider is configured for embeddings and no lexical overlap is
    /// found, falls back to recency-based retrieval.
    func searchRelevantMemories(
        query: String,
        scope: String? = nil,
        topK: Int = 16,
        candidateLimit: Int = 200,
        includePII: Bool = false,
        similarityThreshold: Float = 0.15
    ) async throws -> [LocalMemoryChunk] {
        let lowercasedQuery = query.lowercased()
        let queryTokens = tokenize(lowercasedQuery)

        let queryEmbedding = try await embedText(query)
        let allCandidates = try await memoryRepository.loadMemories(scope: scope, limit: candidateLimit)
        let candidates: [LocalMemoryChunk] = if includePII {
            allCandidates
        } else {
            allCandidates.filter { !$0.pii }
        }

        // Blend semantic similarity (if available) with a cheap lexical score
        // based on word overlap. This approximates the "hybrid" retrieval
        // described in the architecture doc without requiring a full-text index.
        let alpha: Float = 0.7 // weight for semantic vs lexical

        let scored = candidates.compactMap { chunk -> (LocalMemoryChunk, Float)? in
            let text = chunk.text.lowercased()
            let tokens = tokenize(text)

            // Lexical score: fraction of query tokens that appear in the chunk.
            let lexicalScore: Float
            if tokens.isEmpty || queryTokens.isEmpty {
                lexicalScore = 0
            } else {
                let querySet = Set(queryTokens)
                let tokenSet = Set(tokens)
                let intersectionCount = Float(querySet.intersection(tokenSet).count)
                lexicalScore = intersectionCount / Float(querySet.count)
            }

            // Semantic score via cosine similarity if we have embeddings.
            let semanticScore: Float = if let qEmb = queryEmbedding,
                                          let emb = chunk.embedding,
                                          emb.count == qEmb.count {
                cosineSimilarity(qEmb, emb)
            } else {
                0
            }

            let combined = alpha * semanticScore + (1 - alpha) * lexicalScore
            // Drop items that have effectively no signal at all, or that fall
            // below the configured similarity threshold.
            guard combined > 0, combined >= similarityThreshold else { return nil }
            return (chunk, combined)
        }

        if scored.isEmpty {
            // No candidates with any signal yet; fall back to recency, still
            // respecting the PII filter and recency ordering from the repository.
            return Array(candidates.prefix(topK))
        }

        // Sort by score descending, then apply Jaccard-based deduplication over
        // token sets so that highly-overlapping chunks do not all appear in the
        // top-k results.
        let sorted = scored.sorted { $0.1 > $1.1 }

        var selected: [LocalMemoryChunk] = []
        var selectedTokenSets: [Set<String>] = []
        let maxResults = max(1, topK)
        let dedupThreshold: Float = 0.85

        for (chunk, _) in sorted {
            if selected.count >= maxResults { break }
            let tokens = Set(tokenize(chunk.text.lowercased()))
            if tokens.isEmpty {
                selected.append(chunk)
                selectedTokenSets.append(tokens)
                continue
            }

            var isDuplicate = false
            for existingTokens in selectedTokenSets {
                let jaccard = jaccardSimilarity(existingTokens, tokens)
                if jaccard >= dedupThreshold {
                    isDuplicate = true
                    break
                }
            }

            if !isDuplicate {
                selected.append(chunk)
                selectedTokenSets.append(tokens)
            }
        }

        return selected
    }

    // MARK: - Semantic Tool Search

    /// Search for the most relevant MCP tools for a user query using the same
    /// hybrid semantic + lexical scoring used for memory retrieval.
    ///
    /// Returns the top-K tools sorted by relevance. Falls back to nil if no
    /// embedding provider is configured (caller should use keyword matching).
    ///
    /// - Parameters:
    ///   - query: The user's natural language message.
    ///   - tools: All available MCP tool definitions.
    ///   - topK: Maximum number of tools to return.
    ///   - similarityThreshold: Minimum combined score to include a tool.
    /// - Returns: Sorted array of (tool, score) pairs, or nil if embeddings unavailable.
    func searchRelevantTools(
        query: String,
        tools: [ToolDefinition],
        topK: Int = 8,
        similarityThreshold: Float = 0.10
    ) async -> [(tool: ToolDefinition, score: Float)]? {
        guard !tools.isEmpty else { return nil }

        // Get or compute tool embeddings from the cache.
        guard let toolEmbeddings = await ToolEmbeddingCache.shared.getEmbeddings(for: tools) else {
            // No embedding provider configured — caller should fall back to
            // keyword matching.
            return nil
        }

        // Embed the user query.
        let queryEmbedding: [Float]?
        do {
            queryEmbedding = try await embedText(query)
        } catch {
            AppErrorReporter.log(error: error, context: "EmbeddingService.searchRelevantTools.embedQuery")
            return nil
        }

        let lowerQuery = query.lowercased()
        let queryTokens = tokenize(lowerQuery)

        // Blend semantic + lexical scoring, same pattern as memory retrieval.
        // Alpha = 0.7 means 70% semantic, 30% lexical.
        let alpha: Float = 0.7

        var scored: [(tool: ToolDefinition, score: Float)] = []
        for tool in tools {
            // Build a searchable text from the tool name + description.
            let searchText = "\(tool.name) \(tool.description)".lowercased()
            let toolTokens = tokenize(searchText)

            // Lexical score: fraction of query tokens found in the tool text.
            let lexicalScore: Float
            if queryTokens.isEmpty || toolTokens.isEmpty {
                lexicalScore = 0
            } else {
                let querySet = Set(queryTokens)
                let toolSet = Set(toolTokens)
                let overlap = Float(querySet.intersection(toolSet).count)
                lexicalScore = overlap / Float(querySet.count)
            }

            // Semantic score via cosine similarity if we have both embeddings.
            let semanticScore: Float = if let qEmb = queryEmbedding,
                                          let tEmb = toolEmbeddings[tool.name],
                                          qEmb.count == tEmb.count {
                cosineSimilarity(qEmb, tEmb)
            } else {
                0
            }

            let combined = alpha * semanticScore + (1 - alpha) * lexicalScore
            guard combined >= similarityThreshold else { continue }
            scored.append((tool, combined))
        }

        // Sort by score descending and return top-K.
        let sorted = scored.sorted { $0.score > $1.score }
        return Array(sorted.prefix(topK))
    }

    // MARK: - Cosine similarity

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        let count = min(a.count, b.count)
        if count == 0 { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0 ..< count {
            let va = a[i]
            let vb = b[i]
            dot += va * vb
            normA += va * va
            normB += vb * vb
        }
        let denom = (normA.squareRoot() * normB.squareRoot())
        return denom == 0 ? 0 : dot / denom
    }

    // MARK: - Tokenization & Jaccard helper

    /// Extremely simple whitespace/punctuation tokenizer used for lexical
    /// overlap scoring in hybrid retrieval and for Jaccard-based de-duplication.
    /// This is intentionally minimal and does not perform stemming or
    /// stop-word removal.
    private func tokenize(_ text: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        return text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Jaccard similarity between two token sets, used to collapse highly
    /// overlapping memory chunks after initial scoring.
    private func jaccardSimilarity(_ a: Set<String>, _ b: Set<String>) -> Float {
        if a.isEmpty && b.isEmpty { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        let intersectionCount = Float(a.intersection(b).count)
        let unionCount = Float(a.union(b).count)
        return unionCount == 0 ? 0 : intersectionCount / unionCount
    }
}
