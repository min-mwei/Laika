import Foundation

public struct ObservedTextBlock: Codable, Equatable, Sendable {
    public let tag: String
    public let role: String
    public let text: String
    public let linkCount: Int
    public let linkDensity: Double
    public let handleId: String?

    public init(
        tag: String,
        role: String,
        text: String,
        linkCount: Int,
        linkDensity: Double,
        handleId: String? = nil
    ) {
        self.tag = tag
        self.role = role
        self.text = text
        self.linkCount = linkCount
        self.linkDensity = linkDensity
        self.handleId = handleId
    }

    private enum CodingKeys: String, CodingKey {
        case tag
        case role
        case text
        case linkCount
        case linkDensity
        case handleId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tag = try container.decode(String.self, forKey: .tag)
        role = try container.decode(String.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        linkCount = try container.decode(Int.self, forKey: .linkCount)
        linkDensity = try container.decode(Double.self, forKey: .linkDensity)
        handleId = try container.decodeIfPresent(String.self, forKey: .handleId)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tag, forKey: .tag)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encode(linkCount, forKey: .linkCount)
        try container.encode(linkDensity, forKey: .linkDensity)
        try container.encodeIfPresent(handleId, forKey: .handleId)
    }
}

public struct ObservedItem: Codable, Equatable, Sendable {
    public let title: String
    public let url: String
    public let snippet: String
    public let tag: String
    public let linkCount: Int
    public let linkDensity: Double
    public let handleId: String?
    public let links: [ObservedItemLink]

    public init(
        title: String,
        url: String,
        snippet: String,
        tag: String,
        linkCount: Int,
        linkDensity: Double,
        handleId: String? = nil,
        links: [ObservedItemLink] = []
    ) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.tag = tag
        self.linkCount = linkCount
        self.linkDensity = linkDensity
        self.handleId = handleId
        self.links = links
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case url
        case snippet
        case tag
        case linkCount
        case linkDensity
        case handleId
        case links
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(String.self, forKey: .url)
        snippet = try container.decode(String.self, forKey: .snippet)
        tag = try container.decode(String.self, forKey: .tag)
        linkCount = try container.decode(Int.self, forKey: .linkCount)
        linkDensity = try container.decode(Double.self, forKey: .linkDensity)
        handleId = try container.decodeIfPresent(String.self, forKey: .handleId)
        links = try container.decodeIfPresent([ObservedItemLink].self, forKey: .links) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(url, forKey: .url)
        try container.encode(snippet, forKey: .snippet)
        try container.encode(tag, forKey: .tag)
        try container.encode(linkCount, forKey: .linkCount)
        try container.encode(linkDensity, forKey: .linkDensity)
        try container.encodeIfPresent(handleId, forKey: .handleId)
        try container.encode(links, forKey: .links)
    }
}

public struct ObservedItemLink: Codable, Equatable, Sendable {
    public let title: String
    public let url: String
    public let handleId: String?

    public init(title: String, url: String, handleId: String? = nil) {
        self.title = title
        self.url = url
        self.handleId = handleId
    }
}

public struct ObservedComment: Codable, Equatable, Sendable {
    public let text: String
    public let author: String?
    public let age: String?
    public let score: String?
    public let depth: Int
    public let handleId: String?

    public init(
        text: String,
        author: String? = nil,
        age: String? = nil,
        score: String? = nil,
        depth: Int = 0,
        handleId: String? = nil
    ) {
        self.text = text
        self.author = author
        self.age = age
        self.score = score
        self.depth = depth
        self.handleId = handleId
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
    public let handleId: String?

    public init(
        tag: String,
        role: String,
        text: String,
        linkCount: Int,
        linkDensity: Double,
        handleId: String? = nil
    ) {
        self.tag = tag
        self.role = role
        self.text = text
        self.linkCount = linkCount
        self.linkDensity = linkDensity
        self.handleId = handleId
    }

    private enum CodingKeys: String, CodingKey {
        case tag
        case role
        case text
        case linkCount
        case linkDensity
        case handleId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tag = try container.decode(String.self, forKey: .tag)
        role = try container.decode(String.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        linkCount = try container.decode(Int.self, forKey: .linkCount)
        linkDensity = try container.decode(Double.self, forKey: .linkDensity)
        handleId = try container.decodeIfPresent(String.self, forKey: .handleId)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tag, forKey: .tag)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encode(linkCount, forKey: .linkCount)
        try container.encode(linkDensity, forKey: .linkDensity)
        try container.encodeIfPresent(handleId, forKey: .handleId)
    }
}

public struct Observation: Codable, Equatable, Sendable {
    public let url: String
    public let title: String
    public let text: String
    public let elements: [ObservedElement]
    public let blocks: [ObservedTextBlock]
    public let items: [ObservedItem]
    public let outline: [ObservedOutlineItem]
    public let primary: ObservedPrimaryContent?
    public let comments: [ObservedComment]

    public init(
        url: String,
        title: String,
        text: String,
        elements: [ObservedElement],
        blocks: [ObservedTextBlock] = [],
        items: [ObservedItem] = [],
        outline: [ObservedOutlineItem] = [],
        primary: ObservedPrimaryContent? = nil,
        comments: [ObservedComment] = []
    ) {
        self.url = url
        self.title = title
        self.text = text
        self.elements = elements
        self.blocks = blocks
        self.items = items
        self.outline = outline
        self.primary = primary
        self.comments = comments
    }

    private enum CodingKeys: String, CodingKey {
        case url
        case title
        case text
        case elements
        case blocks
        case items
        case outline
        case primary
        case comments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        title = try container.decode(String.self, forKey: .title)
        text = try container.decode(String.self, forKey: .text)
        elements = try container.decode([ObservedElement].self, forKey: .elements)
        blocks = try container.decodeIfPresent([ObservedTextBlock].self, forKey: .blocks) ?? []
        items = try container.decodeIfPresent([ObservedItem].self, forKey: .items) ?? []
        outline = try container.decodeIfPresent([ObservedOutlineItem].self, forKey: .outline) ?? []
        primary = try container.decodeIfPresent(ObservedPrimaryContent.self, forKey: .primary)
        comments = try container.decodeIfPresent([ObservedComment].self, forKey: .comments) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        try container.encode(title, forKey: .title)
        try container.encode(text, forKey: .text)
        try container.encode(elements, forKey: .elements)
        try container.encode(blocks, forKey: .blocks)
        try container.encode(items, forKey: .items)
        try container.encode(outline, forKey: .outline)
        try container.encodeIfPresent(primary, forKey: .primary)
        try container.encode(comments, forKey: .comments)
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
    public let goalPlan: GoalPlan?
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
        goalPlan: GoalPlan? = nil,
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
        self.goalPlan = goalPlan
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
        case goalPlan
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
        goalPlan = try container.decodeIfPresent(GoalPlan.self, forKey: .goalPlan)
        runId = try container.decodeIfPresent(String.self, forKey: .runId)
        step = try container.decodeIfPresent(Int.self, forKey: .step)
        maxSteps = try container.decodeIfPresent(Int.self, forKey: .maxSteps)
    }
}
