import Foundation
import LaikaShared

enum LLMCPResponseParser {
    enum ParseMode: String {
        case strict
        case lenient
        case fallbackNoJSON
        case fallbackInvalidJSON
    }

    struct ParseOutcome {
        let response: ModelResponse
        let mode: ParseMode
        let error: String?
    }

    private static func decodeResponse(_ jsonString: String) throws -> LLMCPResponse {
        guard let data = jsonString.data(using: .utf8) else {
            throw ModelError.invalidResponse("Model output could not be encoded as UTF-8.")
        }
        return try JSONDecoder().decode(LLMCPResponse.self, from: data)
    }

    private static func extractJSON(from text: String) -> String? {
        let sanitized = ModelOutputParser.sanitize(text)
        guard let jsonString = ModelOutputParser.extractJSONObject(from: sanitized)
            ?? ModelOutputParser.extractJSONObjectRelaxed(from: sanitized) else {
            return nil
        }
        return ModelOutputParser.repairJSON(jsonString)
    }

    private static func parseStrict(_ jsonString: String) throws -> ModelResponse {
        let decoded = try decodeResponse(jsonString)
        try validateProtocol(decoded)
        var toolCalls: [ToolCall] = []
        for call in decoded.toolCalls {
            guard let name = ToolName(rawValue: call.name) else {
                throw ModelError.invalidResponse("Unknown tool name: \(call.name).")
            }
            let normalized = normalizeArguments(for: name, arguments: call.arguments ?? [:])
            guard ToolSchemaValidator.validateArguments(name: name, arguments: normalized) else {
                throw ModelError.invalidResponse("Invalid tool arguments for \(name.rawValue).")
            }
            toolCalls.append(ToolCall(name: name, arguments: normalized))
        }
        let assistant = AssistantMessage(
            title: decoded.assistant.title,
            render: decoded.assistant.render,
            citations: decoded.assistant.citations ?? []
        )
        return ModelResponse(toolCalls: toolCalls, assistant: assistant)
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

    private static func validateProtocol(_ response: LLMCPResponse) throws {
        guard response.protocolInfo.name == "laika.llmcp" else {
            throw ModelError.invalidResponse("Unexpected protocol name: \(response.protocolInfo.name).")
        }
        guard response.protocolInfo.version == 1 else {
            throw ModelError.invalidResponse("Unsupported protocol version: \(response.protocolInfo.version).")
        }
        guard response.type == .response else {
            throw ModelError.invalidResponse("Unexpected message type: \(response.type.rawValue).")
        }
    }

    static func parse(_ text: String) throws -> ModelResponse {
        return parseWithOutcome(text).response
    }

    static func parseWithOutcome(_ text: String) -> ParseOutcome {
        let sanitized = ModelOutputParser.sanitize(text)
        guard let jsonString = extractJSON(from: text) else {
            let response = fallbackResponse(from: sanitized)
            return ParseOutcome(response: response, mode: .fallbackNoJSON, error: "no_json")
        }
        do {
            let response = try parseStrict(jsonString)
            return ParseOutcome(response: response, mode: .strict, error: nil)
        } catch {
            if let parsed = try? parseLenient(jsonString, error: error) {
                return ParseOutcome(response: parsed, mode: .lenient, error: error.localizedDescription)
            }
            let response = fallbackResponse(from: sanitized)
            return ParseOutcome(response: response, mode: .fallbackInvalidJSON, error: error.localizedDescription)
        }
    }

    private static func parseLenient(_ jsonString: String, error: Error) throws -> ModelResponse {
        guard let data = jsonString.data(using: .utf8) else {
            throw ModelError.invalidResponse("Model output could not be encoded as UTF-8.")
        }
        guard let rawObject = try? JSONSerialization.jsonObject(with: data, options: []),
              let root = rawObject as? [String: Any] else {
            throw ModelError.invalidResponse("Model output JSON could not be parsed: \(error.localizedDescription)")
        }

        let protocolInfo = root["protocol"] as? [String: Any]
        let protocolName = protocolInfo?["name"] as? String
        let messageType = root["type"] as? String
        let shouldAcceptToolCalls = protocolName == "laika.llmcp" && messageType == "response"
        let toolParse = shouldAcceptToolCalls ? parseToolCalls(from: root) : ToolCallParseResult()
        let toolCalls = (toolParse.hasUnknownTool || toolParse.hasInvalidTool) ? [] : toolParse.toolCalls
        let assistantInfo = root["assistant"] as? [String: Any] ?? [:]
        let title = assistantInfo["title"] as? String
        let renderDocument = renderDocument(from: assistantInfo["render"])
        let citations = parseCitations(from: assistantInfo["citations"])

        let fallbackText = [
            extractText(from: assistantInfo["render"]),
            extractText(from: assistantInfo["title"])
        ].first(where: { !$0.isEmpty }) ?? ""

        let summaryText = fallbackText.isEmpty ? "Unable to parse response." : fallbackText
        let render = renderDocument ?? Document.paragraph(text: summaryText)
        let assistant = AssistantMessage(title: title, render: render, citations: citations)
        return ModelResponse(toolCalls: toolCalls, assistant: assistant, summary: summaryText)
    }

    private static func fallbackResponse(from text: String) -> ModelResponse {
        let summary = fallbackSummary(from: text)
        let assistant = AssistantMessage(render: Document.paragraph(text: summary))
        return ModelResponse(toolCalls: [], assistant: assistant, summary: summary)
    }

    private static func fallbackSummary(from text: String) -> String {
        let target = extractJSON(from: text) ?? text
        let candidates = extractStringValues(from: target, keys: ["summary", "text", "title"])
        let trimmed = candidates.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return truncateSummary(trimmed)
        }
        let fallback = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if fallback.isEmpty {
            return "Unable to parse response."
        }
        if looksLikeJSON(fallback) {
            return "Unable to parse response."
        }
        return truncateSummary(fallback)
    }

