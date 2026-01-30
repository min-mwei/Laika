import XCTest
@testable import LaikaModel

final class ModelOutputParserTests: XCTestCase {
    func testExtractsJSONObjectInsideCodeFence() {
        let output = """
        ```json
        { "protocol": { "name": "laika.llmcp", "version": 1 }, "assistant": { "render": { "type": "doc", "children": [] } } }
        ```
        """
        let json = ModelOutputParser.extractJSONObject(from: output)
        XCTAssertNotNil(json)
        XCTAssertTrue(json?.contains("\"protocol\"") == true)
        XCTAssertTrue(json?.contains("\"assistant\"") == true)
    }
}
