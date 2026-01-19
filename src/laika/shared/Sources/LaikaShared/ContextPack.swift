import Foundation

public struct ObservedTextBlock: Codable, Equatable, Sendable {
    public let tag: String
    public let role: String
    public let text: String
    public let linkCount: Int
    public let linkDensity: Double

    public init(tag: String, role: String, text: String, linkCount: Int, linkDensity: Double) {
        self.tag = tag
        self.role = role
        self.text = text
        self.linkCount = linkCount
        self.linkDensity = linkDensity
    }
}

public struct ObservedOutlineItem: Codable, Equatable, Sendable {
    public let level: Int
    public let tag: String
    public let role: String
    public let text: String

    public init(level: Int, tag: String, role: String, text: String) {
        self.level = level
        self.tag = tag
        self.role = role
        self.text = text
    }
}

public struct ObservedPrimaryContent: Codable, Equatable, Sendable {
    public let tag: String
    public let role: String
    public let text: String
    public let linkCount: Int
    public let linkDensity: Double

    public init(tag: String, role: String, text: String, linkCount: Int, linkDensity: Double) {
        self.tag = tag
        self.role = role
        self.text = text
        self.linkCount = linkCount
        self.linkDensity = linkDensity
    }
}

public struct Observation: Codable, Equatable, Sendable {
    public let url: String
    public let title: String
    public let text: String
    public let elements: [ObservedElement]
    public let blocks: [ObservedTextBlock]
    public let outline: [ObservedOutlineItem]
    public let primary: ObservedPrimaryContent?

    public init(
        url: String,
        title: String,
        text: String,
        elements: [ObservedElement],
        blocks: [ObservedTextBlock] = [],
        outline: [ObservedOutlineItem] = [],
        primary: ObservedPrimaryContent? = nil
    ) {
        self.url = url
        self.title = title
        self.text = text
        self.elements = elements
        self.blocks = blocks
        self.outline = outline
        self.primary = primary
    }

    private enum CodingKeys: String, CodingKey {
        case url
        case title
        case text
        case elements
        case blocks
        case outline
        case primary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        title = try container.decode(String.self, forKey: .title)
        text = try container.decode(String.self, forKey: .text)
        elements = try container.decode([ObservedElement].self, forKey: .elements)
        blocks = try container.decodeIfPresent([ObservedTextBlock].self, forKey: .blocks) ?? []
        outline = try container.decodeIfPresent([ObservedOutlineItem].self, forKey: .outline) ?? []
        primary = try container.decodeIfPresent(ObservedPrimaryContent.self, forKey: .primary)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        try container.encode(title, forKey: .title)
        try container.encode(text, forKey: .text)
        try container.encode(elements, forKey: .elements)
        try container.encode(blocks, forKey: .blocks)
        try container.encode(outline, forKey: .outline)
        try container.encodeIfPresent(primary, forKey: .primary)
    }
}

public struct ObservedElement: Codable, Equatable, Sendable {
    public let handleId: String
    public let role: String
    public let label: String
    public let boundingBox: BoundingBox
    public let href: String?
    public let inputType: String?

    public init(
        handleId: String,
        role: String,
        label: String,
        boundingBox: BoundingBox,
        href: String? = nil,
        inputType: String? = nil
    ) {
        self.handleId = handleId
        self.role = role
        self.label = label
        self.boundingBox = boundingBox
        self.href = href
        self.inputType = inputType
    }
}

public struct BoundingBox: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct TabSummary: Codable, Equatable, Sendable {
    public let title: String
    public let url: String
    public let origin: String
    public let isActive: Bool

    public init(title: String, url: String, origin: String, isActive: Bool) {
        self.title = title
        self.url = url
        self.origin = origin
        self.isActive = isActive
    }
}

public struct ContextPack: Codable, Equatable, Sendable {
    public let origin: String
    public let mode: SiteMode
    public let observation: Observation
    public let recentToolCalls: [ToolCall]
    public let recentToolResults: [ToolResult]
    public let tabs: [TabSummary]
    public let runId: String?
    public let step: Int?
    public let maxSteps: Int?

    public init(
        origin: String,
        mode: SiteMode,
        observation: Observation,
        recentToolCalls: [ToolCall],
        recentToolResults: [ToolResult] = [],
        tabs: [TabSummary] = [],
        runId: String? = nil,
        step: Int? = nil,
        maxSteps: Int? = nil
    ) {
        self.origin = origin
        self.mode = mode
        self.observation = observation
        self.recentToolCalls = recentToolCalls
        self.recentToolResults = recentToolResults
        self.tabs = tabs
        self.runId = runId
        self.step = step
        self.maxSteps = maxSteps
    }

    private enum CodingKeys: String, CodingKey {
        case origin
        case mode
        case observation
        case recentToolCalls
        case recentToolResults
        case tabs
        case runId
        case step
        case maxSteps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        origin = try container.decode(String.self, forKey: .origin)
        mode = try container.decode(SiteMode.self, forKey: .mode)
        observation = try container.decode(Observation.self, forKey: .observation)
        recentToolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .recentToolCalls) ?? []
        recentToolResults = try container.decodeIfPresent([ToolResult].self, forKey: .recentToolResults) ?? []
        tabs = try container.decodeIfPresent([TabSummary].self, forKey: .tabs) ?? []
        runId = try container.decodeIfPresent(String.self, forKey: .runId)
        step = try container.decodeIfPresent(Int.self, forKey: .step)
        maxSteps = try container.decodeIfPresent(Int.self, forKey: .maxSteps)
    }
}
