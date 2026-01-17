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

    public init(modelURL: URL, maxTokens: Int = 256) {
        self.modelURL = modelURL
        self.maxTokens = maxTokens
    }

    public func generatePlan(context: ContextPack, userGoal: String) async throws -> ModelResponse {
        let container = try await store.container(for: modelURL)
        let systemPrompt = PromptBuilder.systemPrompt()
        let userPrompt = PromptBuilder.userPrompt(context: context, goal: userGoal)
        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0.2, topP: 0.9)
        let session = ChatSession(container, instructions: systemPrompt, generateParameters: parameters)

        let output = try await session.respond(to: userPrompt)
        return try ToolCallParser.parse(output)
    }
}
