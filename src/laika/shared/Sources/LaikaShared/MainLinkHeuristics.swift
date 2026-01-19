import Foundation

public struct MainLinkHeuristics {
    private static func isMetadataLabel(_ label: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return true
        }
        var alnumCount = 0
        var digitCount = 0
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                alnumCount += 1
                if CharacterSet.decimalDigits.contains(scalar) {
                    digitCount += 1
                }
            }
        }
        if alnumCount == 0 {
            return true
        }
        if trimmed.count <= 3 && digitCount > 0 {
            return true
        }
        let digitRatio = alnumCount > 0 ? Double(digitCount) / Double(alnumCount) : 0
        if trimmed.count <= 8 && digitRatio >= 0.6 {
            return true
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
            if label.count < 4 {
                return false
            }
            if label.count > 200 {
                return false
            }
            return true
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
