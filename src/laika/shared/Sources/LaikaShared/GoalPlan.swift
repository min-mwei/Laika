import Foundation

public struct GoalPlan: Codable, Equatable, Sendable {
    public enum Intent: String, Codable, Sendable {
        case pageSummary = "page_summary"
        case itemSummary = "item_summary"
        case commentSummary = "comment_summary"
        case action = "action"
        case unknown = "unknown"
    }

    public let intent: Intent
    public let itemIndex: Int?
    public let itemQuery: String?
    public let wantsComments: Bool

    public init(
        intent: Intent,
        itemIndex: Int? = nil,
        itemQuery: String? = nil,
        wantsComments: Bool = false
    ) {
        self.intent = intent
        self.itemIndex = itemIndex
        self.itemQuery = itemQuery
        self.wantsComments = wantsComments
    }

    public static let unknown = GoalPlan(intent: .unknown, itemIndex: nil, itemQuery: nil, wantsComments: false)
}
