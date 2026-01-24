import Foundation
import LaikaShared

enum LLMCPRequestBuilder {
    private enum ObservationBudget {
        static let maxItems = 12
        static let maxItemSnippetChars = 160
        static let maxOutline = 12
        static let maxComments = 12
        static let maxCommentChars = 220
        static let maxPrimaryChars = 3200
        static let maxSummaryTextChars = 1600
        static let maxChunkedSummaryTextChars = 1000
        static let maxChunkedPrimaryChars = 1600
        static let maxActionSummaryTextChars = 600
        static let maxActionPrimaryChars = 1200
        static let maxChunkChars = 2000
        static let maxChunks = 3
        static let maxElements = 40
        static let maxElementLabelChars = 120
        static let maxTitleChars = 140
        static let maxTopDiscussions = 5
    }

    static func build(context: ContextPack, userGoal: String) -> LLMCPRequest {
        let conversationId = context.runId?.isEmpty == false ? context.runId! : UUID().uuidString
        let turn = context.step ?? 1
        let requestId = UUID().uuidString
        let task = taskForGoalPlan(context.goalPlan, userGoal: userGoal)
        let input = LLMCPInput(
            userMessage: LLMCPUserMessage(id: UUID().uuidString, text: userGoal),
            task: task
        )
        let documents = buildObservationDocuments(context: context)
        let request = LLMCPRequest(
            protocolInfo: LLMCPProtocol(name: "laika.llmcp", version: 1),
            id: requestId,
            type: .request,
            createdAt: LLMCPClock.nowString(),
            conversation: LLMCPConversation(id: conversationId, turn: turn),
            sender: LLMCPSender(role: "agent"),
            input: input,
            context: LLMCPContext(documents: documents),
            output: LLMCPOutputSpec(format: "json"),
            trace: nil
        )
        return request
    }

    private static func taskForGoalPlan(_ goalPlan: GoalPlan?, userGoal: String) -> LLMCPTask {
        let plan = goalPlan ?? GoalPlan.unknown
        var args: [String: JSONValue] = [:]
        if plan.wantsComments {
            args["wants_comments"] = .bool(true)
        }
        switch plan.intent {
        case .pageSummary:
            args["style"] = .string("concise")
            args["focus"] = .string("page")
            return LLMCPTask(name: "web.summarize", args: args)
        case .itemSummary:
            args["style"] = .string("concise")
            args["focus"] = .string("item")
            if let index = plan.itemIndex {
                args["item_index"] = .number(Double(index))
            }
            if let query = plan.itemQuery, !query.isEmpty {
                args["item_query"] = .string(query)
            }
            return LLMCPTask(name: "web.summarize", args: args)
        case .commentSummary:
            args["style"] = .string("concise")
            args["focus"] = .string("comments")
            if let index = plan.itemIndex {
                args["item_index"] = .number(Double(index))
            }
            if let query = plan.itemQuery, !query.isEmpty {
                args["item_query"] = .string(query)
            }
            return LLMCPTask(name: "web.summarize", args: args)
        case .action:
            args["intent"] = .string("action")
            return LLMCPTask(name: "web.answer", args: args)
        case .unknown:
            return LLMCPTask(name: "web.answer", args: args.isEmpty ? nil : args)
        }
    }

    private static func buildObservationDocuments(context: ContextPack) -> [LLMCPDocument] {
        let observation = context.observation
        let goalPlan = context.goalPlan ?? GoalPlan.unknown
        let chunkDocs = buildChunkDocuments(observation: observation, goalPlan: goalPlan)
        let summaryDoc = buildSummaryDocument(
            observation: observation,
            goalPlan: goalPlan,
            hasChunks: !chunkDocs.isEmpty
        )
        return [summaryDoc] + chunkDocs
    }

    private static func buildSummaryDocument(
        observation: Observation,
        goalPlan: GoalPlan,
        hasChunks: Bool
    ) -> LLMCPDocument {
        let content = JSONValue.object(
            buildSummaryContent(observation: observation, goalPlan: goalPlan, hasChunks: hasChunks)
        )
        return LLMCPDocument(
            docId: "doc:web:summary",
            kind: "web.observation.summary.v1",
            trust: "untrusted",
            source: LLMCPDocumentSource(browser: "safari", tabId: nil),
            content: content
        )
    }

