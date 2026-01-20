import Foundation
import LaikaShared

struct SummaryInput: Sendable {
    enum Kind: String, Sendable {
        case list
        case item
        case pageText
        case comments
    }

    let kind: Kind
    let text: String
    let usedItems: Int
    let usedBlocks: Int
    let usedComments: Int
    let usedPrimary: Bool
    let accessLimited: Bool
    let accessSignals: [String]
}

struct SummaryInputBuilder {
    static func build(context: ContextPack, goalPlan: GoalPlan) -> SummaryInput {
        if wantsComments(goalPlan: goalPlan) {
            if !context.observation.comments.isEmpty {
                return buildFromComments(context: context)
            }
            return buildFromEmptyComments(context: context)
        }
        if goalPlan.intent == .itemSummary,
           shouldUseItemSnippet(context: context),
           let item = selectTargetItem(context: context, goalPlan: goalPlan) {
            return buildFromItem(context: context, item: item)
        }
        if isListObservation(context), !context.observation.items.isEmpty {
            return buildFromItems(context: context)
        }
        return buildFromBlocks(context: context)
    }

    private static func wantsComments(goalPlan: GoalPlan) -> Bool {
        return goalPlan.intent == .commentSummary || goalPlan.wantsComments
    }

    private static func isListObservation(_ context: ContextPack) -> Bool {
        let itemCount = context.observation.items.count
        let primaryChars = context.observation.primary?.text.count ?? 0
        if itemCount >= 12 {
            return true
        }
        if itemCount >= 6 && primaryChars < 500 {
            return true
        }
        if itemCount >= 3 && primaryChars < 200 {
            return true
        }
        return false
    }

    private static func buildFromItems(context: ContextPack) -> SummaryInput {
        let items = context.observation.items
        var lines: [String] = []
        var used = 0
        var displayIndex = 0
        for item in items.prefix(24) {
            let title = TextUtils.normalizeWhitespace(item.title)
            if title.isEmpty {
                continue
            }
            displayIndex += 1
            var line = "\(displayIndex). \(title)"
            let snippet = SnippetFormatter.format(item.snippet, title: title, maxChars: 200)
            if !snippet.isEmpty {
                line += " — \(snippet)"
            }
            lines.append(line)
            used += 1
        }
        let titleLine = buildTitleLine(context: context)
        let countLine = "Item count: \(items.count)"
        let body = lines.joined(separator: "\n")
        let text = [titleLine, countLine, body].filter { !$0.isEmpty }.joined(separator: "\n")
        let signals = accessSignals(context: context, kind: .list)
        return SummaryInput(
            kind: .list,
            text: TextUtils.truncate(text, maxChars: 9000),
            usedItems: used,
            usedBlocks: 0,
            usedComments: 0,
            usedPrimary: false,
            accessLimited: signals.limited,
            accessSignals: signals.reasons
        )
    }

