import Foundation

public enum SnippetFormatter {
    public static func format(
        _ snippet: String,
        title: String? = nil,
        maxChars: Int = 180
    ) -> String {
        var output = TextUtils.normalizeWhitespace(snippet)
        if output.isEmpty {
            return ""
        }
        output = stripLeadingOrdinal(output)
        if let title, !title.isEmpty {
            let normalizedTitle = TextUtils.normalizeWhitespace(title)
            if !normalizedTitle.isEmpty {
                let lowerOutput = output.lowercased()
                let lowerTitle = normalizedTitle.lowercased()
                if lowerOutput.hasPrefix(lowerTitle) {
                    output = String(output.dropFirst(normalizedTitle.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    output = trimLeadingPunctuation(output)
                }
            }
        }
        output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty {
            return ""
        }
        return TextUtils.truncate(output, maxChars: maxChars)
    }

    private static func stripLeadingOrdinal(_ text: String) -> String {
        let pattern = "^\\s*\\d{1,3}[\\.)-]\\s*"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let stripped = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimLeadingPunctuation(_ text: String) -> String {
        var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let leading = CharacterSet(charactersIn: ":-.[]()")
        while let first = output.unicodeScalars.first, leading.contains(first) {
            output.removeFirst()
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return output
    }
}
