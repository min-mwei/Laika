import Foundation
import LaikaShared

public enum ModelPreference: Sendable {
    case mlx
    case staticFallback
}

public final class ModelRouter: ModelRunner, StreamingModelRunner {
    private let runner: ModelRunner

    public init(preferred: ModelPreference, modelURL: URL?, maxTokens: Int = 2048) {
        switch preferred {
        case .mlx:
            if let url = modelURL {
                self.runner = MLXModelRunner(modelURL: url, maxTokens: maxTokens)
            } else {
                self.runner = StaticModelRunner()
            }
        case .staticFallback:
            self.runner = StaticModelRunner()
        }
    }

    public func generatePlan(context: ContextPack, userGoal: String) async throws -> ModelResponse {
        try await runner.generatePlan(context: context, userGoal: userGoal)
    }

    public func parseGoalPlan(context: ContextPack, userGoal: String) async throws -> GoalPlan {
        try await runner.parseGoalPlan(context: context, userGoal: userGoal)
    }

    public func streamText(_ request: StreamRequest) -> AsyncThrowingStream<String, Error> {
        guard let streaming = runner as? StreamingModelRunner else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: ModelError.modelUnavailable("Streaming model unavailable."))
            }
        }
        return streaming.streamText(request)
    }
}
