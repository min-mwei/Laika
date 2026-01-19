import Foundation
import LaikaShared

public struct ModelResponse: Codable, Equatable, Sendable {
    public let toolCalls: [ToolCall]
    public let summary: String

    public init(toolCalls: [ToolCall], summary: String) {
        self.toolCalls = toolCalls
        self.summary = summary
    }
}

public enum ModelError: Error, LocalizedError {
    case modelUnavailable(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let message):
            return message
        case .invalidResponse(let message):
            return message
        }
    }
}

public protocol ModelRunner: Sendable {
    func generatePlan(context: ContextPack, userGoal: String) async throws -> ModelResponse
    func parseGoalPlan(context: ContextPack, userGoal: String) async throws -> GoalPlan
}

public extension ModelRunner {
    func parseGoalPlan(context: ContextPack, userGoal: String) async throws -> GoalPlan {
        return GoalPlan.unknown
    }
}
