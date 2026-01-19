import Foundation
import LaikaShared

public final class StaticModelRunner: ModelRunner {
    public init() {}

    public func generatePlan(context: ContextPack, userGoal: String) async throws -> ModelResponse {
        if context.mode == .observe {
            return ModelResponse(toolCalls: [], summary: "Summary requested.")
        }
        return ModelResponse(toolCalls: [], summary: "No tool calls proposed.")
    }
}
