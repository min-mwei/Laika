import Foundation
import LaikaShared
import LaikaModel

public struct AgentAction: Codable, Equatable, Sendable {
    public let toolCall: ToolCall
    public let policy: PolicyResult

    public init(toolCall: ToolCall, policy: PolicyResult) {
        self.toolCall = toolCall
        self.policy = policy
    }
}

public struct AgentResponse: Codable, Equatable, Sendable {
    public let summary: String
    public let actions: [AgentAction]

    public init(summary: String, actions: [AgentAction]) {
        self.summary = summary
        self.actions = actions
    }
}

public final class AgentOrchestrator: Sendable {
    private let model: ModelRunner
    private let policyGate: PolicyGate

    private enum SummaryFocus {
        case mainLinks
        case pageText
        case comments
    }

    public init(model: ModelRunner, policyGate: PolicyGate = PolicyGate()) {
        self.model = model
        self.policyGate = policyGate
    }

    public func runOnce(context: ContextPack, userGoal: String) async throws -> AgentResponse {
        if context.mode == .observe {
            let summary = try await generateObservedSummary(context: context, userGoal: userGoal)
            return AgentResponse(summary: summary, actions: [])
        }
        let modelResponse = try await model.generatePlan(context: context, userGoal: userGoal)
        let summary = postProcessSummary(modelResponse.summary, context: context, goal: userGoal)
        let actions = applyPolicy(to: modelResponse.toolCalls, context: context)
        return AgentResponse(summary: summary, actions: actions)
    }

    private func applyPolicy(to toolCalls: [ToolCall], context: ContextPack) -> [AgentAction] {
        let policyContext = PolicyContext(
            origin: context.origin,
            mode: context.mode,
            fieldKind: .unknown
        )
        return toolCalls.map { toolCall in
            let decision = policyGate.decide(for: toolCall, context: policyContext)
            return AgentAction(toolCall: toolCall, policy: decision)
        }
    }

    private func generateObservedSummary(context: ContextPack, userGoal: String) async throws -> String {
        let focus = summaryFocus(for: userGoal)
        let initial = try await model.generatePlan(context: context, userGoal: userGoal)
        var summary = initial.summary
        var grounding = evaluateGrounding(summary: summary, context: context, focus: focus)
        if !grounding.isSatisfied {
            let retryGoal = buildGroundingRetryGoal(userGoal: userGoal, requiredCount: grounding.requiredCount, focus: focus)
            let retry = try await model.generatePlan(context: context, userGoal: retryGoal)
            summary = retry.summary
            grounding = evaluateGrounding(summary: summary, context: context, focus: focus)
        }
        return enforceGrounding(summary: summary, context: context, grounding: grounding, goal: userGoal, focus: focus)
    }

    private func postProcessSummary(_ summary: String, context: ContextPack, goal: String) -> String {
        guard context.mode == .observe else {
            return summary
        }
        let focus = summaryFocus(for: goal)
        let grounding = evaluateGrounding(summary: summary, context: context, focus: focus)
        return enforceGrounding(summary: summary, context: context, grounding: grounding, goal: goal, focus: focus)
    }

    private struct GroundingResult {
        let labels: [String]
        let requiredCount: Int
        let mentionedCount: Int
        let keywordMatches: Int
        let wordCount: Int
        let minWordCount: Int

        var isSatisfied: Bool {
            if minWordCount > 0 && wordCount < minWordCount {
                return false
            }
            if !labels.isEmpty {
                return mentionedCount >= requiredCount
            }
            return keywordMatches >= requiredCount
        }
    }

    private func evaluateGrounding(summary: String, context: ContextPack, focus: SummaryFocus) -> GroundingResult {
        let wordCount = normalizeForMatch(summary).split(separator: " ").count
        let minWordCount = minimumWordCount(for: context, focus: focus)

        if focus == .mainLinks {
            let labels = MainLinkHeuristics.labels(from: context.observation.elements, limit: 12)
            let requiredCount = mainLinkRequirement(count: labels.count)
            let normalizedSummary = normalizeForMatch(summary)
            let mentionedCount = countLabelMentions(summaryNormalized: normalizedSummary, labels: labels)
            if !labels.isEmpty {
                return GroundingResult(
                    labels: labels,
                    requiredCount: requiredCount,
                    mentionedCount: mentionedCount,
                    keywordMatches: 0,
                    wordCount: wordCount,
                    minWordCount: minWordCount
                )
            }
        }

        if focus == .comments {
            let blockText = combinedBlockText(from: context)
            let sourceText = blockText.isEmpty ? context.observation.text : blockText
            let keywords = keywordCandidates(from: sourceText, limit: 28)
            if keywords.isEmpty {
                return GroundingResult(
                    labels: [],
                    requiredCount: 0,
                    mentionedCount: 0,
                    keywordMatches: 0,
                    wordCount: wordCount,
                    minWordCount: minWordCount
                )
            }
            let summaryTokens = Set(normalizeForMatch(summary).split(separator: " ").map(String.init))
            let keywordMatches = keywords.filter { summaryTokens.contains($0) }.count
            let keywordRequired = max(1, min(3, keywords.count))
            return GroundingResult(
                labels: [],
                requiredCount: keywordRequired,
                mentionedCount: 0,
                keywordMatches: keywordMatches,
                wordCount: wordCount,
                minWordCount: minWordCount
            )
        }

        let blockText = combinedBlockText(from: context)
        let sourceText = blockText.isEmpty ? context.observation.text : blockText
        let keywords = keywordCandidates(from: sourceText, limit: 28)
        if keywords.isEmpty {
            return GroundingResult(
                labels: [],
                requiredCount: 0,
                mentionedCount: 0,
                keywordMatches: 0,
                wordCount: wordCount,
                minWordCount: minWordCount
            )
        }
        let summaryTokens = Set(normalizeForMatch(summary).split(separator: " ").map(String.init))
        let keywordMatches = keywords.filter { summaryTokens.contains($0) }.count
        let keywordRequired = max(1, min(3, keywords.count))
        return GroundingResult(
            labels: [],
            requiredCount: keywordRequired,
            mentionedCount: 0,
            keywordMatches: keywordMatches,
            wordCount: wordCount,
            minWordCount: minWordCount
        )
    }

