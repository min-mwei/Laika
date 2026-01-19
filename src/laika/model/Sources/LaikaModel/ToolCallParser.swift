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

    private static func decodeOutput(_ jsonString: String) throws -> ModelOutput {
        guard let data = jsonString.data(using: .utf8) else {
            throw ModelError.invalidResponse("Model output could not be encoded as UTF-8.")
        }
        return try JSONDecoder().decode(ModelOutput.self, from: data)
    }

    private static func parseOutput(from text: String) throws -> ModelOutput {
        let sanitized = ModelOutputParser.sanitize(text)
        guard let jsonString = ModelOutputParser.extractJSONObject(from: sanitized)
            ?? ModelOutputParser.extractJSONObjectRelaxed(from: sanitized) else {
            throw ModelError.invalidResponse("Model output did not contain JSON.")
        }
        do {
            return try decodeOutput(jsonString)
        } catch {
            let repaired = ModelOutputParser.repairJSON(jsonString)
            if repaired != jsonString {
                return try decodeOutput(repaired)
            }
            throw error
        }
    }

    private static func normalizeArguments(for name: ToolName, arguments: [String: JSONValue]) -> [String: JSONValue] {
        guard name == .browserObserveDom else {
            return arguments
        }
        var normalized = arguments
        if let value = normalized.removeValue(forKey: "maxItemsChars"), normalized["maxItemChars"] == nil {
            normalized["maxItemChars"] = value
        }
        if let value = normalized.removeValue(forKey: "maxItemsChar"), normalized["maxItemChars"] == nil {
            normalized["maxItemChars"] = value
        }
        return normalized
    }

    static func parse(_ text: String) throws -> ModelResponse {
        let sanitized = ModelOutputParser.sanitize(text)
        let decoded: ModelOutput
        do {
            decoded = try parseOutput(from: sanitized)
        } catch {
            let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return ModelResponse(toolCalls: [], summary: "")
            }
            throw error
        }
        let toolCalls = (decoded.tool_calls ?? []).compactMap { call -> ToolCall? in
            guard let name = ToolName(rawValue: call.name) else {
                return nil
            }
            let normalized = normalizeArguments(for: name, arguments: call.arguments ?? [:])
            return ToolCall(name: name, arguments: normalized)
        }
        return ModelResponse(toolCalls: toolCalls, summary: decoded.summary ?? "")
    }

    static func parseRequiringJSON(_ text: String) throws -> ModelResponse {
        let decoded = try parseOutput(from: text)
        let toolCalls = (decoded.tool_calls ?? []).compactMap { call -> ToolCall? in
            guard let name = ToolName(rawValue: call.name) else {
                return nil
            }
            let normalized = normalizeArguments(for: name, arguments: call.arguments ?? [:])
            return ToolCall(name: name, arguments: normalized)
        }
        return ModelResponse(toolCalls: toolCalls, summary: decoded.summary ?? "")
    }

}
