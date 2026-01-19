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

    func testObserveModeDeniesAction() async throws {
        let element = ObservedElement(
            handleId: "el-1",
            role: "button",
            label: "Continue",
            boundingBox: BoundingBox(x: 0, y: 0, width: 10, height: 10)
        )
        let observation = Observation(url: "https://example.com", title: "Example", text: "", elements: [element])
        let context = ContextPack(origin: "https://example.com", mode: .observe, observation: observation, recentToolCalls: [])

        let model = StaticModelRunner()
        let orchestrator = AgentOrchestrator(model: model)
        let response = try await orchestrator.runOnce(context: context, userGoal: "Click continue")

        XCTAssertEqual(response.actions.count, 0)
    }

    func testObserveModeAppendsMainLinksWhenSummaryUngrounded() async throws {
        let elements = [
            ObservedElement(
                handleId: "el-1",
                role: "a",
                label: "Alpha Beta Gamma",
                boundingBox: BoundingBox(x: 0, y: 0, width: 10, height: 10),
                href: "https://example.com/a"
            ),
            ObservedElement(
                handleId: "el-2",
                role: "a",
                label: "Delta Epsilon Zeta",
                boundingBox: BoundingBox(x: 0, y: 20, width: 10, height: 10),
                href: "https://example.com/b"
            ),
            ObservedElement(
                handleId: "el-3",
                role: "a",
                label: "Eta Theta Iota",
                boundingBox: BoundingBox(x: 0, y: 40, width: 10, height: 10),
                href: "https://example.com/c"
            )
        ]
        let observation = Observation(url: "https://example.com", title: "Example", text: "", elements: elements)
        let context = ContextPack(origin: "https://example.com", mode: .observe, observation: observation, recentToolCalls: [])
        let model = MockModelRunner(summary: "This page is about Example.")
        let orchestrator = AgentOrchestrator(model: model)

        let response = try await orchestrator.runOnce(context: context, userGoal: "What is this page about?")

        XCTAssertTrue(response.summary.contains("Alpha Beta Gamma"))
        XCTAssertEqual(response.actions.count, 0)
    }
}
