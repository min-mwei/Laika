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
        }
    }
}
