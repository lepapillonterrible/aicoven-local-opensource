import Foundation

/// Errors for embedding-related operations.
enum EmbeddingServiceError: Error {
    case noEmbeddingProviderConfigured
    case embeddingFailed
}

/// Service responsible for computing embeddings via the configured LLM
/// providers and wiring them into the local memory store.
actor EmbeddingService {
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
