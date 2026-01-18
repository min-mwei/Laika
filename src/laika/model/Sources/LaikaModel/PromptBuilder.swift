import Foundation
import LaikaShared

enum PromptBuilder {
    static func systemPrompt() -> String {
        return """
You are Laika, a safe browser agent. Respond with a single JSON object only.
Do not include extra text or Markdown.
The first character must be "{" and the last character must be "}".
Schema:
{
  "summary": "short user-facing summary",
  "tool_calls": [
    {"name": "browser.click", "arguments": {"handleId": "..."}},
    {"name": "browser.type", "arguments": {"handleId": "...", "text": "..."}},
    {"name": "browser.scroll", "arguments": {"deltaY": 400}},
    {"name": "browser.open_tab", "arguments": {"url": "https://..."}}
  ]
}
If no action is needed, return an empty tool_calls array.
"""
    }

    static func userPrompt(context: ContextPack, goal: String) -> String {
        var lines: [String] = []
        lines.append("Goal: \(goal)")
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
        lines.append("Page URL: \(context.observation.url)")
        lines.append("Page Title: \(context.observation.title)")
        lines.append("Page Text: \(context.observation.text)")
        lines.append("Elements:")
        for element in context.observation.elements {
            let label = element.label.isEmpty ? "-" : element.label
            lines.append("- id=\(element.handleId) role=\(element.role) label=\"\(label)\" bbox=\(format(element.boundingBox))")
        }
        return lines.joined(separator: "\n")
    }

    private static func format(_ box: BoundingBox) -> String {
        String(format: "(%.0f,%.0f,%.0f,%.0f)", box.x, box.y, box.width, box.height)
    }
}
