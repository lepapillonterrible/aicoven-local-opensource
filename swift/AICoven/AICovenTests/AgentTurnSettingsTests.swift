@testable import AICoven
import XCTest

/// What a model was asked with, each time it was asked. Sendable
/// unchecked: what it holds that changes is read and written under its lock.
private final class OptionsHearingModel: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [ChatOptions] = []
    private let answer: @Sendable (Int) -> String

    /// Answers each request with what `answer` gives for its number, from 0.
    init(answering answer: @escaping @Sendable (Int) -> String = { _ in "Heard." }) {
        self.answer = answer
    }

    var asked: [ChatOptions] {
        lock.withLock { heard }
    }

    func completeChat(messages _: [LLMMessage], model: String, options: ChatOptions) async throws -> LLMChatResponse {
        let number = lock.withLock {
            heard.append(options)
            return heard.count - 1
        }
        return LLMChatResponse(message: LLMMessage(role: .assistant, content: answer(number)), providerID: "test", modelID: model, usage: nil)
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
        // An agent's turn takes as many steps as the agent says, and not steps without end.
        XCTAssertEqual(AgentTurnSettings(of: role(temperature: nil, maxTokens: nil, steps: 1)).mostSteps, 1)
        XCTAssertEqual(AgentTurnSettings(of: role(temperature: nil, maxTokens: nil, steps: 30)).mostSteps, 30)
        XCTAssertEqual(AgentTurnSettings(of: role(temperature: nil, maxTokens: nil, steps: 100_000)).mostSteps, 100)
    }

    func testWhatATurnTakesFromStrixsSettings() {
        XCTAssertEqual(AgentTurnSettings(ofStrix: nil), .standard, "Nothing stored")
        XCTAssertEqual(AgentTurnSettings(ofStrix: LocalStrixSettings()), .standard)
        XCTAssertEqual(
            AgentTurnSettings(ofStrix: LocalStrixSettings(autonomousMaxSteps: 12, temperature: 0.3, maxTokens: 900)),
            AgentTurnSettings(temperature: 0.3, maxTokens: 900, mostSteps: 12)
        )
        let odd = AgentTurnSettings(ofStrix: LocalStrixSettings(autonomousMaxSteps: 100_000, temperature: 5, maxTokens: 0))
        XCTAssertEqual(odd, AgentTurnSettings(temperature: 2, maxTokens: nil, mostSteps: 100))
        XCTAssertNil(AgentTurnSettings(ofStrix: LocalStrixSettings(autonomousMaxSteps: 0)).mostSteps)
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

    /// Which model a turn's client was asked for.
    private final class ModelHearingModel: LLMClient, @unchecked Sendable {
        private let lock = NSLock()
        private var heard: [String] = []

        var asked: [String] {
            lock.withLock { heard }
        }

        func completeChat(messages _: [LLMMessage], model: String, options _: ChatOptions) async throws -> LLMChatResponse {
            lock.withLock { heard.append(model) }
            return LLMChatResponse(message: LLMMessage(role: .assistant, content: "Heard."), providerID: "mlx", modelID: model, usage: nil)
        }

        func embed(texts: [String], model _: String) async throws -> [[Float]] {
            Array(repeating: [0, 1], count: texts.count)
        }
    }

    func testATurnForAnAgentOnThisDeviceIsAnsweredByTheModelThatIsActiveThere() async throws {
        let defaults = UserDefaults.standard
        let activeKey = "MLXModelManager.activeModelID"
        let was = defaults.object(forKey: activeKey)
        defer { defaults.set(was, forKey: activeKey) }
        defaults.set("active-now", forKey: activeKey)

        let coven = try await CovenService.shared.createCoven(name: "Device \(UUID().uuidString)")
        let thread = try await ThreadService.shared.createThread(title: "Device \(UUID().uuidString)", covenId: coven.id).id
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await ThreadService.shared.deleteThread(threadId: thread)
            try? await CovenService.shared.deleteCoven(id: coven.id)
        }
        // Saved while another model was the active one.
        let agent = try await RoleService.shared.createRole(covenId: coven.id, name: "Scout", model: "saved-earlier", provider: "mlx")
        let model = ModelHearingModel()
        let chat = ChatService(
            contextBuilder: ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4)),
            modelRouter: HeuristicModelRouter(availableModels: [
                // The router knows the model that is active on the device, and one elsewhere.
                ModelDescriptor(providerID: "mlx", modelID: "active-now", maxContextTokens: 4096, supportsTools: false, supportsEmbeddings: false, costClass: .free),
                ModelDescriptor(providerID: "other", modelID: "elsewhere", maxContextTokens: 200_000, supportsTools: true, supportsEmbeddings: false, costClass: .expensive),
            ]),
            llmClients: ["mlx": model, "other": ModelHearingModel()],
            threadStore: ThreadRepository.shared,
            toolService: ToolService.shared,
            shouldAutoRefreshEnvironment: false,
            hermesAgent: { nil },
            openClawTurn: { _ in nil }
        )

        try await chat.streamMessage(threadId: thread, as: UserScope.currentUserID, message: "Hello", roleId: agent.id, onStateChange: { _ in })

        XCTAssertFalse(model.asked.isEmpty, "The model on this device answers, not one elsewhere")
        XCTAssertEqual(Set(model.asked), ["active-now"], "The one that is active, whichever was stored with the agent")
    }

    func testATurnAsksWithItsAgentsTemperatureAndLongestAnswer_andWithTheAppsOwnForNoAgent() async throws {
        let defaults = UserDefaults.standard
        let keys = ["llm_provider", "anthropic_model", "openai_model", "strix_settings.v1"].map(UserScope.scopedKey)
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { saved.forEach { defaults.set($0.1, forKey: $0.0) } }
        defaults.set("anthropic", forKey: keys[0])
        defaults.set("model", forKey: keys[1])
        defaults.set("model", forKey: keys[2])
        // Strix has nothing of its own stored yet.
        defaults.removeObject(forKey: keys[3])

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
            threadId: thread(inCoven: coven.id),
            as: UserScope.currentUserID, message: "Hello", roleId: agent(on: "anthropic").id, onStateChange: { _ in }
        )
        XCTAssertFalse(claude.asked.isEmpty)
        XCTAssertEqual(Set(claude.asked.map(\.temperature)), [0.3])
        XCTAssertEqual(Set(claude.asked.map(\.maxTokens)), [900])

        // An agent on OpenAI: its temperature; no longest answer is sent there.
        let gpt = OptionsHearingModel()
        try await chat(with: gpt, as: "openai").streamMessage(
            threadId: thread(inCoven: coven.id),
            as: UserScope.currentUserID, message: "Hello", roleId: agent(on: "openai").id, onStateChange: { _ in }
        )
        XCTAssertEqual(Set(gpt.asked.map(\.temperature)), [0.3])
        XCTAssertEqual(Set(gpt.asked.map(\.maxTokens)), [nil])

        // A turn for no agent is Strix's: the app's own while Strix has none stored.
        let strix = OptionsHearingModel()
        try await chat(with: strix, as: "anthropic").streamMessage(threadId: thread(inCoven: nil), as: UserScope.currentUserID, message: "Hello", onStateChange: { _ in })
        XCTAssertEqual(Set(strix.asked.map(\.temperature)), [0.7])
        XCTAssertEqual(Set(strix.asked.map(\.maxTokens)), [nil])

        // And Strix's own once it has them, as an agent's.
        try defaults.set(
            JSONEncoder().encode(LocalStrixSettings(model: "model", provider: "anthropic", temperature: 1.2, maxTokens: 1500)), forKey: keys[3]
        )
        let set = OptionsHearingModel()
        try await chat(with: set, as: "anthropic").streamMessage(threadId: thread(inCoven: nil), as: UserScope.currentUserID, message: "Hello", onStateChange: { _ in })
        XCTAssertEqual(Set(set.asked.map(\.temperature)), [1.2])
        XCTAssertEqual(Set(set.asked.map(\.maxTokens)), [1500])
    }

    /// What a model that asks for a tool every time it is asked is asked
    /// with in one turn: it is asked once for each tool step it is given,
    /// and then for its answer. Each time it asks for the time somewhere
    /// else, so that no step is taken for a repeat of the one before.
    private func askings(
        ofATurnFor role: String?, inCoven coven: String?, as provider: String = "anthropic"
    ) async throws -> [ChatOptions] {
        let id = try await ThreadService.shared.createThread(title: "Steps \(UUID().uuidString)", covenId: coven).id
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await ThreadService.shared.deleteThread(threadId: id)
        }
        let places = [
            "Asia/Tokyo", "Europe/Paris", "America/New_York", "Australia/Sydney", "Africa/Cairo", "Asia/Kolkata",
            "America/Sao_Paulo", "Europe/London", "Asia/Bangkok", "Pacific/Auckland", "America/Chicago", "Europe/Athens",
        ]
        let model = OptionsHearingModel { number in
            #"{"tool":"current_time","input":{"timezone":"\#(places[number % places.count])"},"reason":"to know the time there"}"#
        }
        try await chat(with: model, as: provider).streamMessage(threadId: id, as: UserScope.currentUserID, message: "What time is it?", roleId: role, onStateChange: { _ in })
        return model.asked
    }

    func testATurnTakesAsManyToolStepsAsItsAgentAllows_andAsksEachWithItsSettings() async throws {
        let defaults = UserDefaults.standard
        let keys = ["llm_provider", "anthropic_model", "chat_max_tool_steps", "strix_settings.v1"].map(UserScope.scopedKey)
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { saved.forEach { defaults.set($0.1, forKey: $0.0) } }
        defaults.set("anthropic", forKey: keys[0])
        defaults.set("model", forKey: keys[1])
        defaults.set(3, forKey: keys[2])
        defaults.removeObject(forKey: keys[3])

        let coven = try await CovenService.shared.createCoven(name: "Steps \(UUID().uuidString)")
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await CovenService.shared.deleteCoven(id: coven.id)
        }
        func agent(steps: Int?) async throws -> String {
            try await RoleService.shared.createRole(
                covenId: coven.id, name: "Scout \(steps ?? 0)", model: "model", provider: "anthropic",
                temperature: 0.3, maxTokens: 900, autonomousMaxSteps: steps
            ).id
        }

        // The app's own number, for a turn that is for no agent and for an agent that sets none.
        let strix = try await askings(ofATurnFor: nil, inCoven: nil)
        let unset = try await askings(ofATurnFor: agent(steps: nil), inCoven: coven.id)
        // The agent's own.
        let seven = try await askings(ofATurnFor: agent(steps: 7), inCoven: coven.id)
        let nine = try await askings(ofATurnFor: agent(steps: 9), inCoven: coven.id)

        XCTAssertEqual(unset.count, strix.count, "An agent that sets none takes the app's")
        XCTAssertEqual(seven.count - strix.count, 4, "Seven steps where the app gives three")
        XCTAssertEqual(nine.count - seven.count, 2)
        // Every asking of the turn, the tool steps and the answer alike, is with the agent's settings.
        XCTAssertEqual(Set(seven.map(\.temperature)), [0.3])
        XCTAssertEqual(Set(seven.map(\.maxTokens)), [900])
        XCTAssertEqual(Set(strix.map(\.temperature)), [0.7])
        XCTAssertEqual(Set(strix.map(\.maxTokens)), [nil])

        // Strix's own limit, once it has one, as an agent's.
        try defaults.set(JSONEncoder().encode(LocalStrixSettings(model: "model", provider: "anthropic", autonomousMaxSteps: 6)), forKey: keys[3])
        let strixWithSix = try await askings(ofATurnFor: nil, inCoven: nil)
        XCTAssertEqual(strixWithSix.count - strix.count, 3, "Six steps where the app gives three")
    }
}
