import Foundation
import LaikaAgentCore
import LaikaModel
import LaikaShared

final class PlanService {
    private let orchestrator: AgentOrchestrator
    private let summaryService: SummaryService

    init(modelRunner: ModelRunner) {
        self.orchestrator = AgentOrchestrator(model: modelRunner)
        self.summaryService = SummaryService(model: modelRunner)
    }

    func plan(from request: PlanRequest) async throws -> AgentResponse {
        try request.validate()
        return try await orchestrator.runOnce(context: request.context, userGoal: request.goal)
    }

    func summarize(from request: PlanRequest) async throws -> String {
        try request.validate()
        let goalPlan: GoalPlan
        if let existing = request.context.goalPlan {
            goalPlan = existing
        } else {
            goalPlan = await orchestrator.resolveGoalPlan(context: request.context, userGoal: request.goal)
        }
        let summaryContext = contextWithGoalPlan(request.context, goalPlan: goalPlan)
        return try await summaryService.summarize(
            context: summaryContext,
            goalPlan: goalPlan,
            userGoal: request.goal,
            maxTokens: nil
        )
    }

    private func contextWithGoalPlan(_ context: ContextPack, goalPlan: GoalPlan) -> ContextPack {
        if context.goalPlan == goalPlan {
            return context
        }
        return ContextPack(
            origin: context.origin,
            mode: context.mode,
            observation: context.observation,
            recentToolCalls: context.recentToolCalls,
            recentToolResults: context.recentToolResults,
            tabs: context.tabs,
            goalPlan: goalPlan,
            runId: context.runId,
            step: context.step,
            maxSteps: context.maxSteps
        )
    }
}
