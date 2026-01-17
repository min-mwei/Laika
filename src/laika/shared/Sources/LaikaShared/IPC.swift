import Foundation

public enum MessageType: String, Codable, Sendable {
    case observeRequest
    case observeResponse
    case toolRequest
    case toolResponse
    case policyDecision
    case runStatus
}

public struct MessageEnvelope: Codable, Equatable, Sendable {
    public let id: UUID
    public let type: MessageType
    public let payload: JSONValue

    public init(id: UUID = UUID(), type: MessageType, payload: JSONValue) {
        self.id = id
        self.type = type
        self.payload = payload
    }
}
