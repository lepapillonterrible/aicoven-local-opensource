import Foundation

/// Service for summarizing chat history to reduce token usage.
@MainActor
final class SummarizationService {
    private let modelRouter: ModelRouter
    private let llmClients: [String: LLMClient]

    init() {
        let env = LLMConfiguration.makeEnvironment()
        modelRouter = HeuristicModelRouter(availableModels: env.models)
        llmClients = env.clients
    }

    /// Determine if thread summary should be regenerated.
    /// - Parameters:
    ///   - messageCount: Total messages in thread
    ///   - lastSummaryAt: Message count when summary was last generated
    static func shouldGenerateThreadSummary(messageCount: Int, lastSummaryAt: Int = 0) -> Bool {
        let summaryInterval = 15
        if lastSummaryAt == 0, messageCount >= 10 {
            return true
        }
        return (messageCount - lastSummaryAt) >= summaryInterval
    }

    /// Generate a high-level summary of an entire thread.
    func summarizeThread(messages: [ChatMessage]) async -> String {
        guard !messages.isEmpty else { return "" }

        let ctx = RoutingContext(
            task: .summarize,
            requireLocalOnly: false,
            requireLongContext: true,
            preferHighQuality: false
        )

        guard let descriptor = modelRouter.route(for: ctx),
              let client = llmClients[descriptor.providerID] else {
            return ""
        }

        let formattedMessages = messages.map { "\($0.role.uppercased()): \($0.content.prefix(1000))" }.joined(separator: "\n\n")

        let prompt = """
        Generate a high-level summary of this entire conversation thread.

        Focus on:
        - Overall purpose and goals of the conversation
        - Major topics covered
        - Key outcomes or deliverables
        - Important context for understanding the thread

        Be concise. Output 3-5 sentences maximum.

        Conversation:
        \(formattedMessages)

        Summary:
        """

        let promptMessage = LLMMessage(
            role: .user,
            content: prompt
        )

        do {
            let response = try await client.completeChat(messages: [promptMessage], model: descriptor.modelID, options: ChatOptions(temperature: 0.3, maxTokens: 200, stream: false))
            return response.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            AppErrorReporter.log(error: error, context: "SummarizationService.summarizeThread")
            return "[Thread summary - summarization failed]"
        }
    }
}
