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

public final class MLXModelRunner: ModelRunner {
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

    public func generatePlan(context: ContextPack, userGoal: String) async throws -> ModelResponse {
        let container = try await store.container(for: modelURL)
        let systemPrompt = PromptBuilder.systemPrompt(for: context.mode)
        let userPrompt = PromptBuilder.userPrompt(context: context, goal: userGoal)
        let baseRequestId = UUID().uuidString
        let attempts: [GenerationAttempt] = [
            .init(temperature: 0.7, topP: 0.8, enableThinking: false),
            .init(temperature: 0.6, topP: 0.95, enableThinking: false),
        ]
        let maxOutputChars = 24_000

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
                maxTokens: maxTokens,
                temperature: Double(attempt.temperature),
                topP: Double(attempt.topP),
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                observationChars: context.observation.text.count,
                elementCount: context.observation.elements.count,
                tabCount: context.tabs.count
            ))

            do {
                let output = try await generateJSONResponse(
                    container: container,
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    attempt: attempt,
                    maxOutputChars: maxOutputChars
                )
                lastOutput = output
                let parsed = try ToolCallParser.parseRequiringJSON(output)
                LaikaLogger.logLLMEvent(.response(
                    id: requestId,
                    runId: context.runId,
                    step: context.step,
                    maxSteps: context.maxSteps,
                    modelPath: modelURL.lastPathComponent,
                    maxTokens: maxTokens,
                    temperature: Double(attempt.temperature),
                    topP: Double(attempt.topP),
                    output: output,
                    toolCallsCount: parsed.toolCalls.count,
                    summary: parsed.summary,
                    error: nil
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
                    maxTokens: maxTokens,
                    temperature: Double(attempt.temperature),
                    topP: Double(attempt.topP),
                    output: lastOutput ?? "",
                    toolCallsCount: nil,
                    summary: nil,
                    error: error.localizedDescription
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
        maxOutputChars: Int
    ) async throws -> String {
        let parameters = GenerateParameters(
            maxTokens: maxTokens,
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
}
