import Foundation

public enum ExpressionError: Error, LocalizedError, Sendable {
    case emptyExpression
    case invalidToken
    case unexpectedEnd
    case unbalancedParentheses
    case divideByZero

    public var errorDescription: String? {
        switch self {
        case .emptyExpression:
            return "Expression is empty."
        case .invalidToken:
            return "Expression contains an invalid token."
        case .unexpectedEnd:
            return "Expression ended unexpectedly."
        case .unbalancedParentheses:
            return "Expression has unbalanced parentheses."
        case .divideByZero:
            return "Division by zero."
        }
    }
}

public enum ExpressionEvaluator {
    public static func evaluate(_ input: String) throws -> Double {
        var parser = Parser(input: input)
        let value = try parser.parseExpression()
        parser.skipWhitespace()
        if parser.isAtEnd {
            return value
        }
        throw ExpressionError.invalidToken
    }

    private struct Parser {
        let characters: [Character]
        var index: Int

        init(input: String) {
            self.characters = Array(input)
            self.index = 0
        }

        var isAtEnd: Bool {
            index >= characters.count
        }

        mutating func parseExpression() throws -> Double {
            skipWhitespace()
            if isAtEnd {
                throw ExpressionError.emptyExpression
            }
            var value = try parseTerm()
            while true {
                skipWhitespace()
                if match("+") {
                    value += try parseTerm()
                    continue
                }
                if match("-") {
                    value -= try parseTerm()
                    continue
                }
                break
            }
            return value
        }

        mutating func parseTerm() throws -> Double {
            var value = try parseFactor()
            while true {
                skipWhitespace()
                if match("*") {
                    value *= try parseFactor()
                    continue
                }
                if match("/") {
                    let divisor = try parseFactor()
                    if divisor == 0 {
                        throw ExpressionError.divideByZero
                    }
                    value /= divisor
                    continue
                }
                break
            }
            return value
        }

        mutating func parseFactor() throws -> Double {
            skipWhitespace()
            if match("+") {
                return try parseFactor()
            }
            if match("-") {
                let value = try parseFactor()
                return -value
            }
            if match("(") {
                let value = try parseExpression()
                skipWhitespace()
                if !match(")") {
                    throw ExpressionError.unbalancedParentheses
                }
                return value
            }
            return try parseNumber()
        }

        mutating func parseNumber() throws -> Double {
            skipWhitespace()
            let startIndex = index
            var hasDot = false
            while !isAtEnd {
                let character = characters[index]
                if character.isNumber {
                    index += 1
                    continue
                }
                if character == "." && !hasDot {
                    hasDot = true
                    index += 1
                    continue
                }
                break
            }
            if startIndex == index {
                throw ExpressionError.invalidToken
            }
            let valueString = String(characters[startIndex..<index])
            if valueString == "." {
                throw ExpressionError.invalidToken
            }
            guard let value = Double(valueString) else {
                throw ExpressionError.invalidToken
            }
            return value
        }

        mutating func skipWhitespace() {
            while !isAtEnd && characters[index].isWhitespace {
                index += 1
            }
        }

        mutating func match(_ value: Character) -> Bool {
            guard !isAtEnd, characters[index] == value else {
                return false
            }
            index += 1
            return true
        }
    }
}
