import Foundation

public enum TextUtils {
    public static func normalizeWhitespace(_ text: String) -> String {
        return text
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .joined(separator: " ")
    }

    public static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var buffer = ""
        for scalar in text.unicodeScalars {
            buffer.unicodeScalars.append(scalar)
            if isSentenceTerminator(scalar) {
                let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    sentences.append(trimmed)
                }
                buffer = ""
            }
        }
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            sentences.append(tail)
        }
        return sentences
    }

    public static func firstSentences(
        _ text: String,
        maxItems: Int,
        minLength: Int = 40,
        maxLength: Int = 360
    ) -> [String] {
        guard maxItems > 0 else {
            return []
        }
        let normalized = normalizeWhitespace(text)
        if normalized.isEmpty {
            return []
        }
        let sentences = splitSentences(normalized)
        var output: [String] = []
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count < minLength {
                continue
            }
            if trimmed.count > maxLength {
                output.append(String(trimmed.prefix(maxLength)) + "...")
            } else {
                output.append(trimmed)
            }
            if output.count >= maxItems {
                break
            }
        }
        return output
    }

    public static func truncate(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else {
            return text
        }
        return String(text.prefix(maxChars)) + "..."
    }

    public static func stripMarkdown(_ text: String) -> String {
        if text.isEmpty {
            return text
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let cleaned = lines.map { rawLine -> String in
            var line = String(rawLine)
            line = line.replacingOccurrences(of: "**", with: "")
            line = line.replacingOccurrences(of: "__", with: "")
            line = line.replacingOccurrences(of: "`", with: "")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let prefixes = ["- ", "* ", "• ", "– ", "# "]
            for prefix in prefixes {
                if trimmed.hasPrefix(prefix) {
                    line = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                    return line
                }
            }
            if let stripped = stripNumericPrefix(trimmed) {
                return stripped
            }
            return line
        }
        return cleaned.joined(separator: "\n")
    }

    private static func stripNumericPrefix(_ line: String) -> String? {
        let scalars = Array(line.unicodeScalars)
        guard scalars.count >= 3 else {
            return nil
        }
        var idx = 0
        while idx < scalars.count, CharacterSet.decimalDigits.contains(scalars[idx]) {
            idx += 1
        }
        guard idx > 0 && idx < scalars.count else {
            return nil
        }
        let punct = scalars[idx]
        guard punct == "." || punct == ")" || punct == "-" else {
            return nil
        }
        let next = idx + 1
        guard next < scalars.count else {
            return nil
        }
        guard CharacterSet.whitespaces.contains(scalars[next]) else {
            return nil
        }
        let start = line.index(line.startIndex, offsetBy: next + 1)
        let stripped = line[start...].trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? nil : stripped
    }

    private static func isSentenceTerminator(_ scalar: UnicodeScalar) -> Bool {
        if CharacterSet.newlines.contains(scalar) {
            return true
        }
        if CharacterSet.punctuationCharacters.contains(scalar) {
            let skip = CharacterSet(charactersIn: ",;:()[]{}\"'`")
            return !skip.contains(scalar)
        }
        return false
    }
}