    private static func truncateSummary(_ text: String, limit: Int = 600) -> String {
        if text.count <= limit {
            return text
        }
        let index = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<index])
    }

    private static func extractStringValues(from text: String, keys: [String]) -> [String] {
        guard !keys.isEmpty else {
            return []
        }
        let escapedKeys = keys.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let pattern = "\"(?:\(escapedKeys))\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        var results: [String] = []
        results.reserveCapacity(min(matches.count, 12))
        for match in matches {
            guard match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            let rawValue = String(text[valueRange])
            let value = unescapeJSONString(rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                continue
            }
            if results.contains(value) {
                continue
            }
            results.append(value)
            if results.count >= 12 {
                break
            }
        }
        return results
    }

    private static func unescapeJSONString(_ text: String) -> String {
        var output = text
        output = output.replacingOccurrences(of: "\\\\", with: "\\")
        output = output.replacingOccurrences(of: "\\\"", with: "\"")
        output = output.replacingOccurrences(of: "\\n", with: "\n")
        output = output.replacingOccurrences(of: "\\r", with: "\r")
        output = output.replacingOccurrences(of: "\\t", with: "\t")
        return output
    }

    private static func looksLikeJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return true
        }
        if trimmed.hasPrefix("```") {
            return true
        }
        let lowercased = trimmed.lowercased()
        return lowercased.contains("\"protocol\"") && lowercased.contains("\"type\"")
    }

    private struct ToolCallParseResult {
        let toolCalls: [ToolCall]
        let hasUnknownTool: Bool
        let hasInvalidTool: Bool

        init(toolCalls: [ToolCall] = [], hasUnknownTool: Bool = false, hasInvalidTool: Bool = false) {
            self.toolCalls = toolCalls
            self.hasUnknownTool = hasUnknownTool
            self.hasInvalidTool = hasInvalidTool
        }
    }

    private static func parseToolCalls(from root: [String: Any]) -> ToolCallParseResult {
        let rawCalls = (root["tool_calls"] as? [Any])
            ?? (root["toolCalls"] as? [Any])
            ?? []
        var toolCalls: [ToolCall] = []
        var hasUnknownTool = false
        var hasInvalidTool = false
        for raw in rawCalls {
            guard let dict = raw as? [String: Any],
                  let nameRaw = dict["name"] as? String else {
                hasInvalidTool = true
                continue
            }
            guard let name = ToolName(rawValue: nameRaw) else {
                hasUnknownTool = true
                continue
            }
            let arguments = (dict["arguments"] as? [String: Any])
                .flatMap(jsonObject(from:)) ?? [:]
            let normalized = normalizeArguments(for: name, arguments: arguments)
            guard ToolSchemaValidator.validateArguments(name: name, arguments: normalized) else {
                hasInvalidTool = true
                continue
            }
            toolCalls.append(ToolCall(name: name, arguments: normalized))
        }
        return ToolCallParseResult(
            toolCalls: toolCalls,
            hasUnknownTool: hasUnknownTool,
            hasInvalidTool: hasInvalidTool
        )
    }

    private static func parseCitations(from value: Any?) -> [LLMCPCitation] {
        guard let array = value as? [Any] else {
            return []
        }
        return array.compactMap { item in
            guard let dict = item as? [String: Any],
                  let docId = dict["doc_id"] as? String else {
                return nil
            }
            return LLMCPCitation(
                docId: docId,
                nodeId: dict["node_id"] as? String,
                handleId: dict["handle_id"] as? String,
                quote: dict["quote"] as? String
            )
        }
    }

    private static func jsonObject(from dictionary: [String: Any]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for (key, value) in dictionary {
            if let converted = jsonValue(from: value) {
                result[key] = converted
            }
        }
        return result
    }

    private static func jsonValue(from value: Any) -> JSONValue? {
        if value is NSNull {
            return .null
        }
        if let string = value as? String {
            return .string(string)
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        }
        if let dictionary = value as? [String: Any] {
            return .object(jsonObject(from: dictionary))
        }
        if let array = value as? [Any] {
            let items = array.compactMap { jsonValue(from: $0) }
            return .array(items)
        }
        return nil
    }

    private static func renderNodes(from values: [Any]) -> [DocumentNode] {
        var nodes: [DocumentNode] = []
        for value in values {
            if let node = renderNode(from: value) {
                nodes.append(node)
                continue
            }
            if let dict = value as? [String: Any],
               let type = dict["type"] as? String,
               type == "doc" || type == "document" {
                let nestedValues = dict["children"] as? [Any] ?? []
                let nestedNodes = renderNodes(from: nestedValues)
                if !nestedNodes.isEmpty {
                    nodes.append(contentsOf: nestedNodes)
                    continue
                }
            }
            let text = extractText(from: value)
            if !text.isEmpty {
                nodes.append(.paragraph(children: [.text(text: text)]))
            }
        }
        return nodes
    }

    private static func renderDocument(from value: Any?) -> Document? {
        if let dict = value as? [String: Any] {
            if let nested = dict["doc"] as? [String: Any] {
                return renderDocument(from: nested)
            }
            if let nested = dict["document"] as? [String: Any] {
                return renderDocument(from: nested)
            }
            if let typeRaw = dict["type"] as? String {
                let type = typeRaw.lowercased()
                if type == "doc" || type == "document" {
                    var rawChildren: [Any] = []
                    if let children = dict["children"] as? [Any] {
                        rawChildren = children
                    }
                    let children = renderNodes(from: rawChildren)
                    if !children.isEmpty {
                        return Document(children: children)
                    }
                }
            }
            if let children = dict["children"] as? [Any] {
                let parsed = renderNodes(from: children)
                if !parsed.isEmpty {
                    return Document(children: parsed)
                }
            }
        }
        return nil
    }

    private static func renderNode(from value: Any) -> DocumentNode? {
        guard let dict = value as? [String: Any],
              let type = dict["type"] as? String else {
            return nil
        }
        switch type {
        case "heading":
            let level = clampLevel(dict["level"])
            let children = inlineChildren(from: dict) ?? []
            return .heading(level: level, children: children)
        case "paragraph":
            let children = inlineChildren(from: dict) ?? []
            return .paragraph(children: children)
        case "list":
            let ordered = (dict["ordered"] as? Bool) ?? false
            let rawItems = dict["items"] as? [Any] ?? []
            let items = rawItems.compactMap { item -> DocumentNode? in
                if let node = renderNode(from: item) {
                    if case .listItem = node {
                        return node
                    }
                    return .listItem(children: [node])
                }
                let text = extractText(from: item)
                if !text.isEmpty {
                    return .listItem(children: [.paragraph(children: [.text(text: text)])])
                }
                return nil
            }
            return .list(ordered: ordered, items: items)
        case "list_item":
            let children = inlineChildren(from: dict) ?? []
            return .listItem(children: children)
        case "blockquote":
            let children = inlineChildren(from: dict) ?? []
            return .blockquote(children: children)
        case "quote":
            let children = inlineChildren(from: dict) ?? []
            if !children.isEmpty {
                return .blockquote(children: children)
            }
            let text = extractText(from: dict)
            if !text.isEmpty {
                return .blockquote(children: [.text(text: text)])
            }
            return nil
        case "doc", "document":
            let children = renderNodes(from: dict["children"] as? [Any] ?? [])
            if !children.isEmpty {
                return .paragraph(children: children)
            }
            let text = extractText(from: dict)
            if !text.isEmpty {
                return .paragraph(children: [.text(text: text)])
            }
            return nil
        case "code_block":
            let language = dict["language"] as? String
            let text = dict["text"] as? String ?? extractText(from: dict)
            return .codeBlock(language: language, text: text)
        case "text":
            let text = dict["text"] as? String ?? ""
            return .text(text: text)
        case "link":
            guard let href = dict["href"] as? String else {
                return nil
            }
            let children = inlineChildren(from: dict) ?? []
            return .link(href: href, children: children)
        default:
            let text = extractText(from: dict)
            if !text.isEmpty {
                return .paragraph(children: [.text(text: text)])
            }
            return nil
        }
    }

    private static func inlineChildren(from dict: [String: Any]) -> [DocumentNode]? {
        if let children = dict["children"] as? [Any] {
            let parsed = children.compactMap { renderNode(from: $0) }
            if !parsed.isEmpty {
                return parsed
            }
        }
        if let text = dict["text"] as? String, !text.isEmpty {
            return [.text(text: text)]
        }
        return nil
    }

    private static func clampLevel(_ value: Any?) -> Int {
        if let number = value as? NSNumber {
            return max(1, min(6, number.intValue))
        }
        if let intValue = value as? Int {
            return max(1, min(6, intValue))
        }
        return 2
    }

    private static func extractText(from value: Any?) -> String {
        guard let value else {
            return ""
        }
        if let string = value as? String {
            return string
        }
        if let dict = value as? [String: Any] {
            if let text = dict["text"] as? String, !text.isEmpty {
                return text
            }
            var parts: [String] = []
            if let title = dict["title"] as? String, !title.isEmpty {
                parts.append(title)
            }
            if let render = dict["render"] {
                parts.append(extractText(from: render))
            }
            if let document = dict["document"] {
                parts.append(extractText(from: document))
            }
            if let children = dict["children"] as? [Any] {
                parts.append(children.map { extractText(from: $0) }.joined(separator: " "))
            }
            if let items = dict["items"] as? [Any] {
                parts.append(items.map { extractText(from: $0) }.joined(separator: " "))
            }
            if let doc = dict["doc"] {
                parts.append(extractText(from: doc))
            }
            return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let array = value as? [Any] {
            return array.map { extractText(from: $0) }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }
}
