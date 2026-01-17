import XCTest
@testable import LaikaShared

final class PlanRequestTests: XCTestCase {
    func testValidationRejectsEmptyGoal() throws {
        let observation = Observation(url: "https://example.com", title: "", text: "", elements: [])
        let context = ContextPack(origin: "https://example.com", mode: .assist, observation: observation, recentToolCalls: [])
        let request = PlanRequest(context: context, goal: "  ")

        XCTAssertThrowsError(try request.validate())
    }

    func testValidationRejectsInvalidOrigin() throws {
        let observation = Observation(url: "file:///tmp", title: "", text: "", elements: [])
        let context = ContextPack(origin: "file:///tmp", mode: .assist, observation: observation, recentToolCalls: [])
        let request = PlanRequest(context: context, goal: "Summarize")

        XCTAssertThrowsError(try request.validate())
    }
}
