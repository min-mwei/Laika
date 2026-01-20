import Foundation
import LaikaShared

public final class StaticModelRunner: StreamingModelRunner {
    public init() {}

    public func generatePlan(context: ContextPack, userGoal: String) async throws -> ModelResponse {
        return ModelResponse(toolCalls: [], summary: "No tool calls proposed.")
    }

    public func streamText(_ request: StreamRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("Summary requested.")
            continuation.finish()
        }
    }
}
