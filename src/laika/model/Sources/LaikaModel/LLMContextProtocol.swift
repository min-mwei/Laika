import Foundation
import LaikaShared

public struct LLMCPProtocol: Codable, Equatable, Sendable {
    public let name: String
    public let version: Int

    public init(name: String, version: Int) {
        self.name = name
        self.version = version
    }
}

public enum LLMCPMessageType: String, Codable, Sendable {
    case request
    case response
}

public struct LLMCPConversation: Codable, Equatable, Sendable {
    public let id: String
    public let turn: Int

    public init(id: String, turn: Int) {
        self.id = id
        self.turn = turn
    }
}

public struct LLMCPSender: Codable, Equatable, Sendable {
    public let role: String

    public init(role: String) {
        self.role = role
    }
}

public struct LLMCPTrace: Codable, Equatable, Sendable {
    public let runId: String?
    public let step: Int?

    private enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case step
    }

    public init(runId: String?, step: Int?) {
        self.runId = runId
        self.step = step
    }
}

public struct LLMCPUserMessage: Codable, Equatable, Sendable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

public struct LLMCPTask: Codable, Equatable, Sendable {
    public let name: String
    public let args: [String: JSONValue]?

    public init(name: String, args: [String: JSONValue]?) {
        self.name = name
        self.args = args
    }
}

public struct LLMCPInput: Codable, Equatable, Sendable {
    public let userMessage: LLMCPUserMessage
    public let task: LLMCPTask

    private enum CodingKeys: String, CodingKey {
        case userMessage = "user_message"
        case task
    }

    public init(userMessage: LLMCPUserMessage, task: LLMCPTask) {
        self.userMessage = userMessage
        self.task = task
    }
}

public struct LLMCPOutputSpec: Codable, Equatable, Sendable {
    public let format: String

    public init(format: String) {
        self.format = format
    }
}

public struct LLMCPDocumentSource: Codable, Equatable, Sendable {
    public let browser: String?
    public let tabId: String?

    private enum CodingKeys: String, CodingKey {
        case browser
        case tabId = "tab_id"
    }

    public init(browser: String?, tabId: String?) {
        self.browser = browser
        self.tabId = tabId
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

    public init(docId: String, kind: String, trust: String, source: LLMCPDocumentSource?, content: JSONValue) {
        self.docId = docId
        self.kind = kind
        self.trust = trust
        self.source = source
        self.content = content
    }
}

public struct LLMCPContext: Codable, Equatable, Sendable {
    public let documents: [LLMCPDocument]

    public init(documents: [LLMCPDocument]) {
        self.documents = documents
    }
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

    public init(
        protocolInfo: LLMCPProtocol,
        id: String,
        type: LLMCPMessageType,
        createdAt: String,
        conversation: LLMCPConversation,
        sender: LLMCPSender,
        input: LLMCPInput,
        context: LLMCPContext,
        output: LLMCPOutputSpec,
        trace: LLMCPTrace?
    ) {
        self.protocolInfo = protocolInfo
        self.id = id
        self.type = type
        self.createdAt = createdAt
        self.conversation = conversation
        self.sender = sender
        self.input = input
        self.context = context
        self.output = output
        self.trace = trace
    }
}

public struct LLMCPReply: Codable, Equatable, Sendable {
    public let requestId: String

    private enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
    }

    public init(requestId: String) {
        self.requestId = requestId
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

    public init(docId: String, nodeId: String?, handleId: String?, quote: String?) {
        self.docId = docId
        self.nodeId = nodeId
        self.handleId = handleId
        self.quote = quote
    }
}

public struct LLMCPAssistant: Codable, Equatable, Sendable {
    public let title: String?
    public let render: Document
    public let citations: [LLMCPCitation]?

    public init(title: String?, render: Document, citations: [LLMCPCitation]?) {
        self.title = title
        self.render = render
        self.citations = citations
    }
}

public struct LLMCPToolCall: Codable, Equatable, Sendable {
    public let name: String
    public let arguments: [String: JSONValue]?

    public init(name: String, arguments: [String: JSONValue]?) {
        self.name = name
        self.arguments = arguments
    }
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
