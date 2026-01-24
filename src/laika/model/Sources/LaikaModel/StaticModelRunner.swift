import Foundation
import LaikaShared

public final class StaticModelRunner: StreamingModelRunner {
    public init() {}

    public func generatePlan(context: ContextPack, userGoal: String) async throws -> ModelResponse {
        let normalizedGoal = userGoal.lowercased()
        let elements = context.observation.elements
        if normalizedGoal.contains("click") || normalizedGoal.contains("tap") {
            if let target = selectClickTarget(from: elements, goal: normalizedGoal) {
                let toolCall = ToolCall(
                    name: .browserClick,
                    arguments: ["handleId": .string(target.handleId)]
                )
                let render = Document.paragraph(text: "Clicking \(target.label.isEmpty ? "the requested item" : target.label).")
                let assistant = AssistantMessage(render: render)
                return ModelResponse(toolCalls: [toolCall], assistant: assistant)
            }
        }
        let render = Document.paragraph(text: "No tool calls proposed.")
        let assistant = AssistantMessage(render: render)
        return ModelResponse(toolCalls: [], assistant: assistant)
    }

    private func selectClickTarget(from elements: [ObservedElement], goal: String) -> ObservedElement? {
        guard !elements.isEmpty else {
            return nil
        }
        for element in elements {
            let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty {
                continue
            }
            if goal.contains(label.lowercased()) {
                return element
            }
        }
        return elements.first
    }

    public func streamText(_ request: StreamRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("Summary requested.")
            continuation.finish()
        }
    }
}
