import XCTest
@testable import LaikaShared

final class ObservationMetadataTests: XCTestCase {
    func testObservationMetadataRoundTrip() throws {
        let observation = Observation(
            url: "https://example.com",
            title: "Example",
            documentId: "doc-123",
            navGeneration: 2,
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
        XCTAssertEqual(decoded.navGeneration, 2)
        XCTAssertEqual(decoded.observedAtMs, 1700000000000)
        XCTAssertEqual(decoded.signals, ["paywall_or_login"])
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
