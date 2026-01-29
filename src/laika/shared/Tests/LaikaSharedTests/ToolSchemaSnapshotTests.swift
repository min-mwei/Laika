import XCTest
@testable import LaikaShared

final class ToolSchemaSnapshotTests: XCTestCase {
    private struct Snapshot: Decodable {
        let tools: [String: ToolSchemaEntry]
    }

    private struct ToolSchemaEntry: Decodable {
        let required: [String: String]
        let optional: [String: String]
    }

    func testSchemaSnapshotMatchesValidator() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "tool_schema_snapshot", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)

        for (toolName, entry) in snapshot.tools {
            guard let name = ToolName(rawValue: toolName) else {
                XCTFail("Unknown tool name in snapshot: \(toolName)")
                continue
            }

            var arguments: [String: JSONValue] = [:]
            for (key, type) in entry.required {
                arguments[key] = makeValidValue(for: key, type: type)
            }
            XCTAssertTrue(
                ToolSchemaValidator.validateArguments(name: name, arguments: arguments),
                "Expected \(toolName) to accept required args: \(arguments)"
            )

            for (key, type) in entry.optional {
                var withOptional = arguments
                withOptional[key] = makeValidValue(for: key, type: type)
                XCTAssertTrue(
                    ToolSchemaValidator.validateArguments(name: name, arguments: withOptional),
                    "Expected \(toolName) to accept optional arg \(key)"
                )
            }

            var withExtra = arguments
            withExtra["__unknown"] = .string("nope")
            XCTAssertFalse(
                ToolSchemaValidator.validateArguments(name: name, arguments: withExtra),
                "Expected \(toolName) to reject unknown args"
            )

            let combined = entry.required.merging(entry.optional) { current, _ in current }
            for (key, type) in combined {
                var withWrongType = arguments
                withWrongType[key] = makeInvalidValue(for: type)
                XCTAssertFalse(
                    ToolSchemaValidator.validateArguments(name: name, arguments: withWrongType),
                    "Expected \(toolName) to reject wrong type for \(key)"
                )
            }
        }
    }

    private func makeValidValue(for key: String, type: String) -> JSONValue {
        switch type {
        case "string":
            switch key {
            case "handleId", "rootHandleId":
                return .string("laika-1")
            case "url":
                return .string("https://example.com")
            case "expression":
                return .string("1 + 2")
            case "query":
                return .string("example search")
            case "value":
                return .string("option")
            case "mode":
                return .string("auto")
            case "target":
                return .string("viewer")
            default:
                return .string("value")
            }
        case "number":
            if key == "precision" {
                return .number(2)
            }
            if key == "deltaY" {
                return .number(120)
            }
            if key == "maxLinks" {
                return .number(50)
            }
            return .number(1200)
        case "bool":
            return .bool(true)
        case "array":
            if key == "tags" {
                return .array([.string("tag")])
            }
            if key == "sources" {
                return .array([
                    .object([
                        "type": .string("url"),
                        "url": .string("https://example.com")
                    ])
                ])
            }
            return .array([])
        case "object":
            if key == "payload" {
                return .object(["value": .string("ok")])
            }
            if key == "config" {
                return .object(["mode": .string("default")])
            }
            return .object([:])
        default:
            return .string("value")
        }
    }

    private func makeInvalidValue(for type: String) -> JSONValue {
        switch type {
        case "string":
            return .number(1)
        case "number":
            return .string("bad")
        case "bool":
            return .string("bad")
        case "array":
            return .string("bad")
        case "object":
            return .string("bad")
        default:
            return .string("bad")
        }
    }
}
