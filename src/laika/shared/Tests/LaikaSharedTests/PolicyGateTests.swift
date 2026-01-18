import XCTest
@testable import LaikaShared

final class PolicyGateTests: XCTestCase {
    func testObserveAllowsObservation() {
        let gate = PolicyGate()
        let context = PolicyContext(origin: "https://example.com", mode: .observe, fieldKind: .unknown)
        let call = ToolCall(name: .browserObserveDom, arguments: [:])
        let result = gate.decide(for: call, context: context)
        XCTAssertEqual(result.decision, .allow)
    }

    func testObserveBlocksActions() {
        let gate = PolicyGate()
        let context = PolicyContext(origin: "https://example.com", mode: .observe, fieldKind: .unknown)
        let call = ToolCall(name: .browserClick, arguments: [:])
        let result = gate.decide(for: call, context: context)
        XCTAssertEqual(result.decision, .deny)
        XCTAssertEqual(result.reasonCode, "observe_mode_blocks_actions")
    }

    func testSensitiveFieldBlocksActions() {
        let gate = PolicyGate()
        let context = PolicyContext(origin: "https://example.com", mode: .assist, fieldKind: .credential)
        let call = ToolCall(name: .browserType, arguments: [:])
        let result = gate.decide(for: call, context: context)
        XCTAssertEqual(result.decision, .deny)
        XCTAssertEqual(result.reasonCode, "sensitive_field_blocked")
    }

    func testAssistRequiresApprovalForNavigation() {
        let gate = PolicyGate()
        let context = PolicyContext(origin: "https://example.com", mode: .assist, fieldKind: .unknown)
        let call = ToolCall(name: .browserNavigate, arguments: [:])
        let result = gate.decide(for: call, context: context)
        XCTAssertEqual(result.decision, .ask)
        XCTAssertEqual(result.reasonCode, "assist_requires_approval")
    }
}
