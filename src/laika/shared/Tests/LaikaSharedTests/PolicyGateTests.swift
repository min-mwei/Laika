import XCTest
@testable import LaikaShared

final class PolicyGateTests: XCTestCase {
    func testAssistAllowsObservation() {
        let gate = PolicyGate()
        let context = PolicyContext(origin: "https://example.com", mode: .assist, fieldKind: .unknown)
        let call = ToolCall(name: .browserObserveDom, arguments: [:])
        let result = gate.decide(for: call, context: context)
        XCTAssertEqual(result.decision, .allow)
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

    func testSensitiveSearchRequiresApproval() {
        let gate = PolicyGate()
        let context = PolicyContext(origin: "https://example.com", mode: .assist, fieldKind: .unknown)
        let call = ToolCall(name: .search, arguments: ["query": .string("contact me at jane.doe@example.com")])
        let result = gate.decide(for: call, context: context)
        XCTAssertEqual(result.decision, .ask)
        XCTAssertEqual(result.reasonCode, "search_sensitive_query")
    }

    func testNonSensitiveSearchAllowed() {
        let gate = PolicyGate()
        let context = PolicyContext(origin: "https://example.com", mode: .assist, fieldKind: .unknown)
        let call = ToolCall(name: .search, arguments: ["query": .string("best hiking trails near seattle")])
        let result = gate.decide(for: call, context: context)
        XCTAssertEqual(result.decision, .allow)
        XCTAssertEqual(result.reasonCode, "search_allowed")
    }
}
