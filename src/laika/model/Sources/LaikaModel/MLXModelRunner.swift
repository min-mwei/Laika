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

public final class MLXModelRunner: ModelRunner, StreamingModelRunner {
    public let modelURL: URL
    public let maxTokens: Int
    private let store = ModelStore()

    private struct GenerationAttempt {
        let temperature: Float
        let topP: Float
        let enableThinking: Bool
    }

    private struct JSONCapture {
        private(set) var buffer = ""
        private var depth = 0
        private var inString = false
        private var escaped = false
        private var started = false

        mutating func append(_ chunk: String) -> Bool {
            for character in chunk {
                if !started {
                    if character == "{" {
                        started = true
                        depth = 1
                        buffer.append(character)
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
                        return true
                    }
                }
            }
            return false
        }
    }

    public init(modelURL: URL, maxTokens: Int = 2048) {
        self.modelURL = modelURL
        self.maxTokens = maxTokens
    }

    public func parseGoalPlan(context: ContextPack, userGoal: String) async throws -> GoalPlan {
        let container = try await store.container(for: modelURL)
        let systemPrompt = PromptBuilder.goalParseSystemPrompt()
        let userPrompt = PromptBuilder.goalParseUserPrompt(context: context, goal: userGoal)
        let requestId = UUID().uuidString
        let attempt = GenerationAttempt(
            temperature: 0.2,
            topP: 0.7,
            enableThinking: shouldEnableThinkingForGoalParse(goal: userGoal)
        )
        let parseMaxTokens = goalParseMaxTokens(goal: userGoal)
        let maxOutputChars = 8_000

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
            observationChars: context.observation.text.count,
            elementCount: context.observation.elements.count,
            blockCount: context.observation.blocks.count,
            itemCount: context.observation.items.count,
            outlineCount: context.observation.outline.count,
            primaryChars: context.observation.primary?.text.count ?? 0,
            commentCount: context.observation.comments.count,
            tabCount: context.tabs.count,
            stage: "goal_parse"
        ))

        do {
            let output = try await generateJSONResponse(
                container: container,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                attempt: attempt,
                maxOutputChars: maxOutputChars,
                maxTokensOverride: parseMaxTokens
            )
            let parsed = GoalPlanParser.parse(output)
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
                stage: "goal_parse"
            ))
            return parsed
        } catch {
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
                stage: "goal_parse"
            ))
            return GoalPlan.unknown
        }
    }

    public func generatePlan(context: ContextPack, userGoal: String) async throws -> ModelResponse {
        let container = try await store.container(for: modelURL)
        let systemPrompt = PromptBuilder.systemPrompt()
        let userPrompt = PromptBuilder.userPrompt(context: context, goal: userGoal)
        let baseRequestId = UUID().uuidString
        let attempts = planAttempts(context: context, userGoal: userGoal)
        let maxOutputChars = 24_000
        let planMaxTokens = planMaxTokens(context: context, userGoal: userGoal)

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
                observationChars: context.observation.text.count,
                elementCount: context.observation.elements.count,
                blockCount: context.observation.blocks.count,
                itemCount: context.observation.items.count,
                outlineCount: context.observation.outline.count,
                primaryChars: context.observation.primary?.text.count ?? 0,
                commentCount: context.observation.comments.count,
                tabCount: context.tabs.count,
                stage: "plan"
            ))

            do {
                let output = try await generateJSONResponse(
                    container: container,
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    attempt: attempt,
                    maxOutputChars: maxOutputChars,
                    maxTokensOverride: planMaxTokens
                )
                lastOutput = output
                let parsed = try ToolCallParser.parseRequiringJSON(output)
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
                    stage: "plan"
                ))
                return parsed
            } catch {
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
                    stage: "plan"
                ))
            }
        }

        if let lastOutput {
            return try ToolCallParser.parse(lastOutput)
        }
        throw lastError ?? ModelError.invalidResponse("Plan generation failed.")
    }

    private func generateJSONResponse(
        container: ModelContainer,
        systemPrompt: String,
        userPrompt: String,
        attempt: GenerationAttempt,
        maxOutputChars: Int,
        maxTokensOverride: Int? = nil
    ) async throws -> String {
        let tokenLimit = maxTokensOverride ?? maxTokens
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

        var capture = JSONCapture()
        var output = ""
        for try await chunk in session.streamResponse(to: userPrompt) {
            output.append(chunk)
            if output.count >= maxOutputChars {
                return output
            }
            if capture.append(chunk) {
                return capture.buffer
            }
        }

        return output
    }

    public func streamText(_ request: StreamRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let container = try await store.container(for: modelURL)
                    let tokenLimit = min(maxTokens, max(request.maxTokens, 32))
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
        let goalPlan = context.goalPlan ?? GoalPlan.unknown
        let useThinking = shouldEnableThinkingForPlan(goalPlan: goalPlan, goal: userGoal)
        if useThinking {
            return [
                .init(temperature: 0.4, topP: 0.85, enableThinking: true)
            ]
        }
        return [
            .init(temperature: 0.7, topP: 0.8, enableThinking: false),
            .init(temperature: 0.6, topP: 0.95, enableThinking: false)
        ]
    }

    private func goalParseMaxTokens(goal: String) -> Int {
        let threshold = 140
        let desired = goal.count > threshold ? 128 : 72
        return min(maxTokens, desired)
    }

    private func shouldEnableThinkingForGoalParse(goal: String) -> Bool {
        return goal.count > 140
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
        return min(maxTokens, desired)
    }

    private func shouldEnableThinkingForPlan(goalPlan: GoalPlan, goal: String) -> Bool {
        if goalPlan.intent == .pageSummary || goalPlan.intent == .itemSummary || goalPlan.intent == .commentSummary {
            return false
        }
        if goalPlan.wantsComments {
            return false
        }
        return goal.count > 220
    }
}
