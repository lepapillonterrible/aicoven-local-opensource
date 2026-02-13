import XCTest
@testable import AICoven

/// Tests for the local-only MemoryService using a mock MemoryStore.
final class MemoryServiceTests: XCTestCase {

    private final class MockMemoryStore: MemoryStore {
        struct Call: Equatable {
            let method: String
            let scope: String?
            let limit: Int?
        }

        private(set) var calls: [Call] = []
        var memoriesToReturn: [LocalMemoryChunk] = []
        var memoryByID: LocalMemoryChunk?

        func storeMemory(
            scope: String,
            text: String,
            tags: [String],
            pii: Bool,
            createdBy: String?,
            source: String?,
            embedding: [Float]?
        ) async throws -> LocalMemoryChunk {
            LocalMemoryChunk(
                id: UUID().uuidString,
                scope: scope,
                text: text,
                tags: tags,
                pii: pii,
                createdAt: Date(),
                createdBy: createdBy,
                source: source,
                embedding: embedding
            )
        }

        func loadMemories(scope: String?, limit: Int) async throws -> [LocalMemoryChunk] {
            calls.append(Call(method: "loadMemories", scope: scope, limit: limit))
            return memoriesToReturn
        }

        func loadMemory(id: String) async throws -> LocalMemoryChunk? {
            memoryByID
        }

        func deleteMemory(id: String) async throws {}

        func updateMemory(
            id: String,
            newText: String,
            newTags: [String],
            newEmbedding: [Float]?
        ) async throws -> LocalMemoryChunk? {
            LocalMemoryChunk(
                id: id,
                scope: "user",
                text: newText,
                tags: newTags,
                pii: false,
                createdAt: Date(),
                createdBy: nil,
                source: nil,
                embedding: newEmbedding
            )
        }
    }

    func testSearchMemory_withoutQuery_usesStoreWithUserScope() async throws {
        let mockStore = MockMemoryStore()
        mockStore.memoriesToReturn = [
            LocalMemoryChunk(
                id: "1",
                scope: "user",
                text: "Note",
                tags: [],
                pii: false,
                createdAt: Date(),
                createdBy: nil,
                source: nil,
                embedding: nil
            )
        ]
        let service = MemoryService(memoryStore: mockStore)

        let result = try await service.searchMemory(
            covenId: nil,
            query: nil,
            scope: nil,
            tags: nil,
            limit: 10
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.content, "Note")
        // Fallback scope for personal memories is "user".
        XCTAssertEqual(mockStore.calls.last?.scope, "user")
        XCTAssertEqual(mockStore.calls.last?.limit, 10)
    }
}