    private func enforceGrounding(
        summary: String,
        context: ContextPack,
        grounding: GroundingResult,
        goal: String,
        focus: SummaryFocus
    ) -> String {
        if grounding.isSatisfied {
            return summary
        }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantsContentOnly = goal.lowercased().contains("not the web site") ||
            goal.lowercased().contains("not the website") ||
            goal.lowercased().contains("not the site")
        if focus == .mainLinks {
            let labels = grounding.labels.isEmpty
                ? MainLinkHeuristics.labels(from: context.observation.elements, limit: 10)
                : grounding.labels
            let examples = labels.prefix(max(grounding.requiredCount, 5)).joined(separator: "; ")
            let totalCount = MainLinkHeuristics.candidates(from: context.observation.elements).count
            let metadata = metadataSnippets(from: context.observation.elements, limit: 4)
            if wantsContentOnly || trimmed.isEmpty {
                let countText = totalCount > 0 ? "\(totalCount) items" : "multiple items"
                var fallback = "The page lists \(countText). Top items include \(examples)."
                if !metadata.isEmpty {
                    fallback += " Visible metadata includes \(metadata.joined(separator: "; "))."
                }
                fallback += " The list is presented as headlines with adjacent points and comment links."
                return fallback
            }
            var output = trimmed
            let suffix = output.hasSuffix(".") || output.hasSuffix("!") || output.hasSuffix("?") ? " " : ". "
            output += "\(suffix)Top items include \(examples)."
            if !metadata.isEmpty {
                output += " Visible metadata includes \(metadata.joined(separator: "; "))."
            }
            output += " The list is presented as headlines with adjacent points and comment links."
            return output
        }
        if focus == .comments {
            let excerpts = blockExcerpts(from: context, limit: 4)
            let metadata = metadataSnippets(from: context.observation.elements, limit: 3)
            if excerpts.isEmpty {
                return summary
            }
            let joined = excerpts.joined(separator: "; ")
            if wantsContentOnly || trimmed.isEmpty {
                var fallback = "Comment themes include: \(joined)."
                if !metadata.isEmpty {
                    fallback += " Visible metadata includes \(metadata.joined(separator: "; "))."
                }
                return fallback
            }
            var output = trimmed
            let suffix = output.hasSuffix(".") || output.hasSuffix("!") || output.hasSuffix("?") ? " " : ". "
            output += "\(suffix)Comment themes include: \(joined)."
            if !metadata.isEmpty {
                output += " Visible metadata includes \(metadata.joined(separator: "; "))."
            }
            return output
        }
        let keywords = keywordCandidates(from: context.observation.text, limit: 12)
        if keywords.isEmpty {
            return summary
        }
        let examples = keywords.prefix(max(grounding.requiredCount, 6)).joined(separator: ", ")
        let extra = keywords.dropFirst(max(grounding.requiredCount, 6)).prefix(4).joined(separator: ", ")
        if wantsContentOnly || trimmed.isEmpty {
            var fallback = "The page covers topics such as \(examples)."
            if !extra.isEmpty {
                fallback += " Additional terms include \(extra)."
            }
            return fallback
        }
        let suffix = trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?") ? " " : ". "
        var output = "\(trimmed)\(suffix)Topics include \(examples)."
        if !extra.isEmpty {
            output += " Additional terms include \(extra)."
        }
        return output
    }

