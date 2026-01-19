import Foundation
import LaikaShared

public final class StaticModelRunner: ModelRunner {
    public init() {}

    public func generatePlan(context: ContextPack, userGoal: String) async throws -> ModelResponse {
        if context.mode == .observe {
            return ModelResponse(toolCalls: [], summary: "Summary requested.")
        }
        let normalizedGoal = userGoal.lowercased()
        if normalizedGoal.contains("click") || normalizedGoal.contains("open") {
            if let first = context.observation.elements.first {
                let call = ToolCall(
                    name: .browserClick,
                    arguments: ["handleId": .string(first.handleId)]
                )
                return ModelResponse(toolCalls: [call], summary: "Propose clicking an element.")
            }
        }

        if normalizedGoal.contains("type") {
            if let first = context.observation.elements.first {
                let call = ToolCall(
                    name: .browserType,
                    arguments: [
                        "handleId": .string(first.handleId),
                        "text": .string("example")
                    ]
                )
                return ModelResponse(toolCalls: [call], summary: "Propose typing into an element.")
            }
        }

        return ModelResponse(toolCalls: [], summary: "No tool calls proposed.")
    }
}
