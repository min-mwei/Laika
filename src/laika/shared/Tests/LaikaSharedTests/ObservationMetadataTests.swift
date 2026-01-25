import XCTest
@testable import LaikaShared

final class ObservationMetadataTests: XCTestCase {
    func testObservationMetadataRoundTrip() throws {
        let observation = Observation(
            url: "https://example.com",
            title: "Example",
            documentId: "doc-123",
            navigationGeneration: 2,
            observedAtMs: 1700000000000,
            text: "hello",
            elements: [],
            blocks: [],
            items: [],
            outline: [],
            primary: nil,
            comments: [],
            signals: ["paywall_or_login"]
        )

        let data = try JSONEncoder().encode(observation)
        let decoded = try JSONDecoder().decode(Observation.self, from: data)

        XCTAssertEqual(decoded.documentId, "doc-123")
        XCTAssertEqual(decoded.navigationGeneration, 2)
        XCTAssertEqual(decoded.observedAtMs, 1700000000000)
        XCTAssertEqual(decoded.signals, ["paywall_or_login"])
    }

    func testLegacyNavGenerationDecoding() throws {
        let json = """
        {
          "url": "https://example.com",
          "title": "Example",
          "documentId": "doc-legacy",
          "navGeneration": 5,
          "observedAtMs": 1700000000001,
          "text": "hello",
          "elements": [],
          "blocks": [],
          "items": [],
          "outline": [],
          "comments": [],
          "signals": []
        }
        """
        let decoded = try JSONDecoder().decode(Observation.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.documentId, "doc-legacy")
        XCTAssertEqual(decoded.navigationGeneration, 5)
        XCTAssertEqual(decoded.observedAtMs, 1700000000001)
    }

    func testSignalNormalization() {
        XCTAssertEqual(
            ObservationSignalNormalizer.normalize("auth_gate"),
            ObservationSignal.paywallOrLogin.rawValue
        )
        XCTAssertEqual(
            ObservationSignalNormalizer.normalize("consent_overlay"),
            ObservationSignal.consentModal.rawValue
        )
        XCTAssertEqual(
            ObservationSignalNormalizer.normalize("overlay_or_dialog"),
            ObservationSignal.overlayBlocking.rawValue
        )
        XCTAssertEqual(
            ObservationSignalNormalizer.normalize("low_visible_text"),
            ObservationSignal.sparseText.rawValue
        )
    }
}