    private static func buildSummaryContent(
        observation: Observation,
        goalPlan: GoalPlan,
        hasChunks: Bool
    ) -> [String: JSONValue] {
        var content: [String: JSONValue] = [
            "doc_type": .string("web.observation.summary.v1"),
            "url": .string(observation.url),
            "title": .string(TextUtils.truncate(TextUtils.normalizeWhitespace(observation.title), maxChars: ObservationBudget.maxTitleChars))
        ]
        var discussionCandidates: [(title: String, url: String, handleId: String?, commentCount: Int)] = []
        let summaryText = buildSummaryText(
            observation: observation,
            maxChars: summaryTextLimit(goalPlan: goalPlan, hasChunks: hasChunks)
        )
        if !summaryText.isEmpty && (!isListObservation(observation) || observation.items.isEmpty) {
            content["text"] = .string(summaryText)
        }
        if let primary = observation.primary {
            let primaryText = TextUtils.truncate(
                TextUtils.normalizePreservingNewlines(primary.text),
                maxChars: primaryTextLimit(goalPlan: goalPlan, hasChunks: hasChunks)
            )
            if !primaryText.isEmpty {
                var primaryPayload: [String: JSONValue] = [
                    "text": .string(primaryText),
                    "tag": .string(primary.tag),
                    "role": .string(primary.role)
                ]
                if let handleId = primary.handleId, !handleId.isEmpty {
                    primaryPayload["handle_id"] = .string(handleId)
                }
                content["primary"] = .object(primaryPayload)
            }
        }
        if !observation.items.isEmpty {
            let items = observation.items.prefix(ObservationBudget.maxItems).compactMap { item -> JSONValue? in
                let title = TextUtils.normalizeWhitespace(item.title)
                if title.isEmpty {
                    return nil
                }
                var object: [String: JSONValue] = [
                    "title": .string(TextUtils.truncate(title, maxChars: ObservationBudget.maxTitleChars)),
                    "url": .string(item.url)
                ]
                let snippet = SnippetFormatter.format(item.snippet, title: title, maxChars: ObservationBudget.maxItemSnippetChars)
                if !snippet.isEmpty {
                    object["snippet"] = .string(snippet)
                }
                if let commentCount = commentCount(for: item) {
                    object["comment_count"] = .number(Double(commentCount))
                    discussionCandidates.append((
                        title: TextUtils.truncate(title, maxChars: ObservationBudget.maxTitleChars),
                        url: item.url,
                        handleId: item.handleId,
                        commentCount: commentCount
                    ))
                }
                if let handleId = item.handleId, !handleId.isEmpty {
                    object["handle_id"] = .string(handleId)
                }
                return .object(object)
            }
            if !items.isEmpty {
                content["items"] = .array(items)
            }
        }
        if isListObservation(observation), !discussionCandidates.isEmpty {
            let topDiscussions = discussionCandidates
                .sorted { $0.commentCount > $1.commentCount }
                .prefix(ObservationBudget.maxTopDiscussions)
                .map { entry -> JSONValue in
                    var object: [String: JSONValue] = [
                        "title": .string(entry.title),
                        "url": .string(entry.url),
                        "comment_count": .number(Double(entry.commentCount))
                    ]
                    if let handleId = entry.handleId, !handleId.isEmpty {
                        object["handle_id"] = .string(handleId)
                    }
                    return .object(object)
                }
            if !topDiscussions.isEmpty {
                content["top_discussions"] = .array(topDiscussions)
            }
        }
        if wantsComments(goalPlan: goalPlan), !observation.comments.isEmpty {
            let comments = observation.comments.prefix(ObservationBudget.maxComments).compactMap { comment -> JSONValue? in
                let text = TextUtils.truncate(TextUtils.normalizePreservingNewlines(comment.text), maxChars: ObservationBudget.maxCommentChars)
                if text.isEmpty {
                    return nil
                }
                var object: [String: JSONValue] = [
                    "text": .string(text),
                    "depth": .number(Double(comment.depth))
                ]
                if let author = comment.author, !author.isEmpty {
                    object["author"] = .string(author)
                }
                if let age = comment.age, !age.isEmpty {
                    object["age"] = .string(age)
                }
                if let score = comment.score, !score.isEmpty {
                    object["score"] = .string(score)
                }
                if let handleId = comment.handleId, !handleId.isEmpty {
                    object["handle_id"] = .string(handleId)
                }
                return .object(object)
            }
            if !comments.isEmpty {
                content["comments"] = .array(comments)
            }
        }
        if !observation.outline.isEmpty {
            let outline = observation.outline.prefix(ObservationBudget.maxOutline).compactMap { item -> JSONValue? in
                let text = TextUtils.normalizeWhitespace(item.text)
                if text.isEmpty {
                    return nil
                }
                return .object([
                    "level": .number(Double(item.level)),
                    "tag": .string(item.tag),
                    "role": .string(item.role),
                    "text": .string(TextUtils.truncate(text, maxChars: ObservationBudget.maxTitleChars))
                ])
            }
            if !outline.isEmpty {
                content["outline"] = .array(outline)
            }
        }
        if !observation.signals.isEmpty {
            content["signals"] = .array(observation.signals.prefix(12).map { .string($0) })
        }
        if shouldIncludeElements(goalPlan: goalPlan), !observation.elements.isEmpty {
            let elements = observation.elements.prefix(ObservationBudget.maxElements).compactMap { element -> JSONValue? in
                let label = TextUtils.truncate(TextUtils.normalizeWhitespace(element.label), maxChars: ObservationBudget.maxElementLabelChars)
                var object: [String: JSONValue] = [
                    "handle_id": .string(element.handleId),
                    "role": .string(element.role),
                    "text": .string(label)
                ]
                if let href = element.href, !href.isEmpty {
                    object["href"] = .string(href)
                }
                if let inputType = element.inputType, !inputType.isEmpty {
                    object["input_type"] = .string(inputType)
                }
                return .object(object)
            }
            if !elements.isEmpty {
                content["elements"] = .array(elements)
            }
        }
        return content
    }

