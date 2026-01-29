import Foundation

public enum ToolArgumentType: Equatable, Sendable {
    case string
    case number
    case bool
    case object
    case array
}

public enum ToolSchemaValidator {
    public static func validate(toolCall: ToolCall) -> Bool {
        validateArguments(name: toolCall.name, arguments: toolCall.arguments)
    }

    public static func validateArguments(name: ToolName, arguments: [String: JSONValue]) -> Bool {
        switch name {
        case .browserObserveDom:
            let optional: [String: ToolArgumentType] = [
                "maxChars": .number,
                "maxElements": .number,
                "maxBlocks": .number,
                "maxPrimaryChars": .number,
                "maxOutline": .number,
                "maxOutlineChars": .number,
                "maxItems": .number,
                "maxItemChars": .number,
                "maxComments": .number,
                "maxCommentChars": .number,
                "rootHandleId": .string
            ]
            let valid = validate(arguments: arguments, required: [:], optional: optional)
            if !valid {
                return false
            }
            if arguments["rootHandleId"] != nil && !hasNonEmptyString(arguments, key: "rootHandleId") {
                return false
            }
            return true
        case .browserGetSelectionLinks:
            let valid = validate(arguments: arguments, required: [:], optional: ["maxLinks": .number])
            if !valid {
                return false
            }
            return hasValidMaxLinks(arguments, key: "maxLinks")
        case .browserClick:
            return validate(arguments: arguments, required: ["handleId": .string], optional: [:])
                && hasNonEmptyString(arguments, key: "handleId")
        case .browserType:
            return validate(arguments: arguments, required: ["handleId": .string, "text": .string], optional: [:])
                && hasNonEmptyString(arguments, key: "handleId")
        case .browserScroll:
            return validate(arguments: arguments, required: ["deltaY": .number], optional: [:])
        case .browserOpenTab:
            return validate(arguments: arguments, required: ["url": .string], optional: [:])
                && hasNonEmptyString(arguments, key: "url")
        case .browserNavigate:
            return validate(arguments: arguments, required: ["url": .string], optional: [:])
                && hasNonEmptyString(arguments, key: "url")
        case .browserBack, .browserForward, .browserRefresh:
            return arguments.isEmpty
        case .browserSelect:
            return validate(arguments: arguments, required: ["handleId": .string, "value": .string], optional: [:])
                && hasNonEmptyString(arguments, key: "handleId")
                && hasNonEmptyString(arguments, key: "value")
        case .search:
            return validate(arguments: arguments, required: ["query": .string], optional: ["engine": .string, "newTab": .bool])
                && hasNonEmptyString(arguments, key: "query")
        case .appCalculate:
            let valid = validate(arguments: arguments, required: ["expression": .string], optional: ["precision": .number])
            if !valid || !hasNonEmptyString(arguments, key: "expression") {
                return false
            }
            return hasValidPrecision(arguments, key: "precision")
        case .collectionCreate:
            let valid = validate(arguments: arguments, required: ["title": .string], optional: ["tags": .array])
            if !valid || !hasNonEmptyString(arguments, key: "title") {
                return false
            }
            return hasValidStringArray(arguments, key: "tags")
        case .collectionAddSources:
            let valid = validate(arguments: arguments, required: ["collectionId": .string, "sources": .array], optional: [:])
            if !valid || !hasNonEmptyString(arguments, key: "collectionId") {
                return false
            }
            return hasValidSourcesArray(arguments, key: "sources")
        case .collectionListSources:
            return validate(arguments: arguments, required: ["collectionId": .string], optional: [:])
                && hasNonEmptyString(arguments, key: "collectionId")
        case .sourceCapture:
            let valid = validate(arguments: arguments, required: ["collectionId": .string, "url": .string], optional: [
                "mode": .string,
                "maxChars": .number
            ])
            if !valid || !hasNonEmptyString(arguments, key: "collectionId") || !hasNonEmptyString(arguments, key: "url") {
                return false
            }
            if let mode = arguments["mode"], !isValidCaptureMode(mode) {
                return false
            }
            return hasValidMaxChars(arguments, key: "maxChars")
        case .sourceRefresh:
            return validate(arguments: arguments, required: ["sourceId": .string], optional: [:])
                && hasNonEmptyString(arguments, key: "sourceId")
        case .transformListTypes:
            return arguments.isEmpty
        case .transformRun:
            let valid = validate(arguments: arguments, required: ["collectionId": .string, "type": .string], optional: ["config": .object])
            if !valid || !hasNonEmptyString(arguments, key: "collectionId") || !hasNonEmptyString(arguments, key: "type") {
                return false
            }
            return hasValidObject(arguments, key: "config")
        case .artifactSave:
            let valid = validate(arguments: arguments, required: ["title": .string, "markdown": .string], optional: ["tags": .array, "redaction": .string])
            if !valid || !hasNonEmptyString(arguments, key: "title") || !hasNonEmptyString(arguments, key: "markdown") {
                return false
            }
            return hasValidStringArray(arguments, key: "tags")
        case .artifactOpen:
            let valid = validate(arguments: arguments, required: ["artifactId": .string], optional: ["target": .string, "newTab": .bool])
            if !valid || !hasNonEmptyString(arguments, key: "artifactId") {
                return false
            }
            return hasValidArtifactTarget(arguments, key: "target")
        case .artifactShare:
            let valid = validate(arguments: arguments, required: ["artifactId": .string, "format": .string], optional: ["filename": .string, "target": .string])
            if !valid || !hasNonEmptyString(arguments, key: "artifactId") || !hasNonEmptyString(arguments, key: "format") {
                return false
            }
            return hasValidArtifactTarget(arguments, key: "target")
        case .integrationInvoke:
            let valid = validate(arguments: arguments, required: ["integration": .string, "operation": .string, "payload": .object], optional: ["idempotencyKey": .string])
            if !valid || !hasNonEmptyString(arguments, key: "integration") || !hasNonEmptyString(arguments, key: "operation") {
                return false
            }
            return hasValidObject(arguments, key: "payload")
        }
    }

