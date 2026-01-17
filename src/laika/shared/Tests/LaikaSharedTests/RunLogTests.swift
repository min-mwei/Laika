import XCTest
@testable import LaikaShared

final class RunLogTests: XCTestCase {
    func testAppendWritesJSONLines() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("laika_run_log_test.jsonl")
        try? FileManager.default.removeItem(at: fileURL)

        let log = RunLog(fileURL: fileURL)
        let event = RunEvent(type: "test", payload: .object(["value": .string("ok")]))
        try log.append(event)
        try log.append(event)

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
    }
}
