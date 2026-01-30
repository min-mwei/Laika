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
    public let rawMarkdown: String?

    public init(toolCalls: [ToolCall], assistant: AssistantMessage, summary: String? = nil) {
        self.init(toolCalls: toolCalls, assistant: assistant, summary: summary, rawMarkdown: nil)
    }

    public init(toolCalls: [ToolCall], assistant: AssistantMessage, summary: String? = nil, rawMarkdown: String?) {
        self.toolCalls = toolCalls
        self.assistant = assistant
        self.summary = summary ?? assistant.render.plainText()
        self.rawMarkdown = rawMarkdown
    }
}

public struct AnswerLogContext: Codable, Equatable, Sendable {
    public let runId: String?
    public let step: Int?
    public let maxSteps: Int?
    public let origin: String
    public let pageURL: String
    public let pageTitle: String
    public let sourceCount: Int
    public let contextChars: Int

    public init(
        runId: String?,
        step: Int?,
        maxSteps: Int?,
        origin: String,
        pageURL: String,
        pageTitle: String,
        sourceCount: Int,
        contextChars: Int
    ) {
        self.runId = runId
        self.step = step
        self.maxSteps = maxSteps
        self.origin = origin
        self.pageURL = pageURL
        self.pageTitle = pageTitle
        self.sourceCount = sourceCount
        self.contextChars = contextChars
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
    func generateAnswer(request: LLMCPRequest, logContext: AnswerLogContext) async throws -> ModelResponse
}

public extension ModelRunner {
    func parseGoalPlan(context: ContextPack, userGoal: String) async throws -> GoalPlan {
        return GoalPlan.unknown
    }
}
