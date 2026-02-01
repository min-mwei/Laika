import XCTest
@testable import LaikaModel

final class MarkdownCitationsTests: XCTestCase {
    func testExtractsCitationsBlock() {
        let input = """
        Answer line

        ---CITATIONS---
        {"doc_id":"src_1","quote":"Quote one"}
        {"doc_id":"src_2","quote":"Quote two"}
        ---END CITATIONS---
        """
        let result = MarkdownCitations.extract(from: input)
        XCTAssertEqual(result.markdown, "Answer line")
        XCTAssertEqual(result.citations.count, 2)
        XCTAssertEqual(result.citations[0].docId, "src_1")
        XCTAssertEqual(result.citations[1].docId, "src_2")
    }

    func testIgnoresMissingCitationsBlock() {
        let input = "Just text"
        let result = MarkdownCitations.extract(from: input)
        XCTAssertEqual(result.markdown, input)
        XCTAssertTrue(result.citations.isEmpty)
    }
}
