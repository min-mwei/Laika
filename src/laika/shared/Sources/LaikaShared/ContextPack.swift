import Foundation

public struct Observation: Codable, Equatable, Sendable {
    public let url: String
    public let title: String
    public let text: String
    public let elements: [ObservedElement]

    public init(url: String, title: String, text: String, elements: [ObservedElement]) {
        self.url = url
        self.title = title
        self.text = text
        self.elements = elements
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
