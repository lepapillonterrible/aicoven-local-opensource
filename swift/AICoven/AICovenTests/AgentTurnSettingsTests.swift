@testable import AICoven
import XCTest

/// What a model was asked with, each time it was asked. Sendable
/// unchecked: what it holds that changes is read and written under its lock.
private final class OptionsHearingModel: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [ChatOptions] = []

    var asked: [ChatOptions] {
        lock.withLock { heard }
    }

    func completeChat(messages _: [LLMMessage], model: String, options: ChatOptions) async throws -> LLMChatResponse {
        lock.withLock { heard.append(options) }
        return LLMChatResponse(message: LLMMessage(role: .assistant, content: "Heard."), providerID: "test", modelID: model, usage: nil)
    }

    func embed(texts: [String], model _: String) async throws -> [[Float]] {
        Array(repeating: [0, 1], count: texts.count)
    }
}

/// A turn uses the settings of the agent it is for.
@MainActor
final class AgentTurnSettingsTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        await ThreadService.shared.reloadForCurrentUser()
    }

    override func tearDown() async throws {
        await DataEncryptionService.shared.lock()
        try await super.tearDown()
    }

    private func role(temperature: Double?, maxTokens: Int?, steps: Int?) -> Role {
        Role(
            id: "r", covenId: "c", name: "Scout", emoji: nil, description: nil, systemPrompt: nil,
            model: "model", provider: "openai", providerAccountId: nil, temperature: temperature, maxTokens: maxTokens,
            settings: RoleSettings(
                toolConfig: nil, allowedTools: nil, collaboratorRoleIds: nil, autonomousMode: nil,
                autonomousMaxSteps: steps, plannerMaxTasks: nil, plannerMaxSeconds: nil
            ),
            createdAt: Date(), updatedAt: Date()
        )
    }

    func testWhatATurnTakesFromItsAgentsSettings() {
        XCTAssertEqual(
            AgentTurnSettings(of: role(temperature: 0.3, maxTokens: 900, steps: 12)),
            AgentTurnSettings(temperature: 0.3, maxTokens: 900, mostSteps: 12)
        )
        // An agent that says nothing takes the app's own.
        XCTAssertEqual(AgentTurnSettings(of: role(temperature: nil, maxTokens: nil, steps: nil)), .standard)
        XCTAssertEqual(AgentTurnSettings.standard, AgentTurnSettings(temperature: 0.7, maxTokens: nil, mostSteps: nil))
        // A stored zero is a real temperature; one out of range is brought in.
        XCTAssertEqual(AgentTurnSettings(of: role(temperature: 0, maxTokens: nil, steps: nil)).temperature, 0)
        XCTAssertEqual(AgentTurnSettings(of: role(temperature: 3, maxTokens: nil, steps: nil)).temperature, 2)
        XCTAssertEqual(AgentTurnSettings(of: role(temperature: -1, maxTokens: nil, steps: nil)).temperature, 0)
        // A number that is no limit is none.
        XCTAssertNil(AgentTurnSettings(of: role(temperature: nil, maxTokens: 0, steps: 0)).maxTokens)
        XCTAssertNil(AgentTurnSettings(of: role(temperature: nil, maxTokens: -5, steps: -1)).mostSteps)
        // An agent's turn has at least five steps, as in the cloud app, and not steps without end.
        XCTAssertEqual(AgentTurnSettings(of: role(temperature: nil, maxTokens: nil, steps: 1)).mostSteps, 5)
        XCTAssertEqual(AgentTurnSettings(of: role(temperature: nil, maxTokens: nil, steps: 30)).mostSteps, 30)
        XCTAssertEqual(AgentTurnSettings(of: role(temperature: nil, maxTokens: nil, steps: 100_000)).mostSteps, 100)
    }

    func testTheMostToolStepsOfATurnAreItsAgentsOwn_elseTheApps() {
        let key = UserScope.scopedKey("chat_max_tool_steps")
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(3, forKey: key)

        XCTAssertEqual(ChatService.mostToolSteps(of: .standard), 3)
        XCTAssertEqual(ChatService.mostToolSteps(of: AgentTurnSettings(temperature: 0.7, maxTokens: nil, mostSteps: 30)), 30)
    }

    func testWhichSettingsATurnUsesByWhatAnswersIt() {
        XCTAssertTrue(AgentTurnSettings.usesMaxTokens(provider: "anthropic"))
        XCTAssertTrue(AgentTurnSettings.usesMaxTokens(provider: "MLX"))
        for provider in ["openai", "openrouter", "google", "ollama", "openclaw", "openai_compatible", "hermes"] {
            XCTAssertFalse(AgentTurnSettings.usesMaxTokens(provider: provider), provider)
        }
        XCTAssertTrue(AgentTurnSettings.usesTemperature(provider: "openai", model: "gpt-4o"))
        XCTAssertFalse(AgentTurnSettings.usesTemperature(provider: "openai", model: "gpt-5-mini"))
        XCTAssertTrue(AgentTurnSettings.usesTemperature(provider: "anthropic", model: "claude-sonnet-4-6"))
        XCTAssertFalse(AgentTurnSettings.usesTemperature(provider: "anthropic", model: "claude-haiku-5-5"))
        XCTAssertTrue(AgentTurnSettings.usesTemperature(provider: "google", model: "gemini-3.5-flash"))
        XCTAssertTrue(AgentTurnSettings.usesTemperature(provider: "ollama", model: "llama3.2"))
        XCTAssertFalse(AgentTurnSettings.usesTemperature(provider: "mlx", model: "mlx-community/Qwen3-4B-4bit"))
        XCTAssertFalse(AgentTurnSettings.usesTemperature(provider: "hermes", model: ""))

        XCTAssertTrue(AgentTurnSettings.runsItself(provider: "Hermes", hasGateway: false))
        XCTAssertTrue(AgentTurnSettings.runsItself(provider: "openclaw", hasGateway: true))
        XCTAssertFalse(AgentTurnSettings.runsItself(provider: "openclaw", hasGateway: false), "Without a Gateway its turns are a model's")
        XCTAssertFalse(AgentTurnSettings.runsItself(provider: "anthropic", hasGateway: true))
    }

    // MARK: - A turn

    private func chat(with model: OptionsHearingModel, as provider: String) -> ChatService {
        ChatService(
            contextBuilder: ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4)),
            modelRouter: HeuristicModelRouter(availableModels: [ModelDescriptor(
                providerID: provider, modelID: "model", maxContextTokens: 32768,
                supportsTools: false, supportsEmbeddings: false, costClass: .cheap
            )]),
            llmClients: [provider: model],
            threadStore: ThreadRepository.shared,
            toolService: ToolService.shared,
            shouldAutoRefreshEnvironment: false,
            hermesAgent: { nil },
            openClawTurn: { _ in nil }
        )
    }

    func testATurnAsksWithItsAgentsTemperatureAndLongestAnswer_andWithTheAppsOwnForNoAgent() async throws {
        let defaults = UserDefaults.standard
        let keys = ["llm_provider", "anthropic_model", "openai_model"].map(UserScope.scopedKey)
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { saved.forEach { defaults.set($0.1, forKey: $0.0) } }
        defaults.set("anthropic", forKey: keys[0])
        defaults.set("model", forKey: keys[1])
        defaults.set("model", forKey: keys[2])

        let coven = try await CovenService.shared.createCoven(name: "Settings \(UUID().uuidString)")
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await CovenService.shared.deleteCoven(id: coven.id)
        }
        func agent(on provider: String) async throws -> Role {
            try await RoleService.shared.createRole(
                covenId: coven.id, name: "Scout \(provider)", model: "model", provider: provider, temperature: 0.3, maxTokens: 900
            )
        }
        func thread(inCoven coven: String?) async throws -> String {
            let id = try await ThreadService.shared.createThread(title: "Settings \(UUID().uuidString)", covenId: coven).id
            addTeardownBlock {
                await DataEncryptionService.shared.unlockForTestingEphemeral()
                try? await ThreadService.shared.deleteThread(threadId: id)
            }
            return id
        }

        // An agent on Anthropic: its temperature and its longest answer.
        let claude = OptionsHearingModel()
        try await chat(with: claude, as: "anthropic").streamMessage(
            threadId: thread(inCoven: coven.id), message: "Hello", roleId: agent(on: "anthropic").id, onStateChange: { _ in }
        )
        XCTAssertFalse(claude.asked.isEmpty)
        XCTAssertEqual(Set(claude.asked.map(\.temperature)), [0.3])
        XCTAssertEqual(Set(claude.asked.map(\.maxTokens)), [900])

        // An agent on OpenAI: its temperature; no longest answer is sent there.
        let gpt = OptionsHearingModel()
        try await chat(with: gpt, as: "openai").streamMessage(
            threadId: thread(inCoven: coven.id), message: "Hello", roleId: agent(on: "openai").id, onStateChange: { _ in }
        )
        XCTAssertEqual(Set(gpt.asked.map(\.temperature)), [0.3])
        XCTAssertEqual(Set(gpt.asked.map(\.maxTokens)), [nil])

        // A turn for no agent: the app's own.
        let strix = OptionsHearingModel()
        try await chat(with: strix, as: "anthropic").streamMessage(threadId: thread(inCoven: nil), message: "Hello", onStateChange: { _ in })
        XCTAssertEqual(Set(strix.asked.map(\.temperature)), [0.7])
        XCTAssertEqual(Set(strix.asked.map(\.maxTokens)), [nil])
    }
}
