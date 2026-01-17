import Foundation
import LaikaShared
import LaikaModel

public struct AgentAction: Codable, Equatable, Sendable {
    public let toolCall: ToolCall
    public let policy: PolicyResult

    public init(toolCall: ToolCall, policy: PolicyResult) {
        self.toolCall = toolCall
        self.policy = policy
    }
}

public struct AgentResponse: Codable, Equatable, Sendable {
    public let summary: String
    public let actions: [AgentAction]

    public init(summary: String, actions: [AgentAction]) {
        self.summary = summary
        self.actions = actions
    }
}

public final class AgentOrchestrator: Sendable {
    private let model: ModelRunner
    private let policyGate: PolicyGate

    public init(model: ModelRunner, policyGate: PolicyGate = PolicyGate()) {
        self.model = model
        self.policyGate = policyGate
    }

    public func runOnce(context: ContextPack, userGoal: String) async throws -> AgentResponse {
        let modelResponse = try await model.generatePlan(context: context, userGoal: userGoal)
        let actions = modelResponse.toolCalls.map { toolCall in
            let policyContext = PolicyContext(
                origin: context.origin,
                mode: context.mode,
                fieldKind: .unknown
            )
            let decision = policyGate.decide(for: toolCall, context: policyContext)
            return AgentAction(toolCall: toolCall, policy: decision)
        }
        return AgentResponse(summary: modelResponse.summary, actions: actions)
    }
}
