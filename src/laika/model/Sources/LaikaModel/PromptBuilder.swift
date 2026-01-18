import Foundation
import LaikaShared

enum PromptBuilder {
    static func systemPrompt() -> String {
        return """
You are Laika, a safe browser agent.

Output MUST be a single JSON object and nothing else.
- No extra text, no Markdown, no code fences, no <think>.
- The first character must be "{" and the last character must be "}".

You are given the user's goal and a sanitized page context (URL, title, visible text, and interactive elements).
Choose whether to:
- return a summary with no tool calls, OR
- request ONE tool call that moves toward the goal.

Rules:
- Prefer at most ONE tool call per response.
- If the goal can be answered from the provided page context, do not call tools.
- If the user asks for the "first/second link", interpret it as the first/second item in the "Main Links" list (not site chrome links like "new", "past", etc.).
- Never invent handleId values. Use one from the Elements list.
- Use browser.click for links/buttons (role "a" / "button").
- Use browser.type only for editable fields (role "input" / "textarea" or contenteditable).
- Use browser.select only for <select>.
- After a tool call runs, you will receive updated page context in the next step.

When answering "What is this page about?" / summaries:
- Describe what kind of page it is, using the Title/URL.
- Mention a few representative items from "Main Links" if available.

Tools:
- browser.observe_dom arguments: {"maxChars": int?, "maxElements": int?}
- browser.click arguments: {"handleId": string}
- browser.type arguments: {"handleId": string, "text": string}
- browser.select arguments: {"handleId": string, "value": string}
- browser.scroll arguments: {"deltaY": number}
- browser.navigate arguments: {"url": string}
- browser.open_tab arguments: {"url": string}
- browser.back arguments: {}
- browser.forward arguments: {}
- browser.refresh arguments: {}

Return:
- "tool_calls": [] when no tool is needed.
- "tool_calls": [ ... ] with exactly ONE tool call when needed.

Schema:
{
  "summary": "short user-facing summary",
  "tool_calls": [
    {"name": "browser.click", "arguments": {"handleId": "laika-1"}},
  ]
}
If no action is needed, return an empty tool_calls array.
"""
    }

    static func userPrompt(context: ContextPack, goal: String) -> String {
        var lines: [String] = []
        lines.append("Goal: \(goal)")
        if let runId = context.runId, !runId.isEmpty {
            lines.append("Run: \(runId)")
        }
        if let step = context.step, let maxSteps = context.maxSteps {
            lines.append("Step: \(step)/\(maxSteps)")
        } else if let step = context.step {
            lines.append("Step: \(step)")
        }
        lines.append("Origin: \(context.origin)")
        lines.append("Mode: \(context.mode.rawValue)")
        if !context.tabs.isEmpty {
            lines.append("Open Tabs (current window):")
            for tab in context.tabs {
                let title = tab.title.isEmpty ? "-" : tab.title
                let location = tab.origin.isEmpty ? tab.url : tab.origin
                let activeLabel = tab.isActive ? "[active] " : ""
                lines.append("- \(activeLabel)\(title) (\(location))")
            }
        }
        if !context.recentToolCalls.isEmpty {
            lines.append("Recent Tool Calls:")
            var resultsById: [UUID: ToolResult] = [:]
            for result in context.recentToolResults {
                resultsById[result.toolCallId] = result
            }
            for call in context.recentToolCalls.suffix(8) {
                let result = resultsById[call.id]
                let status = result?.status.rawValue ?? "unknown"
                let payload = result.map { formatPayload($0.payload) } ?? ""
                let suffix = payload.isEmpty ? "" : " \(payload)"
                lines.append("- \(format(call)) -> \(status)\(suffix)")
            }
        }
        lines.append("Current Page:")
        lines.append("- URL: \(context.observation.url)")
        lines.append("- Title: \(context.observation.title)")
        lines.append("- Text: \(context.observation.text)")
        lines.append("- Stats: textChars=\(context.observation.text.count) elementCount=\(context.observation.elements.count)")

        let mainLinks = mainLinkCandidates(from: context.observation.elements)
        if !mainLinks.isEmpty {
            lines.append("Main Links (likely content):")
            for (index, element) in mainLinks.prefix(20).enumerated() {
                let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
                let href = element.href ?? ""
                lines.append("\(index + 1). id=\(element.handleId) label=\"\(label)\" href=\"\(href)\"")
            }
        }

        lines.append("Elements (top-to-bottom):")
        for element in context.observation.elements {
            let label = element.label.isEmpty ? "-" : element.label
            var extras: [String] = []
            if let href = element.href, !href.isEmpty {
                extras.append("href=\"\(href)\"")
            }
            if let inputType = element.inputType, !inputType.isEmpty {
                extras.append("inputType=\"\(inputType)\"")
            }
            let extraText = extras.isEmpty ? "" : " " + extras.joined(separator: " ")
            lines.append("- id=\(element.handleId) role=\(element.role) label=\"\(label)\" bbox=\(format(element.boundingBox))\(extraText)")
        }
        return lines.joined(separator: "\n")
    }

    private static func mainLinkCandidates(from elements: [ObservedElement]) -> [ObservedElement] {
        let excluded: Set<String> = [
            "new", "past", "comments", "ask", "show", "jobs", "submit", "login", "logout",
            "hide", "reply", "flag", "edit", "more", "next", "prev", "previous", "upvote", "downvote"
        ]
        return elements
            .filter { element in
                guard element.role.lowercased() == "a" else {
                    return false
                }
                guard let href = element.href, !href.isEmpty else {
                    return false
                }
                let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
                if label.isEmpty {
                    return false
                }
                if excluded.contains(label.lowercased()) {
                    return false
                }
                if label.count < 12 {
                    return false
                }
                if label.contains(" ") {
                    return true
                }
                // Keep domain-style labels as a fallback, but de-prioritize by filtering them out here.
                return false
            }
    }

    private static func format(_ box: BoundingBox) -> String {
        String(format: "(%.0f,%.0f,%.0f,%.0f)", box.x, box.y, box.width, box.height)
    }

    private static func format(_ call: ToolCall) -> String {
        var parts: [String] = []
        parts.append(call.name.rawValue)
        if !call.arguments.isEmpty {
            let args = call.arguments
                .sorted(by: { $0.key < $1.key })
                .map { key, value in
                    "\(key)=\(format(value))"
                }
                .joined(separator: ", ")
            parts.append("(\(args))")
        }
        return parts.joined()
    }

    private static func format(_ value: JSONValue, maxChars: Int = 80) -> String {
        switch value {
        case .string(let string):
            if string.count <= maxChars {
                return "\"\(string)\""
            }
            let prefix = string.prefix(maxChars)
            return "\"\(prefix)…\""
        case .number(let number):
            return String(number)
        case .bool(let bool):
            return bool ? "true" : "false"
        case .null:
            return "null"
        case .array(let array):
            return "[\(array.count)]"
        case .object(let object):
            return "{\(object.count)}"
        }
    }

    private static func formatPayload(_ payload: [String: JSONValue], maxEntries: Int = 6) -> String {
        if payload.isEmpty {
            return ""
        }
        let parts = payload
            .sorted(by: { $0.key < $1.key })
            .prefix(maxEntries)
            .map { key, value in
                "\(key)=\(format(value))"
            }
            .joined(separator: ", ")
        if payload.count > maxEntries {
            return "(\(parts), …)"
        }
        return "(\(parts))"
    }
}
