import Foundation

/// Lightweight benchmarks for testing a local model's MCP tool-calling ability.
///
/// Run via `MLXModelSettingsView` ("Test This Model") or programmatically.
/// Results are stored in `UserDefaults` keyed by model ID so the UI can
/// display them without re-running the suite.
@MainActor
final class MCPToolCallingBenchmark {
    static let shared = MCPToolCallingBenchmark()

    // MARK: - Result Model

    struct BenchmarkResult: Codable {
        let modelID: String
        let date: Date
        let totalPrompts: Int
        let correctToolCalls: Int
        let refusals: Int
        let hallucinations: Int
        let averageLatencyMs: Double

        var accuracy: Double {
            totalPrompts > 0 ? Double(correctToolCalls) / Double(totalPrompts) : 0
        }

        var refusalRate: Double {
            totalPrompts > 0 ? Double(refusals) / Double(totalPrompts) : 0
        }

        var hallucinationRate: Double {
            totalPrompts > 0 ? Double(hallucinations) / Double(totalPrompts) : 0
        }
    }

    // MARK: - Test Cases

    /// A single test case: a user prompt and the expected tool name.
    struct TestCase {
        let prompt: String
        let expectedTool: String
        /// Optional expected parameter name to check.
        let expectedParam: String?
    }

    /// Predefined test suite covering common MCP tool categories.
    static let defaultTestCases: [TestCase] = [
        // Web tools
        TestCase(
            prompt: "Search the web for Swift concurrency best practices",
            expectedTool: "web_search",
            expectedParam: "query"
        ),
        TestCase(
            prompt: "What time is it in Tokyo?",
            expectedTool: "current_time",
            expectedParam: "timezone"
        ),

        // File tools
        TestCase(
            prompt: "Read the file at /Users/me/notes.txt",
            expectedTool: "file.read",
            expectedParam: "path"
        ),
        TestCase(
            prompt: "List all files in my Documents folder",
            expectedTool: "file.list",
            expectedParam: "path"
        ),
        TestCase(
            prompt: "Write 'Hello World' to /tmp/test.txt",
            expectedTool: "file.write",
            expectedParam: "path"
        ),

        // GitHub tools
        TestCase(
            prompt: "List my GitHub repositories",
            expectedTool: "github.listRepos",
            expectedParam: nil
        ),
        TestCase(
            prompt: "Read the README.md from user/project on GitHub",
            expectedTool: "github.readFile",
            expectedParam: "path"
        ),
        TestCase(
            prompt: "Search for SwiftUI code on GitHub",
            expectedTool: "github.searchCode",
            expectedParam: "query"
        ),

        // Shell tools
        TestCase(
            prompt: "Run 'ls -la' in the terminal",
            expectedTool: "shell.execute",
            expectedParam: "command"
        ),

        // Google Drive
        TestCase(
            prompt: "List my files on Google Drive",
            expectedTool: "google_drive.listFiles",
            expectedParam: nil
        )
    ]

    // MARK: - Persistence

    private static let resultsKey = "MCPToolCallingBenchmark.results"

    /// Load stored results for all models.
    func loadResults() -> [String: BenchmarkResult] {
        guard let data = UserDefaults.standard.data(forKey: Self.resultsKey),
              let decoded = try? JSONDecoder().decode([String: BenchmarkResult].self, from: data)
        else { return [:] }
        return decoded
    }

    /// Load result for a specific model.
    func result(for modelID: String) -> BenchmarkResult? {
        loadResults()[modelID]
    }

    /// Persist results.
    private func save(_ results: [String: BenchmarkResult]) {
        if let data = try? JSONEncoder().encode(results) {
            UserDefaults.standard.set(data, forKey: Self.resultsKey)
        }
    }

    // MARK: - Run Benchmark

    /// Run the benchmark suite against a model via the given LLM client.
    /// This sends each test prompt, examines the response for a valid
    /// tool call JSON block, and classifies the outcome.
    ///
    /// - Parameters:
    ///   - client: The LLM client to use (typically `MLXLLMClient`).
    ///   - modelID: Model identifier for result storage.
    ///   - testCases: The prompts to test. Defaults to `defaultTestCases`.
    /// - Returns: The benchmark result.
    func run(
        client: LLMClient,
        modelID: String,
        testCases: [TestCase] = defaultTestCases
    ) async -> BenchmarkResult {
        var correct = 0
        var refusals = 0
        var hallucinations = 0
        var totalLatency: Double = 0

        for testCase in testCases {
            let messages = [
                LLMMessage(role: .system, content: "You are a helpful assistant. When the user asks you to perform an action, respond ONLY with a JSON object containing the tool call. Format: {\"tool\": \"tool_name\", \"input\": {\"param\": \"value\"}, \"reason\": \"brief explanation\"}"),
                LLMMessage(role: .user, content: testCase.prompt)
            ]

            let options = ChatOptions(temperature: 0.1, maxTokens: 256, stream: false)

            let start = CFAbsoluteTimeGetCurrent()
            do {
                let response = try await client.completeChat(
                    messages: messages,
                    model: modelID,
                    options: options
                )
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                totalLatency += elapsed

                let output = response.message.content.trimmingCharacters(in: .whitespacesAndNewlines)

                // Classify the response.
                let classification = classify(
                    output: output,
                    expectedTool: testCase.expectedTool,
                    expectedParam: testCase.expectedParam
                )

                switch classification {
                case .correct: correct += 1
                case .refusal: refusals += 1
                case .hallucination: hallucinations += 1
                }
            } catch {
                // Network/model error counts as refusal.
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                totalLatency += elapsed
                refusals += 1
            }
        }

        let result = BenchmarkResult(
            modelID: modelID,
            date: Date(),
            totalPrompts: testCases.count,
            correctToolCalls: correct,
            refusals: refusals,
            hallucinations: hallucinations,
            averageLatencyMs: testCases.isEmpty ? 0 : totalLatency / Double(testCases.count)
        )

        // Persist.
        var allResults = loadResults()
        allResults[modelID] = result
        save(allResults)

        return result
    }

    // MARK: - Classification

    private enum ResponseClassification {
        case correct
        case refusal
        case hallucination
    }

    /// Classify a model's text output against expected tool + param.
    private func classify(output: String, expectedTool: String, expectedParam: String?) -> ResponseClassification {
        // Check for common refusal patterns.
        let lower = output.lowercased()
        let refusalPatterns = [
            "i can't", "i cannot", "i'm unable", "i am unable",
            "i don't have", "i do not have", "sorry",
            "as an ai", "as a language model"
        ]
        if refusalPatterns.contains(where: { lower.contains($0) }), !lower.contains("\"tool\"") {
            return .refusal
        }

        // Try to extract tool name from JSON.
        if let toolName = extractToolName(from: output) {
            if toolName == expectedTool {
                return .correct
            } else {
                // Wrong tool = hallucination.
                return .hallucination
            }
        }

        // No JSON found — might be a natural-language refusal or failure.
        if lower.contains(expectedTool) {
            // Mentioned the right tool but didn't format as JSON.
            // Count as hallucination (wrong format).
            return .hallucination
        }

        return .refusal
    }

    /// Extract the "tool" value from a JSON object in the output.
    private func extractToolName(from text: String) -> String? {
        // Find JSON-like content between braces.
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end
        else { return nil }

        let jsonString = String(text[start ... end])
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = json["tool"] as? String
        else { return nil }

        return tool
    }
}
