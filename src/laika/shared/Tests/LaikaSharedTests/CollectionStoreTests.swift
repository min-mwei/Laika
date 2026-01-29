import XCTest
@testable import LaikaShared

final class CollectionStoreTests: XCTestCase {
    func testCreateAndListCollections() async throws {
        let (store, tempDir) = try makeStore()
        defer { cleanupTempHome(tempDir) }

        let created = try await store.createCollection(title: "Test Collection", tags: ["news"])
        let result = try await store.listCollections()

        XCTAssertEqual(result.collections.count, 1)
        XCTAssertEqual(result.collections.first?.id, created.id)
        XCTAssertEqual(result.activeCollectionId, created.id)
        XCTAssertEqual(result.collections.first?.tags, ["news"])
    }

    func testAddSourcesAndDedupe() async throws {
        let (store, tempDir) = try makeStore()
        defer { cleanupTempHome(tempDir) }

        let collection = try await store.createCollection(title: "Links", tags: [])
        let url = "https://example.com/article"
        let result = try await store.addSources(
            collectionId: collection.id,
            sources: [
                SourceInput(type: .url, url: url, title: "Example"),
                SourceInput(type: .url, url: url, title: "Duplicate"),
                SourceInput(type: .note, title: "Note", text: "Remember to verify")
            ]
        )

        XCTAssertEqual(result.dedupedCount, 1)
        XCTAssertEqual(result.ignoredCount, 0)

        let sources = try await store.listSources(collectionId: collection.id)
        XCTAssertEqual(sources.count, 2)
        XCTAssertTrue(sources.contains(where: { $0.kind == .url }))
        XCTAssertTrue(sources.contains(where: { $0.kind == .note }))
    }

    func testSetActiveCollection() async throws {
        let (store, tempDir) = try makeStore()
        defer { cleanupTempHome(tempDir) }

        let first = try await store.createCollection(title: "First")
        let second = try await store.createCollection(title: "Second")
        XCTAssertNotEqual(first.id, second.id)

        try await store.setActiveCollection(first.id)
        let result = try await store.listCollections()
        XCTAssertEqual(result.activeCollectionId, first.id)
    }

    private func makeStore() throws -> (CollectionStore, URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        setenv("LAIKA_HOME", tempDir.path, 1)
        LaikaPaths.resetForTesting()
        let store = CollectionStore(databaseURL: LaikaPaths.databaseURL())
        return (store, tempDir)
    }

    private func cleanupTempHome(_ url: URL) {
        unsetenv("LAIKA_HOME")
        LaikaPaths.resetForTesting()
        try? FileManager.default.removeItem(at: url)
    }
}
