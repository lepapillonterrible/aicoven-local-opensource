import XCTest
@testable import AICoven

/// Tests for the local-only MemoryService using a mock MemoryStore.
final class MemoryServiceTests: XCTestCase {

    private final class MockMemoryStore: MemoryStore {
        struct Call: Equatable {
            let place: MemoryPlace
            let limit: Int
            let offset: Int
        }

        private(set) var calls: [Call] = []
        var memoriesToReturn: [LocalMemoryChunk] = []

        func storeMemory(
            in place: MemoryPlace,
            text: String,
            tags: [String],
            pii: Bool,
            createdBy: String?,
            source: String?,
            embedding: [Float]?,
            as _: String
        ) async throws -> LocalMemoryChunk {
            LocalMemoryChunk(
                id: UUID().uuidString,
                scope: place.scope,
                text: text,
                tags: tags,
                pii: pii,
                createdAt: Date(),
                createdBy: createdBy,
                source: source,
                embedding: embedding,
                covenID: place.covenID
            )
        }

        func loadMemories(in place: MemoryPlace, limit: Int, offset: Int, as _: String) async throws -> [LocalMemoryChunk] {
            calls.append(Call(place: place, limit: limit, offset: offset))
            return memoriesToReturn
        }

        func loadMemory(id _: String) async throws -> LocalMemoryChunk? {
            nil
        }

        func deleteMemory(id _: String, as _: String) async throws {}

        func updateMemory(
            id _: String,
            newText _: String,
            newTags _: [String]?,
            newEmbedding _: [Float]?,
            as _: String
        ) async throws -> LocalMemoryChunk {
            throw MemoryStoreError.noSuchMemory
        }
    }

    private func chunk(_ id: String, _ text: String, unreadable: Bool = false) -> LocalMemoryChunk {
        LocalMemoryChunk(
            id: id, scope: "user", text: text, tags: [], pii: false, createdAt: Date(), createdBy: nil, source: nil, embedding: nil,
            isUnreadable: unreadable
        )
    }

    func testAPageOfAPlace_isAskedOfTheStoreAsItIs_andSaysWhichEntriesCannotBeOpened() async throws {
        let mockStore = MockMemoryStore()
        mockStore.memoriesToReturn = [chunk("1", "Note"), chunk("2", "", unreadable: true)]
        let service = MemoryService(memoryStore: mockStore)

        let page = try await service.memories(in: .strix, limit: 100, offset: 200)
        XCTAssertEqual(mockStore.calls.last, .init(place: .strix, limit: 100, offset: 200))
        XCTAssertEqual(page.map(\.id), ["1", "2"])
        XCTAssertNil(page[0].unreadable)
        XCTAssertEqual(page[1].unreadable, true)
    }

    func testWhereAMemoryIsKept_andWhatAThreadReads() {
        XCTAssertEqual(MemoryPlace.aboutMe.scope, "user")
        XCTAssertEqual(MemoryPlace.strix.scope, "coven")
        XCTAssertEqual(MemoryPlace.coven("work").scope, "coven")
        XCTAssertNil(MemoryPlace.strix.covenID)
        XCTAssertEqual(MemoryPlace.coven("work").covenID, "work")

        // A coven's threads read its pages; a thread in no coven reads the person's own and Strix's.
        XCTAssertEqual(MemoryPlace.read(inCoven: "work"), [.coven("work")])
        XCTAssertEqual(MemoryPlace.read(inCoven: nil), [.aboutMe, .strix])
    }
}
