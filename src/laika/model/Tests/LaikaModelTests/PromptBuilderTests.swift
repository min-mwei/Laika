import XCTest
@testable import LaikaModel

final class PromptBuilderTests: XCTestCase {
    func testMarkdownSystemPromptIsMarkdownOnly() {
        let prompt = PromptBuilder.markdownSystemPrompt()
        XCTAssertTrue(prompt.contains("Output ONLY Markdown"))
        XCTAssertTrue(prompt.contains("Do not output JSON"))
        XCTAssertFalse(prompt.contains("JSON schema"))
    }
}
