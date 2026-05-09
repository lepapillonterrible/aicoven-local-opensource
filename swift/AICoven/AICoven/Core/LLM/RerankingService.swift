import Foundation

/// Reranks local memory chunks using an LLM to improve retrieval precision.
@MainActor
final class RerankingService {
    private let modelRouter: ModelRouter
    private let llmClients: [String: LLMClient]

    init() {
        let env = LLMConfiguration.makeEnvironment()
        modelRouter = HeuristicModelRouter(availableModels: env.models)
        llmClients = env.clients
    }

    /// Reranks a batch of memory chunks based on their relevance to a query.
    ///
    /// - Parameters:
    ///   - query: The search query.
    ///   - chunks: The candidate chunks retrieved via hybrid search.
    ///   - topK: Number of top chunks to return.
    ///   - scoreThreshold: Minimum score (0-10) to be included.
    /// - Returns: Reordered and filtered list of chunks with `rankScore` applied.
    func rerank(
        query: String,
        chunks: [LocalMemoryChunk],
        topK: Int = 8,
        scoreThreshold: Float = 6.0
    ) async -> [LocalMemoryChunk] {
        guard !chunks.isEmpty else { return [] }

        let ctx = RoutingContext(
            task: .judge, // Treat reranking as a judging task
            requireLocalOnly: false,
            requireLongContext: false,
            preferHighQuality: false
        )

        guard let descriptor = modelRouter.route(for: ctx),
              let client = llmClients[descriptor.providerID] else {
            // Fallback: return top K of the original chunks if no LLM is available.
            return Array(chunks.prefix(topK))
        }

        // Run reranking in parallel or sequence? We'll do a simple sequential map for now to avoid overloading local models.
        var scoredChunks: [(chunk: LocalMemoryChunk, score: Float)] = []
        for chunk in chunks {
            let score = await scoreChunk(query: query, content: chunk.text, client: client, modelID: descriptor.modelID)
            if score >= scoreThreshold {
                scoredChunks.append((chunk, score))
            }
        }

        let sorted = scoredChunks.sorted { $0.score > $1.score }
        return sorted.prefix(topK).map(\.chunk)
    }

    private func scoreChunk(query: String, content: String, client: LLMClient, modelID: String) async -> Float {
        let prompt = """
        Rate the relevance of the following memory chunk to the user's query on a scale of 0 to 10.
        Provide ONLY the numeric score as an integer or float. No explanation.

        Query: "\(query)"

        Memory Chunk:
        "\(content)"

        Score:
        """

        let messages = [
            LLMMessage(role: .user, content: prompt)
        ]

        do {
            let response = try await client.completeChat(messages: messages, model: modelID, options: ChatOptions(temperature: 0.1, maxTokens: 10, stream: false))
            let text = response.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return Float(text) ?? 5.0
        } catch {
            return 5.0 // Neutral score on failure
        }
    }
}
