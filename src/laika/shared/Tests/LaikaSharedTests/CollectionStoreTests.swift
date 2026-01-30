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

    func testCaptureUpdatesStatus() async throws {
        let (store, tempDir) = try makeStore()
        defer { cleanupTempHome(tempDir) }

        let collection = try await store.createCollection(title: "Capture")
        let url = "https://example.com/article"
        _ = try await store.addSources(
            collectionId: collection.id,
            sources: [SourceInput(type: .url, url: url, title: "Example")]
        )

        try await store.markSourceCaptured(
            collectionId: collection.id,
            url: url,
            title: "Example",
            markdown: "# Example\n\nBody",
            links: [CapturedLink(url: "https://example.com/next", text: "Next", context: "Next link")]
        )
        let afterCapture = try await store.listSources(collectionId: collection.id)
        XCTAssertEqual(afterCapture.first(where: { $0.url == url })?.captureStatus, .captured)

        try await store.markSourceCaptureFailed(
            collectionId: collection.id,
            url: url,
            error: "capture_failed"
        )
        let afterFailure = try await store.listSources(collectionId: collection.id)
        XCTAssertEqual(afterFailure.first(where: { $0.url == url })?.captureStatus, .failed)
    }

    func testSourceSnapshotsAndChatEvents() async throws {
        let (store, tempDir) = try makeStore()
        defer { cleanupTempHome(tempDir) }

        let collection = try await store.createCollection(title: "History")
        let url = "https://example.com/article"
        _ = try await store.addSources(
            collectionId: collection.id,
            sources: [SourceInput(type: .url, url: url, title: "Example")]
        )
        try await store.markSourceCaptured(
            collectionId: collection.id,
            url: url,
            title: "Example",
            markdown: "# Example\n\nBody",
            links: [CapturedLink(url: "https://example.com/more", text: "More", context: "More link")]
        )
        let snapshots = try await store.listSourceSnapshots(collectionId: collection.id, limit: 5)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.url, url)
        XCTAssertEqual(snapshots.first?.extractedLinks.count, 1)

        _ = try await store.addChatEvent(collectionId: collection.id, role: "user", markdown: "Question?")
        _ = try await store.addChatEvent(collectionId: collection.id, role: "assistant", markdown: "Answer.")
        let events = try await store.listChatEvents(collectionId: collection.id, limit: 10)
        XCTAssertEqual(events.count, 2)

        try await store.clearChatEvents(collectionId: collection.id)
        let cleared = try await store.listChatEvents(collectionId: collection.id, limit: 10)
        XCTAssertEqual(cleared.count, 0)
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
