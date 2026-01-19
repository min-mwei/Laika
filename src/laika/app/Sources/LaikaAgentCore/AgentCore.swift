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
        let initial = try await model.generatePlan(context: context, userGoal: userGoal)
        var summary = initial.summary
        var grounding = evaluateGrounding(summary: summary, context: context)
        if !grounding.isSatisfied {
            let retryGoal = buildGroundingRetryGoal(userGoal: userGoal, requiredCount: grounding.requiredCount)
            let retry = try await model.generatePlan(context: context, userGoal: retryGoal)
            summary = retry.summary
            grounding = evaluateGrounding(summary: summary, context: context)
        }
        return enforceGrounding(summary: summary, context: context, grounding: grounding, goal: userGoal)
    }

    private func postProcessSummary(_ summary: String, context: ContextPack, goal: String) -> String {
        guard context.mode == .observe else {
            return summary
        }
        let grounding = evaluateGrounding(summary: summary, context: context)
        return enforceGrounding(summary: summary, context: context, grounding: grounding, goal: goal)
    }

    private struct GroundingResult {
        let labels: [String]
        let requiredCount: Int
        let mentionedCount: Int
        let keywordMatches: Int

        var isSatisfied: Bool {
            if !labels.isEmpty {
                return mentionedCount >= requiredCount
            }
            return keywordMatches >= requiredCount
        }
    }

    private func evaluateGrounding(summary: String, context: ContextPack) -> GroundingResult {
        let labels = MainLinkHeuristics.labels(from: context.observation.elements, limit: 12)
        let requiredCount = max(1, min(3, labels.count))
        let normalizedSummary = normalizeForMatch(summary)
        let mentionedCount = countLabelMentions(summaryNormalized: normalizedSummary, labels: labels)
        if !labels.isEmpty {
            return GroundingResult(labels: labels, requiredCount: requiredCount, mentionedCount: mentionedCount, keywordMatches: 0)
        }
        let keywords = keywordCandidates(from: context.observation.text, limit: 24)
        if keywords.isEmpty {
            return GroundingResult(labels: [], requiredCount: 0, mentionedCount: 0, keywordMatches: 0)
        }
        let summaryTokens = Set(normalizeForMatch(summary).split(separator: " ").map(String.init))
        let keywordMatches = keywords.filter { summaryTokens.contains($0) }.count
        let keywordRequired = max(1, min(3, keywords.count))
        return GroundingResult(labels: [], requiredCount: keywordRequired, mentionedCount: 0, keywordMatches: keywordMatches)
    }

    private func enforceGrounding(summary: String, context: ContextPack, grounding: GroundingResult, goal: String) -> String {
        if grounding.isSatisfied {
            return summary
        }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantsContentOnly = goal.lowercased().contains("not the web site") ||
            goal.lowercased().contains("not the website") ||
            goal.lowercased().contains("not the site")
        if !grounding.labels.isEmpty {
            let examples = grounding.labels.prefix(max(grounding.requiredCount, 3)).joined(separator: "; ")
            if wantsContentOnly || trimmed.isEmpty {
                return "The page lists items such as \(examples)."
            }
            let suffix = trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?") ? " " : ". "
            return "\(trimmed)\(suffix)Items include \(examples)."
        }
        let keywords = keywordCandidates(from: context.observation.text, limit: 8)
        if keywords.isEmpty {
            return summary
        }
        let examples = keywords.prefix(max(grounding.requiredCount, 3)).joined(separator: ", ")
        if wantsContentOnly || trimmed.isEmpty {
            return "The page covers topics such as \(examples)."
        }
        let suffix = trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?") ? " " : ". "
        return "\(trimmed)\(suffix)Topics include \(examples)."
    }

    private func buildGroundingRetryGoal(userGoal: String, requiredCount: Int) -> String {
        let count = requiredCount > 0 ? requiredCount : 3
        return "\(userGoal)\n\nRequirement: Mention at least \(count) specific items from the Main Links list. If Main Links are empty, mention \(count) items from Page Text."
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

    private func keywordCandidates(from text: String, limit: Int) -> [String] {
        let normalized = normalizeForMatch(text)
        let stopwords: Set<String> = [
            "about", "after", "also", "and", "are", "back", "been", "before", "being", "between",
            "both", "but", "can", "could", "does", "each", "for", "from", "have", "into", "just",
            "more", "most", "news", "page", "people", "some", "than", "that", "the", "their", "there",
            "these", "they", "this", "those", "with", "would", "your"
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
}
