import XCTest
@testable import LaikaModel
import LaikaShared

final class StaticModelRunnerTests: XCTestCase {
    func testClickProposalWhenElementsPresent() async throws {
        let element = ObservedElement(
            handleId: "el-1",
            role: "button",
            label: "Continue",
            boundingBox: BoundingBox(x: 0, y: 0, width: 10, height: 10)
        )
        let observation = Observation(url: "https://example.com", title: "Example", text: "", elements: [element])
        let context = ContextPack(origin: "https://example.com", mode: .assist, observation: observation, recentToolCalls: [])

        let runner = StaticModelRunner()
        let response = try await runner.generatePlan(context: context, userGoal: "Click continue")

        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls.first?.name, .browserClick)
    }

    func testRouterFallsBackToStatic() async throws {
        let observation = Observation(url: "https://example.com", title: "Example", text: "", elements: [])
        let context = ContextPack(origin: "https://example.com", mode: .assist, observation: observation, recentToolCalls: [])

        let router = ModelRouter(preferred: .staticFallback, modelURL: nil)
        let response = try await router.generatePlan(context: context, userGoal: "Summarize")

        XCTAssertTrue(response.toolCalls.isEmpty)
    }
}
