import Foundation
import LaikaShared

enum GoalPlanParser {
    private struct ModelOutput: Decodable {
        let intent: String?
        let item_index: Int?
        let item_query: String?
        let wants_comments: Bool?
    }

    static func parse(_ text: String) -> GoalPlan {
        let sanitized = ModelOutputParser.sanitize(text)
        guard let jsonString = ModelOutputParser.extractJSONObject(from: sanitized),
              let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ModelOutput.self, from: data)
        else {
            return GoalPlan.unknown
        }

        let intent = GoalPlan.Intent(rawValue: decoded.intent?.lowercased() ?? "") ?? .unknown
        let index = normalizeIndex(decoded.item_index)
        let query = decoded.item_query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantsComments = decoded.wants_comments ?? (intent == .commentSummary)
        return GoalPlan(intent: intent, itemIndex: index, itemQuery: query?.isEmpty == true ? nil : query, wantsComments: wantsComments)
    }

    private static func normalizeIndex(_ raw: Int?) -> Int? {
        guard let raw else {
            return nil
        }
        if raw <= 0 {
            return nil
        }
        return raw
    }
}
