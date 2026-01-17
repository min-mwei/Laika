import XCTest
@testable import LaikaModel
import LaikaShared

final class ToolCallParserTests: XCTestCase {
    func testParsesJSONToolCall() throws {
        let output = """
        {\"summary\":\"ok\",\"tool_calls\":[{\"name\":\"browser.click\",\"arguments\":{\"handleId\":\"laika-1\"}}]}
        """
        let parsed = try ToolCallParser.parse(output)
        XCTAssertEqual(parsed.summary, "ok")
        XCTAssertEqual(parsed.toolCalls.count, 1)
        XCTAssertEqual(parsed.toolCalls.first?.name, .browserClick)
    }

    func testIgnoresUnknownToolNames() throws {
        let output = """
        {\"summary\":\"ok\",\"tool_calls\":[{\"name\":\"browser.unknown\",\"arguments\":{}}]}
        """
        let parsed = try ToolCallParser.parse(output)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testFallbacksToSummaryWhenNoJSON() throws {
        let output = "This page lists recent SEC filings and search options."
        let parsed = try ToolCallParser.parse(output)
        XCTAssertEqual(parsed.summary, output)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }
}
