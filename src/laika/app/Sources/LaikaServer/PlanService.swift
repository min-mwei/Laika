import Foundation
import LaikaAgentCore
import LaikaModel
import LaikaShared

final class PlanService {
    private let orchestrator: AgentOrchestrator

    init(modelRunner: ModelRunner) {
        self.orchestrator = AgentOrchestrator(model: modelRunner)
    }

    func plan(from request: PlanRequest) async throws -> AgentResponse {
        try request.validate()
        return try await orchestrator.runOnce(context: request.context, userGoal: request.goal)
    }
}
