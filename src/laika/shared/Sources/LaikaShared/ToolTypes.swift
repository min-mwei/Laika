import Foundation

public enum ToolName: String, Codable, CaseIterable, Sendable {
    case browserObserveDom = "browser.observe_dom"
    case browserGetSelectionLinks = "browser.get_selection_links"
    case browserClick = "browser.click"
    case browserType = "browser.type"
    case browserScroll = "browser.scroll"
    case browserOpenTab = "browser.open_tab"
    case browserNavigate = "browser.navigate"
    case browserBack = "browser.back"
    case browserForward = "browser.forward"
    case browserRefresh = "browser.refresh"
    case browserSelect = "browser.select"
    case search = "search"
    case appCalculate = "app.calculate"
    case collectionCreate = "collection.create"
    case collectionAddSources = "collection.add_sources"
    case collectionListSources = "collection.list_sources"
    case sourceCapture = "source.capture"
    case sourceRefresh = "source.refresh"
    case transformListTypes = "transform.list_types"
    case transformRun = "transform.run"
    case artifactSave = "artifact.save"
    case artifactOpen = "artifact.open"
    case artifactShare = "artifact.share"
    case integrationInvoke = "integration.invoke"
}

public struct ToolCall: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: ToolName
    public let arguments: [String: JSONValue]

    public init(id: UUID = UUID(), name: ToolName, arguments: [String: JSONValue]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public enum ToolStatus: String, Codable, Sendable {
    case ok
    case error
    case cancelled
}

public struct ToolResult: Codable, Equatable, Sendable {
    public let toolCallId: UUID
    public let status: ToolStatus
    public let payload: [String: JSONValue]

    public init(toolCallId: UUID, status: ToolStatus, payload: [String: JSONValue]) {
        self.toolCallId = toolCallId
        self.status = status
        self.payload = payload
    }
}
