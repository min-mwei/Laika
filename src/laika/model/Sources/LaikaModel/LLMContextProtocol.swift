import Foundation
import LaikaShared

public struct LLMCPProtocol: Codable, Equatable, Sendable {
    public let name: String
    public let version: Int
}

public enum LLMCPMessageType: String, Codable, Sendable {
    case request
    case response
}

public struct LLMCPConversation: Codable, Equatable, Sendable {
    public let id: String
    public let turn: Int
}

public struct LLMCPSender: Codable, Equatable, Sendable {
    public let role: String
}

public struct LLMCPTrace: Codable, Equatable, Sendable {
    public let runId: String?
    public let step: Int?

    private enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case step
    }
}

public struct LLMCPUserMessage: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
}

public struct LLMCPTask: Codable, Equatable, Sendable {
    public let name: String
    public let args: [String: JSONValue]?
}

public struct LLMCPInput: Codable, Equatable, Sendable {
    public let userMessage: LLMCPUserMessage
    public let task: LLMCPTask

    private enum CodingKeys: String, CodingKey {
        case userMessage = "user_message"
        case task
    }
}

public struct LLMCPOutputSpec: Codable, Equatable, Sendable {
    public let format: String
}

public struct LLMCPDocumentSource: Codable, Equatable, Sendable {
    public let browser: String?
    public let tabId: String?

    private enum CodingKeys: String, CodingKey {
        case browser
        case tabId = "tab_id"
    }
}

public struct LLMCPDocument: Codable, Equatable, Sendable {
    public let docId: String
    public let kind: String
    public let trust: String
    public let source: LLMCPDocumentSource?
    public let content: JSONValue

    private enum CodingKeys: String, CodingKey {
        case docId = "doc_id"
        case kind
        case trust
        case source
        case content
    }
}

public struct LLMCPContext: Codable, Equatable, Sendable {
    public let documents: [LLMCPDocument]
}

public struct LLMCPRequest: Codable, Equatable, Sendable {
    public let protocolInfo: LLMCPProtocol
    public let id: String
    public let type: LLMCPMessageType
    public let createdAt: String
    public let conversation: LLMCPConversation
    public let sender: LLMCPSender
    public let input: LLMCPInput
    public let context: LLMCPContext
    public let output: LLMCPOutputSpec
    public let trace: LLMCPTrace?

    private enum CodingKeys: String, CodingKey {
        case protocolInfo = "protocol"
        case id
        case type
        case createdAt = "created_at"
        case conversation
        case sender
        case input
        case context
        case output
        case trace
    }
}

public struct LLMCPReply: Codable, Equatable, Sendable {
    public let requestId: String

    private enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
    }
}

public struct LLMCPCitation: Codable, Equatable, Sendable {
    public let docId: String
    public let nodeId: String?
    public let handleId: String?
    public let quote: String?

    private enum CodingKeys: String, CodingKey {
        case docId = "doc_id"
        case nodeId = "node_id"
        case handleId = "handle_id"
        case quote
    }
}

public struct LLMCPAssistant: Codable, Equatable, Sendable {
    public let title: String?
    public let render: Document
    public let citations: [LLMCPCitation]?
}

public struct LLMCPToolCall: Codable, Equatable, Sendable {
    public let name: String
    public let arguments: [String: JSONValue]?
}

public struct LLMCPResponse: Codable, Equatable, Sendable {
    public let protocolInfo: LLMCPProtocol
    public let id: String
    public let type: LLMCPMessageType
    public let createdAt: String
    public let conversation: LLMCPConversation
    public let sender: LLMCPSender
    public let inReplyTo: LLMCPReply
    public let assistant: LLMCPAssistant
    public let toolCalls: [LLMCPToolCall]

    private enum CodingKeys: String, CodingKey {
        case protocolInfo = "protocol"
        case id
        case type
        case createdAt = "created_at"
        case conversation
        case sender
        case inReplyTo = "in_reply_to"
        case assistant
        case toolCalls = "tool_calls"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolInfo = try container.decode(LLMCPProtocol.self, forKey: .protocolInfo)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(LLMCPMessageType.self, forKey: .type)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        conversation = try container.decode(LLMCPConversation.self, forKey: .conversation)
        sender = try container.decode(LLMCPSender.self, forKey: .sender)
        inReplyTo = try container.decode(LLMCPReply.self, forKey: .inReplyTo)
        assistant = try container.decode(LLMCPAssistant.self, forKey: .assistant)
        toolCalls = try container.decodeIfPresent([LLMCPToolCall].self, forKey: .toolCalls) ?? []
    }
}

enum LLMCPClock {
    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func nowString() -> String {
        isoFormatter.string(from: Date())
    }
}
