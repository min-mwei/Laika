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

    public init(handleId: String, role: String, label: String, boundingBox: BoundingBox) {
        self.handleId = handleId
        self.role = role
        self.label = label
        self.boundingBox = boundingBox
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
    public let tabs: [TabSummary]

    public init(origin: String, mode: SiteMode, observation: Observation, recentToolCalls: [ToolCall], tabs: [TabSummary] = []) {
        self.origin = origin
        self.mode = mode
        self.observation = observation
        self.recentToolCalls = recentToolCalls
        self.tabs = tabs
    }

    private enum CodingKeys: String, CodingKey {
        case origin
        case mode
        case observation
        case recentToolCalls
        case tabs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        origin = try container.decode(String.self, forKey: .origin)
        mode = try container.decode(SiteMode.self, forKey: .mode)
        observation = try container.decode(Observation.self, forKey: .observation)
        recentToolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .recentToolCalls) ?? []
        tabs = try container.decodeIfPresent([TabSummary].self, forKey: .tabs) ?? []
    }
}