    private static func buildChunkDocuments(observation: Observation, goalPlan: GoalPlan) -> [LLMCPDocument] {
        if wantsComments(goalPlan: goalPlan) {
            return []
        }
        let sourceText: String
        if let primary = observation.primary, !primary.text.isEmpty {
            sourceText = primary.text
        } else {
            sourceText = observation.text
        }
        let chunks = chunkText(sourceText, maxChunkChars: ObservationBudget.maxChunkChars, maxChunks: ObservationBudget.maxChunks)
        guard chunks.count > 1 else {
            return []
        }
        let total = chunks.count
        return chunks.enumerated().map { index, chunk in
            let content: [String: JSONValue] = [
                "doc_type": .string("web.observation.chunk.v1"),
                "url": .string(observation.url),
                "title": .string(TextUtils.truncate(TextUtils.normalizeWhitespace(observation.title), maxChars: ObservationBudget.maxTitleChars)),
                "chunk_index": .number(Double(index + 1)),
                "chunk_count": .number(Double(total)),
                "text": .string(chunk)
            ]
            return LLMCPDocument(
                docId: "doc:web:chunk:\(index + 1)",
                kind: "web.observation.chunk.v1",
                trust: "untrusted",
                source: LLMCPDocumentSource(browser: "safari", tabId: nil),
                content: .object(content)
            )
        }
    }

