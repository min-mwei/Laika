import Foundation

public struct MainLinkHeuristics {
    private static let excludedLabels: Set<String> = [
        "new", "past", "comments", "ask", "show", "jobs", "submit", "login", "logout",
        "hide", "reply", "flag", "edit", "more", "next", "prev", "previous", "upvote", "downvote"
    ]

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
            if excludedLabels.contains(label.lowercased()) {
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
