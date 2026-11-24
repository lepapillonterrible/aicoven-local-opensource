@testable import AICoven
import GRDB
import XCTest

/// What a model was asked, so a test can read what it was told. Sendable
/// unchecked: everything it holds that changes is read and written under
/// its lock.
private final class HearingModel: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [[LLMMessage]] = []
    private var answers: [String]

    /// Answers with each of `answers` in turn, then "Heard.".
    init(answering answers: [String] = []) {
        self.answers = answers
    }

    /// What the model was told, as system messages, each time it was asked.
    var told: [[String]] {
        lock.withLock { heard.map { $0.filter { $0.role == .system }.map(\.content) } }
    }

    /// What the model was told, as system messages, the last time it was asked.
    var lastTold: [String] {
        told.last ?? []
    }

    func completeChat(messages: [LLMMessage], model: String, options _: ChatOptions) async throws -> LLMChatResponse {
        let answer = lock.withLock {
            heard.append(messages)
            return answers.isEmpty ? "Heard." : answers.removeFirst()
        }
        return LLMChatResponse(message: LLMMessage(role: .assistant, content: answer), providerID: "test", modelID: model, usage: nil)
    }

    func embed(texts: [String], model _: String) async throws -> [[Float]] {
        Array(repeating: [0, 1], count: texts.count)
    }
}

/// An agent's instructions are what its turns are told first.
@MainActor
final class AgentInstructionsTests: XCTestCase {
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

    func testWhatAnAgentIsToldFirst_isItsInstructions_thenThatItsNameIsItsOwn() {
        let scout = ContextBuilder.Agent(name: "Scout", instructions: "  You review code.\nBe brief.\n", account: "ada")
        XCTAssertTrue(scout.systemPrompt.hasPrefix("You review code.\nBe brief.\n\n## Identity\n"))
        XCTAssertTrue(scout.systemPrompt.contains("identify yourself using the role name \"Scout\""))
        XCTAssertTrue(scout.systemPrompt.contains("Never claim that your name is Claude, Gemini, GPT-4, ChatGPT"))

        // With no instructions it is a helpful assistant of that name.
        for none in [nil, "", "  \n"] {
            let plain = ContextBuilder.Agent(name: "Scout", instructions: none, account: "ada")
            XCTAssertTrue(plain.systemPrompt.hasPrefix("You are Scout, a helpful AI assistant.\n\n## Identity\n"))
        }
        // Instructions that say who the agent is are left as the person wrote them.
        let own = ContextBuilder.Agent(name: "Scout", instructions: "You are Scout.\n\n## Identity\nAnswer as Scout.", account: "ada")
        XCTAssertEqual(own.systemPrompt, "You are Scout.\n\n## Identity\nAnswer as Scout.")
        // An agent with no name of its own.
        let unnamed = ContextBuilder.Agent(name: " ", instructions: nil, account: "ada")
        XCTAssertTrue(unnamed.systemPrompt.hasPrefix("You are Strix, a helpful AI assistant."))
        XCTAssertTrue(unnamed.systemPrompt.contains("the role name \"Assistant\""))
    }