    private func buildGroundingRetryGoal(userGoal: String, requiredCount: Int, focus: SummaryFocus) -> String {
        let count = requiredCount > 0 ? requiredCount : 3
        let requirement: String
        switch focus {
        case .mainLinks:
            requirement = "Mention at least \(count) specific items from the Main Links list. Include visible metrics (points/comments/timestamps) when available."
        case .pageText:
            requirement = "Mention at least \(count) specific points from Page Text. Provide more detail than a short list."
        case .comments:
            requirement = "Mention at least \(count) distinct points from the comment text. Provide more detail than a short list."
        }
        return "\(userGoal)\n\nRequirement: \(requirement)"
    }

    private func countLabelMentions(summaryNormalized: String, labels: [String]) -> Int {
        var count = 0
        for label in labels {
            let normalized = normalizeForMatch(label)
            if normalized.isEmpty {
                continue
            }
            if summaryNormalized.contains(normalized) {
                count += 1
                continue
            }
            let tokens = normalized.split(separator: " ")
            if tokens.count >= 3 {
                let prefix = tokens.prefix(6).joined(separator: " ")
                if prefix.count >= 12 && summaryNormalized.contains(prefix) {
                    count += 1
                }
            }
        }
        return count
    }

    private func normalizeForMatch(_ text: String) -> String {
        let lower = text.lowercased()
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(lower.unicodeScalars.count)
        for scalar in lower.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
            } else {
                scalars.append(" ")
            }
        }
        let cleaned = String(String.UnicodeScalarView(scalars))
        return cleaned.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .joined(separator: " ")
    }

    private func summaryFocus(for goal: String) -> SummaryFocus {
        let lower = goal.lowercased()
        if lower.contains("comment") || lower.contains("thread") || lower.contains("discussion") {
            return .comments
        }
        if lower.contains("linked page") ||
            lower.contains("linked") ||
            lower.contains("article") ||
            lower.contains("story") ||
            lower.contains("page content") {
            return .pageText
        }
        return .mainLinks
    }

    private func mainLinkRequirement(count: Int) -> Int {
        if count >= 5 {
            return 5
        }
        if count >= 3 {
            return 3
        }
        return count
    }

    private func minimumWordCount(for context: ContextPack, focus: SummaryFocus) -> Int {
        let textCount = context.observation.text.count
        var minimum: Int
        if textCount < 400 {
            minimum = 20
        } else if textCount < 1200 {
            minimum = 40
        } else if textCount < 2400 {
            minimum = 55
        } else {
            minimum = 70
        }
        if focus == .pageText {
            minimum += 10
        } else if focus == .comments {
            minimum += 20
        }
        return minimum
    }

    private func combinedBlockText(from context: ContextPack) -> String {
        var parts: [String] = []
        if let primary = context.observation.primary?.text, !primary.isEmpty {
            parts.append(primary)
        }
        let blocks = context.observation.blocks
        if !blocks.isEmpty {
            parts.append(contentsOf: blocks.map { $0.text })
        }
        return parts.joined(separator: " ")
    }

    private func blockExcerpts(from context: ContextPack, limit: Int) -> [String] {
        if limit <= 0 {
            return []
        }
        var output: [String] = []
        if let primary = context.observation.primary?.text {
            let trimmed = primary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                output.append(trimmed)
            }
        }
        let blocks = context.observation.blocks
        for block in blocks {
            let trimmed = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            output.append(trimmed)
            if output.count >= limit {
                break
            }
        }
        return output
    }

    private func keywordCandidates(from text: String, limit: Int) -> [String] {
        let normalized = normalizeForMatch(text)
        let stopwords: Set<String> = [
            "about", "after", "also", "and", "are", "back", "been", "before", "being", "between",
            "both", "but", "can", "could", "does", "each", "for", "from", "have", "into", "just",
            "more", "most", "news", "page", "people", "some", "than", "that", "the", "their", "there",
            "these", "they", "this", "those", "with", "would", "your", "hacker", "submit", "login",
            "logout", "register", "reply", "flag", "hide", "comments", "comment", "points", "favorite",
            "past", "new", "show", "ask", "jobs", "next", "previous", "more", "link", "links", "vote",
            "upvote", "downvote", "ycombinator", "thread", "threads"
        ]
        var output: [String] = []
        var seen: Set<String> = []
        for token in normalized.split(separator: " ").map(String.init) {
            if token.count < 5 {
                continue
            }
            if stopwords.contains(token) {
                continue
            }
            if seen.contains(token) {
                continue
            }
            output.append(token)
            seen.insert(token)
            if output.count >= limit {
                break
            }
        }
        return output
    }

    private func metadataSnippets(from elements: [ObservedElement], limit: Int) -> [String] {
        var snippets: [String] = []
        var seen: Set<String> = []
        for element in elements {
            let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty {
                continue
            }
            let lower = label.lowercased()
            if lower.contains("points") || lower.contains("comments") || lower.contains("ago") {
                if label.rangeOfCharacter(from: .decimalDigits) == nil {
                    continue
                }
                if seen.contains(lower) {
                    continue
                }
                snippets.append(label)
                seen.insert(lower)
                if snippets.count >= limit {
                    break
                }
            }
        }
        return snippets
    }
}
