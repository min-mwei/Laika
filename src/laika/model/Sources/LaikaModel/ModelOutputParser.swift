import Foundation

enum ModelOutputParser {
    static func sanitize(_ text: String) -> String {
        let withoutThinking = stripThinkBlocks(from: text)
        return stripCodeFences(from: withoutThinking)
    }

    static func extractJSONObject(from text: String) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        var startIndex: String.Index?

        for index in text.indices {
            let char = text[index]
            if escaped {
                escaped = false
                continue
            }
            if char == "\\" {
                if inString {
                    escaped = true
                }
                continue
            }
            if char == "\"" {
                inString.toggle()
                continue
            }
            if inString {
                continue
            }
            if char == "{" {
                if depth == 0 {
                    startIndex = index
                }
                depth += 1
            } else if char == "}" {
                if depth > 0 {
                    depth -= 1
                    if depth == 0, let startIndex {
                        let endIndex = text.index(after: index)
                        return String(text[startIndex..<endIndex])
                    }
                }
            }
        }
        return nil
    }

    static func extractJSONObjectRelaxed(from text: String) -> String? {
        if let strict = extractJSONObject(from: text) {
            return strict
        }
        guard let startIndex = text.firstIndex(of: "{"),
              let endIndex = text.lastIndex(of: "}")
        else {
            return nil
        }
        if startIndex >= endIndex {
            return nil
        }
        return String(text[startIndex...endIndex])
    }

    static func repairJSON(_ text: String) -> String {
        let pattern = ",\\s*([}\\]])"
        return text.replacingOccurrences(of: pattern, with: "$1", options: [.regularExpression])
    }

    private static func stripThinkBlocks(from text: String) -> String {
        let pattern = "<think>[\\s\\S]*?</think>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private static func stripCodeFences(from text: String) -> String {
        let pattern = "```[a-zA-Z0-9]*"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let stripped = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return stripped.replacingOccurrences(of: "```", with: "")
    }
}