    private static func validate(
        arguments: [String: JSONValue],
        required: [String: ToolArgumentType],
        optional: [String: ToolArgumentType]
    ) -> Bool {
        if !containsOnlyKnownKeys(arguments: arguments, required: required, optional: optional) {
            return false
        }
        for (key, type) in required {
            guard let value = arguments[key], isType(value, expected: type) else {
                return false
            }
        }
        for (key, value) in arguments {
            if let expected = required[key] ?? optional[key], !isType(value, expected: expected) {
                return false
            }
        }
        return true
    }

    private static func containsOnlyKnownKeys(
        arguments: [String: JSONValue],
        required: [String: ToolArgumentType],
        optional: [String: ToolArgumentType]
    ) -> Bool {
        for key in arguments.keys {
            if required[key] == nil && optional[key] == nil {
                return false
            }
        }
        return true
    }

    private static func isType(_ value: JSONValue, expected: ToolArgumentType) -> Bool {
        switch (value, expected) {
        case (.string, .string):
            return true
        case let (.number(number), .number):
            return number.isFinite
        case (.bool, .bool):
            return true
        case (.object, .object):
            return true
        case (.array, .array):
            return true
        default:
            return false
        }
    }

    private static func hasNonEmptyString(_ arguments: [String: JSONValue], key: String) -> Bool {
        guard case let .string(value)? = arguments[key] else {
            return false
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func hasValidPrecision(_ arguments: [String: JSONValue], key: String) -> Bool {
        guard let value = arguments[key] else {
            return true
        }
        guard case let .number(precision) = value else {
            return false
        }
        if precision.rounded() != precision {
            return false
        }
        return precision >= 0 && precision <= 6
    }

    private static func hasValidMaxChars(_ arguments: [String: JSONValue], key: String) -> Bool {
        guard let value = arguments[key] else {
            return true
        }
        guard case let .number(maxChars) = value else {
            return false
        }
        if !maxChars.isFinite || maxChars.rounded() != maxChars {
            return false
        }
        return maxChars >= 100 && maxChars <= 200_000
    }

    private static func hasValidMaxLinks(_ arguments: [String: JSONValue], key: String) -> Bool {
        guard let value = arguments[key] else {
            return true
        }
        guard case let .number(maxLinks) = value else {
            return false
        }
        if maxLinks.rounded() != maxLinks {
            return false
        }
        return maxLinks >= 1 && maxLinks <= 200
    }

    private static func hasValidStringArray(_ arguments: [String: JSONValue], key: String) -> Bool {
        guard let value = arguments[key] else {
            return true
        }
        guard case let .array(items) = value else {
            return false
        }
        for item in items {
            guard case let .string(text) = item else {
                return false
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
        }
        return true
    }

    private static func hasValidObject(_ arguments: [String: JSONValue], key: String) -> Bool {
        guard let value = arguments[key] else {
            return true
        }
        if case .object = value {
            return true
        }
        return false
    }

    private static func isValidCaptureMode(_ value: JSONValue) -> Bool {
        guard case let .string(mode) = value else {
            return false
        }
        switch mode {
        case "auto", "article", "list":
            return true
        default:
            return false
        }
    }

    private static func hasValidArtifactTarget(_ arguments: [String: JSONValue], key: String) -> Bool {
        guard let value = arguments[key] else {
            return true
        }
        guard case let .string(target) = value else {
            return false
        }
        if target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        return ["viewer", "source", "download"].contains(target)
    }

    private static func hasValidSourcesArray(_ arguments: [String: JSONValue], key: String) -> Bool {
        guard let value = arguments[key] else {
            return false
        }
        guard case let .array(items) = value else {
            return false
        }
        if items.isEmpty {
            return false
        }
        for item in items {
            guard case let .object(payload) = item else {
                return false
            }
            guard case let .string(type) = payload["type"] else {
                return false
            }
            if type == "url" {
                guard case let .string(url) = payload["url"],
                      !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return false
                }
                if let title = payload["title"] {
                    guard case let .string(text) = title,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return false
                    }
                }
                let allowedKeys = ["type", "url", "title"]
                if payload.keys.contains(where: { key in !allowedKeys.contains(key) }) {
                    return false
                }
            } else if type == "note" {
                guard case let .string(text) = payload["text"],
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return false
                }
                if let title = payload["title"] {
                    guard case let .string(text) = title,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return false
                    }
                }
                let allowedKeys = ["type", "text", "title"]
                if payload.keys.contains(where: { key in !allowedKeys.contains(key) }) {
                    return false
                }
            } else {
                return false
            }
        }
        return true
    }
}
