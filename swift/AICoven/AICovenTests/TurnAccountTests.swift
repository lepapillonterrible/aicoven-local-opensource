@testable import AICoven
import XCTest

/// A model that answers with a script, counts how often it was asked, and
/// does something of the test's when it is first asked. Sendable by hand:
/// what changes is read and written under its lock.
private final class ScriptedModel: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String]
    private var asked = 0
    private let whenFirstAsked: @Sendable () -> Void

    init(answering answers: [String], whenFirstAsked: @escaping @Sendable () -> Void) {
        self.answers = answers
        self.whenFirstAsked = whenFirstAsked
    }

    var timesAsked: Int {
        lock.withLock { asked }
    }

    func completeChat(messages _: [LLMMessage], model: String, options _: ChatOptions) async throws -> LLMChatResponse {
        let (answer, isFirst) = lock.withLock { () -> (String, Bool) in
            asked += 1
            return (answers.isEmpty ? "Done." : answers.removeFirst(), asked == 1)
        }
        if isFirst { whenFirstAsked() }
        return LLMChatResponse(message: LLMMessage(role: .assistant, content: answer), providerID: "test", modelID: model, usage: nil)
    }

    func embed(texts: [String], model _: String) async throws -> [[Float]] {
        Array(repeating: [0, 1], count: texts.count)
    }
}

/// The same model, for a provider that streams its final answer.
private final class StreamingScriptedModel: StreamingLLMClient, @unchecked Sendable {
    let model: ScriptedModel

    init(_ model: ScriptedModel) {
        self.model = model
    }

    func completeChat(messages: [LLMMessage], model name: String, options: ChatOptions) async throws -> LLMChatResponse {
        try await model.completeChat(messages: messages, model: name, options: options)
    }

    func embed(texts: [String], model name: String) async throws -> [[Float]] {
        try await model.embed(texts: texts, model: name)
    }
}

/// Who is signed in, changed by the test. Sendable by hand, under its lock.
private final class SignedIn: @unchecked Sendable {
    private let lock = NSLock()
    private var account: String

    init(_ account: String) {
        self.account = account
    }

    var now: String {
        get { lock.withLock { account } }
        set { lock.withLock { account = newValue } }
    }
}

/// The states a turn went through. Sendable by hand, under its lock.
private final class States: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [TurnState] = []

    func add(_ state: TurnState) {
        lock.withLock { states.append(state) }
    }

    var last: TurnState? {
        lock.withLock { states.last }
    }
}

/// What a turn has gathered is its account's: no request of the turn is
/// sent to a provider once another account has signed in.
@MainActor
final class TurnAccountTests: XCTestCase {
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

