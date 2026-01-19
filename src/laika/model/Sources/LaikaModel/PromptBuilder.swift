import Foundation
import LaikaShared

enum PromptBuilder {
    static func systemPrompt(for mode: SiteMode) -> String {
        switch mode {
        case .observe:
            return observeSystemPrompt()
        case .assist:
            return assistSystemPrompt()
        }
    }

    private static func observeSystemPrompt() -> String {
        return """
You are Laika, a safe browser assistant focused on summaries.

Output MUST be a single JSON object and nothing else.
- No extra text, no Markdown, no code fences, no <think>.
- The first character must be "{" and the last character must be "}".

You are given the user's goal and a sanitized page context (URL, title, visible text, Primary Content, Text Blocks, DOM Outline, and a Main Links list).
Your job: return a grounded, detailed summary of the page contents.

Rules:
- tool_calls MUST be [] in observe mode.
- Follow the Summary requirements in the user prompt.
- Use Text Blocks when provided; they highlight likely content.
- Do not describe the site in general terms; summarize what is on the page now.

Examples:
{"summary":"The page lists items such as ...","tool_calls":[]}
"""
    }

    private static func assistSystemPrompt() -> String {
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
- Tool arguments must match the schema exactly; do not add extra keys.
- After a tool call runs, you will receive updated page context in the next step.

When answering "What is this page about?" / summaries:
- Describe what kind of page it is, using the Title/URL.
- Mention a few representative items from "Main Links" if available.

Tools:
- browser.observe_dom arguments: {"maxChars": int?, "maxElements": int?, "maxBlocks": int?, "maxPrimaryChars": int?, "maxOutline": int?, "maxOutlineChars": int?}
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

Examples:
{"summary":"short user-facing summary","tool_calls":[]}
{"summary":"short user-facing summary","tool_calls":[{"name":"browser.click","arguments":{"handleId":"laika-1"}}]}
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
        let mainLinks = MainLinkHeuristics.candidates(from: context.observation.elements)
        let isCommentGoal = isCommentGoal(goal)
        let textBlocks = context.observation.blocks
        let outline = context.observation.outline
        let primary = context.observation.primary
        if context.mode == .observe {
            lines.append("Summary requirements: \(summaryRequirements(goal: goal, mainLinkCount: mainLinks.count, textCount: context.observation.text.count, blockCount: textBlocks.count, outlineCount: outline.count, hasPrimary: primary != nil))")
        }
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
        let primaryChars = primary?.text.count ?? 0
        lines.append("- Stats: textChars=\(context.observation.text.count) elementCount=\(context.observation.elements.count) blockCount=\(textBlocks.count) outlineCount=\(outline.count) primaryChars=\(primaryChars)")

        if context.mode == .observe, let primary {
            lines.append("Primary Content (readability candidate):")
            let tag = primary.tag.isEmpty ? "-" : primary.tag
            let role = primary.role.isEmpty ? "-" : primary.role
            let density = String(format: "%.2f", primary.linkDensity)
            lines.append("- tag=\(tag) role=\(role) links=\(primary.linkCount) density=\(density) text=\"\(primary.text)\"")
        }

        if context.mode == .observe && !outline.isEmpty {
            lines.append("DOM Outline:")
            for (index, item) in outline.prefix(20).enumerated() {
                let tag = item.tag.isEmpty ? "-" : item.tag
                let role = item.role.isEmpty ? "-" : item.role
                lines.append("\(index + 1). level=\(item.level) tag=\(tag) role=\(role) text=\"\(item.text)\"")
            }
        }

        if context.mode == .observe && !textBlocks.isEmpty {
            lines.append("Text Blocks (content candidates):")
            for (index, block) in textBlocks.prefix(18).enumerated() {
                let tag = block.tag.isEmpty ? "-" : block.tag
                let role = block.role.isEmpty ? "-" : block.role
                let density = String(format: "%.2f", block.linkDensity)
                lines.append("\(index + 1). tag=\(tag) role=\(role) links=\(block.linkCount) density=\(density) text=\"\(block.text)\"")
            }
        }
        if !mainLinks.isEmpty && !isCommentGoal {
            lines.append("Main Links (likely content):")
            for (index, element) in mainLinks.prefix(20).enumerated() {
                let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
                let href = element.href ?? ""
                lines.append("\(index + 1). id=\(element.handleId) label=\"\(label)\" href=\"\(href)\"")
            }
        }

        if context.mode == .assist {
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
        } else {
            lines.append("Elements omitted in observe mode.")
        }
        return lines.joined(separator: "\n")
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

    private static func summaryRequirements(
        goal: String,
        mainLinkCount: Int,
        textCount: Int,
        blockCount: Int,
        outlineCount: Int,
        hasPrimary: Bool
    ) -> String {
        let primaryHint = hasPrimary ? "Primary Content" : "Page Text"
        let outlineHint = outlineCount > 0 ? "DOM Outline" : "Page Text"
        let lowerGoal = goal.lowercased()
        if lowerGoal.contains("comment") || lowerGoal.contains("thread") || lowerGoal.contains("discussion") {
            let evidence = blockCount > 0 ? "Text Blocks" : "Page Text"
            return "Provide 6-8 bullet points summarizing distinct themes or arguments from the comments. Mention at least 3 concrete points from \(evidence) or \(primaryHint). Use \(outlineHint) to structure if helpful. Avoid navigation."
        }
        if lowerGoal.contains("linked page") ||
            lowerGoal.contains("linked") ||
            lowerGoal.contains("article") ||
            lowerGoal.contains("story") ||
            lowerGoal.contains("page content") {
            let evidence = blockCount > 0 ? "Text Blocks" : "Page Text"
            return "Provide 6-8 sentences summarizing the linked page content. Mention key facts, names, and any visible numbers from \(evidence) or \(primaryHint). Use \(outlineHint) to structure if helpful. Avoid navigation."
        }
        if lowerGoal.contains("what is this page about") ||
            lowerGoal.contains("what is this page") ||
            lowerGoal.contains("summarize") ||
            lowerGoal.contains("overview") {
            let required = mainLinkRequirement(count: mainLinkCount)
            let metricsHint = "Include any visible metrics (points, comments, timestamps) from Page Text."
            let evidence = blockCount > 0 ? "Text Blocks" : "Page Text"
            return "Provide 6-8 sentences summarizing the page contents. Mention at least \(required) items from Main Links. Use \(evidence) and \(primaryHint) for detail. Use \(outlineHint) to structure if helpful. \(metricsHint)"
        }
        let fallbackRequired = mainLinkRequirement(count: mainLinkCount)
        if fallbackRequired > 0 {
            return "Provide 5-7 sentences summarizing the page contents with concrete details. Mention at least \(fallbackRequired) items from Main Links."
        }
        if textCount < 400 {
            return "Provide 4-6 sentences summarizing the page contents using Page Text details."
        }
        return "Provide 5-7 sentences summarizing the page contents using Page Text details."
    }

    private static func mainLinkRequirement(count: Int) -> Int {
        if count >= 5 {
            return 5
        }
        if count >= 3 {
            return 3
        }
        return count
    }

    private static func isCommentGoal(_ goal: String) -> Bool {
        let lower = goal.lowercased()
        return lower.contains("comment") || lower.contains("thread") || lower.contains("discussion")
    }
}
