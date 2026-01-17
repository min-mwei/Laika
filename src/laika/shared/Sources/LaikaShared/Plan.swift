import Foundation

public struct PlanRequest: Codable, Equatable, Sendable {
    public let context: ContextPack
    public let goal: String

    public init(context: ContextPack, goal: String) {
        self.context = context
        self.goal = goal
    }

    public func validate() throws {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedGoal.isEmpty {
            throw PlanValidationError.emptyGoal
        }
        guard let url = URL(string: context.origin),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw PlanValidationError.invalidOrigin
        }
    }
}

public enum PlanValidationError: Error, LocalizedError, Sendable {
    case emptyGoal
    case invalidOrigin

    public var errorDescription: String? {
        switch self {
        case .emptyGoal:
            return "Goal must not be empty."
        case .invalidOrigin:
            return "Origin must be a valid http(s) URL."
        }
    }
}
