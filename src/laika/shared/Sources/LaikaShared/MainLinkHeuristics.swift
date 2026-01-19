import Foundation

public struct MainLinkHeuristics {
    private static let excludedLabels: Set<String> = [
        "new", "past", "comments", "ask", "show", "jobs", "submit", "login", "logout",
        "hide", "reply", "flag", "edit", "more", "next", "prev", "previous", "upvote", "downvote"
    ]

    private static func isMetadataLabel(_ label: String) -> Bool {
        let lower = label.lowercased()
        if excludedLabels.contains(lower) {
            return true
        }
        if lower == "discuss" {
            return true
        }
        let hasDigits = lower.rangeOfCharacter(from: .decimalDigits) != nil
        if hasDigits && lower.contains("comment") {
            return true
        }
        if hasDigits && lower.contains("point") {
            return true
        }
        if hasDigits && lower.contains("ago") {
            if lower.contains("minute") || lower.contains("hour") || lower.contains("day") || lower.contains("week") {
                return true
            }
        }
        return false
    }

    public static func candidates(from elements: [ObservedElement]) -> [ObservedElement] {
        return elements.filter { element in
            guard element.role.lowercased() == "a" else {
                return false
            }
            guard let href = element.href, !href.isEmpty else {
                return false
            }
            let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty {
                return false
            }
            if isMetadataLabel(label) {
                return false
            }
            if label.count < 12 {
                return false
            }
            return label.contains(" ")
        }
    }

    public static func labels(from elements: [ObservedElement], limit: Int? = nil) -> [String] {
        var output: [String] = []
        var seen: Set<String> = []
        let candidates = candidates(from: elements)
        for element in candidates {
            let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = label.lowercased()
            if seen.contains(key) {
                continue
            }
            output.append(label)
            seen.insert(key)
            if let limit, output.count >= limit {
                break
            }
        }
        return output
    }
}
