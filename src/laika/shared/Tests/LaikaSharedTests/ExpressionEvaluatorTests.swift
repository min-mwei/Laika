import XCTest
@testable import LaikaShared

final class ExpressionEvaluatorTests: XCTestCase {
    func testEvaluatesBasicExpressions() throws {
        XCTAssertEqual(try ExpressionEvaluator.evaluate("1 + 2 * 3"), 7, accuracy: 0.0001)
        XCTAssertEqual(try ExpressionEvaluator.evaluate("(1 + 2) * 3"), 9, accuracy: 0.0001)
        XCTAssertEqual(try ExpressionEvaluator.evaluate("-4 + 2"), -2, accuracy: 0.0001)
        XCTAssertEqual(try ExpressionEvaluator.evaluate("3 / 2"), 1.5, accuracy: 0.0001)
        XCTAssertEqual(try ExpressionEvaluator.evaluate(".5 + 1"), 1.5, accuracy: 0.0001)
    }

    func testRejectsInvalidExpressions() {
        XCTAssertThrowsError(try ExpressionEvaluator.evaluate(""))
        XCTAssertThrowsError(try ExpressionEvaluator.evaluate("1 +"))
        XCTAssertThrowsError(try ExpressionEvaluator.evaluate("2 * (3 + 4"))
    }

    func testDivideByZero() {
        XCTAssertThrowsError(try ExpressionEvaluator.evaluate("10 / 0")) { error in
            guard let exprError = error as? ExpressionError else {
                XCTFail("Unexpected error type")
                return
            }
            XCTAssertEqual(exprError, .divideByZero)
        }
    }
}
