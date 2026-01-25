import Foundation

public enum ToolArgumentType: Equatable, Sendable {
    case string
    case number
    case bool
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
        case (.number, .number):
            return true
        case (.bool, .bool):
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
}
