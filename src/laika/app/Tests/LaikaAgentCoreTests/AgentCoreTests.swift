import XCTest
@testable import LaikaAgentCore
import LaikaModel
import LaikaShared

final class AgentCoreTests: XCTestCase {
    private struct MockModelRunner: ModelRunner {
        let summary: String

        func generatePlan(context: ContextPack, userGoal: String) async throws -> ModelResponse {
            ModelResponse(toolCalls: [], summary: summary)
        }
    }

    func testAssistSummaryFallsBackWithoutStreamingModel() async throws {
        let element = ObservedElement(
            handleId: "el-1",
            role: "button",
            label: "Continue",
            boundingBox: BoundingBox(x: 0, y: 0, width: 10, height: 10)
        )
        let observation = Observation(url: "https://example.com", title: "Example", text: "", elements: [element])
        let context = ContextPack(origin: "https://example.com", mode: .assist, observation: observation, recentToolCalls: [])

        let model = StaticModelRunner()
        let orchestrator = AgentOrchestrator(model: model)
        let response = try await orchestrator.runOnce(context: context, userGoal: "What is this page about?")

        XCTAssertTrue(response.summary.isEmpty == false)
        XCTAssertEqual(response.actions.count, 0)
    }

    func testAssistSummaryFallbackIncludesItems() async throws {
        let items = [
            ObservedItem(
                title: "Alpha Beta Gamma",
                url: "https://example.com/a",
                snippet: "Alpha Beta Gamma is a sample item.",
                tag: "article",
                linkCount: 1,
                linkDensity: 0.1
            ),
            ObservedItem(
                title: "Delta Epsilon Zeta",
                url: "https://example.com/b",
                snippet: "Delta Epsilon Zeta follows up with more detail.",
                tag: "article",
                linkCount: 1,
                linkDensity: 0.1
            )
        ]
        let observation = Observation(
            url: "https://example.com",
            title: "Example",
            text: "",
            elements: [],
            items: items
        )
        let context = ContextPack(origin: "https://example.com", mode: .assist, observation: observation, recentToolCalls: [])
        let model = MockModelRunner(summary: "This page is about Example.")
        let orchestrator = AgentOrchestrator(model: model)

        let response = try await orchestrator.runOnce(context: context, userGoal: "What is this page about?")

        XCTAssertTrue(response.summary.contains("Alpha Beta Gamma"))
        XCTAssertEqual(response.actions.count, 0)
    }
}
