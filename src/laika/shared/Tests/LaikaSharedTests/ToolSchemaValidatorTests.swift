import XCTest
@testable import LaikaShared

final class ToolSchemaValidatorTests: XCTestCase {
    func testValidateClickArguments() {
        let valid = ToolSchemaValidator.validateArguments(
            name: .browserClick,
            arguments: ["handleId": .string("laika-1")]
        )
        XCTAssertTrue(valid)

        let missing = ToolSchemaValidator.validateArguments(
            name: .browserClick,
            arguments: [:]
        )
        XCTAssertFalse(missing)

        let extra = ToolSchemaValidator.validateArguments(
            name: .browserClick,
            arguments: ["handleId": .string("laika-1"), "extra": .string("nope")]
        )
        XCTAssertFalse(extra)
    }

    func testValidateObserveDomArguments() {
        let valid = ToolSchemaValidator.validateArguments(
            name: .browserObserveDom,
            arguments: ["maxChars": .number(1200), "rootHandleId": .string("laika-1")]
        )
        XCTAssertTrue(valid)

        let invalid = ToolSchemaValidator.validateArguments(
            name: .browserObserveDom,
            arguments: ["maxChars": .string("1200")]
        )
        XCTAssertFalse(invalid)

        let nonFinite = ToolSchemaValidator.validateArguments(
            name: .browserObserveDom,
            arguments: ["maxChars": .number(.nan)]
        )
        XCTAssertFalse(nonFinite)
    }

    func testValidateSearchArguments() {
        let valid = ToolSchemaValidator.validateArguments(
            name: .search,
            arguments: ["query": .string("SEC filing deadlines"), "newTab": .bool(true)]
        )
        XCTAssertTrue(valid)

        let invalid = ToolSchemaValidator.validateArguments(
            name: .search,
            arguments: ["query": .string(""), "engine": .number(2)]
        )
        XCTAssertFalse(invalid)
    }

    func testRejectsEmptyHandle() {
        let invalid = ToolSchemaValidator.validateArguments(
            name: .browserClick,
            arguments: ["handleId": .string("   ")]
        )
        XCTAssertFalse(invalid)
    }

    func testValidateCalculateArguments() {
        let valid = ToolSchemaValidator.validateArguments(
            name: .appCalculate,
            arguments: ["expression": .string("1 + 2"), "precision": .number(2)]
        )
        XCTAssertTrue(valid)

        let invalidExpression = ToolSchemaValidator.validateArguments(
            name: .appCalculate,
            arguments: ["expression": .string(" ")]
        )
        XCTAssertFalse(invalidExpression)

        let invalidPrecision = ToolSchemaValidator.validateArguments(
            name: .appCalculate,
            arguments: ["expression": .string("1+2"), "precision": .number(2.5)]
        )
        XCTAssertFalse(invalidPrecision)
    }

    func testRejectsNonFiniteScrollDelta() {
        let invalid = ToolSchemaValidator.validateArguments(
            name: .browserScroll,
            arguments: ["deltaY": .number(.infinity)]
        )
        XCTAssertFalse(invalid)
    }

    func testValidateCollectionCreateArguments() {
        let valid = ToolSchemaValidator.validateArguments(
            name: .collectionCreate,
            arguments: ["title": .string("Meta coverage"), "tags": .array([.string("news")])]
        )
        XCTAssertTrue(valid)

        let invalid = ToolSchemaValidator.validateArguments(
            name: .collectionCreate,
            arguments: ["title": .string(" "), "tags": .array([.string("")])]
        )
        XCTAssertFalse(invalid)
    }

    func testValidateCollectionAddSourcesArguments() {
        let sources: JSONValue = .array([
            .object(["type": .string("url"), "url": .string("https://example.com")]),
            .object(["type": .string("note"), "text": .string("A note")])
        ])
        let valid = ToolSchemaValidator.validateArguments(
            name: .collectionAddSources,
            arguments: ["collectionId": .string("col_123"), "sources": sources]
        )
        XCTAssertTrue(valid)

        let invalid = ToolSchemaValidator.validateArguments(
            name: .collectionAddSources,
            arguments: ["collectionId": .string("col_123"), "sources": .array([])]
        )
        XCTAssertFalse(invalid)
    }

    func testValidateSourceCaptureArguments() {
        let valid = ToolSchemaValidator.validateArguments(
            name: .sourceCapture,
            arguments: [
                "collectionId": .string("col_123"),
                "url": .string("https://example.com"),
                "mode": .string("article"),
                "maxChars": .number(24000)
            ]
        )
        XCTAssertTrue(valid)

        let invalid = ToolSchemaValidator.validateArguments(
            name: .sourceCapture,
            arguments: [
                "collectionId": .string("col_123"),
                "url": .string("https://example.com"),
                "mode": .string("unknown")
            ]
        )
        XCTAssertFalse(invalid)
    }
}
