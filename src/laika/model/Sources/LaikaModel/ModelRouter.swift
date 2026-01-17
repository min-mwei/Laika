import Foundation
import LaikaShared

public enum ModelPreference: Sendable {
    case mlx
    case staticFallback
}

public final class ModelRouter: ModelRunner {
    private let runner: ModelRunner

    public init(preferred: ModelPreference, modelURL: URL?, maxTokens: Int = 256) {
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
}
