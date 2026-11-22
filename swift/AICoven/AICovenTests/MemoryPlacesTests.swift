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

        // What a model once asked to keep for one conversation was stored in no coven, with the
        // scope "thread". No turn read it then, and it is in no place now.
        let queue = try XCTUnwrap(DatabaseManager.shared.dbQueue)
        let old = "old-thread-note-\(UUID().uuidString)"
        let account = account
        let sealed = try await DataEncryptionService.shared.encrypt(Data("For one conversation \(mark)".utf8), purpose: "memory_chunk")
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO memory_chunks (id, scope, pii_flag, created_at, text_ciphertext, user_id) VALUES (?, 'thread', 0, ?, ?, ?)",
                arguments: [old, Date(), sealed, account]
            )
        }
        addTeardownBlock { try? await MemoryRepository.shared.deleteMemory(id: old, as: account) }
        for place in [MemoryPlace.aboutMe, .strix, .coven(work)] {
            let read = try await texts(in: place)
            XCTAssertFalse(read.contains("For one conversation \(mark)"), "\(place)")
        }
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

    func testWithAnotherAccountsKeyInMemory_nothingIsReadOrWritten() async throws {
        let coven = try await newCoven()
        let mine = try await keep("Mine", in: .coven(coven))
        // What is in memory for a moment after a switch from another account: that account's key.
        await DataEncryptionService.shared.unlockForTestingEphemeral(ownedBy: "someone-who-signed-out")

        func refused(_ what: String, _ body: () async throws -> Void) async {
            do {
                try await body()
                XCTFail("\(what) with another account's key")
            } catch {
                XCTAssertEqual(error as? RepositoryError, .dataLocked, what)
            }
        }
        await refused("Read a page") { _ = try await self.store.loadMemories(in: .coven(coven), limit: 10) }
        await refused("Read a memory") { _ = try await self.store.loadMemory(id: mine.id) }
        await refused("Stored a memory") {
            _ = try await self.store.storeMemory(
                in: .coven(coven), text: "Sealed with another's key", tags: [], pii: false, createdBy: nil, source: nil, embedding: nil, as: self.account
            )
        }
        await refused("Changed a memory") {
            _ = try await self.store.updateMemory(id: mine.id, newText: "Sealed with another's key", newTags: nil, newEmbedding: nil, as: self.account)
        }

        await DataEncryptionService.shared.unlockForTestingEphemeral()
        let count = try await store.loadMemories(in: .coven(coven), limit: 10).count
        XCTAssertEqual(count, 1, "Nothing was added")
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

    func testWhatAModelAsksToKeep_isProposedWhereItsThreadIs_andKeptOnlyOnceThePersonSaysSo() async throws {
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
        let proposals = MemoryProposalRepository.shared
        func proposed(in coven: String?) async throws -> [MemoryProposalRecord] {
            try await proposals.listProposals(covenId: coven, status: "pending").filter { $0.proposedContent.hasSuffix(mark) }
        }
        let account = account
        addTeardownBlock {
            await DataEncryptionService.shared.unlockForTestingEphemeral()
            // The questions leave the screen, and what was proposed in no coven is settled.
            await MainActor.run { MemoryProposalQuestions.shared.accountChanged() }
            for left in await (try? proposals.listProposals(covenId: nil, status: "pending")) ?? [] where left.proposedContent.hasSuffix(mark) {
                _ = try? await proposals.settlePending(id: left.id, as: "rejected", reviewedBy: nil, reviewFeedback: nil, for: account)
            }
        }

        try await chat(answering: answer).streamMessage(threadId: inCoven, message: "Remember when we ship.", onStateChange: { _ in })
        let covens = try await proposed(in: coven)
        XCTAssertEqual(covens.map(\.proposedContent), ["Ships on Fridays \(mark)"], "Proposed for the coven its thread is in")
        XCTAssertEqual(covens.map(\.scope), ["coven"])
        let keptInCoven = try await texts(in: .coven(coven))
        XCTAssertEqual(keptInCoven, [], "Nothing is kept until the person says so")
        var own = try await proposed(in: nil)
        XCTAssertEqual(own.count, 0, "Not proposed as the person's own")

        try await chat(answering: answer).streamMessage(threadId: personal, message: "Remember when we ship.", onStateChange: { _ in })
        own = try await proposed(in: nil)
        XCTAssertEqual(own.map(\.proposedContent), ["Ships on Fridays \(mark)"], "What was for one conversation is not proposed")
        XCTAssertEqual(own.map(\.scope), ["user"])
        let keptAsOwn = try await texts(in: .aboutMe).filter { $0.hasSuffix(mark) }
        XCTAssertEqual(keptAsOwn, [])

        // Approved, it is kept where it was proposed.
        let service = MemoryService(memoryStore: MemoryRepository.shared, embed: { _ in nil })
        _ = try await service.reviewProposal(proposalId: XCTUnwrap(covens.first).id, action: "approve")
        let approved = try await texts(in: .coven(coven))
        XCTAssertEqual(approved, ["Ships on Fridays \(mark)"])

        // In a thread whose coven is gone, or that is not there, nothing is proposed anywhere.
        let gone = try await newCoven()
        let orphan = try await thread(inCoven: gone)
        try await CovenService.shared.deleteCoven(id: gone)
        let builder = ContextBuilder(limits: .init(maxRecentMessages: 4, maxRecentMemories: 4))
        let told = try await builder.buildContext(threadID: orphan, userMessage: "What do you know of \(mark)?", maxContextTokens: 8000, toolConfig: .noTools)
        XCTAssertFalse(told.contains { $0.content.contains("Ships on Fridays") }, "Nor is it told any other place's memory")
        try await chat(answering: answer).streamMessage(threadId: orphan, message: "Remember when we ship.", onStateChange: { _ in })
        try? await chat(answering: answer).streamMessage(threadId: "no-such-thread-\(UUID().uuidString)", message: "Remember when we ship.", onStateChange: { _ in })
        own = try await proposed(in: nil)
        XCTAssertEqual(own.count, 1, "Only what the personal thread proposed")
        let ofTheGoneCoven = try await proposed(in: gone)
        XCTAssertTrue(ofTheGoneCoven.isEmpty, "A coven that is gone is proposed nothing")
    }
}
