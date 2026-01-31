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
    public let assistant: AssistantMessage
    public let actions: [AgentAction]
    public let goalPlan: GoalPlan?

    public init(
        summary: String,
        assistant: AssistantMessage,
        actions: [AgentAction],
        goalPlan: GoalPlan? = nil
    ) {
        self.summary = summary
        self.assistant = assistant
        self.actions = actions
        self.goalPlan = goalPlan
    }
}

public final class AgentOrchestrator: @unchecked Sendable {
    private let model: ModelRunner
    private let policyGate: PolicyGate
    private var cachedListItemsByRun: [String: [ObservedItem]] = [:]
    private var lastListItems: [ObservedItem] = []
    private var lastListOrigin: String = ""
    private let cacheLock = NSLock()
    private static let debugEnabled: Bool = {
        guard let raw = ProcessInfo.processInfo.environment["LAIKA_DEBUG"]?.lowercased() else {
            return false
        }
        if raw == "1" || raw == "true" || raw == "yes" {
            return true
        }
        return false
    }()
    private static let commentCountRegex: NSRegularExpression = {
        let pattern = "(\\d[\\d,]*)\\s*(comments?|repl(?:y|ies))"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private enum SummaryFocus {
        case mainLinks
        case pageText
        case comments
    }

    private enum SummaryFormat {
        case plain
        case pageSummary
        case topicDetail
        case commentDetail
    }

    private struct ResolvedItems {
        let items: [ObservedItem]
        let source: String
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
            return AgentResponse(
                summary: planned.summary,
                assistant: assistantFromSummary(planned.summary),
                actions: actions,
                goalPlan: goalPlan
            )
        }

        if let planned = planSelectionLinksTool(context: enrichedContext, userGoal: userGoal) {
            let actions = applyPolicy(to: [planned.toolCall], context: enrichedContext)
            logPlannedAction(planned: planned, actions: actions, context: enrichedContext)
            logFinalSummary(summary: planned.summary, context: enrichedContext, goalPlan: goalPlan, source: "planned_action")
            return AgentResponse(
                summary: planned.summary,
                assistant: assistantFromSummary(planned.summary),
                actions: actions,
                goalPlan: goalPlan
            )
        }

        if let response = answerSelectionLinksIfAvailable(context: enrichedContext, userGoal: userGoal, goalPlan: goalPlan) {
            return response
        }

        if let planned = planSearchTool(context: enrichedContext, userGoal: userGoal) {
            let actions = applyPolicy(to: [planned.toolCall], context: enrichedContext)
            logPlannedAction(planned: planned, actions: actions, context: enrichedContext)
            logFinalSummary(summary: planned.summary, context: enrichedContext, goalPlan: goalPlan, source: "planned_action")
            return AgentResponse(
                summary: planned.summary,
                assistant: assistantFromSummary(planned.summary),
                actions: actions,
                goalPlan: goalPlan
            )
        }
        let modelResponse = try await model.generatePlan(context: enrichedContext, userGoal: userGoal)
        if modelResponse.toolCalls.isEmpty,
           let planned = planSearchTool(context: enrichedContext, userGoal: userGoal) {
            let actions = applyPolicy(to: [planned.toolCall], context: enrichedContext)
            logPlannedAction(planned: planned, actions: actions, context: enrichedContext)
            logFinalSummary(summary: planned.summary, context: enrichedContext, goalPlan: goalPlan, source: "planned_action")
            return AgentResponse(
                summary: planned.summary,
                assistant: assistantFromSummary(planned.summary),
                actions: actions,
                goalPlan: goalPlan
            )
        }
        if shouldForceSummary(context: enrichedContext, goalPlan: goalPlan, modelResponse: modelResponse) {
            let summary = try await generateSummaryFallback(context: enrichedContext, userGoal: userGoal, goalPlan: goalPlan)
            logFinalSummary(summary: summary, context: enrichedContext, goalPlan: goalPlan, source: "summary_fallback")
            return AgentResponse(
                summary: summary,
                assistant: assistantFromSummary(summary),
                actions: [],
                goalPlan: goalPlan
            )
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
        let assistant = assistantForModelResponse(modelResponse, summary: summary)
        logFinalSummary(summary: summary, context: enrichedContext, goalPlan: goalPlan, source: "model_summary")
        return AgentResponse(summary: summary, assistant: assistant, actions: actions, goalPlan: goalPlan)
    }

    private func applyPolicy(to toolCalls: [ToolCall], context: ContextPack) -> [AgentAction] {
        return toolCalls.map { toolCall in
            let policyContext = PolicyContext(
                origin: context.origin,
                mode: context.mode,
                fieldKind: fieldKindForToolCall(toolCall, context: context)
            )
            let decision = policyGate.decide(for: toolCall, context: policyContext)
            return AgentAction(toolCall: toolCall, policy: decision)
        }
    }

    private func fieldKindForToolCall(_ toolCall: ToolCall, context: ContextPack) -> FieldKind {
        switch toolCall.name {
        case .browserType, .browserSelect:
            guard case let .string(handleId)? = toolCall.arguments["handleId"] else {
                return .unknown
            }
            guard let element = context.observation.elements.first(where: { $0.handleId == handleId }) else {
                return .unknown
            }
            return classifyFieldKind(element)
        default:
            return .unknown
        }
    }

    private func classifyFieldKind(_ element: ObservedElement) -> FieldKind {
        let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let inputType = (element.inputType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if inputType == "password" || containsAny(label, tokens: Self.credentialFieldTokens) {
            return .credential
        }
        if matchesPaymentField(label: label, inputType: inputType) {
            return .payment
        }
        if matchesPersonalIdField(label: label, inputType: inputType) {
            return .personalId
        }
        return .unknown
    }

    private func matchesPaymentField(label: String, inputType: String) -> Bool {
        if containsAny(label, tokens: Self.paymentFieldTokens) {
            return true
        }
        if inputType == "number" && containsAny(label, tokens: Self.paymentNumberTokens) {
            return true
        }
        return false
    }

    private func matchesPersonalIdField(label: String, inputType: String) -> Bool {
        if inputType == "email" {
            return true
        }
        if inputType == "tel" && containsAny(label, tokens: Self.phoneFieldTokens) {
            return true
        }
        return containsAny(label, tokens: Self.personalIdFieldTokens)
    }

    private func containsAny(_ text: String, tokens: [String]) -> Bool {
        guard !text.isEmpty else {
            return false
        }
        for token in tokens {
            if text.contains(token) {
                return true
            }
        }
        return false
    }

    private static let credentialFieldTokens = [
        "password",
        "passcode",
        "pin",
        "one-time",
        "otp",
        "verification",
        "auth code"
    ]
    private static let paymentFieldTokens = [
        "card",
        "credit",
        "debit",
        "cvv",
        "cvc",
        "security code",
        "expiration",
        "expiry",
        "exp date",
        "billing",
        "iban",
        "routing",
        "account number",
        "bank account"
    ]
    private static let paymentNumberTokens = [
        "card",
        "cvv",
        "cvc",
        "expiration",
        "expiry",
        "exp"
    ]
    private static let personalIdFieldTokens = [
        "email",
        "e-mail",
        "phone",
        "mobile",
        "ssn",
        "social security",
        "passport",
        "driver",
        "license",
        "tax id",
        "ein",
        "national id",
        "birth",
        "dob"
    ]
    private static let phoneFieldTokens = [
        "phone",
        "mobile",
        "cell"
    ]

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

    private func planSearchTool(context: ContextPack, userGoal: String) -> PlannedAction? {
        guard let intent = extractSearchIntent(from: userGoal) else {
            return nil
        }
        if Self.debugEnabled {
            let payload: [String: JSONValue] = [
                "query": .string(truncateForLog(intent.query, maxChars: 160)),
                "engine": .string(intent.engine ?? ""),
                "goal": .string(truncateForLog(userGoal, maxChars: 160))
            ]
            logDebugEvent("search_intent", context: context, payload: payload)
        }
        if let lastSearch = mostRecentSearchCall(context) {
            let lastQuery = extractSearchQuery(from: lastSearch)
            if lastQuery == intent.query {
                let blockReason = searchBlockReason(context.observation)
                if shouldRetrySearch(intent: intent, lastSearch: lastSearch, blockReason: blockReason) {
                    if Self.debugEnabled {
                        let payload: [String: JSONValue] = [
                            "reason": .string(blockReason ?? "unknown"),
                            "fromEngine": .string(extractSearchEngine(from: lastSearch) ?? ""),
                            "toEngine": .string("duckduckgo"),
                            "url": .string(truncateForLog(context.observation.url, maxChars: 200))
                        ]
                        logDebugEvent("search_retry", context: context, payload: payload)
                    }
                    return buildSearchAction(query: intent.query, engine: "duckduckgo", summaryPrefix: "Search blocked")
                }
                if Self.debugEnabled {
                    let payload: [String: JSONValue] = [
                        "reason": .string("duplicate_query"),
                        "engine": .string(extractSearchEngine(from: lastSearch) ?? "")
                    ]
                    logDebugEvent("search_skip", context: context, payload: payload)
                }
                return nil
            }
        }
        var arguments: [String: JSONValue] = [
            "query": .string(intent.query),
            "newTab": .bool(true)
        ]
        if let engine = intent.engine, !engine.isEmpty {
            arguments["engine"] = .string(engine)
        }
        let summary = buildSearchSummary(query: intent.query, engine: intent.engine, newTab: true)
        let toolCall = ToolCall(name: .search, arguments: arguments)
        return PlannedAction(toolCall: toolCall, summary: summary)
    }

    private func planSelectionLinksTool(context: ContextPack, userGoal: String) -> PlannedAction? {
        let normalized = normalizeForMatch(userGoal)
        guard !normalized.isEmpty else {
            return nil
        }
        let triggers = [
            "get selection links",
            "selection links",
            "selected links"
        ]
        var matched = false
        for trigger in triggers where normalized.contains(trigger) {
            matched = true
            break
        }
        guard matched else {
            return nil
        }
        if let lastCall = context.recentToolCalls.last, lastCall.name == .browserGetSelectionLinks {
            return nil
        }
        return PlannedAction(
            toolCall: ToolCall(name: .browserGetSelectionLinks, arguments: [:]),
            summary: "Collecting the selected links."
        )
    }

    private func answerSelectionLinksIfAvailable(context: ContextPack, userGoal: String, goalPlan: GoalPlan) -> AgentResponse? {
        guard shouldAnswerSelectionLinks(from: userGoal) else {
            return nil
        }
        guard let urls = selectionLinksFromRecentResults(context: context) else {
            return nil
        }

        var lines: [String] = []
        lines.append("Selected links (\(urls.count)):")
        for (index, url) in urls.prefix(50).enumerated() {
            lines.append("\(index + 1). \(url)")
        }
        if urls.count > 50 {
            lines.append("…")
        }
        lines.append("Note: non-http(s) links (e.g., mailto:) are omitted by design.")

        let summary = lines.joined(separator: "\n")
        logFinalSummary(summary: summary, context: context, goalPlan: goalPlan, source: "selection_links_answer")
        return AgentResponse(summary: summary, assistant: assistantFromSummary(summary), actions: [], goalPlan: goalPlan)
    }

    private func shouldAnswerSelectionLinks(from goal: String) -> Bool {
        let normalized = normalizeForMatch(goal)
        guard !normalized.isEmpty else {
            return false
        }
        let triggers = [
            "get selection links",
            "selection links",
            "selected links"
        ]
        var matched = false
        for trigger in triggers where normalized.contains(trigger) {
            matched = true
            break
        }
        guard matched else {
            return false
        }
        let outputTokens = ["list", "show", "count", "url", "urls"]
        for token in outputTokens where normalized.contains(token) {
            return true
        }
        return false
    }

    private func selectionLinksFromRecentResults(context: ContextPack) -> [String]? {
        if context.recentToolCalls.isEmpty || context.recentToolResults.isEmpty {
            return nil
        }
        for result in context.recentToolResults.reversed() {
            guard result.status == .ok else {
                continue
            }
            guard let call = context.recentToolCalls.first(where: { $0.id == result.toolCallId }) else {
                continue
            }
            guard call.name == .browserGetSelectionLinks else {
                continue
            }
            guard case let .array(values)? = result.payload["urls"] else {
                continue
            }
            let urls = values.compactMap { value -> String? in
                guard case let .string(url) = value else {
                    return nil
                }
                let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return urls.isEmpty ? nil : urls
        }
        return nil
    }

    private func buildSearchAction(query: String, engine: String, summaryPrefix: String) -> PlannedAction? {
        let arguments: [String: JSONValue] = [
            "query": .string(query),
            "engine": .string(engine),
            "newTab": .bool(true)
        ]
        let engineLabel = displaySearchEngine(engine)
        let summary = "\(summaryPrefix). Retrying '\(query)' with \(engineLabel) in a new tab."
        let toolCall = ToolCall(name: .search, arguments: arguments)
        return PlannedAction(toolCall: toolCall, summary: summary)
    }

    private func buildSearchSummary(query: String, engine: String?, newTab: Bool) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let engineLabel = displaySearchEngine(engine)
        let tabSuffix = newTab ? " in a new tab" : ""
        return "Searching the web for '\(trimmed)' (engine: \(engineLabel))\(tabSuffix)."
    }

    private func displaySearchEngine(_ engine: String?) -> String {
        let trimmed = engine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return "default"
        }
        let normalized = trimmed.lowercased()
        switch normalized {
        case "google":
            return "Google"
        case "duckduckgo":
            return "DuckDuckGo"
        case "bing":
            return "Bing"
        case "yahoo":
            return "Yahoo"
        case "custom":
            return "Custom"
        default:
            return trimmed
        }
    }

    private func assistantFromSummary(_ summary: String) -> AssistantMessage {
        AssistantMessage(render: Document.paragraph(text: summary))
    }

    private func assistantForModelResponse(_ modelResponse: ModelResponse, summary: String) -> AssistantMessage {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = modelResponse.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == original {
            return modelResponse.assistant
        }
        return assistantFromSummary(trimmed)
    }

    public func resolveGoalPlan(context: ContextPack, userGoal: String) async -> GoalPlan {
        let contextSnapshot = context
        if let existing = contextSnapshot.goalPlan {
            return existing
        }
        if let heuristic = heuristicGoalPlan(context: contextSnapshot, userGoal: userGoal) {
            let resolved = applyFallbackGoalPlan(heuristic, context: contextSnapshot, userGoal: userGoal)
            logGoalPlan(
                parsed: heuristic,
                resolved: resolved,
                userGoal: userGoal,
                context: contextSnapshot,
                sourceOverride: "heuristic"
            )
            return resolved
        }
        do {
            let parsed = try await model.parseGoalPlan(context: contextSnapshot, userGoal: userGoal)
            let resolved = applyFallbackGoalPlan(parsed, context: contextSnapshot, userGoal: userGoal)
            logGoalPlan(parsed: parsed, resolved: resolved, userGoal: userGoal, context: contextSnapshot)
            return resolved
        } catch {
            let fallback = applyFallbackGoalPlan(.unknown, context: contextSnapshot, userGoal: userGoal)
            logGoalPlan(
                parsed: nil,
                resolved: fallback,
                userGoal: userGoal,
                context: contextSnapshot,
                sourceOverride: "parse_error"
            )
            return fallback
        }
    }

    private func heuristicGoalPlan(context: ContextPack, userGoal: String) -> GoalPlan? {
        let normalized = normalizeForMatch(userGoal)
        guard !normalized.isEmpty else {
            return nil
        }
        if isActionLikeGoal(normalized) {
            return nil
        }
        let listLike = isListObservation(context)
            || shouldUseMainLinkFallback(context: context)
            || !context.observation.items.isEmpty
        let wantsComments = extractWantsComments(from: userGoal)
        let itemIndex = extractOrdinalIndex(from: userGoal)
        if wantsComments {
            return GoalPlan(
                intent: .commentSummary,
                itemIndex: listLike ? itemIndex : nil,
                itemQuery: nil,
                wantsComments: true
            )
        }
        if hasSummaryIntent(normalized) {
            return GoalPlan(intent: .pageSummary, itemIndex: nil, itemQuery: nil, wantsComments: false)
        }
        if let itemIndex, listLike {
            return GoalPlan(intent: .itemSummary, itemIndex: itemIndex, itemQuery: nil, wantsComments: false)
        }
        return nil
    }

    private func isActionLikeGoal(_ normalized: String) -> Bool {
        let tokens = [
            "click",
            "open",
            "go to",
            "navigate",
            "scroll",
            "type",
            "enter",
            "fill",
            "search",
            "collect",
            "add",
            "remove",
            "delete",
            "download",
            "compare",
            "difference",
            "differences",
            "versus",
            "vs"
        ]
        for token in tokens where normalized.contains(token) {
            return true
        }
        return false
    }

    private func hasSummaryIntent(_ normalized: String) -> Bool {
        let tokens = [
            "summarize",
            "summary",
            "overview",
            "key takeaways",
            "highlights",
            "recap",
            "tldr",
            "tl dr"
        ]
        for token in tokens where normalized.contains(token) {
            return true
        }
        return false
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

    private func logDebugEvent(_ type: String, context: ContextPack, payload: [String: JSONValue]) {
        guard Self.debugEnabled else {
            return
        }
        LaikaLogger.logAgentEvent(
            type: "agent.debug.\(type)",
            runId: context.runId,
            step: context.step,
            maxSteps: context.maxSteps,
            payload: payload
        )
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

    private struct SearchIntent {
        let query: String
        let engine: String?
    }

    private func extractSearchIntent(from goal: String) -> SearchIntent? {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        let lower = trimmed.lowercased()
        let enginePrefixes: [(String, String)] = [
            ("google", "google"),
            ("bing", "bing"),
            ("duckduckgo", "duckduckgo"),
            ("ddg", "duckduckgo"),
            ("kagi", "custom")
        ]
        for (token, engine) in enginePrefixes {
            let prefix = token + " "
            if lower.hasPrefix(prefix) {
                let remainder = String(trimmed.dropFirst(prefix.count))
                let query = sanitizeSearchQuery(remainder)
                if !query.isEmpty {
                    return SearchIntent(query: query, engine: engine)
                }
            }
        }
        let prefixes = [
            "search the web for",
            "search the web about",
            "search the web",
            "web search for",
            "web search",
            "search for",
            "search",
            "look up",
            "lookup",
            "find on the web",
            "find online"
        ]
        if let intent = extractSearchIntent(from: trimmed, lower: lower, prefixes: prefixes) {
            return intent
        }
        let embedded = ["search the web for", "web search for"]
        if let intent = extractSearchIntent(from: trimmed, lower: lower, prefixes: embedded) {
            return intent
        }
        return nil
    }

    private func extractSearchIntent(from text: String, lower: String, prefixes: [String]) -> SearchIntent? {
        for prefix in prefixes {
            if let intent = extractSearchIntent(from: text, lower: lower, prefix: prefix) {
                return intent
            }
        }
        return nil
    }

    private func extractSearchIntent(from text: String, lower: String, prefix: String) -> SearchIntent? {
        let prefixToken = prefix + " "
        if lower.hasPrefix(prefixToken) {
            let remainder = String(text.dropFirst(prefixToken.count))
            let query = sanitizeSearchQuery(remainder)
            return query.isEmpty ? nil : SearchIntent(query: query, engine: nil)
        }
        if let range = lower.range(of: prefix) {
            let offset = lower.distance(from: lower.startIndex, to: range.upperBound)
            if offset < 2 {
                let remainder = String(text.dropFirst(offset))
                let query = sanitizeSearchQuery(remainder)
                return query.isEmpty ? nil : SearchIntent(query: query, engine: nil)
            }
        }
        return nil
    }

    private func sanitizeSearchQuery(_ query: String) -> String {
        var trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix(":") || trimmed.hasPrefix("-") {
            trimmed.removeFirst()
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let strip = CharacterSet(charactersIn: "\"'.,:;!?")
        trimmed = trimmed.trimmingCharacters(in: strip)
        trimmed = stripSearchSuffix(from: trimmed)
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripSearchSuffix(from query: String) -> String {
        let lower = query.lowercased()
        let suffixes = [
            " and summarize",
            " and summarize the",
            " and list",
            " and list the",
            " and show",
            " and show the",
            " and give",
            " and give me",
            " and provide",
            " and provide a",
            " then summarize",
            " then list",
            " then show",
            " then give",
            " then provide"
        ]
        for suffix in suffixes {
            if let range = lower.range(of: suffix) {
                let offset = lower.distance(from: lower.startIndex, to: range.lowerBound)
                if offset > 0 && offset < query.count {
                    return String(query.prefix(offset)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return query
    }

    private func mostRecentSearchCall(_ context: ContextPack) -> ToolCall? {
        return context.recentToolCalls.reversed().first { $0.name == .search }
    }

    private func extractSearchQuery(from call: ToolCall) -> String? {
        if case let .string(query)? = call.arguments["query"] {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private func extractSearchEngine(from call: ToolCall) -> String? {
        if case let .string(engine)? = call.arguments["engine"] {
            let trimmed = engine.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed.lowercased()
        }
        return nil
    }

    private func shouldRetrySearch(
        intent: SearchIntent,
        lastSearch: ToolCall,
        blockReason: String?
    ) -> Bool {
        guard blockReason != nil else {
            return false
        }
        if let engine = extractSearchEngine(from: lastSearch), engine == "duckduckgo" {
            return false
        }
        if let engine = intent.engine, !engine.isEmpty, engine.lowercased() != "google" {
            return false
        }
        return true
    }

    private func searchBlockReason(_ observation: Observation) -> String? {
        let url = observation.url.lowercased()
        if url.contains("google.com/sorry") || url.contains("consent.google.") {
            return "google_block_url"
        }
        let text = normalizeForMatch(observation.text)
        if text.contains("unusual traffic") && text.contains("google") {
            return "unusual_traffic_text"
        }
        if text.contains("verify that you are not a robot") {
            return "robot_check_text"
        }
        return nil
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
            let stats = commentStats(for: context.observation.comments)
            if stats.substantial {
                if Self.debugEnabled {
                    let payload: [String: JSONValue] = [
                        "reason": .string("comments_substantial"),
                        "commentCount": .number(Double(stats.count)),
                        "commentChars": .number(Double(stats.totalChars)),
                        "commentLongCount": .number(Double(stats.longCount)),
                        "commentMetaCount": .number(Double(stats.metaCount))
                    ]
                    logDebugEvent("comment_link_skipped", context: context, payload: payload)
                }
                return nil
            }
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
        let resolved = resolvedItemCandidates(context: context, goalPlan: goalPlan)
        let items = resolved.items
        if Self.debugEnabled {
            var payload: [String: JSONValue] = [
                "source": .string(resolved.source),
                "count": .number(Double(items.count)),
                "origin": .string(context.origin),
                "intent": .string(goalPlan.intent.rawValue),
                "wantsComments": .bool(goalPlan.wantsComments),
                "listLike": .bool(isListObservation(context))
            ]
            if let index = goalPlan.itemIndex {
                payload["requestedIndex"] = .number(Double(index))
            } else {
                payload["requestedIndex"] = .null
            }
            if let query = goalPlan.itemQuery, !query.isEmpty {
                payload["requestedQuery"] = .string(truncateForLog(query, maxChars: 120))
            }
            var commentLinkCount = 0
            for item in items where itemHasCommentLink(item) {
                commentLinkCount += 1
            }
            payload["commentLinkItemCount"] = .number(Double(commentLinkCount))
            logDebugEvent("items_resolved", context: context, payload: payload)
        }
        if let index = goalPlan.itemIndex, index > 0 {
            if items.count >= index {
                let item = items[index - 1]
                if Self.debugEnabled {
                    logDebugEvent(
                        "item_selected",
                        context: context,
                        payload: debugItemPayload(item: item, selection: "index", index: index)
                    )
                }
                return TargetItem(index: index, title: item.title, url: item.url, handleId: item.handleId, links: item.links)
            }
            if shouldUseMainLinkFallback(context: context) {
                let fallbackLinks = MainLinkHeuristics.candidates(from: context.observation.elements)
                if fallbackLinks.count >= index {
                    let link = fallbackLinks[index - 1]
                    if Self.debugEnabled {
                        let payload: [String: JSONValue] = [
                            "selection": .string("main_link_fallback"),
                            "index": .number(Double(index)),
                            "title": .string(truncateForLog(link.label, maxChars: 120)),
                            "url": .string(link.href ?? ""),
                            "candidateCount": .number(Double(fallbackLinks.count))
                        ]
                        logDebugEvent("item_selected", context: context, payload: payload)
                    }
                    return TargetItem(index: index, title: link.label, url: link.href ?? "", handleId: link.handleId, links: [])
                }
            }
        }
        if let query = goalPlan.itemQuery, !query.isEmpty {
            if let match = matchItem(query: query, items: items) {
                if Self.debugEnabled {
                    logDebugEvent(
                        "item_selected",
                        context: context,
                        payload: debugTargetPayload(target: match, selection: "query")
                    )
                }
                return match
            }
        }
        if Self.debugEnabled {
            let payload: [String: JSONValue] = [
                "reason": .string("no_item_match"),
                "count": .number(Double(items.count))
            ]
            logDebugEvent("item_not_found", context: context, payload: payload)
        }
        return nil
    }

    private func resolvedItemCandidates(context: ContextPack, goalPlan: GoalPlan) -> ResolvedItems {
        if goalPlan.intent == .commentSummary || goalPlan.wantsComments {
            let fallback = cachedLastListItems()
            if !fallback.isEmpty {
                return ResolvedItems(items: fallback, source: "cached_last_list")
            }
        }
        if isListObservation(context) {
            if goalPlan.intent == .commentSummary || goalPlan.wantsComments {
                if let runId = context.runId, !runId.isEmpty,
                   let cached = cachedListItems(for: runId),
                   itemsContainCommentLinks(cached) {
                    return ResolvedItems(items: cached, source: "cached_run")
                }
                let fallback = cachedLastListItems()
                let fallbackOrigin = cachedLastListOrigin()
                if itemsContainCommentLinks(fallback), !fallbackOrigin.isEmpty, fallbackOrigin != context.origin {
                    return ResolvedItems(items: fallback, source: "cached_last_list_other_origin")
                }
                if itemsContainCommentLinks(context.observation.items) {
                    return ResolvedItems(items: context.observation.items, source: "current_observation")
                }
            }
            return ResolvedItems(items: context.observation.items, source: "current_observation")
        }
        guard let runId = context.runId, !runId.isEmpty else {
            return ResolvedItems(items: context.observation.items, source: "current_observation")
        }
        if let cached = cachedListItems(for: runId), !cached.isEmpty {
            return ResolvedItems(items: cached, source: "cached_run")
        }
        let fallback = cachedLastListItems()
        if !fallback.isEmpty {
            return ResolvedItems(items: fallback, source: "cached_last_list")
        }
        return ResolvedItems(items: context.observation.items, source: "current_observation")
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
        guard isListObservation(context) else {
            return
        }
        cacheLock.lock()
        if let runId = context.runId, !runId.isEmpty {
            if cachedListItemsByRun[runId] == nil || cachedListItemsByRun[runId]?.isEmpty == true {
                cachedListItemsByRun[runId] = context.observation.items
            }
        }
        if itemsContainCommentLinks(context.observation.items),
           itemsMostlyExternal(context.observation.items, origin: context.origin) {
            lastListItems = context.observation.items
            lastListOrigin = context.origin
        }
        cacheLock.unlock()
    }

    private func cachedListItems(for runId: String) -> [ObservedItem]? {
        cacheLock.lock()
        let items = cachedListItemsByRun[runId]
        cacheLock.unlock()
        return items
    }

    private func cachedLastListItems() -> [ObservedItem] {
        cacheLock.lock()
        let items = lastListItems
        cacheLock.unlock()
        return items
    }

    private func cachedLastListOrigin() -> String {
        cacheLock.lock()
        let origin = lastListOrigin
        cacheLock.unlock()
        return origin
    }

    private struct CommentStats {
        let count: Int
        let totalChars: Int
        let longCount: Int
        let metaCount: Int
        let substantial: Bool
    }

    private func commentStats(for comments: [ObservedComment]) -> CommentStats {
        guard !comments.isEmpty else {
            return CommentStats(count: 0, totalChars: 0, longCount: 0, metaCount: 0, substantial: false)
        }
        var totalChars = 0
        var longCount = 0
        var metaCount = 0
        for comment in comments {
            let trimmed = comment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            totalChars += trimmed.count
            if trimmed.count >= 120 {
                longCount += 1
            }
            if let author = comment.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
                metaCount += 1
            }
            if let age = comment.age?.trimmingCharacters(in: .whitespacesAndNewlines), !age.isEmpty {
                metaCount += 1
            }
            if let score = comment.score?.trimmingCharacters(in: .whitespacesAndNewlines), !score.isEmpty {
                metaCount += 1
            }
        }
        let count = comments.count
        var substantial = false
        if count >= 6 {
            substantial = true
        } else if count >= 3 && (longCount >= 2 || totalChars >= 600 || metaCount >= 2) {
            substantial = true
        } else if totalChars >= 900 {
            substantial = true
        }
        return CommentStats(
            count: count,
            totalChars: totalChars,
            longCount: longCount,
            metaCount: metaCount,
            substantial: substantial
        )
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
        if Self.debugEnabled {
            var payloads: [JSONValue] = []
            for (link, score) in scored.prefix(6) {
                let entry: [String: JSONValue] = [
                    "title": .string(truncateForLog(link.title, maxChars: 120)),
                    "url": .string(link.url),
                    "score": .number(Double(score)),
                    "commentScore": .number(Double(commentSignalScore(text: link.title, url: link.url))),
                    "host": .string(hostForURL(link.url))
                ]
                payloads.append(.object(entry))
            }
            let payload: [String: JSONValue] = [
                "targetTitle": .string(truncateForLog(target.title, maxChars: 160)),
                "targetUrl": .string(target.url),
                "candidateCount": .number(Double(scored.count)),
                "originHost": .string(originHost),
                "targetHost": .string(targetHost),
                "candidates": .array(payloads)
            ]
            logDebugEvent("comment_link_candidates", context: context, payload: payload)
        }
        let sorted = scored.sorted { lhs, rhs in
            if lhs.1 == rhs.1 {
                return lhs.0.title.count < rhs.0.title.count
            }
            return lhs.1 > rhs.1
        }
        guard let selected = sorted.first?.0 ?? candidates.first else {
            return nil
        }
        if Self.debugEnabled {
            let payload: [String: JSONValue] = [
                "targetTitle": .string(truncateForLog(target.title, maxChars: 160)),
                "selectedTitle": .string(truncateForLog(selected.title, maxChars: 120)),
                "selectedUrl": .string(selected.url),
                "selectedScore": .number(Double(commentSignalScore(text: selected.title, url: selected.url)))
            ]
            logDebugEvent("comment_link_selected", context: context, payload: payload)
        }
        return selected
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

    private func itemsContainCommentLinks(_ items: [ObservedItem]) -> Bool {
        for item in items where itemHasCommentLink(item) {
            return true
        }
        return false
    }

    private func itemHasCommentLink(_ item: ObservedItem) -> Bool {
        for link in item.links {
            if commentSignalScore(text: link.title, url: link.url) > 0 {
                return true
            }
        }
        return false
    }

    private func itemsMostlyExternal(_ items: [ObservedItem], origin: String) -> Bool {
        let originHost = hostForURL(origin)
        guard !originHost.isEmpty else {
            return false
        }
        var externalCount = 0
        var total = 0
        for item in items {
            let itemHost = hostForURL(item.url)
            if itemHost.isEmpty {
                continue
            }
            total += 1
            if itemHost != originHost {
                externalCount += 1
            }
        }
        guard total > 0 else {
            return false
        }
        return Double(externalCount) / Double(total) >= 0.4
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
        if trimmed.isEmpty || trimmed == "Unable to parse response." || trimmed.hasPrefix("Unable to parse response.") {
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
        output = appendTopDiscussionsIfNeeded(summary: output, context: context, focus: focus)
        output = appendAccessLimitationsIfNeeded(summary: output, context: context)
        return output
    }

    private func appendTopDiscussionsIfNeeded(
        summary: String,
        context: ContextPack,
        focus: SummaryFocus
    ) -> String {
        guard focus == .mainLinks else {
            return summary
        }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return summary
        }
        let lower = trimmed.lowercased()
        if lower.contains("top discussions") || lower.contains("top discussion") {
            return summary
        }
        let topDiscussions = topDiscussionSummaries(from: context.observation.items, limit: 3)
        guard !topDiscussions.isEmpty else {
            return summary
        }
        let line = "Top discussions (by comments): " + topDiscussions.joined(separator: "; ")
        return trimmed + "\n" + line
    }

    private func appendAccessLimitationsIfNeeded(summary: String, context: ContextPack) -> String {
        guard let line = accessLimitationsLine(for: context) else {
            return summary
        }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return line
        }
        if trimmed.lowercased().contains("access limitation") {
            return summary
        }
        return trimmed + "\n" + line
    }

    private func accessLimitationsLine(for context: ContextPack) -> String? {
        let labels = accessLimitations(for: context)
        guard !labels.isEmpty else {
            return nil
        }
        return "Access limitations: " + labels.joined(separator: "; ") + "."
    }

    private func accessLimitations(for context: ContextPack) -> [String] {
        var allowed = ObservationSignalNormalizer.accessLimitSignals
        allowed.insert(ObservationSignal.sparseText.rawValue)
        allowed.insert(ObservationSignal.nonTextContent.rawValue)
        let normalized = context.observation.signals
            .map { ObservationSignalNormalizer.normalize($0) }
            .filter { allowed.contains($0) }
        var labels: [String] = []
        for signal in normalized {
            if let label = accessLimitationLabel(for: signal), !labels.contains(label) {
                labels.append(label)
            }
        }
        return labels
    }

    private func accessLimitationLabel(for signal: String) -> String? {
        switch signal {
        case ObservationSignal.paywallOrLogin.rawValue:
            return "paywall or login required"
        case ObservationSignal.consentModal.rawValue:
            return "consent modal"
        case ObservationSignal.overlayBlocking.rawValue:
            return "overlay blocking content"
        case ObservationSignal.captchaOrRobotCheck.rawValue:
            return "captcha or robot check"
        case ObservationSignal.ageGate.rawValue:
            return "age gate"
        case ObservationSignal.geoBlock.rawValue:
            return "geo-restricted content"
        case ObservationSignal.scriptRequired.rawValue:
            return "scripts required"
        case ObservationSignal.sparseText.rawValue:
            return "sparse text"
        case ObservationSignal.nonTextContent.rawValue:
            return "non-text content"
        default:
            return nil
        }
    }

    private func topDiscussionSummaries(from items: [ObservedItem], limit: Int) -> [String] {
        guard limit > 0 else {
            return []
        }
        let candidates = items.compactMap { item -> (title: String, count: Int)? in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let count = commentCount(for: item) else {
                return nil
            }
            return (title, count)
        }
        let sorted = candidates.sorted { $0.count > $1.count }
        return sorted.prefix(limit).map { entry in
            let label = entry.count == 1 ? "comment" : "comments"
            return "\(entry.title) (\(entry.count) \(label))"
        }
    }

    private func commentCount(for item: ObservedItem) -> Int? {
        var counts: [Int] = []
        counts.reserveCapacity(item.links.count + 1)
        for link in item.links {
            if let count = parseCommentCount(from: link.title) {
                counts.append(count)
            }
        }
        if let count = parseCommentCount(from: item.snippet) {
            counts.append(count)
        }
        return counts.max()
    }

    private func parseCommentCount(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = Self.commentCountRegex.firstMatch(in: trimmed, options: [], range: range),
              match.numberOfRanges > 1,
              let countRange = Range(match.range(at: 1), in: trimmed) else {
            return nil
        }
        let rawValue = trimmed[countRange].replacingOccurrences(of: ",", with: "")
        return Int(rawValue)
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
        case .browserGetSelectionLinks:
            return "Collecting the selected links."
        case .browserBack:
            return "Going back to the previous page."
        case .browserForward:
            return "Going forward."
        case .browserRefresh:
            return "Refreshing the page."
        case .search:
            if case let .string(query)? = call.arguments["query"] {
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let engine = (call.arguments["engine"]).flatMap { value -> String? in
                        if case let .string(engineValue) = value {
                            return engineValue
                        }
                        return nil
                    }
                    let newTab = (call.arguments["newTab"]).flatMap { value -> Bool? in
                        if case let .bool(flag) = value {
                            return flag
                        }
                        return nil
                    } ?? false
                    return buildSearchSummary(query: trimmed, engine: engine, newTab: newTab)
                }
            }
            return "Running a web search."
        case .appCalculate:
            if case let .string(expression)? = call.arguments["expression"] {
                let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return "Calculating \(trimmed)."
                }
            }
            return "Calculating the requested expression."
        case .collectionCreate:
            return "Creating a new collection."
        case .collectionAddSources:
            return "Adding sources to the collection."
        case .collectionListSources:
            return "Listing the collection sources."
        case .sourceCapture:
            return "Capturing the source content."
        case .sourceRefresh:
            return "Refreshing the captured source."
        case .transformListTypes:
            return "Listing available transforms."
        case .transformRun:
            return "Running the requested transform."
        case .artifactSave:
            return "Saving the artifact."
        case .artifactOpen:
            return "Opening the artifact."
        case .artifactShare:
            return "Sharing the artifact."
        case .integrationInvoke:
            return "Running the requested integration."
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
        if goalPlan.intent == .pageSummary {
            return .pageSummary
        }
        return .plain
    }

    private func requiredHeadings(for format: SummaryFormat) -> [String] {
        switch format {
        case .plain:
            return []
        case .pageSummary:
            return [
                "Summary:",
                "Key takeaways:",
                "What to verify next:"
            ]
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

    private func debugItemPayload(item: ObservedItem, selection: String, index: Int) -> [String: JSONValue] {
        return [
            "selection": .string(selection),
            "index": .number(Double(index)),
            "title": .string(truncateForLog(item.title, maxChars: 160)),
            "url": .string(item.url),
            "linkCount": .number(Double(item.linkCount)),
            "linkDensity": .number(item.linkDensity),
            "links": .array(debugLinksPayload(item.links))
        ]
    }

    private func debugTargetPayload(target: TargetItem, selection: String) -> [String: JSONValue] {
        return [
            "selection": .string(selection),
            "index": .number(Double(target.index)),
            "title": .string(truncateForLog(target.title, maxChars: 160)),
            "url": .string(target.url),
            "links": .array(debugLinksPayload(target.links))
        ]
    }

    private func debugLinksPayload(_ links: [ObservedItemLink], limit: Int = 6) -> [JSONValue] {
        var payloads: [JSONValue] = []
        payloads.reserveCapacity(min(limit, links.count))
        for link in links.prefix(limit) {
            let entry: [String: JSONValue] = [
                "title": .string(truncateForLog(link.title, maxChars: 120)),
                "url": .string(link.url),
                "commentScore": .number(Double(commentSignalScore(text: link.title, url: link.url))),
                "host": .string(hostForURL(link.url))
            ]
            payloads.append(.object(entry))
        }
        return payloads
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
        case .pageSummary:
            let overview = buildOverview(title: title, url: url, fallback: "Not stated in the page.")
            let accessLimited = !accessLimitations(for: context).isEmpty
            return buildPageSummary(sentences: sentences, overview: overview, accessLimited: accessLimited)
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
            if sentences.isEmpty {
                return buildOverview(title: title, url: url, fallback: "Not stated in the page.")
            }
            return sentences.joined(separator: " ")
        }
    }

    private func buildPageSummary(sentences: [String], overview: String, accessLimited: Bool) -> String {
        let summaryLine = sentences.first ?? overview
        let takeaways = sentences.dropFirst().prefix(2).joined(separator: " ")
        let takeawaysText = takeaways.isEmpty ? "Not stated in the page." : takeaways
        let verifyText = accessLimited
            ? "Access appears limited; verify details directly on the site."
            : "Verify key details on the page or open relevant links for confirmation."
        return [
            "Summary: \(summaryLine)",
            "Key takeaways: \(takeawaysText)",
            "What to verify next: \(verifyText)"
        ].joined(separator: "\n")
    }

    private func structuredSummaryFromText(_ summary: String, format: SummaryFormat, context: ContextPack) -> String? {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        switch format {
        case .pageSummary:
            let sentences = TextUtils.firstSentences(trimmed, maxItems: 5, minLength: 24, maxLength: 280)
            let overview = buildOverview(
                title: context.observation.title,
                url: context.observation.url,
                fallback: "Not stated in the page."
            )
            let accessLimited = !accessLimitations(for: context).isEmpty
            return buildPageSummary(sentences: sentences, overview: overview, accessLimited: accessLimited)
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
