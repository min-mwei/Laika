import Foundation

public struct StreamRequest: Sendable {
    public let systemPrompt: String
    public let userPrompt: String
    public let maxTokens: Int
    public let temperature: Float
    public let topP: Float
    public let repetitionPenalty: Float?
    public let repetitionContextSize: Int
    public let enableThinking: Bool

    public init(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        repetitionPenalty: Float? = nil,
        repetitionContextSize: Int = 64,
        enableThinking: Bool = false
    ) {
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.repetitionPenalty = repetitionPenalty
        self.repetitionContextSize = repetitionContextSize
        self.enableThinking = enableThinking
    }
}

public protocol StreamingModelRunner: ModelRunner {
    func streamText(_ request: StreamRequest) -> AsyncThrowingStream<String, Error>
}