    private static func buildSummaryText(observation: Observation, maxChars: Int) -> String {
        if isListObservation(observation), !observation.items.isEmpty {
            var lines: [String] = []
            var index = 0
            for item in observation.items.prefix(ObservationBudget.maxItems) {
                let title = TextUtils.normalizeWhitespace(item.title)
                if title.isEmpty {
                    continue
                }
                index += 1
                var line = "\(index). \(TextUtils.truncate(title, maxChars: ObservationBudget.maxTitleChars))"
                let snippet = SnippetFormatter.format(item.snippet, title: title, maxChars: ObservationBudget.maxItemSnippetChars)
                if !snippet.isEmpty {
                    line += " — \(snippet)"
                }
                lines.append(line)
            }
            let combined = lines.joined(separator: "\n")
            return TextUtils.truncate(combined, maxChars: maxChars)
        }
        if let primary = observation.primary, !primary.text.isEmpty {
            let normalized = TextUtils.normalizePreservingNewlines(primary.text)
            return TextUtils.truncate(normalized, maxChars: maxChars)
        }
        if !observation.blocks.isEmpty {
            let lines = observation.blocks.prefix(12).map { block in
                TextUtils.truncate(TextUtils.normalizeWhitespace(block.text), maxChars: ObservationBudget.maxItemSnippetChars)
            }.filter { !$0.isEmpty }
            let combined = lines.joined(separator: "\n")
            return TextUtils.truncate(combined, maxChars: maxChars)
        }
        return TextUtils.truncate(TextUtils.normalizePreservingNewlines(observation.text), maxChars: maxChars)
    }

    private static func isListObservation(_ observation: Observation) -> Bool {
        let itemCount = observation.items.count
        let primaryChars = observation.primary?.text.count ?? 0
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

    private static func wantsComments(goalPlan: GoalPlan) -> Bool {
        return goalPlan.intent == .commentSummary || goalPlan.wantsComments
    }

    private static func shouldIncludeElements(goalPlan: GoalPlan) -> Bool {
        return goalPlan.intent == .action || goalPlan.intent == .unknown
    }

    private static let commentCountRegex: NSRegularExpression = {
        let pattern = "(\\d[\\d,]*)\\s*(comments?|repl(?:y|ies))"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static func commentCount(for item: ObservedItem) -> Int? {
        var counts: [Int] = []
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

    private static func parseCommentCount(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = commentCountRegex.firstMatch(in: trimmed, options: [], range: range),
              match.numberOfRanges > 1,
              let countRange = Range(match.range(at: 1), in: trimmed) else {
            return nil
        }
        let rawValue = trimmed[countRange].replacingOccurrences(of: ",", with: "")
        return Int(rawValue)
    }

    private static func summaryTextLimit(goalPlan: GoalPlan, hasChunks: Bool) -> Int {
        if goalPlan.intent == .action {
            return ObservationBudget.maxActionSummaryTextChars
        }
        if hasChunks {
            return ObservationBudget.maxChunkedSummaryTextChars
        }
        return ObservationBudget.maxSummaryTextChars
    }

    private static func primaryTextLimit(goalPlan: GoalPlan, hasChunks: Bool) -> Int {
        if goalPlan.intent == .action {
            return ObservationBudget.maxActionPrimaryChars
        }
        if hasChunks {
            return ObservationBudget.maxChunkedPrimaryChars
        }
        return ObservationBudget.maxPrimaryChars
    }

    private static func chunkText(_ text: String, maxChunkChars: Int, maxChunks: Int) -> [String] {
        guard maxChunkChars > 0, maxChunks > 0 else {
            return []
        }
        let normalized = TextUtils.normalizePreservingNewlines(text)
        if normalized.isEmpty {
            return []
        }
        var chunks: [String] = []
        var current = ""
        func flushCurrent() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                chunks.append(trimmed)
            }
            current = ""
        }
        let paragraphs = normalized.components(separatedBy: "\n")
        for paragraph in paragraphs {
            let cleaned = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                continue
            }
            if cleaned.count >= maxChunkChars {
                if !current.isEmpty {
                    flushCurrent()
                }
                var start = cleaned.startIndex
                while start < cleaned.endIndex && chunks.count < maxChunks {
                    let end = cleaned.index(start, offsetBy: maxChunkChars, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
                    let slice = cleaned[start..<end]
                    chunks.append(String(slice))
                    start = end
                }
                if chunks.count >= maxChunks {
                    break
                }
                continue
            }
            if current.count + cleaned.count + 1 > maxChunkChars {
                flushCurrent()
            }
            if current.isEmpty {
                current = cleaned
            } else {
                current += "\n" + cleaned
            }
            if chunks.count >= maxChunks {
                break
            }
        }
        if chunks.count < maxChunks {
            flushCurrent()
        }
        if chunks.count > maxChunks {
            return Array(chunks.prefix(maxChunks))
        }
        return chunks
    }
}
