import Foundation

public enum SummaryHeuristics {
    public static func extractKeyFacts(
        text: String,
        title: String = "",
        maxItems: Int = 6
    ) -> [String] {
        let normalized = normalizeWhitespace(text)
        guard !normalized.isEmpty, maxItems > 0 else {
            return []
        }
        let sentences = splitSentences(normalized)
        if sentences.isEmpty {
            return []
        }
        let titleTokens = Set(tokens(from: title).filter { $0.count >= 4 }.map { $0.lowercased() })
        var scored: [(score: Int, index: Int, sentence: String)] = []
        for (index, rawSentence) in sentences.enumerated() {
            var sentence = rawSentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.count < 40 {
                continue
            }
            if sentence.count > 360 {
                sentence = String(sentence.prefix(360)) + "..."
            }
            let score = scoreSentence(sentence, titleTokens: titleTokens)
            if score > 0 {
                scored.append((score, index, sentence))
            }
        }
        if scored.isEmpty {
            return []
        }
        scored.sort { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.sentence.count > rhs.sentence.count
            }
            return lhs.score > rhs.score
        }
        let pickCount = min(maxItems * 2, scored.count)
        let picked = scored.prefix(pickCount)
        let pickedIndexes = Set(picked.map { $0.index })
        var ordered: [String] = []
        for (index, sentence) in sentences.enumerated() {
            if pickedIndexes.contains(index) {
                let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !ordered.contains(trimmed) {
                    ordered.append(trimmed.count > 360 ? String(trimmed.prefix(360)) + "..." : trimmed)
                }
            }
            if ordered.count >= maxItems {
                break
            }
        }
        return ordered
    }

    public static func pickSentences(
        text: String,
        maxItems: Int = 3,
        minLength: Int = 40,
        maxLength: Int = 360
    ) -> [String] {
        let normalized = normalizeWhitespace(text)
        guard !normalized.isEmpty, maxItems > 0 else {
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

    private static func scoreSentence(_ sentence: String, titleTokens: Set<String>) -> Int {
        var score = 0
        let lower = sentence.lowercased()
        if sentence.rangeOfCharacter(from: .decimalDigits) != nil {
            score += 3
        }
        if sentence.contains("%") || sentence.contains("$") {
            score += 1
        }
        if sentence.contains(":") {
            score += 1
        }
        if sentence.contains("(") || sentence.contains(")") {
            score += 1
        }
        if hasUppercaseTokens(sentence) {
            score += 1
        }
        if !titleTokens.isEmpty {
            var hits = 0
            for token in titleTokens where lower.contains(token) {
                hits += 1
            }
            if hits > 0 {
                score += min(2, hits)
            }
        }
        return score
    }

    private static func hasUppercaseTokens(_ sentence: String) -> Bool {
        let tokens = tokens(from: sentence)
        var count = 0
        for token in tokens where token.count >= 3 {
            if token == token.uppercased() || token.first?.isUppercase == true {
                count += 1
            }
            if count >= 2 {
                return true
            }
        }
        return false
    }

    private static func splitSentences(_ text: String) -> [String] {
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

    private static func tokens(from text: String) -> [String] {
        var output: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                output.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            output.append(current)
        }
        return output
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        return text
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .joined(separator: " ")
    }
}
