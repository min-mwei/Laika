import XCTest
@testable import LaikaAgentCore
import LaikaModel
import LaikaShared

final class AgentCoreTests: XCTestCase {
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

        XCTAssertEqual(response.actions.count, 1)
        XCTAssertEqual(response.actions.first?.policy.decision, .deny)
    }
}