    private static func buildFromComments(context: ContextPack) -> SummaryInput {
        var lines: [String] = []
        var used = 0
        for (index, comment) in context.observation.comments.prefix(28).enumerated() {
            let text = TextUtils.normalizeWhitespace(comment.text)
            if text.isEmpty {
                continue
            }
            var prefix: [String] = []
            if let author = comment.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
                prefix.append(author)
            }
            if let age = comment.age?.trimmingCharacters(in: .whitespacesAndNewlines), !age.isEmpty {
                prefix.append(age)
            }
            if let score = comment.score?.trimmingCharacters(in: .whitespacesAndNewlines), !score.isEmpty {
                prefix.append(score)
            }
            let header = prefix.isEmpty ? "" : prefix.joined(separator: " · ") + ": "
            let line = "Comment \(index + 1): " + header + TextUtils.truncate(text, maxChars: 280)
            lines.append(line)
            used += 1
        }
        let titleLine = buildTitleLine(context: context)
        let countLine = "Comment count: \(context.observation.comments.count)"
        let body = lines.joined(separator: "\n")
        let text = [titleLine, countLine, body].filter { !$0.isEmpty }.joined(separator: "\n")
        let signals = accessSignals(context: context, kind: .comments)
        return SummaryInput(
            kind: .comments,
            text: TextUtils.truncate(text, maxChars: 9000),
            usedItems: 0,
            usedBlocks: 0,
            usedComments: used,
            usedPrimary: false,
            accessLimited: signals.limited,
            accessSignals: signals.reasons
        )
    }

    private static func buildFromEmptyComments(context: ContextPack) -> SummaryInput {
        let titleLine = buildTitleLine(context: context)
        let text = [titleLine, "Comments: Not stated in the page."].filter { !$0.isEmpty }.joined(separator: "\n")
        let signals = accessSignals(context: context, kind: .comments)
        return SummaryInput(
            kind: .comments,
            text: TextUtils.truncate(text, maxChars: 9000),
            usedItems: 0,
            usedBlocks: 0,
            usedComments: 0,
            usedPrimary: false,
            accessLimited: signals.limited,
            accessSignals: signals.reasons
        )
    }

    private static func buildFromItem(context: ContextPack, item: ObservedItem) -> SummaryInput {
        var lines: [String] = []
        let title = TextUtils.normalizeWhitespace(item.title)
        if !title.isEmpty {
            lines.append("Item: \(title)")
        }
        let url = TextUtils.normalizeWhitespace(item.url)
        if !url.isEmpty {
            lines.append("URL: \(url)")
        }
        let snippet = SnippetFormatter.format(item.snippet, title: title, maxChars: 360)
        if !snippet.isEmpty {
            lines.append("Snippet: \(snippet)")
        }
        let titleLine = buildTitleLine(context: context)
        let body = lines.joined(separator: "\n")
        let text = [titleLine, body].filter { !$0.isEmpty }.joined(separator: "\n")
        let signals = accessSignals(context: context, kind: .item)
        return SummaryInput(
            kind: .item,
            text: TextUtils.truncate(text, maxChars: 9000),
            usedItems: 1,
            usedBlocks: 0,
            usedComments: 0,
            usedPrimary: false,
            accessLimited: signals.limited,
            accessSignals: signals.reasons
        )
    }

    private static func buildFromBlocks(context: ContextPack) -> SummaryInput {
        var segments: [String] = []
        var usedBlocks = 0
        var usedPrimary = false
        var seen: Set<String> = []

        if let primary = context.observation.primary, isRelevant(primary: primary) {
            let normalized = TextUtils.normalizeWhitespace(primary.text)
            if !normalized.isEmpty {
                segments.append(normalized)
                seen.insert(normalized.lowercased())
                usedPrimary = true
            }
        }

        for block in context.observation.blocks.prefix(20) {
            if !isRelevant(block: block) {
                continue
            }
            let normalized = TextUtils.normalizeWhitespace(block.text)
            if normalized.isEmpty {
                continue
            }
            let key = normalized.lowercased()
            if seen.contains(key) {
                continue
            }
            seen.insert(key)
            segments.append(normalized)
            usedBlocks += 1
        }

        if segments.isEmpty {
            let normalized = TextUtils.normalizeWhitespace(context.observation.text)
            if !normalized.isEmpty {
                segments.append(normalized)
            }
        }

        if segments.isEmpty {
            let outlineLines = buildOutlineLines(context: context)
            if !outlineLines.isEmpty {
                segments.append(outlineLines.joined(separator: "\n"))
            }
        }

        let titleLine = buildTitleLine(context: context)
        let body = segments.joined(separator: "\n")
        let text = [titleLine, body].filter { !$0.isEmpty }.joined(separator: "\n")
        let signals = accessSignals(context: context, kind: .pageText)
        return SummaryInput(
            kind: .pageText,
            text: TextUtils.truncate(text, maxChars: 9000),
            usedItems: 0,
            usedBlocks: usedBlocks,
            usedComments: 0,
            usedPrimary: usedPrimary,
            accessLimited: signals.limited,
            accessSignals: signals.reasons
        )
    }

    private static func buildTitleLine(context: ContextPack) -> String {
        let title = TextUtils.normalizeWhitespace(context.observation.title)
        if !title.isEmpty {
            return "Title: \(title)"
        }
        let url = TextUtils.normalizeWhitespace(context.observation.url)
        if !url.isEmpty {
            return "URL: \(url)"
        }
        return ""
    }

    private static func shouldUseItemSnippet(context: ContextPack) -> Bool {
        if !isListObservation(context) {
            return false
        }
        let primaryChars = context.observation.primary?.text.count ?? 0
        if primaryChars >= 400 {
            return false
        }
        if context.observation.blocks.count >= 6 && primaryChars >= 200 {
            return false
        }
        return true
    }

    private static func selectTargetItem(context: ContextPack, goalPlan: GoalPlan) -> ObservedItem? {
        let items = context.observation.items
        if items.isEmpty {
            return nil
        }
        if let index = goalPlan.itemIndex, index > 0, items.count >= index {
            return items[index - 1]
        }
        if let query = goalPlan.itemQuery, !query.isEmpty {
            let normalizedQuery = normalizeForMatch(query)
            for item in items {
                let normalizedTitle = normalizeForMatch(item.title)
                if normalizedTitle.contains(normalizedQuery) {
                    return item
                }
            }
        }
        return nil
    }

    private static func normalizeForMatch(_ text: String) -> String {
        let normalized = TextUtils.normalizeWhitespace(text)
        return normalized.lowercased()
    }

    private static func buildOutlineLines(context: ContextPack) -> [String] {
        var lines: [String] = []
        for item in context.observation.outline.prefix(12) {
            if !isRelevantOutline(item: item) {
                continue
            }
            let text = TextUtils.normalizeWhitespace(item.text)
            if text.isEmpty {
                continue
            }
            lines.append(text)
        }
        return lines
    }

    private static func isRelevantOutline(item: ObservedOutlineItem) -> Bool {
        let tag = item.tag.lowercased()
        if tag == "nav" || tag == "footer" || tag == "header" || tag == "aside" || tag == "menu" {
            return false
        }
        let role = item.role.lowercased()
        if role == "navigation" || role == "banner" || role == "contentinfo" || role == "menu" {
            return false
        }
        if role == "dialog" || role == "alertdialog" {
            return false
        }
        return true
    }

    private static func isRelevant(block: ObservedTextBlock) -> Bool {
        let tag = block.tag.lowercased()
        if tag.isEmpty {
            return true
        }
        let excludedTags: Set<String> = [
            "nav",
            "header",
            "footer",
            "aside",
            "menu",
            "form",
            "address",
            "button",
            "input",
            "label",
            "dialog"
        ]
        if excludedTags.contains(tag) {
            return false
        }
        let role = block.role.lowercased()
        if role == "navigation" || role == "banner" || role == "contentinfo" || role == "menu" {
            return false
        }
        if role == "dialog" || role == "alertdialog" {
            return false
        }
        if block.linkDensity >= 0.6 && block.linkCount >= 6 {
            return false
        }
        if block.linkDensity >= 0.4 && block.linkCount >= 10 {
            return false
        }
        return true
    }

    private static func isRelevant(primary: ObservedPrimaryContent) -> Bool {
        let tag = primary.tag.lowercased()
        if tag == "dialog" || tag == "form" || tag == "nav" || tag == "header" || tag == "footer" || tag == "aside" {
            return false
        }
        let role = primary.role.lowercased()
        if role == "navigation" || role == "banner" || role == "contentinfo" || role == "menu" {
            return false
        }
        if role == "dialog" || role == "alertdialog" {
            return false
        }
        if primary.linkDensity >= 0.6 && primary.linkCount >= 6 {
            return false
        }
        return true
    }

    private struct AccessSignals {
        let limited: Bool
        let reasons: [String]
    }

    private static func accessSignals(context: ContextPack, kind: SummaryInput.Kind) -> AccessSignals {
        if kind == .list || kind == .comments {
            return AccessSignals(limited: false, reasons: [])
        }
        if isListObservation(context) {
            return AccessSignals(limited: false, reasons: [])
        }
        let primaryChars: Int
        if let primary = context.observation.primary, isRelevant(primary: primary) {
            primaryChars = primary.text.count
        } else {
            primaryChars = 0
        }
        let relevantBlocks = context.observation.blocks.filter { isRelevant(block: $0) }
        let blockChars = relevantBlocks.reduce(0) { $0 + $1.text.count }
        let textChars = context.observation.text.count
        let hasDialog = context.observation.blocks.contains { block in
            let role = block.role.lowercased()
            let tag = block.tag.lowercased()
            return role == "dialog" || role == "alertdialog" || tag == "dialog"
        }
        let hasAuthField = context.observation.elements.contains { element in
            guard let inputType = element.inputType?.lowercased() else {
                return false
            }
            return inputType == "password" || inputType == "email"
        }
        let lowContent = primaryChars < 220 && blockChars < 900 && textChars < 1800
        if lowContent && (hasDialog || hasAuthField || textChars < 120) {
            var reasons: [String] = []
            if hasDialog {
                reasons.append("overlay_or_dialog")
            }
            if hasAuthField {
                reasons.append("auth_fields")
            }
            if reasons.isEmpty {
                reasons.append("low_visible_text")
            }
            return AccessSignals(limited: true, reasons: reasons)
        }
        return AccessSignals(limited: false, reasons: [])
    }
}
