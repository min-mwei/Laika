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

public enum MessageFormat: String, Codable, Equatable, Sendable {
    case plain
    case markdown
}

public struct AgentResponse: Codable, Equatable, Sendable {
    public let summary: String
    public let actions: [AgentAction]
    public let goalPlan: GoalPlan?
    public let summaryFormat: MessageFormat

    public init(
        summary: String,
        actions: [AgentAction],
        goalPlan: GoalPlan? = nil,
        summaryFormat: MessageFormat = .plain
    ) {
        self.summary = summary
        self.actions = actions
        self.goalPlan = goalPlan
        self.summaryFormat = summaryFormat
    }
}

public final class AgentOrchestrator: @unchecked Sendable {
    private let model: ModelRunner
    private let policyGate: PolicyGate
    private var cachedListItemsByRun: [String: [ObservedItem]] = [:]
    private let cacheLock = NSLock()

    private enum SummaryFocus {
        case mainLinks
        case pageText
        case comments
    }

    private enum SummaryFormat {
        case plain
        case topicDetail
        case commentDetail
    }

    public init(model: ModelRunner, policyGate: PolicyGate = PolicyGate()) {
        self.model = model
        self.policyGate = policyGate
    }

    public func runOnce(context: ContextPack, userGoal: String) async throws -> AgentResponse {
        let goalPlan = await resolveGoalPlan(context: context, userGoal: userGoal)
        let enrichedContext = contextWithGoalPlan(context, goalPlan: goalPlan)
        cacheListItemsIfNeeded(context: enrichedContext)

        if let planned = planAction(context: enrichedContext, goalPlan: goalPlan) {
            let actions = applyPolicy(to: [planned.toolCall], context: enrichedContext)
            logPlannedAction(planned: planned, actions: actions, context: enrichedContext)
            logFinalSummary(summary: planned.summary, context: enrichedContext, goalPlan: goalPlan, source: "planned_action")
            return AgentResponse(summary: planned.summary, actions: actions, goalPlan: goalPlan, summaryFormat: .plain)
        }

        if let planned = planSummaryTool(context: enrichedContext, goalPlan: goalPlan) {
            let actions = applyPolicy(to: [planned.toolCall], context: enrichedContext)
            logPlannedAction(planned: planned, actions: actions, context: enrichedContext)
            logSummaryIntro(summary: planned.summary, context: enrichedContext, goalPlan: goalPlan)
            return AgentResponse(summary: planned.summary, actions: actions, goalPlan: goalPlan, summaryFormat: .plain)
        }

        if shouldSummarizeWithoutTools(goalPlan: goalPlan) {
            let summary = try await generateSummaryFallback(context: enrichedContext, userGoal: userGoal, goalPlan: goalPlan)
            logFinalSummary(summary: summary, context: enrichedContext, goalPlan: goalPlan, source: "summary_fallback")
            return AgentResponse(summary: summary, actions: [], goalPlan: goalPlan, summaryFormat: .markdown)
        }
        let modelResponse = try await model.generatePlan(context: enrichedContext, userGoal: userGoal)
        if shouldForceSummary(context: enrichedContext, goalPlan: goalPlan, modelResponse: modelResponse) {
            let summary = try await generateSummaryFallback(context: enrichedContext, userGoal: userGoal, goalPlan: goalPlan)
            logFinalSummary(summary: summary, context: enrichedContext, goalPlan: goalPlan, source: "summary_fallback")
            return AgentResponse(summary: summary, actions: [], goalPlan: goalPlan, summaryFormat: .markdown)
        }
        let focus = summaryFocus(context: enrichedContext, goalPlan: goalPlan)
        let format = summaryFormat(goalPlan: goalPlan)
        let summary = finalizeSummaryIfNeeded(
            modelResponse: modelResponse,
            context: enrichedContext,
            focus: focus,
            format: format
        )
        let actions = applyPolicy(to: modelResponse.toolCalls, context: enrichedContext)
        logFinalSummary(summary: summary, context: enrichedContext, goalPlan: goalPlan, source: "model_summary")
        return AgentResponse(summary: summary, actions: actions, goalPlan: goalPlan, summaryFormat: .plain)
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

    private struct TargetItem {
        let index: Int
        let title: String
        let url: String
        let handleId: String?
        let links: [ObservedItemLink]
    }

    private struct PlannedAction {
        let toolCall: ToolCall
        let summary: String
    }

    private func planSummaryTool(context: ContextPack, goalPlan: GoalPlan) -> PlannedAction? {
        guard shouldSummarizeWithoutTools(goalPlan: goalPlan) else {
            return nil
        }
        guard model is StreamingModelRunner else {
            return nil
        }
        let summary = summaryToolIntro(goalPlan: goalPlan)
        let toolCall = ToolCall(name: .contentSummarize, arguments: [:])
        return PlannedAction(toolCall: toolCall, summary: summary)
    }

    private func summaryToolIntro(goalPlan: GoalPlan) -> String {
        if goalPlan.intent == .commentSummary || goalPlan.wantsComments {
            return "Summarizing the discussion on this page."
        }
        if goalPlan.intent == .itemSummary {
            return "Summarizing the main content on this page."
        }
        return "Summarizing the page content."
    }

    public func resolveGoalPlan(context: ContextPack, userGoal: String) async -> GoalPlan {
        if let existing = context.goalPlan {
            return existing
        }
        if let deterministic = deterministicGoalPlan(context: context, userGoal: userGoal) {
            logGoalPlan(parsed: nil, resolved: deterministic, userGoal: userGoal, context: context, sourceOverride: "deterministic")
            return deterministic
        }
        do {
            let parsed = try await model.parseGoalPlan(context: context, userGoal: userGoal)
            let resolved = applyFallbackGoalPlan(parsed, context: context, userGoal: userGoal)
            logGoalPlan(parsed: parsed, resolved: resolved, userGoal: userGoal, context: context)
            return resolved
        } catch {
            logGoalPlan(parsed: nil, resolved: GoalPlan.unknown, userGoal: userGoal, context: context, sourceOverride: "parse_error")
            return GoalPlan.unknown
        }
    }

    private func contextWithGoalPlan(_ context: ContextPack, goalPlan: GoalPlan) -> ContextPack {
        if context.goalPlan == goalPlan {
            return context
        }
        return ContextPack(
            origin: context.origin,
            mode: context.mode,
            observation: context.observation,
            recentToolCalls: context.recentToolCalls,
            recentToolResults: context.recentToolResults,
            tabs: context.tabs,
            goalPlan: goalPlan,
            runId: context.runId,
            step: context.step,
            maxSteps: context.maxSteps
        )
    }

    private func shouldForceSummary(
        context: ContextPack,
        goalPlan: GoalPlan,
        modelResponse: ModelResponse
    ) -> Bool {
        guard !modelResponse.toolCalls.isEmpty else {
            return false
        }
        if goalPlan.intent == .commentSummary || goalPlan.wantsComments {
            return !context.observation.comments.isEmpty
        }
        if goalPlan.intent == .itemSummary {
            return context.observation.primary != nil || !context.observation.blocks.isEmpty
        }
        return false
    }

    private func shouldSummarizeWithoutTools(goalPlan: GoalPlan) -> Bool {
        switch goalPlan.intent {
        case .pageSummary, .itemSummary, .commentSummary:
            return true
        case .action, .unknown:
            return goalPlan.wantsComments
        }
    }

    private func applyFallbackGoalPlan(_ parsed: GoalPlan, context: ContextPack, userGoal: String) -> GoalPlan {
        if parsed.intent == .action {
            return parsed
        }
        let listLike = isListObservation(context)
            || shouldUseMainLinkFallback(context: context)
            || hasCachedListItems(context: context)
        var itemIndex = parsed.itemIndex
        let itemQuery = parsed.itemQuery
        let wantsComments = parsed.wantsComments || extractWantsComments(from: userGoal)
        if itemIndex == nil, let index = extractOrdinalIndex(from: userGoal) {
            if listLike || !context.observation.items.isEmpty {
                itemIndex = index
            }
        }
        var intent = parsed.intent
        if intent == .unknown || intent == .pageSummary {
            if wantsComments {
                intent = .commentSummary
            } else if itemIndex != nil || (itemQuery?.isEmpty == false) {
                intent = .itemSummary
            }
        }
        return GoalPlan(intent: intent, itemIndex: itemIndex, itemQuery: itemQuery, wantsComments: wantsComments)
    }

    private func logGoalPlan(
        parsed: GoalPlan?,
        resolved: GoalPlan,
        userGoal: String,
        context: ContextPack,
        sourceOverride: String? = nil
    ) {
        var payload: [String: JSONValue] = [
            "goal": .string(userGoal),
            "intent": .string(resolved.intent.rawValue),
            "wantsComments": .bool(resolved.wantsComments),
            "itemCount": .number(Double(context.observation.items.count)),
            "commentCount": .number(Double(context.observation.comments.count))
        ]
        if let index = resolved.itemIndex {
            payload["itemIndex"] = .number(Double(index))
        } else {
            payload["itemIndex"] = .null
        }
        if let query = resolved.itemQuery, !query.isEmpty {
            payload["itemQuery"] = .string(query)
        }
        let fallbackUsed = parsed.map { $0 != resolved } ?? true
        let source = sourceOverride ?? (fallbackUsed ? "fallback" : "model")
        payload["source"] = .string(source)
        if let parsed, parsed != resolved {
            payload["parsedIntent"] = .string(parsed.intent.rawValue)
            if let parsedIndex = parsed.itemIndex {
                payload["parsedItemIndex"] = .number(Double(parsedIndex))
            }
            if let parsedQuery = parsed.itemQuery, !parsedQuery.isEmpty {
                payload["parsedItemQuery"] = .string(parsedQuery)
            }
            if parsed.wantsComments != resolved.wantsComments {
                payload["parsedWantsComments"] = .bool(parsed.wantsComments)
            }
        }
        LaikaLogger.logAgentEvent(
            type: "agent.goal_plan",
            runId: context.runId,
            step: context.step,
            maxSteps: context.maxSteps,
            payload: payload
        )
    }

    private func deterministicGoalPlan(context: ContextPack, userGoal: String) -> GoalPlan? {
        let normalized = normalizeForMatch(userGoal)
        if normalized.isEmpty {
            return nil
        }
        if looksLikeActionGoal(normalized) {
            return nil
        }
        let wantsComments = extractWantsComments(from: userGoal)
        let itemIndex = extractOrdinalIndex(from: userGoal)
        let isPageSummary = isPageSummaryRequest(normalized)
        if wantsComments {
            if let index = itemIndex {
                return GoalPlan(intent: .commentSummary, itemIndex: index, itemQuery: nil, wantsComments: true)
            }
            if isPageSummary {
                return GoalPlan(intent: .commentSummary, itemIndex: nil, itemQuery: nil, wantsComments: true)
            }
            if normalized.count <= 90 {
                return GoalPlan(intent: .commentSummary, itemIndex: nil, itemQuery: nil, wantsComments: true)
            }
        }
        if let index = itemIndex {
            let listLike = isListObservation(context) || !context.observation.items.isEmpty
            if listLike && looksLikeItemSummaryGoal(normalized) {
                return GoalPlan(intent: .itemSummary, itemIndex: index, itemQuery: nil, wantsComments: false)
            }
        }
        if isPageSummary && itemIndex == nil {
            return GoalPlan(intent: .pageSummary, itemIndex: nil, itemQuery: nil, wantsComments: false)
        }
        return nil
    }

    private func looksLikeActionGoal(_ normalized: String) -> Bool {
        let hints = [
            "open",
            "click",
            "go to",
            "goto",
            "visit",
            "navigate",
            "select",
            "choose",
            "scroll",
            "reply",
            "submit"
        ]
        for hint in hints where normalized.contains(hint) {
            return true
        }
        return false
    }

    private func looksLikeItemSummaryGoal(_ normalized: String) -> Bool {
        let hints = [
            "about",
            "tell me",
            "describe",
            "explain",
            "summary",
            "summarize",
            "summarise",
            "overview",
            "topic",
            "article",
            "link",
            "story",
            "post",
            "entry",
            "subject",
            "headline"
        ]
        for hint in hints where normalized.contains(hint) {
            return true
        }
        return false
    }

    private func isPageSummaryRequest(_ normalized: String) -> Bool {
        let summaryHints = [
            "summarize",
            "summarise",
            "summary",
            "overview",
            "recap"
        ]
        for hint in summaryHints where normalized.contains(hint) {
            return true
        }
        let pageHints = [
            "this page",
            "the page",
            "page about",
            "what is this page about",
            "what is this site about",
            "what is on this page",
            "what's on this page"
        ]
        for hint in pageHints where normalized.contains(hint) {
            return true
        }
        return false
    }

    private func logPlannedAction(planned: PlannedAction, actions: [AgentAction], context: ContextPack) {
        guard let action = actions.first else {
            return
        }
        var payload: [String: JSONValue] = [
            "summary": .string(planned.summary),
            "tool": .string(action.toolCall.name.rawValue),
            "policy": .string(action.policy.decision.rawValue)
        ]
        if !action.toolCall.arguments.isEmpty {
            payload["arguments"] = .object(action.toolCall.arguments)
        }
        LaikaLogger.logAgentEvent(
            type: "agent.plan_action",
            runId: context.runId,
            step: context.step,
            maxSteps: context.maxSteps,
            payload: payload
        )
    }

    private func logFinalSummary(summary: String, context: ContextPack, goalPlan: GoalPlan, source: String) {
        let preview = truncateForLog(summary, maxChars: 360)
        let words = normalizeForMatch(summary).split(separator: " ").count
        let payload: [String: JSONValue] = [
            "summaryPreview": .string(preview),
            "summaryChars": .number(Double(summary.count)),
            "summaryWords": .number(Double(words)),
            "intent": .string(goalPlan.intent.rawValue),
            "wantsComments": .bool(goalPlan.wantsComments),
            "mode": .string(context.mode.rawValue),
            "source": .string(source)
        ]
        LaikaLogger.logAgentEvent(
            type: "agent.final_summary",
            runId: context.runId,
            step: context.step,
            maxSteps: context.maxSteps,
            payload: payload
        )
    }

    private func logSummaryIntro(summary: String, context: ContextPack, goalPlan: GoalPlan) {
        let preview = truncateForLog(summary, maxChars: 200)
        let payload: [String: JSONValue] = [
            "summaryPreview": .string(preview),
            "intent": .string(goalPlan.intent.rawValue),
            "wantsComments": .bool(goalPlan.wantsComments),
            "mode": .string(context.mode.rawValue),
            "source": .string("summary_tool_intro")
        ]
        LaikaLogger.logAgentEvent(
            type: "agent.summary_tool_intro",
            runId: context.runId,
            step: context.step,
            maxSteps: context.maxSteps,
            payload: payload
        )
    }

    private func extractWantsComments(from goal: String) -> Bool {
        let normalized = normalizeForMatch(goal)
        if normalized.isEmpty {
            return false
        }
        let hints = [
            "comment",
            "comments",
            "discussion",
            "thread",
            "threads",
            "reply",
            "replies",
            "responses"
        ]
        for hint in hints where normalized.contains(hint) {
            return true
        }
        return false
    }

    private func extractOrdinalIndex(from goal: String) -> Int? {
        let lower = goal.lowercased()
        if let numeric = extractNumericIndex(from: lower) {
            return numeric
        }
        let mapping: [(String, Int)] = [
            ("first", 1),
            ("second", 2),
            ("third", 3),
            ("fourth", 4),
            ("fifth", 5)
        ]
        for (token, value) in mapping where lower.contains(token) {
            return value
        }
        return nil
    }

    private func extractNumericIndex(from goal: String) -> Int? {
        let pattern = "(?:#|no\\.|number\\s*)?(\\d{1,2})(?:st|nd|rd|th)?"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(goal.startIndex..<goal.endIndex, in: goal)
        guard let match = regex.firstMatch(in: goal, options: [], range: range),
              match.numberOfRanges >= 2,
              let indexRange = Range(match.range(at: 1), in: goal)
        else {
            return nil
        }
        let value = Int(goal[indexRange]) ?? 0
        return value > 0 ? value : nil
    }

    private func planAction(context: ContextPack, goalPlan: GoalPlan) -> PlannedAction? {
        let intent = goalPlan.intent
        guard intent == .itemSummary || intent == .commentSummary || intent == .action else {
            return nil
        }
        if intent == .itemSummary, hasRecentItemNavigation(context: context) {
            return nil
        }
        guard let target = selectTargetItem(context: context, goalPlan: goalPlan) else {
            return nil
        }
        if intent == .commentSummary || goalPlan.wantsComments {
            if let commentLink = selectCommentLink(from: target, context: context) {
                if !isSameURL(context.observation.url, commentLink.url) {
                    let summary = "Opening discussion for item \(target.index): \(target.title)."
                    let toolCall = ToolCall(name: .browserOpenTab, arguments: ["url": .string(commentLink.url)])
                    return PlannedAction(toolCall: toolCall, summary: summary)
                }
                return nil
            }
        }
        if isSameURL(context.observation.url, target.url) {
            return nil
        }
        let summary = "Opening item \(target.index): \(target.title)."
        let toolCall = ToolCall(name: .browserOpenTab, arguments: ["url": .string(target.url)])
        return PlannedAction(toolCall: toolCall, summary: summary)
    }

    private func selectTargetItem(context: ContextPack, goalPlan: GoalPlan) -> TargetItem? {
        let items = resolvedItemCandidates(context: context)
        if let index = goalPlan.itemIndex, index > 0 {
            if items.count >= index {
                let item = items[index - 1]
                return TargetItem(index: index, title: item.title, url: item.url, handleId: item.handleId, links: item.links)
            }
            if shouldUseMainLinkFallback(context: context) {
                let fallbackLinks = MainLinkHeuristics.candidates(from: context.observation.elements)
                if fallbackLinks.count >= index {
                    let link = fallbackLinks[index - 1]
                    return TargetItem(index: index, title: link.label, url: link.href ?? "", handleId: link.handleId, links: [])
                }
            }
        }
        if let query = goalPlan.itemQuery, !query.isEmpty {
            if let match = matchItem(query: query, items: items) {
                return match
            }
        }
        return nil
    }

    private func resolvedItemCandidates(context: ContextPack) -> [ObservedItem] {
        if isListObservation(context) {
            return context.observation.items
        }
        guard let runId = context.runId, !runId.isEmpty else {
            return context.observation.items
        }
        if let cached = cachedListItems(for: runId), !cached.isEmpty {
            return cached
        }
        return context.observation.items
    }

    private func hasCachedListItems(context: ContextPack) -> Bool {
        guard let runId = context.runId, !runId.isEmpty else {
            return false
        }
        guard let cached = cachedListItems(for: runId) else {
            return false
        }
        return !cached.isEmpty
    }

    private func isListObservation(_ context: ContextPack) -> Bool {
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

    private func cacheListItemsIfNeeded(context: ContextPack) {
        guard let runId = context.runId, !runId.isEmpty else {
            return
        }
        guard isListObservation(context) else {
            return
        }
        cacheLock.lock()
        cachedListItemsByRun[runId] = context.observation.items
        cacheLock.unlock()
    }

    private func cachedListItems(for runId: String) -> [ObservedItem]? {
        cacheLock.lock()
        let items = cachedListItemsByRun[runId]
        cacheLock.unlock()
        return items
    }

    private func shouldUseMainLinkFallback(context: ContextPack) -> Bool {
        if !context.observation.items.isEmpty {
            return false
        }
        let primaryChars = context.observation.primary?.text.count ?? 0
        if primaryChars >= 400 {
            return false
        }
        if context.observation.blocks.count >= 8 && primaryChars >= 200 {
            return false
        }
        let candidates = MainLinkHeuristics.candidates(from: context.observation.elements)
        return candidates.count >= 3
    }

    private func hasRecentItemNavigation(context: ContextPack) -> Bool {
        guard let lastURL = lastNavigationURL(from: context) else {
            return false
        }
        return isSameURL(context.observation.url, lastURL)
    }

    private func lastNavigationURL(from context: ContextPack) -> String? {
        for call in context.recentToolCalls.reversed() {
            if call.name != .browserOpenTab && call.name != .browserNavigate {
                continue
            }
            if case let .string(url)? = call.arguments["url"] {
                if !url.isEmpty {
                    return url
                }
            }
        }
        return nil
    }

    private func matchItem(query: String, items: [ObservedItem]) -> TargetItem? {
        let normalizedQuery = normalizeForMatch(query)
        guard !normalizedQuery.isEmpty else {
            return nil
        }
        for (index, item) in items.enumerated() {
            let normalizedTitle = normalizeForMatch(item.title)
            if normalizedTitle.contains(normalizedQuery) {
                return TargetItem(index: index + 1, title: item.title, url: item.url, handleId: item.handleId, links: item.links)
            }
        }
        return nil
    }

    private func selectCommentLink(from target: TargetItem, context: ContextPack) -> ObservedItemLink? {
        let candidates = target.links.filter { !$0.url.isEmpty && $0.url != target.url }
        if candidates.isEmpty {
            return nil
        }
        let originHost = hostForURL(context.observation.url)
        let targetHost = hostForURL(target.url)
        let scored = candidates.map { link -> (ObservedItemLink, Int) in
            var score = 0
            score += commentSignalScore(text: link.title, url: link.url)
            let linkHost = hostForURL(link.url)
            if !originHost.isEmpty && linkHost == originHost {
                score += 2
            }
            if !targetHost.isEmpty && linkHost != targetHost {
                score += 1
            }
            if link.title.rangeOfCharacter(from: .decimalDigits) != nil {
                score += 1
            }
            return (link, score)
        }
        let sorted = scored.sorted { lhs, rhs in
            if lhs.1 == rhs.1 {
                return lhs.0.title.count < rhs.0.title.count
            }
            return lhs.1 > rhs.1
        }
        return sorted.first?.0 ?? candidates.first
    }

    private func commentSignalScore(text: String, url: String) -> Int {
        let lowerText = text.lowercased()
        let lowerURL = url.lowercased()
        let signals = ["comment", "comments", "discussion", "discuss", "thread", "reply", "replies"]
        if signals.contains(where: { lowerText.contains($0) }) {
            return 5
        }
        if signals.contains(where: { lowerURL.contains($0) }) {
            return 4
        }
        return 0
    }

    private func hostForURL(_ raw: String) -> String {
        guard let url = URL(string: raw), let host = url.host?.lowercased() else {
            return ""
        }
        return host
    }

    private func isSameURL(_ left: String, _ right: String) -> Bool {
        let normalizedLeft = normalizeURL(left)
        let normalizedRight = normalizeURL(right)
        return !normalizedLeft.isEmpty && normalizedLeft == normalizedRight
    }

    private func normalizeURL(_ raw: String) -> String {
        guard let url = URL(string: raw) else {
            return raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        components.fragment = nil
        let normalized = components.url?.absoluteString ?? raw
        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func generateSummaryFallback(context: ContextPack, userGoal: String, goalPlan: GoalPlan) async throws -> String {
        let format = summaryFormat(goalPlan: goalPlan)
        let summaryService = SummaryService(model: model)
        do {
            let summary = try await summaryService.summarize(
                context: context,
                goalPlan: goalPlan,
                userGoal: userGoal,
                maxTokens: nil
            )
            if !summary.isEmpty {
                return summary
            }
        } catch {
        }
        return buildSummaryFallback(format: format, context: context)
    }

    private func finalizeSummaryIfNeeded(
        modelResponse: ModelResponse,
        context: ContextPack,
        focus: SummaryFocus,
        format: SummaryFormat
    ) -> String {
        let trimmed = modelResponse.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !modelResponse.toolCalls.isEmpty {
            if !trimmed.isEmpty {
                return trimmed
            }
            if let actionSummary = summarizeToolCalls(modelResponse.toolCalls, context: context) {
                return actionSummary
            }
            return buildStructuredFallback(format: format, context: context)
        }
        let grounding = evaluateGrounding(summary: trimmed, context: context, focus: focus)
        var output = enforceGrounding(
            summary: trimmed,
            context: context,
            grounding: grounding,
            focus: focus
        )
        let headings = requiredHeadings(for: format)
        if !headings.isEmpty && !containsHeadings(output, headings: headings) {
            if let structured = structuredSummaryFromText(output, format: format, context: context) {
                output = structured
            } else {
                output = buildStructuredFallback(format: format, context: context)
            }
        }
        return output
    }

    private func summarizeToolCalls(_ toolCalls: [ToolCall], context: ContextPack) -> String? {
        guard let call = toolCalls.first else {
            return nil
        }
        switch call.name {
        case .browserOpenTab, .browserNavigate:
            if case let .string(url)? = call.arguments["url"] {
                if let title = titleForURL(url, context: context) {
                    return "Opening: \(title)."
                }
                if !url.isEmpty {
                    return "Opening \(url)."
                }
            }
            return "Opening the requested page."
        case .browserClick:
            if case let .string(handleId)? = call.arguments["handleId"] {
                if let label = labelForHandle(handleId, context: context) {
                    return "Clicking '\(label)'."
                }
            }
            return "Clicking the requested element."
        case .browserType:
            if case let .string(handleId)? = call.arguments["handleId"] {
                if let label = labelForHandle(handleId, context: context) {
                    return "Entering text into '\(label)'."
                }
            }
            return "Entering text."
        case .browserSelect:
            if case let .string(handleId)? = call.arguments["handleId"] {
                if let label = labelForHandle(handleId, context: context) {
                    return "Selecting an option in '\(label)'."
                }
            }
            return "Selecting an option."
        case .browserScroll:
            return "Scrolling to see more content."
        case .browserObserveDom:
            return "Reading the page for more detail."
        case .contentSummarize:
            return summaryToolIntro(goalPlan: context.goalPlan ?? .unknown)
        case .browserBack:
            return "Going back to the previous page."
        case .browserForward:
            return "Going forward."
        case .browserRefresh:
            return "Refreshing the page."
        }
    }

    private func labelForHandle(_ handleId: String, context: ContextPack) -> String? {
        guard !handleId.isEmpty else {
            return nil
        }
        if let element = context.observation.elements.first(where: { $0.handleId == handleId }) {
            let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty {
                return label
            }
        }
        return nil
    }

    private func titleForURL(_ url: String, context: ContextPack) -> String? {
        let normalizedTarget = normalizeURL(url)
        for item in context.observation.items {
            if normalizeURL(item.url) == normalizedTarget {
                return item.title
            }
            for link in item.links {
                if normalizeURL(link.url) == normalizedTarget {
                    let title = link.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty {
                        return title
                    }
                }
            }
        }
        let candidates = MainLinkHeuristics.candidates(from: context.observation.elements)
        for element in candidates {
            guard let href = element.href else {
                continue
            }
            if normalizeURL(href) == normalizedTarget {
                return element.label
            }
        }
        return nil
    }

    private struct GroundingResult {
        let anchors: [String]
        let requiredCount: Int
        let mentionedCount: Int
        let wordCount: Int
        let minWordCount: Int

        var isSatisfied: Bool {
            if minWordCount > 0 && wordCount < minWordCount {
                return false
            }
            if !anchors.isEmpty {
                return mentionedCount >= requiredCount
            }
            return true
        }
    }

    private func evaluateGrounding(summary: String, context: ContextPack, focus: SummaryFocus) -> GroundingResult {
        let wordCount = normalizeForMatch(summary).split(separator: " ").count
        let minWordCount = minimumWordCount(for: context, focus: focus)
        let normalizedSummary = normalizeForMatch(summary)

        if focus == .mainLinks {
            let anchors = itemAnchors(from: context, limit: 12)
            let requiredCount = mainLinkRequirement(count: anchors.count)
            let mentionedCount = countPhraseMentions(summaryNormalized: normalizedSummary, phrases: anchors)
            return GroundingResult(
                anchors: anchors,
                requiredCount: requiredCount,
                mentionedCount: mentionedCount,
                wordCount: wordCount,
                minWordCount: minWordCount
            )
        }

        let blockText = combinedBlockText(from: context)
        let commentsText = context.observation.comments.map { $0.text }.joined(separator: " ")
        let sourceText: String
        if focus == .comments, !commentsText.isEmpty {
            sourceText = commentsText
        } else {
            sourceText = blockText.isEmpty ? context.observation.text : blockText
        }
        let anchors = anchorPhrases(from: sourceText, title: context.observation.title, limit: 6)
        if anchors.isEmpty {
            return GroundingResult(
                anchors: [],
                requiredCount: 0,
                mentionedCount: 0,
                wordCount: wordCount,
                minWordCount: minWordCount
            )
        }
        let requiredCount = max(1, min(3, anchors.count))
        let mentionedCount = countPhraseMentions(summaryNormalized: normalizedSummary, phrases: anchors)
        return GroundingResult(
            anchors: anchors,
            requiredCount: requiredCount,
            mentionedCount: mentionedCount,
            wordCount: wordCount,
            minWordCount: minWordCount
        )
    }

    private func enforceGrounding(
        summary: String,
        context: ContextPack,
        grounding: GroundingResult,
        focus: SummaryFocus
    ) -> String {
        if grounding.isSatisfied {
            if focus == .mainLinks {
                let details = itemDetailSnippets(from: context, limit: 4)
                if !details.isEmpty && grounding.wordCount < (grounding.minWordCount + 10) {
                    let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    let suffix = trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?") ? " " : ". "
                    return trimmed + suffix + "Top items: \(details.joined(separator: "; "))."
                }
            }
            return summary
        }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if focus == .mainLinks {
            let anchors = grounding.anchors.isEmpty ? itemAnchors(from: context, limit: 10) : grounding.anchors
            let details = itemDetailSnippets(from: context, limit: 4)
            let exampleCount = min(max(grounding.requiredCount, 3), anchors.count)
            let examples = anchors.prefix(exampleCount).joined(separator: "; ")
            let totalCount = itemAnchorCount(from: context)
            let countText = totalCount > 0 ? "\(totalCount) items" : "multiple items"
            if trimmed.isEmpty {
                var fallback = "The page lists \(countText)."
                if !details.isEmpty {
                    fallback += " Top items: \(details.joined(separator: "; "))."
                } else if !examples.isEmpty {
                    fallback += " Notable items include \(examples)."
                }
                return fallback
            }
            var output = trimmed
            let suffix = output.hasSuffix(".") || output.hasSuffix("!") || output.hasSuffix("?") ? " " : ". "
            if !details.isEmpty {
                output += "\(suffix)Top items: \(details.joined(separator: "; "))."
            } else if !examples.isEmpty {
                output += "\(suffix)Notable items include \(examples)."
            }
            return output
        }
        if focus == .comments {
            let excerpts = blockExcerpts(from: context, limit: 4)
            let joined = excerpts.joined(separator: "; ")
            if trimmed.isEmpty {
                let themes = joined.isEmpty ? "Not stated in the page." : joined
                return "Comment themes include: \(themes)."
            }
            var output = trimmed
            if !joined.isEmpty {
                let suffix = output.hasSuffix(".") || output.hasSuffix("!") || output.hasSuffix("?") ? " " : ". "
                output += "\(suffix)Comment themes include: \(joined)."
            }
            return output
        }
        let anchors = grounding.anchors.isEmpty
            ? anchorPhrases(from: context.observation.text, title: context.observation.title, limit: 6)
            : grounding.anchors
        if anchors.isEmpty {
            return summary
        }
        let examples = anchors.prefix(max(grounding.requiredCount, 4)).joined(separator: "; ")
        if trimmed.isEmpty {
            return "The page covers topics such as \(examples)."
        }
        let suffix = trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?") ? " " : ". "
        return "\(trimmed)\(suffix)Topics include \(examples)."
    }

    private func buildGroundingRetryGoal(userGoal: String, requiredCount: Int, focus: SummaryFocus) -> String {
        let count = requiredCount > 0 ? requiredCount : 3
        let requirement: String
        switch focus {
        case .mainLinks:
            requirement = "Mention at least \(count) specific items from Items or Link candidates. Include visible numbers when available."
        case .pageText:
            requirement = "Mention at least \(count) specific points from Page Text. Provide more detail than a short list."
        case .comments:
            requirement = "Mention at least \(count) distinct points from the comment text. Provide more detail than a short list."
        }
        return "\(userGoal)\n\nRequirement: \(requirement)"
    }

    private func countPhraseMentions(summaryNormalized: String, phrases: [String]) -> Int {
        var count = 0
        for phrase in phrases {
            let normalized = normalizeForMatch(phrase)
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

    private func summaryFocus(context: ContextPack, goalPlan: GoalPlan) -> SummaryFocus {
        if goalPlan.intent == .commentSummary || goalPlan.wantsComments {
            return .comments
        }
        if goalPlan.intent == .itemSummary {
            return .pageText
        }
        if !context.observation.items.isEmpty || shouldUseMainLinkFallback(context: context) {
            return .mainLinks
        }
        return .pageText
    }

    private func summaryFormat(goalPlan: GoalPlan) -> SummaryFormat {
        if goalPlan.intent == .commentSummary || goalPlan.wantsComments {
            return .commentDetail
        }
        if goalPlan.intent == .itemSummary {
            return .topicDetail
        }
        return .plain
    }

    private func requiredHeadings(for format: SummaryFormat) -> [String] {
        switch format {
        case .plain:
            return []
        case .topicDetail:
            return [
                "Topic overview:",
                "What it is:",
                "Key points:",
                "Why it is notable:",
                "Optional next step:"
            ]
        case .commentDetail:
            return [
                "Comment themes:",
                "Notable contributors or tools:",
                "Technical clarifications or Q&A:",
                "Reactions or viewpoints:"
            ]
        }
    }

    private func containsHeadings(_ summary: String, headings: [String]) -> Bool {
        let lower = summary.lowercased()
        for heading in headings {
            let normalized = heading.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty {
                continue
            }
            let raw = normalized.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            if !lower.contains(normalized) && !lower.contains(raw) {
                return false
            }
        }
        return true
    }

    private func buildHeadingRetryGoal(userGoal: String, headings: [String]) -> String {
        let joined = headings.joined(separator: " ")
        return "\(userGoal)\n\nRequirement: Use headings exactly as listed: \(joined)"
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
            minimum = 30
        } else if textCount < 1200 {
            minimum = 50
        } else if textCount < 2400 {
            minimum = 70
        } else {
            minimum = 90
        }
        if focus == .pageText {
            minimum += 15
        } else if focus == .comments {
            minimum += 25
        }
        return minimum
    }

    private func itemAnchors(from context: ContextPack, limit: Int) -> [String] {
        if limit <= 0 {
            return []
        }
        var output: [String] = []
        var seen: Set<String> = []
        for item in context.observation.items {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty {
                continue
            }
            let key = title.lowercased()
            if seen.contains(key) {
                continue
            }
            seen.insert(key)
            output.append(title)
            if output.count >= limit {
                break
            }
        }
        if !output.isEmpty {
            return output
        }
        let fallback = MainLinkHeuristics.labels(from: context.observation.elements, limit: limit)
        return fallback
    }

    private func itemAnchorCount(from context: ContextPack) -> Int {
        if !context.observation.items.isEmpty {
            return context.observation.items.count
        }
        return MainLinkHeuristics.candidates(from: context.observation.elements).count
    }

    private func anchorPhrases(from text: String, title: String, limit: Int) -> [String] {
        if limit <= 0 {
            return []
        }
        return TextUtils.firstSentences(text, maxItems: limit, minLength: 32, maxLength: 240)
    }

    private func metricSnippets(from elements: [ObservedElement], limit: Int) -> [String] {
        if limit <= 0 {
            return []
        }
        var snippets: [String] = []
        var seen: Set<String> = []
        for element in elements {
            let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty {
                continue
            }
            if label.rangeOfCharacter(from: .decimalDigits) == nil {
                continue
            }
            if label.count > 32 {
                continue
            }
            let key = label.lowercased()
            if seen.contains(key) {
                continue
            }
            seen.insert(key)
            snippets.append(label)
            if snippets.count >= limit {
                break
            }
        }
        return snippets
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

    private func itemDetailSnippets(from context: ContextPack, limit: Int) -> [String] {
        if limit <= 0 {
            return []
        }
        var output: [String] = []
        var seen: Set<String> = []
        for item in context.observation.items {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty {
                continue
            }
            let key = title.lowercased()
            if seen.contains(key) {
                continue
            }
            seen.insert(key)
            let snippet = SnippetFormatter.format(
                item.snippet,
                title: title,
                maxChars: 180
            )
            if snippet.isEmpty {
                output.append(title)
            } else {
                output.append("\(title): \(snippet)")
            }
            if output.count >= limit {
                break
            }
        }
        return output
    }

    private func truncateText(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else {
            return text
        }
        return String(text.prefix(maxChars)) + "…"
    }

    private func truncateForLog(_ text: String, maxChars: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return truncateText(trimmed, maxChars: maxChars)
    }

    private func buildStructuredFallback(format: SummaryFormat, context: ContextPack) -> String {
        return buildSummaryFallback(format: format, context: context)
    }

    private func buildSummaryFallback(format: SummaryFormat, context: ContextPack) -> String {
        let input = SummaryInputBuilder.build(context: context, goalPlan: context.goalPlan ?? .unknown)
        let baseText = input.text
        let sentences = TextUtils.firstSentences(baseText, maxItems: 5, minLength: 24, maxLength: 280)
        let title = context.observation.title
        let url = context.observation.url

        switch format {
        case .topicDetail:
            let overview = buildOverview(title: title, url: url, fallback: "Topic at \(url).")
            let whatItIs = sentences.first ?? "Not stated in the page."
            let keyPoints = sentences.dropFirst().prefix(2).joined(separator: " ")
            let notable = pickNotableSentence(from: sentences) ?? "Not stated in the page."
            let nextStep = "Ask for comments or a deeper technical breakdown."
            return [
                "Topic overview: \(overview)",
                "What it is: \(whatItIs)",
                "Key points: \(keyPoints.isEmpty ? "Not stated in the page." : keyPoints)",
                "Why it is notable: \(notable)",
                "Optional next step: \(nextStep)"
            ].joined(separator: "\n")
        case .commentDetail:
            let themes = sentences.first ?? "Not stated in the page."
            let authors = collectCommentAuthors(from: context, limit: 4)
            let contributors = authors.isEmpty ? "Not stated in the page." : authors.joined(separator: ", ")
            let clarifications = sentences.dropFirst().first ?? "Not stated in the page."
            let reactions = pickNotableSentence(from: sentences) ?? "Not stated in the page."
            return [
                "Comment themes: \(themes)",
                "Notable contributors or tools: \(contributors)",
                "Technical clarifications or Q&A: \(clarifications)",
                "Reactions or viewpoints: \(reactions)"
            ].joined(separator: "\n")
        case .plain:
            if input.kind == .list {
                let lines = baseText.split(separator: "\n").map { String($0) }
                let bodyLines = lines.filter { !$0.hasPrefix("Title:") && !$0.hasPrefix("URL:") }
                let preview = bodyLines.prefix(6).joined(separator: " ")
                if !preview.isEmpty {
                    return preview
                }
            }
            return sentences.joined(separator: " ")
        }
    }

    private func structuredSummaryFromText(_ summary: String, format: SummaryFormat, context: ContextPack) -> String? {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        switch format {
        case .topicDetail:
            let sentences = TextUtils.firstSentences(trimmed, maxItems: 5, minLength: 24, maxLength: 280)
            let overview = buildOverview(title: context.observation.title, url: context.observation.url, fallback: "Topic at \(context.observation.url).")
            let whatItIs = sentences.first ?? trimmed
            let keyPoints = sentences.dropFirst().prefix(2).joined(separator: " ")
            let notable = pickNotableSentence(from: sentences) ?? "Not stated in the page."
            let nextStep = "Ask for comments or a deeper technical breakdown."
            return [
                "Topic overview: \(overview)",
                "What it is: \(whatItIs)",
                "Key points: \(keyPoints.isEmpty ? "Not stated in the page." : keyPoints)",
                "Why it is notable: \(notable)",
                "Optional next step: \(nextStep)"
            ].joined(separator: "\n")
        case .commentDetail:
            let sentences = TextUtils.firstSentences(trimmed, maxItems: 4, minLength: 24, maxLength: 280)
            let themes = sentences.first ?? trimmed
            let authors = collectCommentAuthors(from: context, limit: 4)
            let contributors = authors.isEmpty ? "Not stated in the page." : authors.joined(separator: ", ")
            let clarifications = sentences.dropFirst().first ?? "Not stated in the page."
            let reactions = pickNotableSentence(from: sentences) ?? "Not stated in the page."
            return [
                "Comment themes: \(themes)",
                "Notable contributors or tools: \(contributors)",
                "Technical clarifications or Q&A: \(clarifications)",
                "Reactions or viewpoints: \(reactions)"
            ].joined(separator: "\n")
        case .plain:
            return trimmed
        }
    }

    private func buildOverview(title: String, url: String, fallback: String) -> String {
        if !title.isEmpty && !url.isEmpty {
            return "\(title) (\(url))."
        }
        if !title.isEmpty {
            return title
        }
        if !url.isEmpty {
            return fallback
        }
        return "Not stated in the page."
    }

    private func pickNotableSentence(from sentences: [String]) -> String? {
        for sentence in sentences {
            if sentence.rangeOfCharacter(from: .decimalDigits) != nil {
                return sentence
            }
        }
        return sentences.sorted { $0.count > $1.count }.first ?? sentences.first
    }

    private func collectCommentAuthors(from context: ContextPack, limit: Int) -> [String] {
        if limit <= 0 {
            return []
        }
        var seen: Set<String> = []
        var output: [String] = []
        for comment in context.observation.comments {
            guard let author = comment.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty else {
                continue
            }
            let key = author.lowercased()
            if seen.contains(key) {
                continue
            }
            seen.insert(key)
            output.append(author)
            if output.count >= limit {
                break
            }
        }
        return output
    }

}
