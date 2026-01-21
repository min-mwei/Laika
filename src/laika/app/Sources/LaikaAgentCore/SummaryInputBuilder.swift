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
        if goalPlan.intent == .itemSummary {
            let blockInput = buildFromBlocks(context: context, goalPlan: goalPlan)
            let primaryChars = context.observation.primary?.text.count ?? 0
            if isListObservation(context), shouldUseItemSnippet(context: context), primaryChars < 500 {
                if let item = selectTargetItem(context: context, goalPlan: goalPlan) {
                    return buildFromItem(context: context, item: item)
                }
            }
            if !isLowSignalSummaryInput(blockInput) {
                return blockInput
            }
            if shouldUseItemSnippet(context: context),
               let item = selectTargetItem(context: context, goalPlan: goalPlan) {
                return buildFromItem(context: context, item: item)
            }
            return blockInput
        }
        if isListObservation(context), !context.observation.items.isEmpty {
            return buildFromItems(context: context)
        }
        let blockInput = buildFromBlocks(context: context, goalPlan: goalPlan)
        if isLowSignalSummaryInput(blockInput), !context.observation.items.isEmpty {
            return buildFromItems(context: context)
        }
        return blockInput
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
            let snippet = formatSnippet(item.snippet, title: title, maxChars: 260)
            if isUsefulSnippet(snippet) {
                line += " — \(snippet)"
            }
            lines.append(line)
            used += 1
        }
        let titleLine = buildTitleLine(context: context)
        let countLine = "Observed items: \(items.count)"
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
        var authors: [String] = []
        var seenAuthors: Set<String> = []
        var seenTexts: Set<String> = []
        for (index, comment) in context.observation.comments.prefix(28).enumerated() {
            let text = TextUtils.normalizeWhitespace(comment.text)
            if text.isEmpty {
                continue
            }
            let textKey = normalizeForMatch(text)
            if !textKey.isEmpty && seenTexts.contains(textKey) {
                continue
            }
            if !textKey.isEmpty {
                seenTexts.insert(textKey)
            }
            var prefix: [String] = []
            if let author = comment.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
                prefix.append(author)
                let key = author.lowercased()
                if !seenAuthors.contains(key) {
                    seenAuthors.insert(key)
                    authors.append(author)
                }
            }
            if let age = comment.age?.trimmingCharacters(in: .whitespacesAndNewlines), !age.isEmpty {
                prefix.append(age)
            }
            if let score = comment.score?.trimmingCharacters(in: .whitespacesAndNewlines), !score.isEmpty {
                prefix.append(score)
            }
            let header = prefix.isEmpty ? "" : " (" + prefix.joined(separator: " · ") + ") "
            let line = "Comment \(index + 1):" + header + TextUtils.truncate(text, maxChars: 360)
            lines.append(line)
            used += 1
        }
        let titleLine = buildTitleLine(context: context)
        let countLine = "Comment count (metadata): \(context.observation.comments.count)"
        let authorLine = authors.isEmpty ? "" : "Authors (metadata): " + authors.prefix(6).joined(separator: "; ")
        let body = lines.joined(separator: "\n")
        let text = [titleLine, body, authorLine, countLine].filter { !$0.isEmpty }.joined(separator: "\n")
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
        let snippet = formatSnippet(item.snippet, title: title, maxChars: 420)
        if isUsefulSnippet(snippet) {
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

    private static func buildFromBlocks(context: ContextPack, goalPlan: GoalPlan) -> SummaryInput {
        var segments: [String] = []
        var usedBlocks = 0
        var usedPrimary = false
        var seen: Set<String> = []
        let isDetail = goalPlan.intent == .itemSummary

        let maxSentences = isDetail ? 8 : 12
        if let primary = context.observation.primary, isRelevant(primary: primary) {
            let normalized = TextUtils.normalizePreservingNewlines(primary.text)
            if !normalized.isEmpty {
                if !isPromotionalText(normalized) {
                    let compacted = compactText(normalized, maxSentences: maxSentences)
                    if !compacted.isEmpty {
                        segments.append(compacted)
                        seen.insert(compacted.lowercased())
                    }
                    usedPrimary = true
                }
            }
        }

        let maxBlocks = isDetail ? 16 : 20
        for block in context.observation.blocks.prefix(maxBlocks) {
            if isDetail {
                if !isRelevantDetail(block: block) {
                    continue
                }
            } else if !isRelevant(block: block) {
                continue
            }
            let normalized = TextUtils.normalizePreservingNewlines(block.text)
            if normalized.isEmpty {
                continue
            }
            let compacted = compactText(normalized, maxSentences: maxSentences)
            if compacted.isEmpty {
                continue
            }
            let key = compacted.lowercased()
            if seen.contains(key) {
                continue
            }
            seen.insert(key)
            segments.append(compacted)
            usedBlocks += 1
        }

        if segments.isEmpty {
            let normalized = TextUtils.normalizePreservingNewlines(context.observation.text)
            if !normalized.isEmpty && !isLowSignalText(normalized) {
                segments.append(compactText(normalized))
            }
        }

        let outlineLines = buildOutlineLines(context: context)
        if segments.isEmpty {
            if !outlineLines.isEmpty {
                segments.append(outlineLines.joined(separator: "\n"))
            }
        } else if isDetail, !outlineLines.isEmpty {
            let outlineText = outlineLines.joined(separator: "; ")
            if !outlineText.isEmpty {
                segments.insert("Outline: " + outlineText, at: 0)
            }
        }

        let titleLine = buildTitleLine(context: context)
        let body = segments.joined(separator: "\n")
        let signals = accessSignals(context: context, kind: .pageText)
        var reasons = signals.reasons
        var textParts = [String]()
        if isLowSignalText(body) {
            reasons.append("low_signal_text")
        }
        if !titleLine.isEmpty {
            textParts.append(titleLine)
        }
        if !body.isEmpty {
            textParts.append(body)
        }
        let text = textParts.joined(separator: "\n")
        let maxChars = isDetail ? 7000 : 9000
        return SummaryInput(
            kind: .pageText,
            text: TextUtils.truncate(text, maxChars: maxChars),
            usedItems: 0,
            usedBlocks: usedBlocks,
            usedComments: 0,
            usedPrimary: usedPrimary,
            accessLimited: signals.limited,
            accessSignals: reasons
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

    private static func compactText(_ text: String, maxSentences: Int = 12) -> String {
        let normalized = TextUtils.normalizePreservingNewlines(text)
        if normalized.isEmpty {
            return text
        }
        let lines = normalized.split(separator: "\n").map { String($0) }
        if lines.count > 1 {
            let compacted = compactLines(lines, maxLines: maxSentences)
            if compacted.isEmpty {
                return normalized
            }
            return collapseRepeatedTokens(compacted)
        }
        let sentences = TextUtils.splitSentences(normalized)
        guard !sentences.isEmpty else {
            return normalized
        }
        var seen: Set<String> = []
        var output: [String] = []
        output.reserveCapacity(sentences.count)
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            if isLowSignalSentence(trimmed) {
                continue
            }
            if isUiHeavySentence(trimmed) {
                continue
            }
            let key = normalizeForMatch(trimmed)
            if key.isEmpty || seen.contains(key) {
                continue
            }
            seen.insert(key)
            output.append(trimmed)
            if output.count >= maxSentences {
                break
            }
        }
        let joined = output.joined(separator: " ")
        return collapseRepeatedTokens(joined)
    }

    private static func compactLines(_ lines: [String], maxLines: Int) -> String {
        guard maxLines > 0 else {
            return ""
        }
        var seen: Set<String> = []
        var output: [String] = []
        output.reserveCapacity(min(lines.count, maxLines))
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            if isLowSignalLine(trimmed) {
                continue
            }
            let key = normalizeForMatch(trimmed)
            if key.isEmpty || seen.contains(key) {
                continue
            }
            seen.insert(key)
            output.append(line)
            if output.count >= maxLines {
                break
            }
        }
        return output.joined(separator: "\n")
    }

    private static func isLowSignalLine(_ text: String) -> Bool {
        let stripped = stripStructuredPrefix(text)
        if stripped.isEmpty {
            return true
        }
        if isUiOnlySegment(stripped) {
            return true
        }
        if isStructuredLine(text) {
            let words = stripped.split(separator: " ")
            if words.count <= 1 && stripped.count < 12 && !containsDigit(stripped) {
                return true
            }
            return false
        }
        return isLowSignalSentence(stripped)
    }

    private static func isStructuredLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("> ") {
            return true
        }
        if trimmed.count >= 3 {
            let scalars = Array(trimmed.unicodeScalars.prefix(3))
            if scalars.count == 3,
               scalars[0].value == 72,
               CharacterSet.decimalDigits.contains(scalars[1]),
               scalars[2].value == 58 {
                return true
            }
        }
        let prefixes = ["Code:", "Summary:", "Caption:", "Term:", "Definition:"]
        for prefix in prefixes where trimmed.hasPrefix(prefix) {
            return true
        }
        return false
    }

    private static func stripStructuredPrefix(_ text: String) -> String {
        var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.hasPrefix("- ") || output.hasPrefix("> ") {
            output = String(output.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if output.count >= 3 {
            let scalars = Array(output.unicodeScalars.prefix(3))
            if scalars.count == 3,
               scalars[0].value == 72,
               CharacterSet.decimalDigits.contains(scalars[1]),
               scalars[2].value == 58 {
                output = String(output.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let prefixes = ["Code:", "Summary:", "Caption:", "Term:", "Definition:"]
        for prefix in prefixes where output.hasPrefix(prefix) {
            output = String(output.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return output
    }

    private static func isLowSignalSentence(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        let wordCount = words.count
        if wordCount < 6 && text.count < 120 {
            if containsDigit(text) || hasCapitalizedWord(text) || text.contains(":") {
                return false
            }
            return true
        }
        let lowerWords = words.map { $0.lowercased() }
        let uniqueCount = Set(lowerWords).count
        let diversity = wordCount > 0 ? Double(uniqueCount) / Double(wordCount) : 0
        if wordCount >= 12 && diversity < 0.4 {
            return true
        }
        var letters = 0
        var uppercase = 0
        var digits = 0
        var shortWords = 0
        for word in words where word.count <= 2 {
            shortWords += 1
        }
        for scalar in text.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                letters += 1
                if CharacterSet.uppercaseLetters.contains(scalar) {
                    uppercase += 1
                }
            } else if CharacterSet.decimalDigits.contains(scalar) {
                digits += 1
            }
        }
        let total = letters + digits
        if total == 0 {
            return true
        }
        let upperRatio = letters > 0 ? Double(uppercase) / Double(letters) : 0
        let digitRatio = Double(digits) / Double(total)
        let shortRatio = wordCount > 0 ? Double(shortWords) / Double(wordCount) : 0
        if wordCount < 60 {
            if upperRatio > 0.6 || digitRatio > 0.45 || shortRatio > 0.45 {
                return true
            }
        }
        return false
    }

    private static func isUiHeavySentence(_ text: String) -> Bool {
        if isStructuredLine(text) {
            return false
        }
        if text.contains(".") || text.contains("?") || text.contains("!") {
            return false
        }
        let words = text.split(separator: " ")
        if words.count < 6 {
            return false
        }
        if text.contains("|") || text.contains(">") || text.contains("/") {
            return true
        }
        var shortWords = 0
        for word in words where word.count <= 4 {
            shortWords += 1
        }
        let shortRatio = Double(shortWords) / Double(words.count)
        var letters = 0
        var digits = 0
        for scalar in text.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                letters += 1
            } else if CharacterSet.decimalDigits.contains(scalar) {
                digits += 1
            }
        }
        let total = letters + digits
        let digitRatio = total > 0 ? Double(digits) / Double(total) : 0
        if text.count < 140 && shortRatio >= 0.65 {
            return true
        }
        if text.count < 140 && digitRatio > 0.45 {
            return true
        }
        return false
    }

    private static func formatSnippet(_ snippet: String, title: String, maxChars: Int) -> String {
        let expanded = SnippetFormatter.format(snippet, title: title, maxChars: maxChars * 2)
        let cleaned = cleanSnippetSegments(expanded)
        if cleaned.isEmpty {
            return ""
        }
        return TextUtils.truncate(cleaned, maxChars: maxChars)
    }

    private static func cleanSnippetSegments(_ snippet: String) -> String {
        let normalized = TextUtils.normalizeWhitespace(snippet)
        if normalized.isEmpty {
            return ""
        }
        let segments = normalized.split(separator: "|").map { segment in
            segment.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        if segments.count <= 1 {
            return normalized
        }
        var output: [String] = []
        var seen: Set<String> = []
        for segment in segments {
            let cleaned = TextUtils.normalizeWhitespace(String(segment))
            if cleaned.isEmpty {
                continue
            }
            if isUiOnlySegment(cleaned) {
                continue
            }
            if isLowSignalText(cleaned) && !containsDigit(cleaned) {
                continue
            }
            let key = normalizeForMatch(cleaned)
            if seen.contains(key) {
                continue
            }
            seen.insert(key)
            output.append(cleaned)
        }
        if output.isEmpty {
            return normalized
        }
        return output.joined(separator: " | ")
    }

    private static func isUiOnlySegment(_ text: String) -> Bool {
        let lower = text.lowercased()
        let labels: Set<String> = [
            "hide",
            "reply",
            "replies",
            "share",
            "save",
            "bookmark",
            "login",
            "log in",
            "sign in",
            "sign up",
            "signup",
            "subscribe",
            "view",
            "more",
            "next",
            "prev",
            "previous"
        ]
        if labels.contains(lower), !containsDigit(lower) {
            return true
        }
        if lower.count <= 3 && !containsDigit(lower) {
            return true
        }
        return false
    }

    private static func containsDigit(_ text: String) -> Bool {
        return text.rangeOfCharacter(from: .decimalDigits) != nil
    }

    private static func hasCapitalizedWord(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        for word in words {
            guard let first = word.unicodeScalars.first else {
                continue
            }
            if CharacterSet.uppercaseLetters.contains(first) {
                return true
            }
        }
        return false
    }

    private static func collapseRepeatedTokens(_ text: String) -> String {
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        guard tokens.count >= 8 else {
            return text
        }
        var output: [Substring] = []
        output.reserveCapacity(tokens.count)
        var index = 0
        let maxWindow = min(24, tokens.count / 2)
        while index < tokens.count {
            var collapsed = false
            for window in stride(from: maxWindow, through: 4, by: -1) {
                let nextIndex = index + window
                let endIndex = nextIndex + window
                if endIndex > tokens.count {
                    continue
                }
                if tokens[index..<nextIndex] == tokens[nextIndex..<endIndex] {
                    output.append(contentsOf: tokens[index..<nextIndex])
                    index = nextIndex
                    collapsed = true
                    break
                }
            }
            if !collapsed {
                output.append(tokens[index])
                index += 1
            }
        }
        return output.joined(separator: " ")
    }

    private static func isUsefulSnippet(_ snippet: String) -> Bool {
        let normalized = TextUtils.normalizeWhitespace(snippet)
        if normalized.isEmpty {
            return false
        }
        let words = normalized.split(separator: " ")
        var letters = 0
        var digits = 0
        for scalar in normalized.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                letters += 1
            } else if CharacterSet.decimalDigits.contains(scalar) {
                digits += 1
            }
        }
        let total = letters + digits
        if total == 0 {
            return false
        }
        let digitRatio = Double(digits) / Double(total)
        if digitRatio > 0.35 {
            return false
        }
        if words.count >= 6 {
            return !isLowSignalText(normalized)
        }
        if normalized.count >= 40 && digitRatio < 0.2 {
            return true
        }
        return words.count >= 4 && digitRatio < 0.25
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
            if !isUsefulOutlineText(text) {
                continue
            }
            lines.append(text)
        }
        return lines
    }

    private static func isUsefulOutlineText(_ text: String) -> Bool {
        if isUiOnlySegment(text) {
            return false
        }
        let words = text.split(separator: " ")
        if words.count <= 2 && text.rangeOfCharacter(from: .decimalDigits) != nil {
            return false
        }
        if words.count <= 2 && text.count < 16 {
            return false
        }
        return true
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
        if block.linkCount >= 40 && block.linkDensity >= 0.15 {
            return false
        }
        if isLowSignalText(block.text) {
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
        if primary.linkCount >= 40 && primary.linkDensity >= 0.15 {
            return false
        }
        if isLowSignalText(primary.text) {
            return false
        }
        return true
    }

    private static func isRelevantDetail(block: ObservedTextBlock) -> Bool {
        if !isRelevant(block: block) {
            return false
        }
        let normalized = TextUtils.normalizePreservingNewlines(block.text)
        let textLength = normalized.count
        if textLength < 60 {
            if !(containsDigit(normalized) || hasCapitalizedWord(normalized) || normalized.contains(":")) {
                return false
            }
        }
        if block.linkDensity > 0.45 && block.linkCount >= 3 {
            return false
        }
        return true
    }

    private static func isLowSignalSummaryInput(_ input: SummaryInput) -> Bool {
        if input.accessLimited {
            return true
        }
        if input.accessSignals.contains("low_signal_text") {
            return true
        }
        if input.usedBlocks == 0 && !input.usedPrimary {
            return true
        }
        let lines = input.text.split(separator: "\n").map { String($0) }
        let body = lines.filter { !isMetadataLine($0) }.joined(separator: " ")
        if body.isEmpty {
            return true
        }
        return isLowSignalText(body)
    }

    private static func isMetadataLine(_ line: String) -> Bool {
        return line.hasPrefix("Title:")
            || line.hasPrefix("URL:")
            || line.hasPrefix("Item count:")
            || line.hasPrefix("Comment count:")
            || line.hasPrefix("Authors")
            || line.hasPrefix("Outline:")
    }

    private static func isLowSignalText(_ text: String) -> Bool {
        let normalized = TextUtils.normalizeWhitespace(text)
        if normalized.isEmpty {
            return true
        }
        let words = normalized.split(separator: " ")
        let wordCount = words.count
        if wordCount < 6 && normalized.count < 120 {
            if containsDigit(normalized) || hasCapitalizedWord(normalized) || normalized.contains(":") {
                return false
            }
            return true
        }
        var letters = 0
        var uppercase = 0
        var digits = 0
        var shortWords = 0
        for word in words {
            if word.count <= 2 {
                shortWords += 1
            }
        }
        let lowerWords = words.map { $0.lowercased() }
        let uniqueCount = Set(lowerWords).count
        let diversity = wordCount > 0 ? Double(uniqueCount) / Double(wordCount) : 0
        for scalar in normalized.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                letters += 1
                if CharacterSet.uppercaseLetters.contains(scalar) {
                    uppercase += 1
                }
            } else if CharacterSet.decimalDigits.contains(scalar) {
                digits += 1
            }
        }
        let total = letters + digits
        if total == 0 {
            return true
        }
        let upperRatio = letters > 0 ? Double(uppercase) / Double(letters) : 0
        let digitRatio = Double(digits) / Double(total)
        let shortRatio = wordCount > 0 ? Double(shortWords) / Double(wordCount) : 0
        if wordCount >= 12 && diversity < 0.4 {
            return true
        }
        if wordCount < 60 {
            if upperRatio > 0.6 || digitRatio > 0.45 || shortRatio > 0.45 {
                return true
            }
        }
        return false
    }

    private static func isPromotionalText(_ text: String) -> Bool {
        let lower = text.lowercased()
        let keywords = [
            "buy",
            "order",
            "subscribe",
            "sign up",
            "signup",
            "sign in",
            "newsletter",
            "trial",
            "pricing",
            "checkout",
            "cart"
        ]
        var hits = 0
        for keyword in keywords {
            if lower.contains(keyword) {
                hits += 1
            }
        }
        if hits >= 2 {
            return true
        }
        if hits >= 1 && lower.count < 220 {
            return true
        }
        return false
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
