@testable import AICoven
import XCTest

/// A provider that embeds, and counts what it was asked to embed.
private final class CountingEmbedder: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []

    var questions: [String] {
        lock.withLock { asked }
    }

    func completeChat(messages _: [LLMMessage], model: String, options _: ChatOptions) async throws -> LLMChatResponse {
        LLMChatResponse(message: LLMMessage(role: .assistant, content: ""), providerID: "test", modelID: model, usage: nil)
    }

    func embed(texts: [String], model _: String) async throws -> [[Float]] {
        lock.withLock { asked += texts }
        return Array(repeating: [0, 1], count: texts.count)
    }
}

/// What a turn handed to an agent of the person's own (Hermes, an
/// OpenClaw Gateway) is told before the conversation.
@MainActor
final class AgentsToldTests: XCTestCase {
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

    private var account: String {
        UserScope.currentUserID
    }

    func testTheQuestionOfAnAgentsRunIsNotSentToBeEmbedded_andItsMemoriesAreMatchedByTheirWords() async throws {
        let embedder = CountingEmbedder()
        let embedding = EmbeddingService(environment: (
            models: [ModelDescriptor(
                providerID: "test", modelID: "embedder", maxContextTokens: 8_000,
                supportsTools: false, supportsEmbeddings: true, costClass: .cheap
            )],
            clients: ["test": embedder]
        ))
        let builder = ContextBuilder(embeddingService: embedding, limits: .init(maxRecentMessages: 4, maxRecentMemories: 1))
        let coven = try await CovenService.shared.createCoven(name: "Told \(UUID().uuidString)")
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await CovenService.shared.deleteCoven(id: coven.id)
        }
        let thread = try await ThreadService.shared.createThread(title: "Told \(UUID().uuidString)", covenId: coven.id).id
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await ThreadService.shared.deleteThread(threadId: thread)
        }
        for text in ["Dana runs design", "The office closes at six"] {
            _ = try await MemoryRepository.shared.storeMemory(
                in: .coven(coven.id), text: text, tags: [], pii: false, createdBy: nil, source: nil, embedding: nil, as: account
            )
        }
        let scout = ContextBuilder.Agent(name: "Scout", instructions: "You review code.", account: account)

        let told = try await builder.preface(threadID: thread, question: "Who runs design?", agent: scout)

        XCTAssertEqual(embedder.questions, [], "The question goes to the agent and nowhere else")
        XCTAssertEqual(told?.contains("Dana runs design"), true, "The one memory told is the one whose words match, not the newest")
        XCTAssertEqual(told?.contains("The office closes at six"), false)

        // A model's turn has its question embedded, as before.
        _ = try await embedding.searchRelevantMemories(query: "Who runs design?", in: [.coven(coven.id)], of: account)
        XCTAssertEqual(embedder.questions, ["Who runs design?"])
    }

    func testAnAgentsRunIsToldWhoAnswers_whatItsScopeKnows_andTheMemoriesThatBearOnTheQuestion() async throws {
        let builder = ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4))
        let coven = try await CovenService.shared.createCoven(name: "Told \(UUID().uuidString)")
        let empty = try await CovenService.shared.createCoven(name: "Told \(UUID().uuidString)")
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await CovenService.shared.deleteCoven(id: coven.id)
            try? await CovenService.shared.deleteCoven(id: empty.id)
        }
        func thread(inCoven coven: String) async throws -> String {
            let id = try await ThreadService.shared.createThread(title: "Told \(UUID().uuidString)", covenId: coven).id
            addTeardownBlock {
                await DataEncryptionService.shared.unlockForTestingEphemeral()
                try? await ThreadService.shared.deleteThread(threadId: id)
            }
            return id
        }
        let inCoven = try await thread(inCoven: coven.id)
        let inEmpty = try await thread(inCoven: empty.id)
        try await CovenContextRepository.shared.setContext("We ship on Fridays.", forCoven: coven.id, as: account)
        _ = try await MemoryRepository.shared.storeMemory(
            in: .coven(coven.id), text: "Dana runs design", tags: [], pii: false, createdBy: nil, source: nil, embedding: nil, as: account
        )
        let scout = ContextBuilder.Agent(name: "Scout", instructions: "You review code.", account: account)

        let told = try await builder.preface(threadID: inCoven, question: "Who runs design?", agent: scout)
        let whole = try XCTUnwrap(told)
        XCTAssertEqual(whole, """
        \(scout.systemPrompt)

        ## Coven Context
        We ship on Fridays.

        Relevant memories (for your reasoning; avoid reciting private details verbatim):
        - [scope=coven] Dana runs design
        """)
        XCTAssertFalse(whole.contains("TOOL"), "Nothing of this app's own tools is said: the agent runs its own")

        // With no agent given, what the scope knows and its memories are still told.
        let withoutAgent = try await builder.preface(threadID: inCoven, question: "Who runs design?", agent: nil)
        XCTAssertEqual(withoutAgent?.hasPrefix("## Coven Context\nWe ship on Fridays."), true)
        // In a scope that knows and remembers nothing, only who answers; and with nobody to answer, nothing.
        let onlyWho = try await builder.preface(threadID: inEmpty, question: "Who runs design?", agent: scout)
        XCTAssertEqual(onlyWho, scout.systemPrompt)
        let nothing = try await builder.preface(threadID: inEmpty, question: "Who runs design?", agent: nil)
        XCTAssertNil(nothing)
        // An agent read for an account that is not the one signed in is not told.
        let anothers = ContextBuilder.Agent(name: "Scout", instructions: "You review code.", account: "someone-who-signed-out")
        let notTheirs = try await builder.preface(threadID: inEmpty, question: "Who runs design?", agent: anothers)
        XCTAssertNil(notTheirs)
        // A thread that cannot be placed is told nothing of any scope: not Strix's either.
        try await CovenContextRepository.shared.setContext("Strix plans the week.", forCoven: nil, as: account)
        let account = account
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await CovenContextRepository.shared.setContext("", forCoven: nil, as: account)
        }
        let inStrix = try await builder.preface(threadID: nil, question: "Who runs design?", agent: scout)
        XCTAssertEqual(inStrix?.contains("## Coven Context\nStrix plans the week."), true)
        let unplaced = try await builder.preface(threadID: "no-such-thread-\(UUID().uuidString)", question: "Who runs design?", agent: scout)
        XCTAssertEqual(unplaced, scout.systemPrompt)
    }

    func testWhatAHermesRunIsToldFirst_isTheFirstOfItsHistory_asTheSystems() {
        let stored = [
            TurnProgress.message(in: "t", role: "user", content: "Hello"),
            TurnProgress.message(in: "t", role: "assistant", content: "Hi"),
            TurnProgress.message(in: "t", role: "user", content: "And now?"),
        ]
        let history = ChatService.hermesHistory(from: stored, toldFirst: "You are Scout.")
        XCTAssertEqual(history.map(\.role), ["system", "user", "assistant"])
        XCTAssertEqual(history.map(\.content), ["You are Scout.", "Hello", "Hi"])
        XCTAssertEqual(ChatService.hermesHistory(from: stored, toldFirst: nil).map(\.role), ["user", "assistant"])
        XCTAssertEqual(ChatService.hermesHistory(from: stored, toldFirst: "").map(\.role), ["user", "assistant"])
    }
}
