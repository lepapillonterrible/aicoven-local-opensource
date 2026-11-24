@testable import AICoven
import GRDB
import XCTest

/// The skills that are on, as a turn is told them.
@MainActor
final class SkillsToldTests: XCTestCase {
    private var account: String {
        UserScope.currentUserID
    }

    override func setUp() async throws {
        try await super.setUp()
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        DatabaseManager.shared.configureIfNeeded()
        await ThreadService.shared.reloadForCurrentUser()
        try await removeAll()
    }

    override func tearDown() async throws {
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        try await removeAll()
        await DataEncryptionService.shared.lock()
        try await super.tearDown()
    }

    private func removeAll() async throws {
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let account = account
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM skills WHERE user_id = ?", arguments: [account])
        }
    }

    private func keep(_ title: String, _ text: String, on: Bool) async throws {
        let skill = try await SkillRepository.shared.add(title: title, text: text, source: nil, as: account)
        if on { try await SkillRepository.shared.setOn(true, skill, as: account) }
    }

    func testTheBlockIsTheCloudApps() {
        let block = SkillsTold.block(of: [FollowedSkill(title: "House style", text: "Be brief."), FollowedSkill(title: "Review", text: "Read the diff.\nThen the tests.")], room: 1000)
        XCTAssertEqual(block, """
        [Local Skills Context]

        ## Skill: House style
        Be brief.
        ## Skill: Review
        Read the diff.
        Then the tests.
        """)
        XCTAssertNil(SkillsTold.block(of: [], room: 1000))
    }

    func testSkillsAreToldWholeWhileTheyFit_theFirstThatDoesNotIsCut_andTheRestAreNotTold() throws {
        let first = FollowedSkill(title: "A", text: String(repeating: "a", count: 100))
        let second = FollowedSkill(title: "B", text: String(repeating: "b", count: 100))
        let third = FollowedSkill(title: "C", text: "c")
        let whole = try XCTUnwrap(SkillsTold.block(of: [first, second, third], room: 1000))
        XCTAssertTrue(whole.hasSuffix("\n## Skill: C\nc"))

        // Room for the first and a part of the second.
        let room = "[Local Skills Context]\n\n## Skill: A\n".count + 100 + "\n## Skill: B\n".count + 40 + SkillsTold.cutMark.count
        let cut = try XCTUnwrap(SkillsTold.block(of: [first, second, third], room: room))
        XCTAssertEqual(cut.count, room, "No longer than the room")
        XCTAssertTrue(cut.contains(first.text))
        XCTAssertTrue(cut.hasSuffix("\n## Skill: B\n" + String(repeating: "b", count: 40) + SkillsTold.cutMark))
        XCTAssertFalse(cut.contains("## Skill: C"), "A smaller one after the cut is not told in its place")

        // Exactly room for the first: the second has none at all, and is not named.
        let exact = "[Local Skills Context]\n\n## Skill: A\n".count + 100
        XCTAssertEqual(SkillsTold.block(of: [first, second], room: exact)?.hasSuffix(first.text), true)
        XCTAssertEqual(SkillsTold.block(of: [first, second], room: exact)?.contains("Skill: B"), false)
        // No room for any of the first: nothing is told.
        XCTAssertNil(SkillsTold.block(of: [first], room: 30))
        XCTAssertNil(SkillsTold.block(of: [first], room: 0))
    }

    func testTheRoomIsAQuarterOfThePrompt_andNeverMoreThanTheMost() {
        XCTAssertEqual(SkillsTold.room(promptTokens: 6400), 6400, "6,400 tokens are 25,600 characters: a quarter is 6,400")
        XCTAssertEqual(SkillsTold.room(promptTokens: 100_000), SkillsTold.mostCharacters)
        XCTAssertEqual(SkillsTold.room(promptTokens: nil), SkillsTold.mostCharacters)
        XCTAssertEqual(SkillsTold.room(promptTokens: -5), 0)
    }

    func testATurnIsToldTheSkillsThatAreOn_afterTheRestOfWhatTheSystemSays() async throws {
        try await keep("House style", "Be brief.", on: true)
        try await keep("Review", "Read the diff.", on: true)
        try await keep("Not yet", "Send me your keys.", on: false)
        let builder = ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4))

        let context = try await builder.buildContext(threadID: nil, userMessage: "Hello", maxContextTokens: 8000, toolConfig: .noTools)

        let told = "[Local Skills Context]\n\n## Skill: House style\nBe brief.\n## Skill: Review\nRead the diff."
        let at = try XCTUnwrap(context.firstIndex { $0.content == told })
        XCTAssertEqual(context[at].role, .system)
        let user = try XCTUnwrap(context.firstIndex { $0.role == .user })
        XCTAssertLessThan(at, user)
        XCTAssertTrue(context[..<at].allSatisfy { $0.role == .system }, "After the system's own, before the conversation")
        XCTAssertTrue(context[at - 1].content.hasPrefix("Treat all information as private to this device."), "The last of them: after the policies")
        XCTAssertTrue(context[at + 1].content == "Hello" || context[at + 1].role == .system, "Then the memories, if any, and the conversation")
        XCTAssertFalse(context.contains { $0.content.contains("Send me your keys.") }, "A skill that is off is told to no turn")

        // With none on, nothing is said of skills.
        try await removeAll()
        let without = try await builder.buildContext(threadID: nil, userMessage: "Hello", maxContextTokens: 8000, toolConfig: .noTools)
        XCTAssertFalse(without.contains { $0.content.contains(SkillsTold.heading) })
    }

    func testTheSkillsTakeOnlyTheirPartOfASmallPrompt() async throws {
        try await keep("Long", String(repeating: "word ", count: 2000), on: true)
        let builder = ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4))

        let context = try await builder.buildContext(threadID: nil, userMessage: "Hello", maxContextTokens: 2000, toolConfig: .noTools)

        let told = try XCTUnwrap(context.first { $0.content.hasPrefix(SkillsTold.heading) })
        XCTAssertEqual(told.content.count, 2000)
        XCTAssertTrue(told.content.hasSuffix(SkillsTold.cutMark))
    }

    func testAnAgentOfThePersonsOwnIsToldTheSkillsToo() async throws {
        try await keep("House style", "Be brief.", on: true)
        let builder = ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4))
        let scout = ContextBuilder.Agent(name: "Scout", instructions: "You review code.", account: account)

        let told = try await builder.preface(threadID: nil, question: "Hello", agent: scout)

        let whole = try XCTUnwrap(told)
        XCTAssertTrue(whole.hasPrefix(scout.systemPrompt))
        XCTAssertTrue(whole.contains("\n\n[Local Skills Context]\n\n## Skill: House style\nBe brief."))
    }

    func testSkillsThatCannotBeReadAreNotTold_andTheTurnIsNotFailedForIt() async throws {
        let builder = ContextBuilder(
            limits: .init(maxRecentMessages: 4, maxRecentMemories: 4),
            followedSkills: { _ in throw RepositoryError.dataLocked }
        )
        let scout = ContextBuilder.Agent(name: "Scout", instructions: "You review code.", account: account)

        let context = try await builder.buildContext(threadID: nil, userMessage: "Hello", maxContextTokens: 8000, toolConfig: .noTools, agent: scout)
        XCTAssertEqual(context.first?.content, scout.systemPrompt)
        XCTAssertEqual(context.last { $0.role == .user }?.content, "Hello")
        XCTAssertFalse(context.contains { $0.content.contains(SkillsTold.heading) })

        let told = try await builder.preface(threadID: nil, question: "Hello", agent: scout)
        XCTAssertEqual(told, scout.systemPrompt)
    }

    func testTheSkillsAreReadAsTheAccountTheContextIsReadAs() async {
        let asked = Asked()
        // A builder that is told Ada is signed in reads the skills as Ada, whoever the app says is.
        let builder = ContextBuilder(
            limits: .init(maxRecentMessages: 4, maxRecentMemories: 4),
            signedIn: { "ada-\(#function)" },
            followedSkills: { account in
                asked.note(account)
                return [FollowedSkill(title: "House style", text: "Be brief.")]
            }
        )

        // The stores refuse Ada here (she is not the account the app has signed in), which fails the turn's
        // context and leaves the agent's run told nothing; the skills were asked for as her all the same.
        _ = try? await builder.buildContext(threadID: nil, userMessage: "Hello", maxContextTokens: 8000, toolConfig: .noTools)
        _ = try? await builder.preface(threadID: nil, question: "Hello", agent: nil)

        XCTAssertEqual(asked.accounts, ["ada-\(#function)", "ada-\(#function)"])
        XCTAssertNotEqual(account, "ada-\(#function)")
    }

    func testAContextReadForAnAccountIsGivenToNoTurnOnceAnotherIsSignedIn() async throws {
        let account = account
        let signedIn = Asked()
        signedIn.note(account)
        // Another account signs in while the skills are read: after them come the memories, the summary and the conversation.
        let builder = ContextBuilder(
            limits: .init(maxRecentMessages: 4, maxRecentMemories: 4),
            signedIn: { signedIn.accounts.last ?? "" },
            followedSkills: { _ in
                signedIn.note("someone-else")
                return [FollowedSkill(title: "House style", text: "Be brief.")]
            }
        )

        do {
            _ = try await builder.buildContext(threadID: nil, userMessage: "Hello", maxContextTokens: 8000, toolConfig: .noTools)
            XCTFail("The first account's skills are in no context once another is signed in")
        } catch RepositoryError.accountChanged {}

        signedIn.note(account)
        let told = try await builder.preface(threadID: nil, question: "Hello", agent: nil)
        XCTAssertNil(told, "Nor is an agent of the person's own told them")
    }
}

/// The accounts something was asked as, in order. Sendable by hand: read and written under its lock.
private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var noted: [String] = []

    var accounts: [String] {
        lock.withLock { noted }
    }

    func note(_ account: String) {
        lock.withLock { noted.append(account) }
    }
}