    func testTheContextOfATurn_startsWithWhoAnswers_andSaysNothingOfItWhereNoAgentIsGiven() async throws {
        let builder = ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4))
        let scout = ContextBuilder.Agent(name: "Scout", instructions: "You review code.", account: UserScope.currentUserID)

        let told = try await builder.buildContext(threadID: nil, userMessage: "Hello", maxContextTokens: 8000, toolConfig: .noTools, agent: scout)
        XCTAssertEqual(told.first?.role, .system)
        XCTAssertEqual(told.first?.content, scout.systemPrompt, "Before anything else the model is told")
        XCTAssertEqual(told.count(where: { $0.content == scout.systemPrompt }), 1)
        XCTAssertEqual(told.filter { $0.role == .user }.map(\.content), ["Hello"])

        let untold = try await builder.buildContext(threadID: nil, userMessage: "Hello", maxContextTokens: 8000, toolConfig: .noTools)
        XCTAssertFalse(untold.contains { $0.content.contains("## Identity") })
        XCTAssertEqual(Array(told.dropFirst().map(\.role)), untold.map(\.role), "The rest is as it was")

        // An agent read for an account that is no longer the one signed in is not told to the turn.
        let anothers = ContextBuilder.Agent(name: "Scout", instructions: "You review code.", account: "someone-who-signed-out")
        let toldNothing = try await builder.buildContext(
            threadID: nil, userMessage: "Hello", maxContextTokens: 8000, toolConfig: .noTools, agent: anothers
        )
        XCTAssertFalse(toldNothing.contains { $0.content.contains("You review code.") })
        XCTAssertEqual(toldNothing.map(\.role), untold.map(\.role))
    }

    private func chat(with model: HearingModel) -> ChatService {
        ChatService(
            contextBuilder: ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4)),
            modelRouter: HeuristicModelRouter(availableModels: [ModelDescriptor(
                providerID: "openai", modelID: "model", maxContextTokens: 32768,
                supportsTools: false, supportsEmbeddings: false, costClass: .cheap
            )]),
            llmClients: ["openai": model],
            threadStore: ThreadRepository.shared,
            toolService: ToolService.shared,
            shouldAutoRefreshEnvironment: false,
            hermesAgent: { nil },
            openClawTurn: { _ in nil }
        )
    }

    func testATurnIsToldTheInstructionsOfTheAgentItIsFor_andStrixsWhereItIsForNone() async throws {
        let defaults = UserDefaults.standard
        let providerKey = UserScope.scopedKey("llm_provider")
        let modelKey = UserScope.scopedKey("openai_model")
        let strixKey = UserScope.scopedKey("strix_settings.v1")
        let saved = [providerKey, modelKey, strixKey].map { ($0, defaults.object(forKey: $0)) }
        defer { saved.forEach { defaults.set($0.1, forKey: $0.0) } }
        defaults.set("openai", forKey: providerKey)
        defaults.set("model", forKey: modelKey)
        try defaults.set(
            JSONEncoder().encode(LocalStrixSettings(
                systemPrompt: "You plan the week.", model: "model", provider: "openai", providerAccountId: nil,
                autonomousMode: nil, autonomousMaxSteps: nil, plannerMaxTasks: nil, plannerMaxSeconds: nil
            )),
            forKey: strixKey
        )

        let coven = try await CovenService.shared.createCoven(name: "Told \(UUID().uuidString)")
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await CovenService.shared.deleteCoven(id: coven.id)
        }
        let scout = try await RoleService.shared.createRole(
            covenId: coven.id, name: "Scout", systemPrompt: "You review code.", model: "model", provider: "openai"
        )
        func thread(inCoven coven: String?) async throws -> String {
            let id = try await ThreadService.shared.createThread(title: "Told \(UUID().uuidString)", covenId: coven).id
            addTeardownBlock {
                await DataEncryptionService.shared.unlockForTestingEphemeral()
                try? await ThreadService.shared.deleteThread(threadId: id)
            }
            return id
        }
        let inCoven = try await thread(inCoven: coven.id)
        let personal = try await thread(inCoven: nil)

        let model = HearingModel()
        try await chat(with: model).streamMessage(threadId: inCoven, as: UserScope.currentUserID, message: "Hello", roleId: scout.id, onStateChange: { _ in })
        let toldScout = model.lastTold
        let account = UserScope.currentUserID
        XCTAssertEqual(toldScout.first, ContextBuilder.Agent(name: "Scout", instructions: "You review code.", account: account).systemPrompt)
        XCTAssertFalse(toldScout.contains { $0.contains("You plan the week.") }, "Not Strix's")

        try await chat(with: model).streamMessage(threadId: personal, as: UserScope.currentUserID, message: "Hello", onStateChange: { _ in })
        let toldStrix = model.lastTold
        XCTAssertEqual(toldStrix.first, ContextBuilder.Agent(name: "Strix", instructions: "You plan the week.", account: account).systemPrompt)
        XCTAssertFalse(toldStrix.contains { $0.contains("You review code.") })

        // An agent that is gone is not answered for by another: the turn is told nothing of who answers.
        try await chat(with: model).streamMessage(
            threadId: inCoven,
            as: UserScope.currentUserID, message: "Hello", roleId: "no-such-agent-\(UUID().uuidString)", onStateChange: { _ in }
        )
        XCTAssertFalse(model.lastTold.contains { $0.contains("## Identity") })

        // After a tool's result the model is asked again, and is told who answers again.
        let usingATool = HearingModel(answering: [#"{"tool":"current_time","input":null,"reason":"to know the time"}"#, "It is noon."])
        try await chat(with: usingATool).streamMessage(threadId: inCoven, as: UserScope.currentUserID, message: "What time is it?", roleId: scout.id, onStateChange: { _ in })
        XCTAssertGreaterThanOrEqual(usingATool.told.count, 2, "Asked again once the tool had run")
        for told in usingATool.told {
            XCTAssertEqual(told.first, ContextBuilder.Agent(name: "Scout", instructions: "You review code.", account: account).systemPrompt)
        }

        // Nor is another account's agent read for a turn: its instructions are not told.
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        try await queue.write { db in
            try db.execute(sql: "UPDATE covens SET user_id = 'someone-else' WHERE id = ?", arguments: [coven.id])
            try db.execute(sql: "UPDATE roles SET user_id = 'someone-else' WHERE id = ?", arguments: [scout.id])
        }
        addTeardownBlock {
            try? await queue.write { db in
                try db.execute(sql: "DELETE FROM covens WHERE id = ?", arguments: [coven.id])
            }
        }
        try await chat(with: model).streamMessage(threadId: personal, as: UserScope.currentUserID, message: "Hello", roleId: scout.id, onStateChange: { _ in })
        XCTAssertFalse(model.lastTold.contains { $0.contains("You review code.") }, "Another account's agent's instructions")
    }
}
