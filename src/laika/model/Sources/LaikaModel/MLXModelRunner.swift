import Foundation
import LaikaShared
import MLXLLM
import MLXLMCommon

actor ModelStore {
    private var container: ModelContainer?
    private var currentURL: URL?

    func container(for url: URL) async throws -> ModelContainer {
        if let container, currentURL == url {
            return container
        }
        let loaded = try await loadModelContainer(directory: url)
        container = loaded
        currentURL = url
        return loaded
    }
}

public final class MLXModelRunner: ModelRunner, StreamingModelRunner, MaxTokenConfigurable {
    public let modelURL: URL
    public let maxTokens: Int
    private let store = ModelStore()
    private var maxTokensOverride: Int?
    private let maxTokensLock = NSLock()

    private struct GenerationAttempt {
        let temperature: Float
        let topP: Float
        let enableThinking: Bool
    }

    private struct GenerationResult {
        let output: String
        let firstTokenMs: Double?
        let firstJSONMs: Double?
        let captureMode: String
        let outputTruncated: Bool
    }

    private struct JSONCapture {
        private(set) var buffer = ""
        private var depth = 0
        private var inString = false
        private var escaped = false
        private var started = false

        mutating func append(_ chunk: String) -> (started: Bool, completed: Bool) {
            var startedNow = false
            for character in chunk {
                if !started {
                    if character == "{" {
                        started = true
                        startedNow = true
                        depth = 1
                        buffer.append(character)
                        continue
                    }
                    continue
                }

                buffer.append(character)

                if escaped {
                    escaped = false
                    continue
                }

                if inString, character == "\\" {
                    escaped = true
                    continue
                }

                if character == "\"" {
                    inString.toggle()
                    continue
                }

                if inString {
                    continue
                }

                if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return (startedNow, true)
                    }
                }
            }
            return (startedNow, false)
        }
    }

    public init(modelURL: URL, maxTokens: Int = 2048) {
        self.modelURL = modelURL
        self.maxTokens = maxTokens
    }

    public func setMaxTokensOverride(_ maxTokens: Int?) {
        let sanitized = maxTokens.map { max(32, min($0, self.maxTokens)) }
        maxTokensLock.lock()
        maxTokensOverride = sanitized
        maxTokensLock.unlock()
    }

    private func effectiveMaxTokens() -> Int {
        maxTokensLock.lock()
        let override = maxTokensOverride
        maxTokensLock.unlock()
        return override ?? maxTokens
    }

    private func recentToolDebugInfo(for context: ContextPack) -> (name: String?, args: String?, resultStatus: String?, resultPreview: String?) {
        guard let lastCall = context.recentToolCalls.last else {
            return (nil, nil, nil, nil)
        }
        let name = lastCall.name.rawValue
        let args = encodePreview(lastCall.arguments, maxChars: 240)
        let result = context.recentToolResults.last(where: { $0.toolCallId == lastCall.id })
        let status = result?.status.rawValue
        let payload = result.map { encodePreview($0.payload, maxChars: 240) }
        return (name, args, status, payload ?? nil)
    }

    private func encodePreview(_ object: [String: LaikaShared.JSONValue], maxChars: Int) -> String? {
        guard !object.isEmpty else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(object),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return LaikaLogger.preview(text, maxChars: maxChars)
    }

    private struct PromptMetrics {
        let contextChars: Int
        let textChars: Int
        let primaryChars: Int
        let chunkCount: Int
    }

    private func promptMetrics(for request: LLMCPRequest) -> PromptMetrics {
        var contextChars = 0
        var textChars = 0
        var primaryChars = 0
        var chunkCount = 0
        for document in request.context.documents {
            if document.kind == "web.observation.chunk.v1" {
                chunkCount += 1
            }
            guard case let .object(content) = document.content else {
                continue
            }
            if let markdown = extractString(content["markdown"]) {
                contextChars += markdown.count
            }
            if let text = extractString(content["text"]) {
                textChars += text.count
                contextChars += text.count
            }
            if let primary = content["primary"],
               case let .object(primaryContent) = primary,
               let primaryText = extractString(primaryContent["text"]) {
                primaryChars += primaryText.count
                contextChars += primaryText.count
            }
        }
        return PromptMetrics(
            contextChars: contextChars,
            textChars: textChars,
            primaryChars: primaryChars,
            chunkCount: chunkCount
        )
    }

    private func extractString(_ value: LaikaShared.JSONValue?) -> String? {
        guard let value else {
            return nil
        }
        if case let .string(text) = value {
            return text
        }
        return nil
    }

    public func parseGoalPlan(context: ContextPack, userGoal: String) async throws -> GoalPlan {
        let container = try await store.container(for: modelURL)
        let systemPrompt = PromptBuilder.goalParseSystemPrompt()
        let userPrompt = PromptBuilder.goalParseUserPrompt(context: context, goal: userGoal)
        let requestId = UUID().uuidString
        let attempt = GenerationAttempt(
            temperature: 0.2,
            topP: 0.7,
            enableThinking: false
        )
        let parseMaxTokens = goalParseMaxTokens(goal: userGoal)
        let maxOutputChars = 8_000
        let recentTool = recentToolDebugInfo(for: context)
        let contextChars = context.observation.text.count
        let primaryChars = context.observation.primary?.text.count ?? 0

        LaikaLogger.logLLMEvent(.request(
            id: requestId,
            runId: context.runId,
            step: context.step,
            maxSteps: context.maxSteps,
            goal: userGoal,
            origin: context.origin,
            pageURL: context.observation.url,
            pageTitle: context.observation.title,
            recentToolCallsCount: context.recentToolCalls.count,
            modelPath: modelURL.lastPathComponent,
            maxTokens: parseMaxTokens,
            temperature: Double(attempt.temperature),
            topP: Double(attempt.topP),
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            contextChars: contextChars,
            textChars: contextChars,
            primaryChars: primaryChars,
            chunkCount: 0,
            observationChars: context.observation.text.count,
            elementCount: context.observation.elements.count,
            blockCount: context.observation.blocks.count,
            itemCount: context.observation.items.count,
            outlineCount: context.observation.outline.count,
            commentCount: context.observation.comments.count,
            tabCount: context.tabs.count,
            recentToolName: recentTool.name,
            recentToolArgumentsPreview: recentTool.args,
            recentToolResultStatus: recentTool.resultStatus,
            recentToolResultPreview: recentTool.resultPreview,
            stage: "goal_parse"
        ))

        let startedAt = Date()
        do {
            let result = try await generateJSONResponse(
                container: container,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                attempt: attempt,
                maxOutputChars: maxOutputChars,
                maxTokensOverride: parseMaxTokens
            )
            let output = result.output
            let parsed = GoalPlanParser.parse(output)
            let durationMs = max(0, Date().timeIntervalSince(startedAt) * 1000)
            LaikaLogger.logLLMEvent(.response(
                id: requestId,
                runId: context.runId,
                step: context.step,
                maxSteps: context.maxSteps,
                modelPath: modelURL.lastPathComponent,
                maxTokens: parseMaxTokens,
                temperature: Double(attempt.temperature),
                topP: Double(attempt.topP),
                output: output,
                toolCallsCount: nil,
                summary: parsed.intent.rawValue,
                error: nil,
                durationMs: durationMs,
                stage: "goal_parse",
                firstTokenMs: result.firstTokenMs,
                firstJSONMs: result.firstJSONMs,
                captureMode: result.captureMode,
                outputTruncated: result.outputTruncated
            ))
            return parsed
        } catch {
            let durationMs = max(0, Date().timeIntervalSince(startedAt) * 1000)
            LaikaLogger.logLLMEvent(.response(
                id: requestId,
                runId: context.runId,
                step: context.step,
                maxSteps: context.maxSteps,
                modelPath: modelURL.lastPathComponent,
                maxTokens: parseMaxTokens,
                temperature: Double(attempt.temperature),
                topP: Double(attempt.topP),
                output: "",
                toolCallsCount: nil,
                summary: nil,
                error: error.localizedDescription,
                durationMs: durationMs,
                stage: "goal_parse"
            ))
            return GoalPlan.unknown
        }
    }

    public func generatePlan(context: ContextPack, userGoal: String) async throws -> ModelResponse {
        let container = try await store.container(for: modelURL)
        let request = LLMCPRequestBuilder.build(context: context, userGoal: userGoal)
        let wantsMarkdown = request.output.format == "markdown"
        let systemPrompt = wantsMarkdown ? PromptBuilder.markdownSystemPrompt() : PromptBuilder.systemPrompt()
        let userPrompt = wantsMarkdown
            ? PromptBuilder.markdownUserPrompt(request: request)
            : PromptBuilder.userPrompt(request: request, runId: context.runId, step: context.step, maxSteps: context.maxSteps)
        let baseRequestId = UUID().uuidString
        let attempts = planAttempts(context: context, userGoal: userGoal)
        let maxOutputChars = 24_000
        let planMaxTokens = planMaxTokens(context: context, userGoal: userGoal)
        let recentTool = recentToolDebugInfo(for: context)
        let metrics = promptMetrics(for: request)

        var lastOutput: String?
        var lastError: Error?

        for (index, attempt) in attempts.enumerated() {
            let requestId = "\(baseRequestId)-\(index + 1)"
            LaikaLogger.logLLMEvent(.request(
                id: requestId,
                runId: context.runId,
                step: context.step,
                maxSteps: context.maxSteps,
                goal: userGoal,
                origin: context.origin,
                pageURL: context.observation.url,
                pageTitle: context.observation.title,
                recentToolCallsCount: context.recentToolCalls.count,
                modelPath: modelURL.lastPathComponent,
                maxTokens: planMaxTokens,
                temperature: Double(attempt.temperature),
                topP: Double(attempt.topP),
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                contextChars: metrics.contextChars,
                textChars: metrics.textChars,
                primaryChars: metrics.primaryChars,
                chunkCount: metrics.chunkCount,
                observationChars: context.observation.text.count,
                elementCount: context.observation.elements.count,
                blockCount: context.observation.blocks.count,
                itemCount: context.observation.items.count,
                outlineCount: context.observation.outline.count,
                commentCount: context.observation.comments.count,
                tabCount: context.tabs.count,
                recentToolName: recentTool.name,
                recentToolArgumentsPreview: recentTool.args,
                recentToolResultStatus: recentTool.resultStatus,
                recentToolResultPreview: recentTool.resultPreview,
                stage: "plan"
            ))

            let startedAt = Date()
            do {
                if wantsMarkdown {
                    let result = try await generateTextResponse(
                        container: container,
                        systemPrompt: systemPrompt,
                        userPrompt: userPrompt,
                        attempt: attempt,
                        maxOutputChars: maxOutputChars,
                        maxTokensOverride: planMaxTokens
                    )
                    let output = result.output
                    lastOutput = output
                    let cleaned = cleanMarkdownOutput(output)
                    let markdown = cleaned.isEmpty ? output.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
                    let assistant = AssistantMessage(render: Document.paragraph(text: markdown))
                    let response = ModelResponse(toolCalls: [], assistant: assistant, summary: markdown, rawMarkdown: markdown)
                    let durationMs = max(0, Date().timeIntervalSince(startedAt) * 1000)
                    LaikaLogger.logLLMEvent(.response(
                        id: requestId,
                        runId: context.runId,
                        step: context.step,
                        maxSteps: context.maxSteps,
                        modelPath: modelURL.lastPathComponent,
                        maxTokens: planMaxTokens,
                        temperature: Double(attempt.temperature),
                        topP: Double(attempt.topP),
                        output: output,
                        toolCallsCount: 0,
                        summary: markdown,
                        error: nil,
                        durationMs: durationMs,
                        stage: "plan",
                        firstTokenMs: result.firstTokenMs,
                        firstJSONMs: result.firstJSONMs,
                        captureMode: result.captureMode,
                        outputTruncated: result.outputTruncated
                    ))
                    return response
                }

                let result = try await generateJSONResponse(
                    container: container,
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    attempt: attempt,
                    maxOutputChars: maxOutputChars,
                    maxTokensOverride: planMaxTokens
                )
                let output = result.output
                lastOutput = output
                let outcome = LLMCPResponseParser.parseWithOutcome(output)
                let parsed = outcome.response
                let durationMs = max(0, Date().timeIntervalSince(startedAt) * 1000)
                logParseOutcome(outcome, context: context, stage: "plan", outputChars: output.count)
                LaikaLogger.logLLMEvent(.response(
                    id: requestId,
                    runId: context.runId,
                    step: context.step,
                    maxSteps: context.maxSteps,
                    modelPath: modelURL.lastPathComponent,
                    maxTokens: planMaxTokens,
                    temperature: Double(attempt.temperature),
                    topP: Double(attempt.topP),
                    output: output,
                    toolCallsCount: parsed.toolCalls.count,
                    summary: parsed.summary,
                    error: nil,
                    durationMs: durationMs,
                    stage: "plan",
                    firstTokenMs: result.firstTokenMs,
                    firstJSONMs: result.firstJSONMs,
                    captureMode: result.captureMode,
                    outputTruncated: result.outputTruncated
                ))
                return parsed
            } catch {
                let durationMs = max(0, Date().timeIntervalSince(startedAt) * 1000)
                lastError = error
                LaikaLogger.logLLMEvent(.response(
                    id: requestId,
                    runId: context.runId,
                    step: context.step,
                    maxSteps: context.maxSteps,
                    modelPath: modelURL.lastPathComponent,
                    maxTokens: planMaxTokens,
                    temperature: Double(attempt.temperature),
                    topP: Double(attempt.topP),
                    output: lastOutput ?? "",
                    toolCallsCount: nil,
                    summary: nil,
                    error: error.localizedDescription,
                    durationMs: durationMs,
                    stage: "plan"
                ))
            }
        }

        if let lastOutput {
            if wantsMarkdown {
                let cleaned = cleanMarkdownOutput(lastOutput)
                let markdown = cleaned.isEmpty ? lastOutput.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
                let assistant = AssistantMessage(render: Document.paragraph(text: markdown))
                return ModelResponse(toolCalls: [], assistant: assistant, summary: markdown, rawMarkdown: markdown)
            } else {
                let outcome = LLMCPResponseParser.parseWithOutcome(lastOutput)
                logParseOutcome(outcome, context: context, stage: "plan", outputChars: lastOutput.count)
                return outcome.response
            }
        }
        throw lastError ?? ModelError.invalidResponse("Plan generation failed.")
    }

    public func generateAnswer(request: LLMCPRequest, logContext: AnswerLogContext) async throws -> ModelResponse {
        let container = try await store.container(for: modelURL)
        if request.output.format == "markdown" {
            return try await generateMarkdownAnswer(request: request, logContext: logContext, container: container)
        }
        let systemPrompt = PromptBuilder.systemPrompt()
        let userPrompt = PromptBuilder.userPrompt(request: request, runId: logContext.runId, step: logContext.step, maxSteps: logContext.maxSteps)
        let requestId = UUID().uuidString
        let attempt = GenerationAttempt(temperature: 0.2, topP: 0.7, enableThinking: false)
        let maxOutputChars = 28_000
        let answerMaxTokens = answerMaxTokens(sourceCount: logContext.sourceCount)
        let metrics = promptMetrics(for: request)

        LaikaLogger.logLLMEvent(.request(
            id: requestId,
            runId: logContext.runId,
            step: logContext.step,
            maxSteps: logContext.maxSteps,
            goal: request.input.userMessage.text,
            origin: logContext.origin,
            pageURL: logContext.pageURL,
            pageTitle: logContext.pageTitle,
            recentToolCallsCount: 0,
            modelPath: modelURL.lastPathComponent,
            maxTokens: answerMaxTokens,
            temperature: Double(attempt.temperature),
            topP: Double(attempt.topP),
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            contextChars: metrics.contextChars,
            textChars: metrics.textChars,
            primaryChars: metrics.primaryChars,
            chunkCount: metrics.chunkCount,
            observationChars: logContext.contextChars,
            elementCount: 0,
            blockCount: 0,
            itemCount: 0,
            outlineCount: 0,
            commentCount: 0,
            tabCount: 0,
            recentToolName: nil,
            recentToolArgumentsPreview: nil,
            recentToolResultStatus: nil,
            recentToolResultPreview: nil,
            stage: "collection_answer"
        ))

        let startedAt = Date()
        do {
            let result = try await generateJSONResponse(
                container: container,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                attempt: attempt,
                maxOutputChars: maxOutputChars,
                maxTokensOverride: answerMaxTokens
            )
            let output = result.output
            let outcome = LLMCPResponseParser.parseWithOutcome(output)
            let parsed = outcome.response
            let durationMs = max(0, Date().timeIntervalSince(startedAt) * 1000)
            logParseOutcome(outcome, logContext: logContext, stage: "collection_answer", outputChars: output.count)
            LaikaLogger.logLLMEvent(.response(
                id: requestId,
                runId: logContext.runId,
                step: logContext.step,
                maxSteps: logContext.maxSteps,
                modelPath: modelURL.lastPathComponent,
                maxTokens: answerMaxTokens,
                temperature: Double(attempt.temperature),
                topP: Double(attempt.topP),
                output: output,
                toolCallsCount: parsed.toolCalls.count,
                summary: parsed.summary,
                error: nil,
                durationMs: durationMs,
                stage: "collection_answer",
                firstTokenMs: result.firstTokenMs,
                firstJSONMs: result.firstJSONMs,
                captureMode: result.captureMode,
                outputTruncated: result.outputTruncated
            ))
            return parsed
        } catch {
            let durationMs = max(0, Date().timeIntervalSince(startedAt) * 1000)
            LaikaLogger.logLLMEvent(.response(
                id: requestId,
                runId: logContext.runId,
                step: logContext.step,
                maxSteps: logContext.maxSteps,
                modelPath: modelURL.lastPathComponent,
                maxTokens: answerMaxTokens,
                temperature: Double(attempt.temperature),
                topP: Double(attempt.topP),
                output: "",
                toolCallsCount: nil,
                summary: nil,
                error: error.localizedDescription,
                durationMs: durationMs,
                stage: "collection_answer"
            ))
            throw error
        }
    }

    private func generateMarkdownAnswer(
        request: LLMCPRequest,
        logContext: AnswerLogContext,
        container: ModelContainer
    ) async throws -> ModelResponse {
        let systemPrompt = PromptBuilder.markdownSystemPrompt()
        let userPrompt = PromptBuilder.markdownUserPrompt(request: request)
        let requestId = UUID().uuidString
        let attempt = GenerationAttempt(temperature: 0.2, topP: 0.7, enableThinking: false)
        let maxOutputChars = 28_000
        let answerMaxTokens = answerMaxTokens(sourceCount: logContext.sourceCount)
        let metrics = promptMetrics(for: request)

        LaikaLogger.logLLMEvent(.request(
            id: requestId,
            runId: logContext.runId,
            step: logContext.step,
            maxSteps: logContext.maxSteps,
            goal: request.input.userMessage.text,
            origin: logContext.origin,
            pageURL: logContext.pageURL,
            pageTitle: logContext.pageTitle,
            recentToolCallsCount: 0,
            modelPath: modelURL.lastPathComponent,
            maxTokens: answerMaxTokens,
            temperature: Double(attempt.temperature),
            topP: Double(attempt.topP),
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            contextChars: metrics.contextChars,
            textChars: metrics.textChars,
            primaryChars: metrics.primaryChars,
            chunkCount: metrics.chunkCount,
            observationChars: logContext.contextChars,
            elementCount: 0,
            blockCount: 0,
            itemCount: 0,
            outlineCount: 0,
            commentCount: 0,
            tabCount: 0,
            recentToolName: nil,
            recentToolArgumentsPreview: nil,
            recentToolResultStatus: nil,
            recentToolResultPreview: nil,
            stage: "collection_answer"
        ))

        let startedAt = Date()
        do {
            let result = try await generateTextResponse(
                container: container,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                attempt: attempt,
                maxOutputChars: maxOutputChars,
                maxTokensOverride: answerMaxTokens
            )
            let output = result.output
            let cleaned = cleanMarkdownOutput(output)
            if let jsonCandidate = extractLLMCPJSON(from: output) {
                let outcome = LLMCPResponseParser.parseWithOutcome(jsonCandidate)
                let parsed = outcome.response
                let rendered = parsed.assistant.render.markdown()
                let durationMs = max(0, Date().timeIntervalSince(startedAt) * 1000)
                logParseOutcome(outcome, logContext: logContext, stage: "collection_answer", outputChars: output.count)
                LaikaLogger.logLLMEvent(.response(
                    id: requestId,
                    runId: logContext.runId,
                    step: logContext.step,
                    maxSteps: logContext.maxSteps,
                    modelPath: modelURL.lastPathComponent,
                    maxTokens: answerMaxTokens,
                    temperature: Double(attempt.temperature),
                    topP: Double(attempt.topP),
                    output: output,
                    toolCallsCount: parsed.toolCalls.count,
                    summary: rendered,
                    error: nil,
                    durationMs: durationMs,
                    stage: "collection_answer",
                    firstTokenMs: result.firstTokenMs,
                    firstJSONMs: result.firstJSONMs,
                    captureMode: result.captureMode,
                    outputTruncated: result.outputTruncated
                ))
                return ModelResponse(toolCalls: [], assistant: parsed.assistant, summary: rendered, rawMarkdown: rendered)
            }

            let initialMarkdown = cleaned.isEmpty ? output.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
            let parsed = MarkdownCitations.extract(from: initialMarkdown)
            let markdown = parsed.markdown
            let assistant = AssistantMessage(render: Document.paragraph(text: markdown), citations: parsed.citations)
            let durationMs = max(0, Date().timeIntervalSince(startedAt) * 1000)
            LaikaLogger.logLLMEvent(.response(
                id: requestId,
                runId: logContext.runId,
                step: logContext.step,
                maxSteps: logContext.maxSteps,
                modelPath: modelURL.lastPathComponent,
                maxTokens: answerMaxTokens,
                temperature: Double(attempt.temperature),
                topP: Double(attempt.topP),
                output: output,
                toolCallsCount: 0,
                summary: markdown,
                error: nil,
                durationMs: durationMs,
                stage: "collection_answer",
                firstTokenMs: result.firstTokenMs,
                firstJSONMs: result.firstJSONMs,
                captureMode: result.captureMode,
                outputTruncated: result.outputTruncated
            ))
            return ModelResponse(toolCalls: [], assistant: assistant, summary: markdown, rawMarkdown: markdown)
        } catch {
            let durationMs = max(0, Date().timeIntervalSince(startedAt) * 1000)
            LaikaLogger.logLLMEvent(.response(
                id: requestId,
                runId: logContext.runId,
                step: logContext.step,
                maxSteps: logContext.maxSteps,
                modelPath: modelURL.lastPathComponent,
                maxTokens: answerMaxTokens,
                temperature: Double(attempt.temperature),
                topP: Double(attempt.topP),
                output: "",
                toolCallsCount: nil,
                summary: nil,
                error: error.localizedDescription,
                durationMs: durationMs,
                stage: "collection_answer"
            ))
            throw error
        }
    }

    private func generateJSONResponse(
        container: ModelContainer,
        systemPrompt: String,
        userPrompt: String,
        attempt: GenerationAttempt,
        maxOutputChars: Int,
        maxTokensOverride: Int? = nil
    ) async throws -> GenerationResult {
        let maxTokenCap = effectiveMaxTokens()
        let tokenLimit = min(maxTokensOverride ?? maxTokenCap, maxTokenCap)
        let parameters = GenerateParameters(
            maxTokens: tokenLimit,
            temperature: attempt.temperature,
            topP: attempt.topP
        )
        let additionalContext: [String: any Sendable]? =
            attempt.enableThinking ? nil : ["enable_thinking": false]
        let session = ChatSession(
            container,
            instructions: systemPrompt,
            generateParameters: parameters,
            additionalContext: additionalContext
        )

        let startedAt = Date()
        var firstTokenAt: Date?
        var firstJSONAt: Date?
        var capture = JSONCapture()
        var output = ""
        for try await chunk in session.streamResponse(to: userPrompt) {
            if firstTokenAt == nil {
                firstTokenAt = Date()
            }
            output.append(chunk)
            if output.count >= maxOutputChars {
                let firstTokenMs = firstTokenAt.map { $0.timeIntervalSince(startedAt) * 1000 }
                let firstJSONMs = firstJSONAt.map { $0.timeIntervalSince(startedAt) * 1000 }
                return GenerationResult(
                    output: output,
                    firstTokenMs: firstTokenMs,
                    firstJSONMs: firstJSONMs,
                    captureMode: "truncated",
                    outputTruncated: true
                )
            }
            let captureEvent = capture.append(chunk)
            if captureEvent.started && firstJSONAt == nil {
                firstJSONAt = Date()
            }
            if captureEvent.completed {
                let firstTokenMs = firstTokenAt.map { $0.timeIntervalSince(startedAt) * 1000 }
                let firstJSONMs = firstJSONAt.map { $0.timeIntervalSince(startedAt) * 1000 }
                return GenerationResult(
                    output: capture.buffer,
                    firstTokenMs: firstTokenMs,
                    firstJSONMs: firstJSONMs,
                    captureMode: "json_capture",
                    outputTruncated: false
                )
            }
        }

        let firstTokenMs = firstTokenAt.map { $0.timeIntervalSince(startedAt) * 1000 }
        let firstJSONMs = firstJSONAt.map { $0.timeIntervalSince(startedAt) * 1000 }
        return GenerationResult(
            output: output,
            firstTokenMs: firstTokenMs,
            firstJSONMs: firstJSONMs,
            captureMode: "full_output",
            outputTruncated: false
        )
    }

    private func generateTextResponse(
        container: ModelContainer,
        systemPrompt: String,
        userPrompt: String,
        attempt: GenerationAttempt,
        maxOutputChars: Int,
        maxTokensOverride: Int? = nil
    ) async throws -> GenerationResult {
        let maxTokenCap = effectiveMaxTokens()
        let tokenLimit = min(maxTokensOverride ?? maxTokenCap, maxTokenCap)
        let parameters = GenerateParameters(
            maxTokens: tokenLimit,
            temperature: attempt.temperature,
            topP: attempt.topP
        )
        let additionalContext: [String: any Sendable]? =
            attempt.enableThinking ? nil : ["enable_thinking": false]
        let session = ChatSession(
            container,
            instructions: systemPrompt,
            generateParameters: parameters,
            additionalContext: additionalContext
        )

        let startedAt = Date()
        var firstTokenAt: Date?
        var output = ""
        for try await chunk in session.streamResponse(to: userPrompt) {
            if firstTokenAt == nil {
                firstTokenAt = Date()
            }
            output.append(chunk)
            if output.count >= maxOutputChars {
                let firstTokenMs = firstTokenAt.map { $0.timeIntervalSince(startedAt) * 1000 }
                return GenerationResult(
                    output: output,
                    firstTokenMs: firstTokenMs,
                    firstJSONMs: nil,
                    captureMode: "truncated",
                    outputTruncated: true
                )
            }
        }

        let firstTokenMs = firstTokenAt.map { $0.timeIntervalSince(startedAt) * 1000 }
        return GenerationResult(
            output: output,
            firstTokenMs: firstTokenMs,
            firstJSONMs: nil,
            captureMode: "full_output",
            outputTruncated: false
        )
    }

    private func cleanMarkdownOutput(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else {
            return trimmed
        }
        guard let firstBreak = trimmed.firstIndex(of: "\n") else {
            return trimmed
        }
        let endIndex = trimmed.index(trimmed.endIndex, offsetBy: -3)
        guard firstBreak < endIndex else {
            return trimmed
        }
        let inner = trimmed[trimmed.index(after: firstBreak)..<endIndex]
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }


    private func extractLLMCPJSON(from text: String) -> String? {
        guard let json = ModelOutputParser.extractJSONObject(from: text)
            ?? ModelOutputParser.extractJSONObjectRelaxed(from: text) else {
            return nil
        }
        let lower = json.lowercased()
        guard lower.contains("\"protocol\""), lower.contains("\"assistant\"") else {
            return nil
        }
        return json
    }

    public func streamText(_ request: StreamRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let container = try await store.container(for: modelURL)
                    let maxTokenCap = effectiveMaxTokens()
                    let tokenLimit = min(maxTokenCap, max(request.maxTokens, 32))
                    var parameters = GenerateParameters(
                        maxTokens: tokenLimit,
                        temperature: request.temperature,
                        topP: request.topP,
                        repetitionPenalty: request.repetitionPenalty,
                        repetitionContextSize: request.repetitionContextSize
                    )
                    if request.repetitionPenalty == nil {
                        parameters.repetitionContextSize = 0
                    }
                    let additionalContext: [String: any Sendable]? =
                        request.enableThinking ? nil : ["enable_thinking": false]
                    let session = ChatSession(
                        container,
                        instructions: request.systemPrompt,
                        generateParameters: parameters,
                        additionalContext: additionalContext
                    )
                    for try await chunk in session.streamResponse(to: request.userPrompt) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func planAttempts(context: ContextPack, userGoal: String) -> [GenerationAttempt] {
        return [
            .init(temperature: 0.7, topP: 0.8, enableThinking: false),
            .init(temperature: 0.6, topP: 0.95, enableThinking: false)
        ]
    }

    private func answerMaxTokens(sourceCount: Int) -> Int {
        let base = 768
        let bonus = min(max(sourceCount, 0), 8) * 64
        let maxTokenCap = effectiveMaxTokens()
        return min(maxTokenCap, base + bonus)
    }

    private func goalParseMaxTokens(goal: String) -> Int {
        let threshold = 140
        let desired = goal.count > threshold ? 128 : 72
        let maxTokenCap = effectiveMaxTokens()
        return min(maxTokenCap, desired)
    }

    private func planMaxTokens(context: ContextPack, userGoal: String) -> Int {
        let goalPlan = context.goalPlan ?? GoalPlan.unknown
        let desired: Int
        switch goalPlan.intent {
        case .pageSummary:
            desired = 256
        case .itemSummary, .commentSummary:
            desired = 384
        case .action:
            desired = 256
        case .unknown:
            desired = 320
        }
        let maxTokenCap = effectiveMaxTokens()
        return min(maxTokenCap, desired)
    }


    private func logParseOutcome(
        _ outcome: LLMCPResponseParser.ParseOutcome,
        context: ContextPack,
        stage: String,
        outputChars: Int
    ) {
        guard outcome.mode != .strict else {
            return
        }
        var payload: [String: LaikaShared.JSONValue] = [
            "mode": .string(outcome.mode.rawValue),
            "stage": .string(stage),
            "outputChars": .number(Double(outputChars))
        ]
        if let error = outcome.error, !error.isEmpty {
            payload["error"] = .string(LaikaLogger.preview(error, maxChars: 200))
        }
        LaikaLogger.logAgentEvent(
            type: "llmcp.parse_mode",
            runId: context.runId,
            step: context.step,
            maxSteps: context.maxSteps,
            payload: payload
        )
    }

    private func logParseOutcome(
        _ outcome: LLMCPResponseParser.ParseOutcome,
        logContext: AnswerLogContext,
        stage: String,
        outputChars: Int
    ) {
        guard outcome.mode != .strict else {
            return
        }
        var payload: [String: LaikaShared.JSONValue] = [
            "mode": .string(outcome.mode.rawValue),
            "stage": .string(stage),
            "outputChars": .number(Double(outputChars))
        ]
        if let error = outcome.error, !error.isEmpty {
            payload["error"] = .string(LaikaLogger.preview(error, maxChars: 200))
        }
        LaikaLogger.logAgentEvent(
            type: "llmcp.parse_mode",
            runId: logContext.runId,
            step: logContext.step,
            maxSteps: logContext.maxSteps,
            payload: payload
        )
    }
}

extension MLXModelRunner: @unchecked Sendable {}
