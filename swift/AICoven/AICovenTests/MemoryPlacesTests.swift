@testable import AICoven
import GRDB
import XCTest

/// A model that answers every question with the same words.
private struct SayingModel: LLMClient {
    let answer: String

    func completeChat(messages _: [LLMMessage], model: String, options _: ChatOptions) async throws -> LLMChatResponse {
        LLMChatResponse(message: LLMMessage(role: .assistant, content: answer), providerID: "test", modelID: model, usage: nil)
    }

    func embed(texts: [String], model _: String) async throws -> [[Float]] {
        Array(repeating: [0, 1], count: texts.count)
    }
}

/// A memory is kept in one place (the person's own, Strix's pages, or a
/// coven's), and is read where it is kept.
@MainActor
final class MemoryPlacesTests: XCTestCase {
    private let store = MemoryRepository.shared

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

    /// A coven of the signed-in account's, deleted when the test ends.
    private func newCoven() async throws -> String {
        let coven = try await CovenService.shared.createCoven(name: "Memory \(UUID().uuidString)")
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await CovenService.shared.deleteCoven(id: coven.id)
        }
        return coven.id
    }

    /// Stores a memory, removed when the test ends.
    @discardableResult
    private func keep(_ text: String, in place: MemoryPlace) async throws -> LocalMemoryChunk {
        let stored = try await store.storeMemory(in: place, text: text, tags: [], pii: false, createdBy: nil, source: nil, embedding: nil, as: account)
        let account = account
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await MemoryRepository.shared.deleteMemory(id: stored.id, as: account)
        }
        return stored
    }

    private func texts(in place: MemoryPlace) async throws -> [String] {
        try await store.loadMemories(in: place, limit: 50).map(\.text)
    }

    // MARK: - The store

    func testAMemoryIsReadOnlyWhereItIsKept() async throws {
        let work = try await newCoven()
        let home = try await newCoven()
        let mark = UUID().uuidString
        try await keep("About me \(mark)", in: .aboutMe)
        try await keep("Strix's \(mark)", in: .strix)
        try await keep("Work's \(mark)", in: .coven(work))
        try await keep("Home's \(mark)", in: .coven(home))

        let worksOwn = try await texts(in: .coven(work))
        XCTAssertEqual(worksOwn, ["Work's \(mark)"], "A coven lists its own memories, and no other coven's")
        let homesOwn = try await texts(in: .coven(home))
        XCTAssertEqual(homesOwn, ["Home's \(mark)"])
        // The two kept in no coven are told apart: the person's own, and Strix's.
        let own = try await texts(in: .aboutMe).filter { $0.hasSuffix(mark) }
        XCTAssertEqual(own, ["About me \(mark)"])
        let strixs = try await texts(in: .strix).filter { $0.hasSuffix(mark) }
        XCTAssertEqual(strixs, ["Strix's \(mark)"])
    }

    func testAPlaceIsReadAPageAtATime_newestFirst() async throws {
        let coven = try await newCoven()
        for number in 1 ... 5 {
            try await keep("Entry \(number)", in: .coven(coven))
        }

        var read: [LocalMemoryChunk] = []
        for offset in stride(from: 0, to: 8, by: 2) {
            let page = try await store.loadMemories(in: .coven(coven), limit: 2, offset: offset)
            XCTAssertLessThanOrEqual(page.count, 2)
            read += page
        }
        XCTAssertEqual(Set(read.map(\.text)).count, 5, "Every entry, each once")
        XCTAssertEqual(read.count, 5)
        XCTAssertEqual(read.map(\.createdAt), read.map(\.createdAt).sorted(by: >), "Newest first")
    }

    func testACovensMemoryIsStoredOnlyInACovenOfTheSameAccount() async throws {
        do {
            try await keep("For a coven that is not there", in: .coven("no-such-coven-\(UUID().uuidString)"))
            XCTFail("Stored a memory for a coven that is not there")
        } catch {}

        // Nor in another account's coven, whatever writes the row.
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let theirs = "their-coven-\(UUID().uuidString)"
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO covens (id, name, created_at, updated_at, user_id) VALUES (?, ?, ?, ?, ?)",
                arguments: [theirs, "Theirs", Date(), Date(), "someone-else"]
            )
        }
        addTeardownBlock {
            try? await queue.write { db in try db.execute(sql: "DELETE FROM covens WHERE id = ?", arguments: [theirs]) }
        }
        do {
            try await keep("For another account's coven", in: .coven(theirs))
            XCTFail("Stored a memory in another account's coven")
        } catch {}
        // A memory that is the account's own is not moved into it either.
        let mine = try await keep("Mine", in: .strix)
        let id = mine.id
        do {
            try await queue.write { db in
                try db.execute(sql: "UPDATE memory_chunks SET coven_id = ? WHERE id = ?", arguments: [theirs, id])
            }
            XCTFail("Moved a memory into another account's coven")
        } catch {}
    }

    func testACovenThatIsDeleted_takesItsMemoriesAndItsProposalsWithIt() async throws {
        let coven = try await newCoven()
        let other = try await newCoven()
        let gone = try await keep("Goes with its coven", in: .coven(coven))
        let stays = try await keep("Another coven's", in: .coven(other))
        let proposal = try await MemoryProposalRepository.shared.insertProposal(
            eventId: nil, covenId: coven, proposedContent: "Proposed there", proposedTags: nil, scope: "coven", reason: nil,
            sourceMessageId: nil, proposedBy: "tester", title: nil
        )

        try await CovenService.shared.deleteCoven(id: coven)

        let goneNow = try await store.loadMemory(id: gone.id)
        XCTAssertNil(goneNow)
        let proposalNow = try await MemoryProposalRepository.shared.loadProposal(id: proposal.id, for: account)
        XCTAssertNil(proposalNow)
        let staysNow = try await store.loadMemory(id: stays.id)
        XCTAssertEqual(staysNow?.text, "Another coven's")
    }

    func testAMemoryWrittenBeforeCovensWereKept_goesToItsAccountsOnlyCoven() throws {
        // The tables as far as the rule reads them.
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE covens (id TEXT PRIMARY KEY, user_id TEXT)")
            try db.execute(sql: "CREATE TABLE memory_chunks (id TEXT PRIMARY KEY, user_id TEXT, scope TEXT, coven_id TEXT)")
            for (id, user) in [("only", "ada"), ("first", "grace"), ("second", "grace")] {
                try db.execute(sql: "INSERT INTO covens VALUES (?, ?)", arguments: [id, user])
            }
            for (id, user, scope) in [
                ("ada-coven", "ada", "coven"), ("ada-agent", "ada", "agent"), ("ada-own", "ada", "user"),
                ("grace-coven", "grace", "coven"), ("grace-own", "grace", "user"),
                ("linus-coven", "linus", "coven"),
            ] {
                try db.execute(sql: "INSERT INTO memory_chunks (id, user_id, scope) VALUES (?, ?, ?)", arguments: [id, user, scope])
            }
            try db.execute(sql: DatabaseManager.givingMemoriesToAnOnlyCoven)
        }

        let covens = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, coven_id FROM memory_chunks").reduce(into: [String: String?]()) { $0[$1["id"]] = $1["coven_id"] as String? }
        }
        XCTAssertEqual(covens["ada-coven"], "only", "An account with one coven wrote it there")
        XCTAssertEqual(covens["ada-agent"], "only")
        XCTAssertEqual(covens["ada-own"], String?.none, "The person's own stays the person's own")
        XCTAssertEqual(covens["grace-coven"], String?.none, "With two covens it is not known which: it stays in none, where Strix's pages show it")
        XCTAssertEqual(covens["grace-own"], String?.none)
        XCTAssertEqual(covens["linus-coven"], String?.none, "With no coven left it stays in none")
    }

    func testAnEntryTheKeyCannotOpen_isReadAsOne_isReadByNoTurn_andCanBeRemoved() async throws {
        let coven = try await newCoven()
        let old = try await keep("Written under another key", in: .coven(coven))
        // The account's key is another now: what was written under the first cannot be opened.
        await DataEncryptionService.shared.unlockForTestingEphemeral()
        try await keep("Written under this key", in: .coven(coven))

        let page = try await store.loadMemories(in: .coven(coven), limit: 10)
        XCTAssertEqual(page.map(\.text), ["Written under this key", ""], "The rest of the page is still read")
        XCTAssertEqual(page.map(\.isUnreadable), [false, true])
        let found = try await EmbeddingService.shared.searchRelevantMemories(query: "Written under", in: [.coven(coven)], topK: 10)
        XCTAssertEqual(found.map(\.text), ["Written under this key"])

        try await store.deleteMemory(id: old.id, as: account)
        let after = try await texts(in: .coven(coven))
        XCTAssertEqual(after, ["Written under this key"])
    }

    func testNothingIsReadWhileTheDataIsLocked_notEvenThatThereIsNothing() async throws {
        let coven = try await newCoven()
        await DataEncryptionService.shared.lock()
        do {
            _ = try await store.loadMemories(in: .coven(coven), limit: 10)
            XCTFail("Read a locked account's memory")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .dataLocked)
        }
        do {
            _ = try await store.loadMemory(id: "any")
            XCTFail("Read a locked account's memory")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .dataLocked)
        }
    }

    // MARK: - What a thread's turns read

    private func thread(inCoven coven: String?) async throws -> String {
        let id = try await ThreadService.shared.createThread(title: "Memory \(UUID().uuidString)", covenId: coven).id
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            try? await ThreadService.shared.deleteThread(threadId: id)
        }
        return id
    }

    func testAThreadsTurnsReadTheMemoryOfWhereTheThreadIs() async throws {
        let builder = ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4))
        let coven = try await newCoven()
        let inCoven = try await thread(inCoven: coven)
        let personal = try await thread(inCoven: nil)

        let ofCoven = await builder.memoryPlaces(ofThread: inCoven, for: account)
        XCTAssertEqual(ofCoven, [.coven(coven)])
        let ofPersonal = await builder.memoryPlaces(ofThread: personal, for: account)
        XCTAssertEqual(ofPersonal, [.aboutMe, .strix])
        let ofNone = await builder.memoryPlaces(ofThread: nil, for: account)
        XCTAssertEqual(ofNone, [.aboutMe, .strix])
        let ofUnknown = await builder.memoryPlaces(ofThread: "no-such-thread-\(UUID().uuidString)", for: account)
        XCTAssertEqual(ofUnknown, [], "What cannot be placed is not read")
        let ofAnothers = await builder.memoryPlaces(ofThread: personal, for: "someone-who-signed-out")
        XCTAssertEqual(ofAnothers, [], "Nor is anything read for an account that is not signed in")
        do {
            _ = try await EmbeddingService.shared.searchRelevantMemories(query: "anything", in: [.aboutMe], of: "someone-who-signed-out")
            XCTFail("Read memories for an account that is not signed in")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .accountChanged)
        }

        // And the context of a turn holds them, and no other place's.
        let mark = "zq" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try await keep("The coven ships on Fridays \(mark)", in: .coven(coven))
        try await keep("The person lives in Lisbon \(mark)", in: .aboutMe)
        try await keep("Strix keeps a reading list \(mark)", in: .strix)

        func memories(told thread: String) async throws -> String {
            try await builder.buildContext(threadID: thread, userMessage: "What do you know of \(mark)?", maxContextTokens: 8000, toolConfig: .noTools)
                .filter { $0.role == .system }.map(\.content).joined(separator: "\n")
        }
        let toldInCoven = try await memories(told: inCoven)
        XCTAssertTrue(toldInCoven.contains("The coven ships on Fridays"))
        XCTAssertFalse(toldInCoven.contains("The person lives in Lisbon"), "A coven's agents are not told the person's own memory")
        XCTAssertFalse(toldInCoven.contains("Strix keeps a reading list"))
        let toldPersonally = try await memories(told: personal)
        XCTAssertTrue(toldPersonally.contains("The person lives in Lisbon"))
        XCTAssertTrue(toldPersonally.contains("Strix keeps a reading list"))
        XCTAssertFalse(toldPersonally.contains("The coven ships on Fridays"), "Strix is not told a coven's memory")
    }

    // MARK: - What a model asks to keep

    private func chat(answering answer: String) -> ChatService {
        ChatService(
            contextBuilder: ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4)),
            modelRouter: HeuristicModelRouter(availableModels: [ModelDescriptor(
                providerID: "openai", modelID: "model", maxContextTokens: 32768,
                supportsTools: false, supportsEmbeddings: false, costClass: .cheap
            )]),
            llmClients: ["openai": SayingModel(answer: answer)],
            threadStore: ThreadRepository.shared,
            toolService: ToolService.shared,
            shouldAutoRefreshEnvironment: false,
            hermesAgent: { nil },
            openClawTurn: { _ in nil }
        )
    }

    func testWhatAModelAsksToKeep_isKeptWhereItsThreadIs_andNotWhatItAsksToKeepForOneThread() async throws {
        let defaults = UserDefaults.standard
        let key = UserScope.scopedKey("llm_provider")
        let saved = defaults.object(forKey: key)
        defer { defaults.set(saved, forKey: key) }
        defaults.set("openai", forKey: key)

        let coven = try await newCoven()
        let inCoven = try await thread(inCoven: coven)
        let personal = try await thread(inCoven: nil)
        let mark = UUID().uuidString
        let answer = """
        Noted.
        [MEMORY_WRITE: scope=user]Ships on Fridays \(mark)[/MEMORY_WRITE]
        [MEMORY_WRITE: scope=thread]Only for this conversation \(mark)[/MEMORY_WRITE]
        """
        let account = account
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            for place in [MemoryPlace.aboutMe, .strix] {
                for kept in await (try? MemoryRepository.shared.loadMemories(in: place, limit: 20)) ?? [] where kept.text.hasSuffix(mark) {
                    try? await MemoryRepository.shared.deleteMemory(id: kept.id, as: account)
                }
            }
        }

        try await chat(answering: answer).streamMessage(threadId: inCoven, message: "Remember when we ship.", onStateChange: { _ in })
        let covens = try await texts(in: .coven(coven))
        XCTAssertEqual(covens, ["Ships on Fridays \(mark)"], "In the coven's pages, where its agents read it")
        var own = try await texts(in: .aboutMe).filter { $0.hasSuffix(mark) }
        XCTAssertEqual(own, [], "Not in the person's own memory")

        try await chat(answering: answer).streamMessage(threadId: personal, message: "Remember when we ship.", onStateChange: { _ in })
        own = try await texts(in: .aboutMe).filter { $0.hasSuffix(mark) }
        XCTAssertEqual(own, ["Ships on Fridays \(mark)"])
        let strixs = try await texts(in: .strix).filter { $0.hasSuffix(mark) }
        XCTAssertEqual(strixs, [], "What was for one conversation is kept nowhere")
        let covensAfter = try await texts(in: .coven(coven))
        XCTAssertEqual(covensAfter.count, 1)
    }
}
