import Foundation

public enum SiteMode: String, Codable, Sendable {
    case assist
}

public enum FieldKind: String, Codable, Sendable {
    case unknown
    case credential
    case payment
    case personalId
}

public struct PolicyContext: Codable, Equatable, Sendable {
    public let origin: String
    public let mode: SiteMode
    public let fieldKind: FieldKind

    public init(origin: String, mode: SiteMode, fieldKind: FieldKind) {
        self.origin = origin
        self.mode = mode
        self.fieldKind = fieldKind
    }
}

public enum PolicyDecision: String, Codable, Sendable {
    case allow
    case ask
    case deny
}

public struct PolicyResult: Codable, Equatable, Sendable {
    public let decision: PolicyDecision
    public let reasonCode: String

    public init(decision: PolicyDecision, reasonCode: String) {
        self.decision = decision
        self.reasonCode = reasonCode
    }
}

public final class PolicyGate: Sendable {
    public init() {}

    public func decide(for toolCall: ToolCall, context: PolicyContext) -> PolicyResult {
        switch toolCall.name {
        case .browserObserveDom:
            return PolicyResult(decision: .allow, reasonCode: "observe_allowed")
        case .search:
            if let query = extractSearchQuery(toolCall),
               isSensitiveSearchQuery(query) {
                return PolicyResult(decision: .ask, reasonCode: "search_sensitive_query")
            }
            // Web search is the safest "navigation" primitive we expose; allow by default.
            return PolicyResult(decision: .allow, reasonCode: "search_allowed")
        case .browserClick,
             .browserType,
             .browserScroll,
             .browserOpenTab,
            .browserNavigate,
             .browserBack,
             .browserForward,
             .browserRefresh,
             .browserSelect:
            if context.fieldKind == .credential || context.fieldKind == .payment || context.fieldKind == .personalId {
                return PolicyResult(decision: .deny, reasonCode: "sensitive_field_blocked")
            }
            return PolicyResult(decision: .ask, reasonCode: "assist_requires_approval")
        case .appCalculate:
            return PolicyResult(decision: .allow, reasonCode: "calculate_allowed")
        }
    }

    private func extractSearchQuery(_ toolCall: ToolCall) -> String? {
        guard case let .string(query)? = toolCall.arguments["query"] else {
            return nil
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func isSensitiveSearchQuery(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return false
        }
        if Self.emailRegex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
            return true
        }
        if let phoneMatch = Self.phoneRegex.firstMatch(
            in: trimmed,
            options: [],
            range: NSRange(trimmed.startIndex..., in: trimmed)
        ) {
            if let range = Range(phoneMatch.range, in: trimmed) {
                let digits = trimmed[range].filter(\.isNumber)
                if digits.count >= 7 {
                    return true
                }
            }
        }
        if Self.keywordRegex.firstMatch(in: trimmed.lowercased(), options: [], range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
            let digitCount = trimmed.filter(\.isNumber).count
            if digitCount >= 4 {
                return true
            }
        }
        if Self.longDigitRegex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
            return true
        }
        return false
    }

    private static let emailRegex: NSRegularExpression = {
        let pattern = "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static let phoneRegex: NSRegularExpression = {
        let pattern = "(?:\\+?\\d[\\d\\s().-]{6,}\\d)"
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static let keywordRegex: NSRegularExpression = {
        let pattern = "(account|acct|routing|iban|swift|ssn|social\\s+security|tax\\s+id|passport|driver\\s+license|card\\s+number|bank\\s+account)"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static let longDigitRegex: NSRegularExpression = {
        let pattern = "\\d{9,}"
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()
}
