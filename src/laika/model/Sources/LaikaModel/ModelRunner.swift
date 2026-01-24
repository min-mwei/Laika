import Foundation
import LaikaShared

public struct AssistantMessage: Codable, Equatable, Sendable {
    public let title: String?
    public let render: Document
    public let citations: [LLMCPCitation]

    public init(title: String? = nil, render: Document, citations: [LLMCPCitation] = []) {
        self.title = title
        self.render = render
        self.citations = citations
    }
}

public struct ModelResponse: Codable, Equatable, Sendable {
    public let toolCalls: [ToolCall]
    public let summary: String
    public let assistant: AssistantMessage

    public init(toolCalls: [ToolCall], assistant: AssistantMessage, summary: String? = nil) {
        self.toolCalls = toolCalls
        self.assistant = assistant
        self.summary = summary ?? assistant.render.plainText()
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