    private func chat(with model: any LLMClient, signedIn: SignedIn) -> ChatService {
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
            openClawTurn: { _ in nil },
            signedIn: { signedIn.now }
        )
    }

    private func newThread() async throws -> String {
        let thread = try await ThreadService.shared.createThread(title: "Turn account \(UUID().uuidString)")
        addTeardownBlock { try? await ThreadService.shared.deleteThread(threadId: thread.id) }
        return thread.id
    }

    func testATurnSendsNothingMoreOnceAnotherAccountHasSignedIn() async throws {
        let thread = try await newThread()
        let signedIn = SignedIn(UserScope.currentUserID)
        // The model asks for a tool; while it answers, another account signs in.
        let model = ScriptedModel(
            answering: [#"{"tool":"current_time","input":null,"reason":"to know the time"}"#, "It is noon."],
            whenFirstAsked: { signedIn.now = "someone-else" }
        )
        let states = States()
        try await chat(with: model, signedIn: signedIn).streamMessage(threadId: thread, as: UserScope.currentUserID, message: "What time is it?", onStateChange: { states.add($0) })
        XCTAssertEqual(model.timesAsked, 1, "What the tool told is not sent: the model is not asked again")
        XCTAssertEqual(states.last?.status, .failed, "The turn ends there")
        XCTAssertEqual(states.last?.answer, ChatService.accountChangedMessage, "In the same words wherever the turn was cut off")
    }

    func testTheFinalAnswerIsNotAskedForOnceAnotherAccountHasSignedIn_streamedOrNot() async throws {
        // One tool step, so that the answer after it is the final one.
        let key = UserScope.scopedKey("chat_max_tool_steps")
        let before = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(1, forKey: key)
        addTeardownBlock { UserDefaults.standard.set(before, forKey: key) }

        for streams in [false, true] {
            let thread = try await newThread()
            let signedIn = SignedIn(UserScope.currentUserID)
            let model = ScriptedModel(
                answering: [#"{"tool":"current_time","input":null,"reason":"to know the time"}"#, "It is noon."],
                whenFirstAsked: { signedIn.now = "someone-else" }
            )
            let client: any LLMClient = streams ? StreamingScriptedModel(model) : model
            let states = States()
            try await chat(with: client, signedIn: signedIn).streamMessage(
                threadId: thread,
                as: UserScope.currentUserID, message: "What time is it?", onStateChange: { states.add($0) }
            )
            XCTAssertEqual(model.timesAsked, 1, "The final answer is not asked for (streams: \(streams))")
            XCTAssertEqual(states.last?.status, .failed)
            XCTAssertEqual(states.last?.answer, ChatService.accountChangedMessage, "Said plainly (streams: \(streams))")
        }
    }

    func testATurnThatThrowsBecauseAnotherAccountSignedInSaysSoPlainly() {
        let ending = TurnProgress(agentName: nil).ending(in: "t", thrown: RepositoryError.accountChanged)
        XCTAssertEqual(ending.outcome, .failed)
        XCTAssertEqual(ending.message.content, ChatService.accountChangedMessage, "Not as a provider's failure")
        let other = TurnProgress(agentName: nil).ending(in: "t", thrown: URLError(.timedOut))
        XCTAssertTrue(other.message.content.hasPrefix("I ran into an error while contacting your provider"))
    }

    func testATurnsContextIsBuiltAsTheAccountItBeganAs_andOnlyWhileThatAccountIsSignedIn() async throws {
        // Another account is signed in by the time the turn's next context is built.
        let asAnother = ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4), signedIn: { "someone-else" })
        do {
            _ = try await asAnother.buildContext(threadID: nil, userMessage: "Hello", maxContextTokens: 8000, toolConfig: .noTools, as: UserScope.currentUserID)
            XCTFail("Not built as whoever has signed in since")
        } catch RepositoryError.accountChanged {}

        // As the same account it is built, with or without being told whose turn it is.
        let builder = ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4))
        let told = try await builder.buildContext(threadID: nil, userMessage: "Hello", maxContextTokens: 8000, toolConfig: .noTools, as: UserScope.currentUserID)
        XCTAssertTrue(told.contains { $0.role == .user && $0.content == "Hello" })
        let untold = try await builder.buildContext(threadID: nil, userMessage: "Hello", maxContextTokens: 8000, toolConfig: .noTools)
        XCTAssertTrue(untold.contains { $0.role == .user && $0.content == "Hello" })
    }

    func testATurnOfTheSameAccountGoesOnAsBefore() async throws {
        let thread = try await newThread()
        let signedIn = SignedIn(UserScope.currentUserID)
        let model = ScriptedModel(
            answering: [#"{"tool":"current_time","input":null,"reason":"to know the time"}"#, "It is noon."], whenFirstAsked: {}
        )
        let states = States()
        try await chat(with: model, signedIn: signedIn).streamMessage(threadId: thread, as: UserScope.currentUserID, message: "What time is it?", onStateChange: { states.add($0) })
        XCTAssertGreaterThanOrEqual(model.timesAsked, 2, "Asked again once the tool had run")
        XCTAssertNotEqual(states.last?.status, .failed)
    }
}
