import Foundation
import LaikaShared

enum ToolCallParser {
    private struct ModelToolCall: Decodable {
        let name: String
        let arguments: [String: JSONValue]?
    }

    private struct ModelOutput: Decodable {
        let summary: String?
        let tool_calls: [ModelToolCall]?
    }

    static func parse(_ text: String) throws -> ModelResponse {
        let sanitized = sanitizeOutput(text)
        guard let jsonString = extractJSONObject(from: sanitized) else {
            let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return ModelResponse(toolCalls: [], summary: trimmed)
            }
            throw ModelError.invalidResponse("Model output did not contain JSON.")
        }
        guard let data = jsonString.data(using: .utf8) else {
            throw ModelError.invalidResponse("Model output could not be encoded as UTF-8.")
        }
        let decoded = try JSONDecoder().decode(ModelOutput.self, from: data)
        let toolCalls = (decoded.tool_calls ?? []).compactMap { call -> ToolCall? in
            guard let name = ToolName(rawValue: call.name) else {
                return nil
            }
            return ToolCall(name: name, arguments: call.arguments ?? [:])
        }
        return ModelResponse(toolCalls: toolCalls, summary: decoded.summary ?? "No summary provided.")
    }

    static func parseRequiringJSON(_ text: String) throws -> ModelResponse {
        let sanitized = sanitizeOutput(text)
        guard let jsonString = extractJSONObject(from: sanitized) else {
            throw ModelError.invalidResponse("Model output did not contain JSON.")
        }
        guard let data = jsonString.data(using: .utf8) else {
            throw ModelError.invalidResponse("Model output could not be encoded as UTF-8.")
        }
        let decoded = try JSONDecoder().decode(ModelOutput.self, from: data)
        let toolCalls = (decoded.tool_calls ?? []).compactMap { call -> ToolCall? in
            guard let name = ToolName(rawValue: call.name) else {
                return nil
            }
            return ToolCall(name: name, arguments: call.arguments ?? [:])
        }
        return ModelResponse(toolCalls: toolCalls, summary: decoded.summary ?? "No summary provided.")
    }

    private static func sanitizeOutput(_ text: String) -> String {
        let withoutThinking = stripThinkBlocks(from: text)
        return stripCodeFences(from: withoutThinking)
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
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let filtered = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.hasPrefix("```")
        }
        return filtered.joined(separator: "\n")
    }

    private static func extractJSONObject(from text: String) -> String? {
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
}
